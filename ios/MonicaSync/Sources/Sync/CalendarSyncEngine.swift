import EventKit
import Foundation
import UIKit

struct CalendarSyncSummary {
    var created = 0
    var updated = 0
    var deleted = 0
}

/// Mirrors Monica reminders (birthdays, stay-in-touch, …) and logged
/// activities into a dedicated "Monica" calendar on the device.
///
/// This direction is one-way: Monica is the source of truth. Reminders become
/// (optionally recurring) all-day events with a morning alarm; activities
/// become all-day events on the day they happened.
final class CalendarSyncEngine {
    private let client: MonicaAPIClient
    private let mappings: SyncMappingStore
    private let settings: SyncSettings
    private let store: EKEventStore

    private static let calendarName = "Monica"

    init(client: MonicaAPIClient, mappings: SyncMappingStore, settings: SyncSettings, store: EKEventStore) {
        self.client = client
        self.mappings = mappings
        self.settings = settings
        self.store = store
    }

    /// Everything needed to create or refresh one mirrored event.
    private struct DesiredEvent {
        let key: String
        let remoteID: Int
        let tagLine: String
        let fingerprint: String
        let configure: (EKEvent) -> Void
    }

    // MARK: - Entry point

    func sync() async throws -> CalendarSyncSummary {
        try await ensureAccess()
        let calendar = try ensureCalendar()

        var summary = CalendarSyncSummary()
        async let remindersRequest = client.fetchAllReminders()
        async let activitiesRequest = client.fetchAllActivities()
        let reminders = try await remindersRequest
        let activities = try await activitiesRequest

        var desired: [DesiredEvent] = []
        desired += reminders.compactMap(Self.desiredEvent(forReminder:))
        desired += activities.compactMap(Self.desiredEvent(forActivity:))

        let adoptionIndex = buildAdoptionIndex(in: calendar)

        for item in desired {
            try syncOne(item, calendar: calendar, adoptionIndex: adoptionIndex, summary: &summary)
        }

        if settings.removeOrphans {
            summary.deleted += removeOrphans(
                prefix: "reminder:",
                remoteIDs: Set(reminders.map(\.id))
            )
            summary.deleted += removeOrphans(
                prefix: "activity:",
                remoteIDs: Set(activities.map(\.id))
            )
        }

        mappings.save()
        return summary
    }

    // MARK: - Permissions & calendar

