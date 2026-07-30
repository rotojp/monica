import Foundation

// MARK: - Envelopes

/// Monica wraps single resources in `{ "data": ... }`.
struct SingleResponse<T: Decodable>: Decodable {
    let data: T
}

/// Monica wraps collections in `{ "data": [...], "meta": { ... } }`.
struct PagedResponse<T: Decodable>: Decodable {
    let data: [T]
    let meta: PageMeta?
}

struct PageMeta: Decodable {
    let currentPage: Int?
    let lastPage: Int?
    let total: Int?

    enum CodingKeys: String, CodingKey {
        case currentPage = "current_page"
        case lastPage = "last_page"
        case total
    }
}

/// Error payload: `{ "error": { "message": "...", "error_code": 31 } }`.
struct APIErrorEnvelope: Decodable {
    struct Detail: Decodable {
        let message: String?
        let errorCode: Int?

        enum CodingKeys: String, CodingKey {
            case message
            case errorCode = "error_code"
        }
    }

    let error: Detail?
}

// MARK: - User

struct MonicaUser: Decodable {
    let id: Int
    let firstName: String?
    let lastName: String?
    let email: String?

    enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case email
    }

    var displayName: String {
        let name = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? (email ?? "Monica user") : name
    }
}

// MARK: - Contact

struct MonicaContact: Decodable, Identifiable {
    let id: Int
    let hashID: String?
    let firstName: String?
    let lastName: String?
    let nickname: String?
    let completeName: String?
    let isPartial: Bool?
    let isActive: Bool?
    let isDead: Bool?
    let isStarred: Bool?
    let information: Information?
    let addresses: [MonicaAddress]?
    let contactFields: [MonicaContactField]?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case hashID = "hash_id"
        case firstName = "first_name"
        case lastName = "last_name"
        case nickname
        case completeName = "complete_name"
        case isPartial = "is_partial"
        case isActive = "is_active"
        case isDead = "is_dead"
        case isStarred = "is_starred"
        case information
        case addresses
        case contactFields
        case updatedAt = "updated_at"
    }

    struct Information: Decodable {
        let dates: Dates?
        let career: Career?
        let avatar: Avatar?
    }

    struct Dates: Decodable {
        let birthdate: EventDate?
        let deceasedDate: EventDate?

        enum CodingKeys: String, CodingKey {
            case birthdate
            case deceasedDate = "deceased_date"
        }
    }

    struct EventDate: Decodable {
        let isAgeBased: Bool?
        let isYearUnknown: Bool?
        let date: Date?

        enum CodingKeys: String, CodingKey {
            case isAgeBased = "is_age_based"
            case isYearUnknown = "is_year_unknown"
            case date
        }
    }

    struct Career: Decodable {
        let job: String?
        let company: String?
    }

    struct Avatar: Decodable {
        let url: String?
        let source: String?
    }

    var displayName: String {
        if let completeName, !completeName.isEmpty { return completeName }
        let name = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? "Contact #\(id)" : name
    }

    var initials: String {
        let parts = [firstName, lastName].compactMap { $0?.first.map(String.init) }
        return parts.isEmpty ? "?" : parts.joined()
    }

    /// True when this contact should be mirrored to the iPhone address book.
    var isSyncable: Bool {
        (isPartial ?? false) == false && (isActive ?? true) == true
    }

    var emails: [String] {
        fields(ofKind: "email")
    }

    var phones: [String] {
        fields(ofKind: "phone")
    }

    private func fields(ofKind kind: String) -> [String] {
        (contactFields ?? []).compactMap { field in
            guard field.contactFieldType?.kind(matches: kind) == true else { return nil }
            return field.content?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
    }
}

struct MonicaContactField: Decodable, Identifiable {
    let id: Int
    let content: String?
    let contactFieldType: MonicaContactFieldType?

    enum CodingKeys: String, CodingKey {
        case id
        case content
        case contactFieldType = "contact_field_type"
    }
}

struct MonicaContactFieldType: Decodable, Identifiable {
    let id: Int
    let name: String?
    let type: String?
    let protocolPrefix: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case protocolPrefix = "protocol"
    }

    /// Matches a semantic kind ("email"/"phone") against either the machine
    /// `type` column or, for older servers, the display name.
    func kind(matches kind: String) -> Bool {
        if let type, type.lowercased() == kind { return true }
        if let name {
            let lowered = name.lowercased()
            if kind == "email" { return lowered == "email" }
            if kind == "phone" { return lowered == "phone" || lowered == "mobile" }
        }
        return false
    }
}

struct MonicaAddress: Decodable, Identifiable {
    let id: Int
    let name: String?
    let street: String?
    let city: String?
    let province: String?
    let postalCode: String?
    let country: Country?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case street
        case city
        case province
        case postalCode = "postal_code"
        case country
    }

    struct Country: Decodable {
        let name: String?
        let iso: String?
    }

    var oneLine: String {
        [street, city, province, postalCode, country?.name]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

// MARK: - Task

struct MonicaTask: Decodable, Identifiable {
    let id: Int
    let title: String?
    let description: String?
    let completed: Bool?
    let completedAt: Date?
    let contact: ContactSummary?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case completed
        case completedAt = "completed_at"
        case contact
        case updatedAt = "updated_at"
    }

    var isCompleted: Bool { completed ?? false }
}

// MARK: - Reminder

struct MonicaReminder: Decodable, Identifiable {
    let id: Int
    let title: String?
    let description: String?
    let frequencyType: String?
    let frequencyNumber: Int?
    let nextExpectedDate: Date?
    let contact: ContactSummary?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case frequencyType = "frequency_type"
        case frequencyNumber = "frequency_number"
        case nextExpectedDate = "next_expected_date"
        case contact
        case updatedAt = "updated_at"
    }
}

// MARK: - Activity

struct MonicaActivity: Decodable, Identifiable {
    let id: Int
    let summary: String?
    let description: String?
    let happenedAt: Date?
    let attendees: Attendees?

    enum CodingKeys: String, CodingKey {
        case id
        case summary
        case description
        case happenedAt = "happened_at"
        case attendees
    }

    struct Attendees: Decodable {
        let total: Int?
        let contacts: [ContactSummary]?
    }

    var attendeeNames: [String] {
        (attendees?.contacts ?? []).map(\.displayName)
    }
}

// MARK: - Call

struct MonicaCall: Decodable, Identifiable {
    let id: Int
    let calledAt: Date?
    let content: String?
    let contact: ContactSummary?

    enum CodingKeys: String, CodingKey {
        case id
        case calledAt = "called_at"
        case content
        case contact
    }
}

// MARK: - Shared

/// The compact contact object Monica embeds in tasks, reminders, calls, …
struct ContactSummary: Decodable, Identifiable {
    let id: Int
    let firstName: String?
    let lastName: String?
    let completeName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case completeName = "complete_name"
    }

    var displayName: String {
        if let completeName, !completeName.isEmpty { return completeName }
        let name = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? "Contact #\(id)" : name
    }
}
