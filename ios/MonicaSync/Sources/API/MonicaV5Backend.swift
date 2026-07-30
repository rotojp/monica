import Foundation

/// Adapter mapping the Monica v5 vault-scoped API onto the neutral models.
final class MonicaV5Backend: MonicaBackend {
    private let client: MonicaV5Client
    private let vaultID: String

    init(client: MonicaV5Client, vaultID: String) {
        self.client = client
        self.vaultID = vaultID
    }

    var generation: ServerGeneration { .v5 }
    var baseURL: URL { client.baseURL }
    var supportsActivities: Bool { false }
    var supportsTaskRename: Bool { false }

    // MARK: - Reads

    func fetchContacts() async throws -> [SyncContact] {
        try await client.fetchContacts(vaultID: vaultID).map(map(contact:))
    }

    func fetchContact(id: String) async throws -> SyncContact {
        map(contact: try await client.fetchContact(vaultID: vaultID, contactID: id))
    }

    func fetchTasks() async throws -> [SyncTask] {
        try await client.fetchTasks(vaultID: vaultID).map(map(task:))
    }

    func fetchReminders() async throws -> [SyncReminder] {
        try await client.fetchReminders(vaultID: vaultID).compactMap(map(reminder:))
    }

    func fetchActivities() async throws -> [SyncActivity] {
        []
    }

    func fetchContactTasks(contactID: String) async throws -> [SyncTask] {
        try await fetchTasks().filter { $0.contactID == contactID }
    }

    func fetchContactReminders(contactID: String) async throws -> [SyncReminder] {
        let reminders = try await client.fetchReminders(vaultID: vaultID)
        return reminders
            .filter { $0.contact?.id == contactID }
            .compactMap(map(reminder:))
    }

    func fetchContactActivities(contactID: String) async throws -> [SyncActivity] {
        []
    }

    func fetchContactCalls(contactID: String) async throws -> [SyncCall] {
        try await client.fetchCalls(vaultID: vaultID, contactID: contactID).map { call in
            SyncCall(
                id: String(call.id),
                date: Self.parseTimestamp(call.calledAt),
                content: call.description
            )
        }
    }

    // MARK: - Writes

    func setTask(_ task: SyncTask, title: String, completed: Bool) async throws {
        // v5 exposes a completion toggle; renames are not supported and the
        // server label wins on the next sync.
        guard completed != task.isCompleted, let taskID = Int(task.id) else { return }
        try await client.toggleTask(vaultID: vaultID, taskID: taskID)
    }

    func createTask(contactID: String, title: String, details: String?) async throws {
        try await client.createTask(
            vaultID: vaultID, contactID: contactID, label: title, description: details
        )
    }

    func logCall(contactID: String, content: String, date: Date) async throws {
        try await client.createCall(
            vaultID: vaultID, contactID: contactID, description: content, calledAt: date
        )
    }

    func pushContactFieldChanges(contact: SyncContact, changes: ContactFieldChanges) async throws {
        guard !changes.isEmpty else { return }
        let types = try await client.fetchContactInformationTypes()
        let emailType = types.first { $0.type?.lowercased() == "email" }
        let phoneType = types.first { $0.type?.lowercased() == "phone" }

        // Removals need the server-side entry IDs — refetch the live contact.
        let remote = try await client.fetchContact(vaultID: vaultID, contactID: contact.id)
        let information = remote.contactInformation ?? []

        if let emailType {
            for added in changes.addedEmails {
                try await client.createContactInformation(
                    vaultID: vaultID, contactID: contact.id, typeID: emailType.id, value: added
                )
            }
        }
        for removed in changes.removedEmails {
            if let entry = information.first(where: {
                $0.contactInformationType?.type?.lowercased() == "email"
                    && $0.content?.lowercased() == removed.lowercased()
            }) {
                try await client.deleteContactInformation(
                    vaultID: vaultID, contactID: contact.id, informationID: entry.id
                )
            }
        }

        if let phoneType {
            for added in changes.addedPhones {
                try await client.createContactInformation(
                    vaultID: vaultID, contactID: contact.id, typeID: phoneType.id, value: added
                )
            }
        }
        for removed in changes.removedPhones {
            if let entry = information.first(where: {
                $0.contactInformationType?.type?.lowercased() == "phone"
                    && ContactsSyncEngine.normalizedPhone($0.content ?? "")
                        == ContactsSyncEngine.normalizedPhone(removed)
            }) {
                try await client.deleteContactInformation(
                    vaultID: vaultID, contactID: contact.id, informationID: entry.id
                )
            }
        }
    }