    private func ensureAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess { return }
        if status == .notDetermined {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            if granted { return }
        }
        throw SyncError.permissionDenied("Calendar")
    }

    private func ensureCalendar() throws -> EKCalendar {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: SyncSettings.Keys.eventCalendarID),
           let calendar = store.calendar(withIdentifier: id),
           calendar.allowsContentModifications {
            return calendar
        }
        if let existing = store.calendars(for: .event)
            .first(where: { $0.title == Self.calendarName && $0.allowsContentModifications }) {
            defaults.set(existing.calendarIdentifier, forKey: SyncSettings.Keys.eventCalendarID)
            return existing
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.calendarName
        calendar.cgColor = UIColor.systemIndigo.cgColor
        guard let source = store.defaultCalendarForNewEvents?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first(where: { $0.sourceType == .local })
        else { throw SyncError.noWritableStore("Calendar") }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        defaults.set(calendar.calendarIdentifier, forKey: SyncSettings.Keys.eventCalendarID)
        return calendar
    }

    // MARK: - Per-event sync

    private func syncOne(
        _ item: DesiredEvent,
        calendar: EKCalendar,
        adoptionIndex: [String: EKEvent],
        summary: inout CalendarSyncSummary
    ) throws {
        var record = mappings[item.key]
        var existing = record.flatMap {
            $0.deletedLocally ? nil : store.event(withIdentifier: $0.localIdentifier)
        }

        if let current = record {
            if current.deletedLocally { return }
            if existing == nil {
                var tombstone = current
                tombstone.deletedLocally = true
                mappings[item.key] = tombstone
                return
            }
        }

        if record == nil, let adopted = adoptionIndex[item.tagLine] {
            record = SyncRecord(
                localIdentifier: adopted.eventIdentifier,
                remoteFingerprint: "",
                localFingerprint: ""
            )
            existing = adopted
        }

        if let currentRecord = record, let event = existing {
            guard item.fingerprint != currentRecord.remoteFingerprint else { return }
            item.configure(event)
            event.calendar = calendar
            try store.save(event, span: .futureEvents, commit: true)
            summary.updated += 1
            mappings[item.key] = SyncRecord(
                localIdentifier: event.eventIdentifier,
                remoteFingerprint: item.fingerprint,
                localFingerprint: ""
            )
            return
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        item.configure(event)
        try store.save(event, span: .thisEvent, commit: true)
        summary.created += 1
        mappings[item.key] = SyncRecord(
            localIdentifier: event.eventIdentifier,
            remoteFingerprint: item.fingerprint,
            localFingerprint: ""
        )
    }

    // MARK: - Desired state builders

    private static func desiredEvent(forReminder reminder: MonicaReminder) -> DesiredEvent? {
        guard let nextDate = reminder.nextExpectedDate else { return nil }
        let startDate = localAllDayStart(for: nextDate)
        let title = reminder.title ?? "Reminder"
        let fingerprint = Fingerprint.of([
            title,
            reminder.description,
            allDayKey(for: nextDate),
            reminder.frequencyType,
            reminder.frequencyNumber.map(String.init),
            reminder.contact?.displayName,
        ])

        return DesiredEvent(
            key: SyncMappingStore.key("reminder", reminder.id),
            remoteID: reminder.id,
            tagLine: SyncTag.reminder(reminder.id),
            fingerprint: fingerprint
        ) { event in
            event.title = title
            event.isAllDay = true
            event.startDate = startDate
            event.endDate = startDate.addingTimeInterval(24 * 3600 - 1)

            var noteLines: [String] = []
            if let description = reminder.description, !description.isEmpty {
                noteLines.append(description)
            }
            if let contact = reminder.contact {
                noteLines.append("For: \(contact.displayName)")
            }
            noteLines.append(SyncTag.reminder(reminder.id))
            event.notes = noteLines.joined(separator: "\n")

            event.recurrenceRules = recurrenceRules(
                frequencyType: reminder.frequencyType,
                frequencyNumber: reminder.frequencyNumber
            )
            // Morning-of alert, mirroring Monica's own morning email.
            event.alarms = [EKAlarm(relativeOffset: 9 * 3600)]
        }
    }

    private static func desiredEvent(forActivity activity: MonicaActivity) -> DesiredEvent? {
        guard let happenedAt = activity.happenedAt else { return nil }
        let startDate = localAllDayStart(for: happenedAt)
        let title = activity.summary ?? "Activity"
        let fingerprint = Fingerprint.of([
            title,
            activity.description,
            allDayKey(for: happenedAt),
            activity.attendeeNames.sorted().joined(separator: "|"),
        ])

        return DesiredEvent(
            key: SyncMappingStore.key("activity", activity.id),
            remoteID: activity.id,
            tagLine: SyncTag.activity(activity.id),
            fingerprint: fingerprint
        ) { event in
            event.title = title
            event.isAllDay = true
            event.startDate = startDate
            event.endDate = startDate.addingTimeInterval(24 * 3600 - 1)

            var noteLines: [String] = []
            if let description = activity.description, !description.isEmpty {
                noteLines.append(description)
            }
            if !activity.attendeeNames.isEmpty {
                noteLines.append("With: \(activity.attendeeNames.joined(separator: ", "))")
            }
            noteLines.append(SyncTag.activity(activity.id))
            event.notes = noteLines.joined(separator: "\n")
            event.recurrenceRules = nil
            event.alarms = nil
        }
    }

    private static func recurrenceRules(
        frequencyType: String?,
        frequencyNumber: Int?
    ) -> [EKRecurrenceRule]? {
        let frequency: EKRecurrenceFrequency
        switch frequencyType?.lowercased() {
        case .some(let type) where type.hasPrefix("week"): frequency = .weekly
        case .some(let type) where type.hasPrefix("month"): frequency = .monthly
        case .some(let type) where type.hasPrefix("year"): frequency = .yearly
        default: return nil
        }
        return [
            EKRecurrenceRule(
                recurrenceWith: frequency,
                interval: max(1, frequencyNumber ?? 1),
                end: nil
            )
        ]
    }

    /// Monica stores day-precision dates in UTC; render them as local all-day
    /// events on the same calendar day.
    private static func localAllDayStart(for date: Date) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = utc.dateComponents([.year, .month, .day], from: date)
        var local = Calendar.current
        local.timeZone = .current
        return local.date(from: components) ?? date
    }

    private static func allDayKey(for date: Date) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = utc.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0, components.month ?? 0, components.day ?? 0
        )
    }

    // MARK: - Adoption & orphans

    /// Scans the Monica calendar (±2 years) for events carrying our marker so
    /// reinstalls re-link instead of duplicating.
    private func buildAdoptionIndex(in calendar: EKCalendar) -> [String: EKEvent] {
        let now = Date()
        let start = now.addingTimeInterval(-2 * 365 * 24 * 3600)
        let end = now.addingTimeInterval(2 * 365 * 24 * 3600)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])

        var index: [String: EKEvent] = [:]
        for event in store.events(matching: predicate) {
            guard let notes = event.notes else { continue }
            for line in notes.split(separator: "\n") {
                let tag = line.trimmingCharacters(in: .whitespaces)
                if tag.hasPrefix("monica://"), index[tag] == nil {
                    index[tag] = event
                }
            }
        }
        return index
    }

    private func removeOrphans(prefix: String, remoteIDs: Set<Int>) -> Int {
        var removed = 0
        for key in mappings.keys(withPrefix: prefix) {
            guard let id = Int(key.split(separator: ":")[1]), !remoteIDs.contains(id),
                  let record = mappings[key]
            else { continue }
            if !record.deletedLocally,
               let event = store.event(withIdentifier: record.localIdentifier) {
                if (try? store.remove(event, span: .futureEvents, commit: true)) != nil {
                    removed += 1
                }
            }
            mappings.remove(key)
        }
        return removed
    }
}
