import EventKit
import Foundation
import UIKit

struct CalendarSyncSummary {
    var created = 0
    var updated = 0
    var deleted = 0
}

/// Mirrors Monica reminders (birthdays, stay-in-touch, …) — and, on servers
/// that log them, activities — into a calendar on the device.
///
/// The target calendar is chosen by the user in Settings — either an existing
/// calendar or a dedicated "Monica" calendar the app creates. Only events the
/// app created (tagged in their notes) are ever touched.
///
/// This direction is one-way: Monica is the source of truth. Reminders become
/// (optionally recurring) all-day events with a morning alarm; activities
/// become all-day events on the day they happened.
final class CalendarSyncEngine {
    private let backend: any MonicaBackend
    private let mappings: SyncMappingStore
    private let settings: SyncSettings
    private let store: EKEventStore

    private static let dedicatedCalendarName = "Monica"

    init(backend: any MonicaBackend, mappings: SyncMappingStore, settings: SyncSettings, store: EKEventStore) {
        self.backend = backend
        self.mappings = mappings
        self.settings = settings
        self.store = store
    }

    /// Everything needed to create or refresh one mirrored event.
    private struct DesiredEvent {
        let key: String
        let tagLine: String
        let fingerprint: String
        let configure: (EKEvent) -> Void
    }

    // MARK: - Entry point

    func sync() async throws -> CalendarSyncSummary {
        try await ensureAccess()
        let calendar = try resolveTargetCalendar()

        var summary = CalendarSyncSummary()
        async let remindersRequest = backend.fetchReminders()
        async let activitiesRequest = backend.fetchActivities()
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

    /// The user-chosen calendar, or a dedicated "Monica" calendar when no
    /// choice was made (created on first use, reused afterwards).
    private func resolveTargetCalendar() throws -> EKCalendar {
        if let chosenID = settings.calendarTargetID {
            if let calendar = store.calendar(withIdentifier: chosenID),
               calendar.allowsContentModifications {
                return calendar
            }
            // The chosen calendar is gone — fall back to the dedicated one.
        }

        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: SyncSettings.Keys.eventCalendarID),
           let calendar = store.calendar(withIdentifier: id),
           calendar.allowsContentModifications {
            return calendar
        }
        if let existing = store.calendars(for: .event)
            .first(where: { $0.title == Self.dedicatedCalendarName && $0.allowsContentModifications }) {
            defaults.set(existing.calendarIdentifier, forKey: SyncSettings.Keys.eventCalendarID)
            return existing
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.dedicatedCalendarName
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

    private static func desiredEvent(forReminder reminder: SyncReminder) -> DesiredEvent? {
        guard let components = reminder.nextDate,
              let dayKey = components.syncDayKey,
              let startDate = components.nextLocalDate()
        else { return nil }

        let frequencyKey: String
        switch reminder.frequency {
        case .oneTime: frequencyKey = "once"
        case .daily(let interval): frequencyKey = "daily:\(interval)"
        case .weekly(let interval): frequencyKey = "weekly:\(interval)"
        case .monthly(let interval): frequencyKey = "monthly:\(interval)"
        case .yearly(let interval): frequencyKey = "yearly:\(interval)"
        }

        let fingerprint = Fingerprint.of([
            reminder.title,
            reminder.details,
            dayKey,
            frequencyKey,
            reminder.contactName,
        ])

        return DesiredEvent(
            key: SyncMappingStore.key("reminder", reminder.id),
            tagLine: SyncTag.reminder(reminder.id),
            fingerprint: fingerprint
        ) { event in
            event.title = reminder.title
            event.isAllDay = true
            event.startDate = startDate
            event.endDate = startDate.addingTimeInterval(24 * 3600 - 1)

            var noteLines: [String] = []
            if let details = reminder.details, !details.isEmpty {
                noteLines.append(details)
            }
            if let contactName = reminder.contactName {
                noteLines.append("For: \(contactName)")
            }
            noteLines.append(SyncTag.reminder(reminder.id))
            event.notes = noteLines.joined(separator: "\n")

            event.recurrenceRules = recurrenceRules(for: reminder.frequency)
            // Morning-of alert, mirroring Monica's own morning email.
            event.alarms = [EKAlarm(relativeOffset: 9 * 3600)]
        }
    }

    private static func desiredEvent(forActivity activity: SyncActivity) -> DesiredEvent? {
        guard let components = activity.date,
              let dayKey = components.syncDayKey,
              let startDate = components.nextLocalDate()
        else { return nil }

        let fingerprint = Fingerprint.of([
            activity.title,
            activity.details,
            dayKey,
            activity.attendees.sorted().joined(separator: "|"),
        ])

        return DesiredEvent(
            key: SyncMappingStore.key("activity", activity.id),
            tagLine: SyncTag.activity(activity.id),
            fingerprint: fingerprint
        ) { event in
            event.title = activity.title
            event.isAllDay = true
            event.startDate = startDate
            event.endDate = startDate.addingTimeInterval(24 * 3600 - 1)

            var noteLines: [String] = []
            if let details = activity.details, !details.isEmpty {
                noteLines.append(details)
            }
            if !activity.attendees.isEmpty {
                noteLines.append("With: \(activity.attendees.joined(separator: ", "))")
            }
            noteLines.append(SyncTag.activity(activity.id))
            event.notes = noteLines.joined(separator: "\n")
            event.recurrenceRules = nil
            event.alarms = nil
        }
    }

    private static func recurrenceRules(for frequency: SyncFrequency) -> [EKRecurrenceRule]? {
        let ekFrequency: EKRecurrenceFrequency
        let interval: Int
        switch frequency {
        case .oneTime:
            return nil
        case .daily(let value):
            ekFrequency = .daily
            interval = value
        case .weekly(let value):
            ekFrequency = .weekly
            interval = value
        case .monthly(let value):
            ekFrequency = .monthly
            interval = value
        case .yearly(let value):
            ekFrequency = .yearly
            interval = value
        }
        return [
            EKRecurrenceRule(
                recurrenceWith: ekFrequency,
                interval: max(1, interval),
                end: nil
            )
        ]
    }

    // MARK: - Adoption & orphans

    /// Scans the target calendar (±2 years) for events carrying our marker so
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

    private func removeOrphans(prefix: String, remoteIDs: Set<String>) -> Int {
        var removed = 0
        for key in mappings.keys(withPrefix: prefix) {
            let id = String(key.dropFirst(prefix.count))
            guard !remoteIDs.contains(id), let record = mappings[key] else { continue }
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