    func fetchAvatarData(from urlString: String) async -> Data? {
        await client.fetchAvatarData(from: urlString)
    }

    // MARK: - Mapping

    private func map(contact: V5Contact) -> SyncContact {
        let information = contact.contactInformation ?? []
        let emails = information
            .filter { $0.contactInformationType?.type?.lowercased() == "email" }
            .compactMap { $0.content?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let phones = information
            .filter { $0.contactInformationType?.type?.lowercased() == "phone" }
            .compactMap { $0.content?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var birthday: SyncBirthday?
        if let birthdate = (contact.importantDates ?? []).first(where: {
            $0.type?.internalType == "birthdate"
        }), let day = birthdate.day, let month = birthdate.month {
            birthday = SyncBirthday(day: day, month: month, year: birthdate.year)
        }

        return SyncContact(
            id: contact.id,
            firstName: contact.firstName,
            lastName: contact.lastName,
            nickname: contact.nickname,
            company: contact.company?.name,
            jobTitle: contact.jobPosition,
            birthday: birthday,
            emails: emails,
            phones: phones,
            addresses: (contact.addresses ?? []).map { address in
                SyncAddress(
                    label: address.addressType?.name,
                    street: [address.line1, address.line2]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: ", "),
                    city: address.city,
                    province: address.province,
                    postalCode: address.postalCode,
                    country: address.country
                )
            },
            avatarURL: contact.avatarURL,
            webURL: baseURL
                .appendingPathComponent("vaults")
                .appendingPathComponent(vaultID)
                .appendingPathComponent("contacts")
                .appendingPathComponent(contact.id)
                .absoluteString,
            isStarred: false
        )
    }

    private func map(task: V5Task) -> SyncTask {
        SyncTask(
            id: String(task.id),
            title: task.label ?? "Task",
            details: task.description,
            isCompleted: task.completed ?? false,
            contactID: task.contact?.id,
            contactName: task.contact?.name
        )
    }

    /// v5 stores reminders as day/month/(year) plus a recurrence type; resolve
    /// the next occurrence on the device.
    private func map(reminder: V5Reminder) -> SyncReminder? {
        let calendar = Calendar.current
        let now = Date()
        let interval = max(1, reminder.frequencyNumber ?? 1)

        var nextDate: DateComponents?
        var frequency: SyncFrequency = .oneTime

        switch reminder.type {
        case "recurring_day":
            frequency = .daily(interval: interval)
            nextDate = calendar.dateComponents([.year, .month, .day], from: now)
        case "recurring_month":
            frequency = .monthly(interval: interval)
            if let day = reminder.day,
               let date = calendar.nextDate(
                   after: now, matching: DateComponents(day: day), matchingPolicy: .nextTime
               ) {
                nextDate = calendar.dateComponents([.year, .month, .day], from: date)
            }
        case "recurring_year":
            frequency = .yearly(interval: interval)
            if let day = reminder.day, let month = reminder.month,
               let date = calendar.nextDate(
                   after: now,
                   matching: DateComponents(month: month, day: day),
                   matchingPolicy: .nextTime
               ) {
                nextDate = calendar.dateComponents([.year, .month, .day], from: date)
            }
        default:
            frequency = .oneTime
            if let day = reminder.day, let month = reminder.month {
                nextDate = DateComponents(year: reminder.year, month: month, day: day)
            }
        }

        guard nextDate != nil else { return nil }

        return SyncReminder(
            id: String(reminder.id),
            title: reminder.label ?? "Reminder",
            details: nil,
            nextDate: nextDate,
            frequency: frequency,
            contactName: reminder.contact?.name
        )
    }

    private static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: raw) { return date }
        let dayOnly = DateFormatter()
        dayOnly.dateFormat = "yyyy-MM-dd"
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = TimeZone(identifier: "UTC")
        return dayOnly.date(from: String(raw.prefix(10)))
    }
}
