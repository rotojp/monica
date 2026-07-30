import Foundation

/// Which Monica server generation we are talking to.
enum ServerGeneration: String, Codable {
    /// Classic Monica (monicahq.com, self-hosted v4.x) — full REST API.
    case v4
    /// Monica v5 "beta" (the Vue/Inertia rewrite) — vault-scoped REST API.
    case v5
}

// MARK: - Neutral domain models
//
// The sync engines and the UI consume these; each backend (v4/v5) maps its
// own wire format into them. IDs are strings so numeric v4 IDs and UUID v5
// IDs travel the same paths (and stay compatible with mapping files written
// by earlier app versions, where v4 IDs were stringified the same way).

struct SyncAddress: Equatable {
    var label: String?
    var street: String?
    var city: String?
    var province: String?
    var postalCode: String?
    var country: String?

    var oneLine: String {
        [street, city, province, postalCode, country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

struct SyncBirthday: Equatable {
    var day: Int
    var month: Int
    /// Nil when the year is unknown or the date is age-based.
    var year: Int?
}

struct SyncContact: Identifiable {
    let id: String
    var firstName: String?
    var lastName: String?
    var nickname: String?
    var company: String?
    var jobTitle: String?
    var birthday: SyncBirthday?
    var emails: [String]
    var phones: [String]
    var addresses: [SyncAddress]
    var avatarURL: String?
    /// Web profile URL on the server; doubles as the re-adoption marker
    /// stored on the mirrored iPhone contact.
    var webURL: String
    var isStarred: Bool

    var displayName: String {
        let name = [firstName, lastName].compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !name.isEmpty { return name }
        if let nickname, !nickname.isEmpty { return nickname }
        return "Unnamed contact"
    }

    var initials: String {
        let parts = [firstName, lastName].compactMap { $0?.first.map(String.init) }
        return parts.isEmpty ? "?" : parts.joined()
    }
}

struct SyncTask: Identifiable {
    let id: String
    var title: String
    var details: String?
    var isCompleted: Bool
    var contactID: String?
    var contactName: String?
}

enum SyncFrequency: Equatable {
    case oneTime
    case daily(interval: Int)
    case weekly(interval: Int)
    case monthly(interval: Int)
    case yearly(interval: Int)
}

struct SyncReminder: Identifiable {
    let id: String
    var title: String
    var details: String?
    /// The next calendar day this reminder is due, resolved by the backend.
    var nextDate: DateComponents?
    var frequency: SyncFrequency
    var contactName: String?
}

struct SyncActivity: Identifiable {
    let id: String
    var title: String
    var details: String?
    var date: DateComponents?
    var attendees: [String]
}

struct SyncCall: Identifiable {
    let id: String
    var date: Date?
    var content: String?
}

struct MonicaVault: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String?
}

// MARK: - Date component helpers

extension DateComponents {
    /// "2018-10-01" / "--10-01" — canonical form used in fingerprints.
    var syncDayKey: String? {
        guard let month, let day else { return nil }
        if let year {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        return String(format: "--%02d-%02d", month, day)
    }

    /// Local-timezone midnight for an all-day event on this day.
    /// Components without a year resolve to the next upcoming occurrence.
    func nextLocalDate(after reference: Date = Date()) -> Date? {
        guard let month, let day else { return nil }
        var calendar = Calendar.current
        calendar.timeZone = .current
        if let year {
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        }
        return calendar.nextDate(
            after: reference,
            matching: DateComponents(month: month, day: day),
            matchingPolicy: .nextTime
        )
    }
}
