import Foundation

/// Adapter mapping the classic Monica v4 REST API onto the neutral models.
final class MonicaV4Backend: MonicaBackend {
    private let client: MonicaAPIClient

    init(client: MonicaAPIClient) {
        self.client = client
    }

    var generation: ServerGeneration { .v4 }
    var baseURL: URL { client.serverConfig.baseURL }
    var supportsActivities: Bool { true }
    var supportsTaskRename: Bool { true }

    // MARK: - Reads

    func fetchContacts() async throws -> [SyncContact] {
        try await client.fetchAllContacts()
            .filter(\.isSyncable)
            .map(map(contact:))
    }

    func fetchContact(id: String) async throws -> SyncContact {
        map(contact: try await client.fetchContact(id: try numeric(id)))
    }

    func fetchTasks() async throws -> [SyncTask] {
        try await client.fetchAllTasks().map(map(task:))
    }

    func fetchReminders() async throws -> [SyncReminder] {
        try await client.fetchAllReminders().compactMap(map(reminder:))
    }

    func fetchActivities() async throws -> [SyncActivity] {
        try await client.fetchAllActivities().map(map(activity:))
    }

    func fetchContactTasks(contactID: String) async throws -> [SyncTask] {
        try await client.fetchTasks(contactID: try numeric(contactID)).map(map(task:))
    }

    func fetchContactReminders(contactID: String) async throws -> [SyncReminder] {
        try await client.fetchReminders(contactID: try numeric(contactID))
            .compactMap(map(reminder:))
    }

    func fetchContactActivities(contactID: String) async throws -> [SyncActivity] {
        try await client.fetchActivities(contactID: try numeric(contactID)).map(map(activity:))
    }

    func fetchContactCalls(contactID: String) async throws -> [SyncCall] {
        try await client.fetchCalls(contactID: try numeric(contactID)).map { call in
            SyncCall(id: String(call.id), date: call.calledAt, content: call.content)
        }
    }

    // MARK: - Writes

    func setTask(_ task: SyncTask, title: String, completed: Bool) async throws {
        let original = MonicaTask(
            id: try numeric(task.id),
            title: task.title,
            description: task.details,
            completed: task.isCompleted,
            completedAt: nil,
            contact: task.contactID.flatMap { Int($0) }.map {
                ContactSummary(id: $0, firstName: nil, lastName: nil, completeName: task.contactName)
            },
            updatedAt: nil
        )
        try await client.updateTask(original, title: title, completed: completed)
    }

    func createTask(contactID: String, title: String, details: String?) async throws {
        try await client.createTask(
            contactID: try numeric(contactID), title: title, description: details
        )
    }

    func logCall(contactID: String, content: String, date: Date) async throws {
        try await client.createCall(
            contactID: try numeric(contactID), content: content, calledAt: date
        )
    }

    func pushContactFieldChanges(contact: SyncContact, changes: ContactFieldChanges) async throws {
        guard !changes.isEmpty else { return }
        let contactID = try numeric(contact.id)
        let types = try await client.fetchContactFieldTypes()
        let emailType = types.first { $0.kind(matches: "email") }
        let phoneType = types.first { $0.kind(matches: "phone") }

        // Removals need the server-side field IDs — refetch the live contact.
        let remote = try await client.fetchContact(id: contactID)
        let fields = remote.contactFields ?? []

        if let emailType {
            for added in changes.addedEmails {
                try await client.createContactField(
                    contactID: contactID, typeID: emailType.id, value: added
                )
            }
        }
        for removed in changes.removedEmails {
            if let field = fields.first(where: {
                $0.contactFieldType?.kind(matches: "email") == true
                    && $0.content?.lowercased() == removed.lowercased()
            }) {
                try await client.deleteContactField(id: field.id)
            }
        }

        if let phoneType {
            for added in changes.addedPhones {
                try await client.createContactField(
                    contactID: contactID, typeID: phoneType.id, value: added
                )
            }
        }
        for removed in changes.removedPhones {
            if let field = fields.first(where: {
                $0.contactFieldType?.kind(matches: "phone") == true
                    && ContactsSyncEngine.normalizedPhone($0.content ?? "")
                        == ContactsSyncEngine.normalizedPhone(removed)
            }) {
                try await client.deleteContactField(id: field.id)
            }
        }
    }

    func fetchAvatarData(from urlString: String) async -> Data? {
        await client.fetchAvatarData(from: urlString)
    }

    // MARK: - Mapping

    private func numeric(_ id: String) throws -> Int {
        guard let value = Int(id) else { throw MonicaAPIError.invalidURL }
        return value
    }

    private func map(contact: MonicaContact) -> SyncContact {
        var birthday: SyncBirthday?
        if let birthdate = contact.information?.dates?.birthdate,
           let date = birthdate.date,
           birthdate.isAgeBased != true {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            if let month = components.month, let day = components.day {
                birthday = SyncBirthday(
                    day: day,
                    month: month,
                    year: birthdate.isYearUnknown == true ? nil : components.year
                )
            }
        }

        return SyncContact(
            id: String(contact.id),
            firstName: contact.firstName,
            lastName: contact.lastName,
            nickname: contact.nickname,
            company: contact.information?.career?.company,
            jobTitle: contact.information?.career?.job,
            birthday: birthday,
            emails: contact.emails,
            phones: contact.phones,
            addresses: (contact.addresses ?? []).map { address in
                SyncAddress(
                    label: address.name,
                    street: address.street,
                    city: address.city,
                    province: address.province,
                    postalCode: address.postalCode,
                    country: address.country?.name
                )
            },
            avatarURL: contact.information?.avatar?.source == "default"
                ? nil
                : contact.information?.avatar?.url,
            webURL: client.serverConfig
                .webURL(forContactID: contact.id, hashID: contact.hashID)
                .absoluteString,
            isStarred: contact.isStarred ?? false
        )
    }

    private func map(task: MonicaTask) -> SyncTask {
        SyncTask(
            id: String(task.id),
            title: task.title ?? "Task",
            details: task.description,
            isCompleted: task.isCompleted,
            contactID: task.contact.map { String($0.id) },
            contactName: task.contact?.displayName
        )
    }

    private func map(reminder: MonicaReminder) -> SyncReminder? {
        var nextDate: DateComponents?
        if let date = reminder.nextExpectedDate {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            nextDate = calendar.dateComponents([.year, .month, .day], from: date)
        }

        let interval = max(1, reminder.frequencyNumber ?? 1)
        let frequency: SyncFrequency
        switch reminder.frequencyType?.lowercased() {
        case .some(let type) where type.hasPrefix("week"): frequency = .weekly(interval: interval)
        case .some(let type) where type.hasPrefix("month"): frequency = .monthly(interval: interval)
        case .some(let type) where type.hasPrefix("year"): frequency = .yearly(interval: interval)
        default: frequency = .oneTime
        }

        return SyncReminder(
            id: String(reminder.id),
            title: reminder.title ?? "Reminder",
            details: reminder.description,
            nextDate: nextDate,
            frequency: frequency,
            contactName: reminder.contact?.displayName
        )
    }

    private func map(activity: MonicaActivity) -> SyncActivity {
        var date: DateComponents?
        if let happenedAt = activity.happenedAt {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            date = calendar.dateComponents([.year, .month, .day], from: happenedAt)
        }
        return SyncActivity(
            id: String(activity.id),
            title: activity.summary ?? "Activity",
            details: activity.description,
            date: date,
            attendees: activity.attendeeNames
        )
    }
}
