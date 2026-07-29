import Contacts
import Foundation

struct ContactSyncSummary {
    var created = 0
    var updated = 0
    var deleted = 0
    var pushedToServer = 0
}

/// Mirrors Monica people into the iPhone address book.
///
/// - Monica is the source of truth: server-side edits always win.
/// - Every mirrored contact carries a "Monica" URL pointing at its profile on
///   the server. The URL doubles as an adoption marker, so reinstalling the
///   app re-links existing contacts instead of duplicating them.
/// - Local edits are preserved until the same contact changes on the server;
///   with "push local changes" enabled, email/phone edits made on the device
///   are written back to Monica as contact fields.
final class ContactsSyncEngine {
    private let client: MonicaAPIClient
    private let mappings: SyncMappingStore
    private let settings: SyncSettings
    private let store = CNContactStore()

    private static let groupName = "Monica"
    private static let urlLabel = "Monica"

    private static let keysToFetch: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactUrlAddressesKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
    ]

    init(client: MonicaAPIClient, mappings: SyncMappingStore, settings: SyncSettings) {
        self.client = client
        self.mappings = mappings
        self.settings = settings
    }

    // MARK: - Entry point

    func sync() async throws -> ContactSyncSummary {
        try await ensureAccess()

        var summary = ContactSyncSummary()
        let remoteContacts = try await client.fetchAllContacts().filter(\.isSyncable)
        let adoptionIndex = buildAdoptionIndex()
        var fieldTypes: [MonicaContactFieldType]?

        for remote in remoteContacts {
            try await syncOne(
                remote,
                adoptionIndex: adoptionIndex,
                fieldTypes: &fieldTypes,
                summary: &summary
            )
        }

        if settings.removeOrphans {
            summary.deleted += removeOrphans(remoteIDs: Set(remoteContacts.map(\.id)))
        }

        mappings.save()
        return summary
    }

    // MARK: - Permissions

    private func ensureAccess() async throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return }
        if status == .notDetermined {
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            if granted { return }
        }
        throw SyncError.permissionDenied("Contacts")
    }

    // MARK: - Per-contact sync

    private func syncOne(
        _ remote: MonicaContact,
        adoptionIndex: [String: String],
        fieldTypes: inout [MonicaContactFieldType]?,
        summary: inout ContactSyncSummary
    ) async throws {
        let key = SyncMappingStore.key("contact", remote.id)
        let webURL = client.serverConfig
            .webURL(forContactID: remote.id, hashID: remote.hashID)
            .absoluteString
        let remoteFingerprint = Fingerprint.of(Self.remoteParts(of: remote))

        var record = mappings[key]
        var existing = record.flatMap { $0.deletedLocally ? nil : fetchLocal($0.localIdentifier) }

        // The user deleted the mirror on the device — honor that choice.
        if let current = record {
            if current.deletedLocally { return }
            if existing == nil {
                var tombstone = current
                tombstone.deletedLocally = true
                mappings[key] = tombstone
                return
            }
        }

        // No mapping yet: adopt a contact that already carries our marker URL
        // (e.g. after a reinstall) before creating a duplicate.
        if record == nil, let adoptedID = adoptionIndex[webURL],
           let adopted = fetchLocal(adoptedID) {
            record = SyncRecord(
                localIdentifier: adoptedID,
                remoteFingerprint: "",
                localFingerprint: ""
            )
            existing = adopted
        }

        if let currentRecord = record, let local = existing {
            let localFingerprint = Fingerprint.of(Self.localParts(of: local))
            let remoteChanged = remoteFingerprint != currentRecord.remoteFingerprint
            let localChanged = localFingerprint != currentRecord.localFingerprint

            if !remoteChanged && !localChanged { return }

            if localChanged && !remoteChanged {
                guard settings.pushLocalContactChanges else { return }
                try await pushLocalFieldChanges(local: local, remote: remote, fieldTypes: &fieldTypes)
                summary.pushedToServer += 1
                // Re-fetch so the stored remote baseline includes the fields
                // we just wrote.
                let refreshed = (try? await client.fetchContact(id: remote.id)) ?? remote
                mappings[key] = SyncRecord(
                    localIdentifier: currentRecord.localIdentifier,
                    remoteFingerprint: Fingerprint.of(Self.remoteParts(of: refreshed)),
                    localFingerprint: localFingerprint
                )
                return
            }

            // Server-side change (possibly alongside a local one): Monica wins.
            let mutable = local.mutableCopy() as! CNMutableContact
            apply(remote, webURL: webURL, to: mutable, avatarData: nil)
            let request = CNSaveRequest()
            request.update(mutable)
            try store.execute(request)
            summary.updated += 1
            mappings[key] = SyncRecord(
                localIdentifier: currentRecord.localIdentifier,
                remoteFingerprint: remoteFingerprint,
                localFingerprint: Fingerprint.of(Self.localParts(of: mutable))
            )
            return
        }

        // Brand new: create the mirror.
        let created = CNMutableContact()
        let avatarData = await fetchAvatarIfAny(for: remote)
        apply(remote, webURL: webURL, to: created, avatarData: avatarData)
        let request = CNSaveRequest()
        request.add(created, toContainerWithIdentifier: nil)
        if let group = try? ensureGroup() {
            request.addMember(created, to: group)
        }
        try store.execute(request)
        summary.created += 1
        mappings[key] = SyncRecord(
            localIdentifier: created.identifier,
            remoteFingerprint: remoteFingerprint,
            localFingerprint: Fingerprint.of(Self.localParts(of: created))
        )
    }

    // MARK: - Applying remote state

    private func apply(
        _ remote: MonicaContact,
        webURL: String,
        to contact: CNMutableContact,
        avatarData: Data?
    ) {
        contact.givenName = remote.firstName ?? ""
        contact.familyName = remote.lastName ?? ""
        contact.nickname = remote.nickname ?? ""
        contact.organizationName = remote.information?.career?.company ?? ""
        contact.jobTitle = remote.information?.career?.job ?? ""

        contact.emailAddresses = remote.emails.map {
            CNLabeledValue(label: CNLabelHome, value: $0 as NSString)
        }
        contact.phoneNumbers = remote.phones.map {
            CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: $0))
        }

        contact.postalAddresses = (remote.addresses ?? []).map { address in
            let postal = CNMutablePostalAddress()
            postal.street = address.street ?? ""
            postal.city = address.city ?? ""
            postal.state = address.province ?? ""
            postal.postalCode = address.postalCode ?? ""
            postal.country = address.country?.name ?? ""
            let label: String
            switch address.name?.lowercased() {
            case "home": label = CNLabelHome
            case "work": label = CNLabelWork
            default: label = address.name ?? CNLabelOther
            }
            return CNLabeledValue(label: label, value: postal)
        }

        // Keep any URLs the user added themselves; ours is identified by label.
        var urls = contact.urlAddresses.filter { $0.label != Self.urlLabel }
        urls.insert(CNLabeledValue(label: Self.urlLabel, value: webURL as NSString), at: 0)
        contact.urlAddresses = urls

        if let birthdate = remote.information?.dates?.birthdate,
           let date = birthdate.date,
           birthdate.isAgeBased != true {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            var components = calendar.dateComponents([.year, .month, .day], from: date)
            if birthdate.isYearUnknown == true { components.year = nil }
            contact.birthday = components
        } else {
            contact.birthday = nil
        }

        if let avatarData {
            contact.imageData = avatarData
        }
    }

    private func fetchAvatarIfAny(for remote: MonicaContact) async -> Data? {
        guard let avatar = remote.information?.avatar,
              let url = avatar.url,
              avatar.source != "default"
        else { return nil }
        return await client.fetchAvatarData(from: url)
    }

    // MARK: - Pushing local edits

    /// Writes device-side email/phone additions and removals back to Monica
    /// as contact fields. Other fields stay device-only until the server-side
    /// contact changes.
    private func pushLocalFieldChanges(
        local: CNContact,
        remote: MonicaContact,
        fieldTypes: inout [MonicaContactFieldType]?
    ) async throws {
        if fieldTypes == nil {
            fieldTypes = try await client.fetchContactFieldTypes()
        }
        guard let types = fieldTypes else { return }
        let emailType = types.first { $0.kind(matches: "email") }
        let phoneType = types.first { $0.kind(matches: "phone") }

        let localEmails = Set(local.emailAddresses.map { ($0.value as String).lowercased() })
        let remoteEmails = Set(remote.emails.map { $0.lowercased() })
        if let emailType {
            for added in localEmails.subtracting(remoteEmails) {
                try await client.createContactField(
                    contactID: remote.id, typeID: emailType.id, value: added
                )
            }
            for removed in remoteEmails.subtracting(localEmails) {
                if let field = (remote.contactFields ?? []).first(where: {
                    $0.contactFieldType?.kind(matches: "email") == true
                        && $0.content?.lowercased() == removed
                }) {
                    try await client.deleteContactField(id: field.id)
                }
            }
        }

        let localPhones = Set(local.phoneNumbers.map { Self.normalizedPhone($0.value.stringValue) })
        let remotePhones = Set(remote.phones.map(Self.normalizedPhone))
        if let phoneType {
            for added in local.phoneNumbers
            where !remotePhones.contains(Self.normalizedPhone(added.value.stringValue)) {
                try await client.createContactField(
                    contactID: remote.id, typeID: phoneType.id, value: added.value.stringValue
                )
            }
            for field in remote.contactFields ?? []
            where field.contactFieldType?.kind(matches: "phone") == true {
                let content = Self.normalizedPhone(field.content ?? "")
                if !content.isEmpty && !localPhones.contains(content) {
                    try await client.deleteContactField(id: field.id)
                }
            }
        }
    }

    // MARK: - Orphan removal

    private func removeOrphans(remoteIDs: Set<Int>) -> Int {
        var removed = 0
        for key in mappings.keys(withPrefix: "contact:") {
            guard let id = Int(key.split(separator: ":")[1]), !remoteIDs.contains(id),
                  let record = mappings[key]
            else { continue }
            if !record.deletedLocally, let local = fetchLocal(record.localIdentifier) {
                let request = CNSaveRequest()
                request.delete(local.mutableCopy() as! CNMutableContact)
                if (try? store.execute(request)) != nil { removed += 1 }
            }
            mappings.remove(key)
        }
        return removed
    }

    // MARK: - Lookup helpers

    private func fetchLocal(_ identifier: String) -> CNContact? {
        try? store.unifiedContact(withIdentifier: identifier, keysToFetch: Self.keysToFetch)
    }

    /// Builds `marker URL → contact identifier` over the whole address book so
    /// previously synced contacts can be re-linked without a mapping file.
    private func buildAdoptionIndex() -> [String: String] {
        var index: [String: String] = [:]
        let keys = [
            CNContactUrlAddressesKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, _ in
            for url in contact.urlAddresses where url.label == Self.urlLabel {
                index[url.value as String] = contact.identifier
            }
        }
        return index
    }

    private func ensureGroup() throws -> CNGroup {
        if let group = try store.groups(matching: nil)
            .first(where: { $0.name == Self.groupName }) {
            return group
        }
        let group = CNMutableGroup()
        group.name = Self.groupName
        let request = CNSaveRequest()
        request.add(group, toContainerWithIdentifier: nil)
        try store.execute(request)
        return group.copy() as! CNGroup
    }

    // MARK: - Fingerprints

    /// Both sides canonicalize to the same field list so an in-sync pair
    /// yields `remoteParts == localParts`.
    private static func remoteParts(of contact: MonicaContact) -> [String?] {
        var parts: [String?] = [
            contact.firstName,
            contact.lastName,
            contact.nickname,
            contact.information?.career?.company,
            contact.information?.career?.job,
        ]
        parts.append(birthdayPart(
            date: contact.information?.dates?.birthdate?.date,
            yearUnknown: contact.information?.dates?.birthdate?.isYearUnknown == true
                || contact.information?.dates?.birthdate?.isAgeBased == true
        ))
        parts.append(contact.emails.map { $0.lowercased() }.sorted().joined(separator: "|"))
        parts.append(contact.phones.map(normalizedPhone).sorted().joined(separator: "|"))
        parts.append(
            (contact.addresses ?? [])
                .map(\.oneLine)
                .sorted()
                .joined(separator: "|")
        )
        return parts
    }

    private static func localParts(of contact: CNContact) -> [String?] {
        var parts: [String?] = [
            contact.givenName,
            contact.familyName,
            contact.nickname,
            contact.organizationName,
            contact.jobTitle,
        ]
        if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
            parts.append(birthdayString(year: birthday.year, month: month, day: day))
        } else {
            parts.append(nil)
        }
        parts.append(
            contact.emailAddresses
                .map { ($0.value as String).lowercased() }
                .sorted()
                .joined(separator: "|")
        )
        parts.append(
            contact.phoneNumbers
                .map { normalizedPhone($0.value.stringValue) }
                .sorted()
                .joined(separator: "|")
        )
        parts.append(
            contact.postalAddresses
                .map { labeled -> String in
                    let address = labeled.value
                    return [address.street, address.city, address.state,
                            address.postalCode, address.country]
                        .filter { !$0.isEmpty }
                        .joined(separator: ", ")
                }
                .sorted()
                .joined(separator: "|")
        )
        return parts
    }

    private static func birthdayPart(date: Date?, yearUnknown: Bool) -> String? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let month = components.month, let day = components.day else { return nil }
        return birthdayString(year: yearUnknown ? nil : components.year, month: month, day: day)
    }

    private static func birthdayString(year: Int?, month: Int, day: Int) -> String {
        if let year {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        return String(format: "--%02d-%02d", month, day)
    }

    static func normalizedPhone(_ raw: String) -> String {
        raw.filter { $0.isNumber || $0 == "+" }
    }
}
