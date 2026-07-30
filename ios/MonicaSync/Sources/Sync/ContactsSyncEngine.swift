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
/// - When "sync only selected contacts" is on, only the chosen people are
///   mirrored; deselecting someone removes their mirror on the next pass.
/// - Every mirrored contact carries a "Monica" URL pointing at its profile on
///   the server. The URL doubles as an adoption marker, so reinstalling the
///   app re-links existing contacts instead of duplicating them.
/// - Local edits are preserved until the same contact changes on the server;
///   with "push local changes" enabled, email/phone edits made on the device
///   are written back to Monica.
final class ContactsSyncEngine {
    private let backend: any MonicaBackend
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

    init(backend: any MonicaBackend, mappings: SyncMappingStore, settings: SyncSettings) {
        self.backend = backend
        self.mappings = mappings
        self.settings = settings
    }

    // MARK: - Entry point

    func sync() async throws -> ContactSyncSummary {
        try await ensureAccess()

        var summary = ContactSyncSummary()

        // Selection turned on but nothing picked yet: treat as "not configured"
        // rather than as "mirror nobody" — otherwise flipping the toggle would
        // wipe every mirrored contact before the user gets to choose.
        if settings.contactSelectionEnabled && settings.selectedContactIDs.isEmpty {
            return summary
        }

        let selected = try await backend.fetchContacts()
            .filter { settings.includesContact(id: $0.id) }
        let adoptionIndex = buildAdoptionIndex()

        for remote in selected {
            try await syncOne(remote, adoptionIndex: adoptionIndex, summary: &summary)
        }

        if settings.removeOrphans {
            // Anything mapped but no longer on the server — or no longer
            // selected — loses its mirror.
            summary.deleted += removeOrphans(remoteIDs: Set(selected.map(\.id)))
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
        _ remote: SyncContact,
        adoptionIndex: [String: String],
        summary: inout ContactSyncSummary
    ) async throws {
        let key = SyncMappingStore.key("contact", remote.id)
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
        if record == nil, let adoptedID = adoptionIndex[remote.webURL],
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
                let changes = Self.fieldChanges(local: local, remote: remote)
                guard !changes.isEmpty else { return }
                try await backend.pushContactFieldChanges(contact: remote, changes: changes)
                summary.pushedToServer += 1
                // Re-fetch so the stored remote baseline includes the fields
                // we just wrote.
                let refreshed = (try? await backend.fetchContact(id: remote.id)) ?? remote
                mappings[key] = SyncRecord(
                    localIdentifier: currentRecord.localIdentifier,
                    remoteFingerprint: Fingerprint.of(Self.remoteParts(of: refreshed)),
                    localFingerprint: localFingerprint
                )
                return
            }

            // Server-side change (possibly alongside a local one): Monica wins.
            let mutable = local.mutableCopy() as! CNMutableContact
            apply(remote, to: mutable, avatarData: nil)
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
        var avatarData: Data?
        if let avatarURL = remote.avatarURL {
            avatarData = await backend.fetchAvatarData(from: avatarURL)
        }
        apply(remote, to: created, avatarData: avatarData)
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

    private func apply(_ remote: SyncContact, to contact: CNMutableContact, avatarData: Data?) {
        contact.givenName = remote.firstName ?? ""
        contact.familyName = remote.lastName ?? ""
        contact.nickname = remote.nickname ?? ""
        contact.organizationName = remote.company ?? ""
        contact.jobTitle = remote.jobTitle ?? ""

        contact.emailAddresses = remote.emails.map {
            CNLabeledValue(label: CNLabelHome, value: $0 as NSString)
        }
        contact.phoneNumbers = remote.phones.map {
            CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: $0))
        }

        contact.postalAddresses = remote.addresses.map { address in
            let postal = CNMutablePostalAddress()
            postal.street = address.street ?? ""
            postal.city = address.city ?? ""
            postal.state = address.province ?? ""
            postal.postalCode = address.postalCode ?? ""
            postal.country = address.country ?? ""
            let label: String
            switch address.label?.lowercased() {
            case "home": label = CNLabelHome
            case "work": label = CNLabelWork
            default: label = address.label ?? CNLabelOther
            }
            return CNLabeledValue(label: label, value: postal)
        }

        // Keep any URLs the user added themselves; ours is identified by label.
        var urls = contact.urlAddresses.filter { $0.label != Self.urlLabel }
        urls.insert(CNLabeledValue(label: Self.urlLabel, value: remote.webURL as NSString), at: 0)
        contact.urlAddresses = urls

        if let birthday = remote.birthday {
            var components = DateComponents()
            components.day = birthday.day
            components.month = birthday.month
            components.year = birthday.year
            contact.birthday = components
        } else {
            contact.birthday = nil
        }

        if let avatarData {
            contact.imageData = avatarData
        }
    }

    // MARK: - Local edit detection

    /// Device-side email/phone additions and removals relative to the server.
    static func fieldChanges(local: CNContact, remote: SyncContact) -> ContactFieldChanges {
        var changes = ContactFieldChanges()

        let localEmails = local.emailAddresses.map { ($0.value as String) }
        let localEmailSet = Set(localEmails.map { $0.lowercased() })
        let remoteEmailSet = Set(remote.emails.map { $0.lowercased() })
        changes.addedEmails = localEmails.filter { !remoteEmailSet.contains($0.lowercased()) }
        changes.removedEmails = remote.emails.filter { !localEmailSet.contains($0.lowercased()) }

        let localPhones = local.phoneNumbers.map { $0.value.stringValue }
        let localPhoneSet = Set(localPhones.map(normalizedPhone))
        let remotePhoneSet = Set(remote.phones.map(normalizedPhone))
        changes.addedPhones = localPhones.filter { !remotePhoneSet.contains(normalizedPhone($0)) }
        changes.removedPhones = remote.phones.filter { !localPhoneSet.contains(normalizedPhone($0)) }

        return changes
    }

    // MARK: - Orphan removal

    private func removeOrphans(remoteIDs: Set<String>) -> Int {
        var removed = 0
        for key in mappings.keys(withPrefix: "contact:") {
            let id = String(key.dropFirst("contact:".count))
            guard !remoteIDs.contains(id), let record = mappings[key] else { continue }
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
        return group
    }

    // MARK: - Fingerprints

    /// Both sides canonicalize to the same field list so an in-sync pair
    /// yields `remoteParts == localParts`.
    private static func remoteParts(of contact: SyncContact) -> [String?] {
        var parts: [String?] = [
            contact.firstName,
            contact.lastName,
            contact.nickname,
            contact.company,
            contact.jobTitle,
        ]
        parts.append(contact.birthday.map {
            birthdayString(year: $0.year, month: $0.month, day: $0.day)
        })
        parts.append(contact.emails.map { $0.lowercased() }.sorted().joined(separator: "|"))
        parts.append(contact.phones.map(normalizedPhone).sorted().joined(separator: "|"))
        parts.append(
            contact.addresses.map(\.oneLine).sorted().joined(separator: "|")
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
