import EventKit
import Foundation
import UIKit

struct TaskSyncSummary {
    var created = 0
    var updated = 0
    var deleted = 0
    var pushedToServer = 0
}

/// Mirrors Monica tasks into a dedicated "Monica" list in the Reminders app.
///
/// Sync is two-way for the fields Reminders can edit: completing (or renaming)
/// a reminder on the iPhone is pushed back to the Monica server, while
/// server-side changes update the reminder. When both sides changed since the
/// last sync, the server wins.
final class RemindersSyncEngine {
    private let client: MonicaAPIClient
    private let mappings: SyncMappingStore
    private let settings: SyncSettings
    private let store: EKEventStore

    private static let listName = "Monica"

    init(client: MonicaAPIClient, mappings: SyncMappingStore, settings: SyncSettings, store: EKEventStore) {
        self.client = client
        self.mappings = mappings
        self.settings = settings
        self.store = store
    }

    // MARK: - Entry point

    func sync() async throws -> TaskSyncSummary {
        try await ensureAccess()
        let list = try ensureList()

        var summary = TaskSyncSummary()
        let remoteTasks = try await client.fetchAllTasks()
        let localReminders = await fetchLocalReminders(in: list)
        let adoptionIndex = Self.adoptionIndex(of: localReminders)

        for task in remoteTasks {
            try await syncOne(task, list: list, adoptionIndex: adoptionIndex, summary: &summary)
        }

        if settings.removeOrphans {
            summary.deleted += removeOrphans(remoteIDs: Set(remoteTasks.map(\.id)))
        }

        mappings.save()
        return summary
    }

    // MARK: - Permissions & list

    private func ensureAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .fullAccess { return }
        if status == .notDetermined {
            let granted = (try? await store.requestFullAccessToReminders()) ?? false
            if granted { return }
        }
        throw SyncError.permissionDenied("Reminders")
    }

    private func ensureList() throws -> EKCalendar {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: SyncSettings.Keys.reminderListID),
           let calendar = store.calendar(withIdentifier: id),
           calendar.allowsContentModifications {
            return calendar
        }
        if let existing = store.calendars(for: .reminder)
            .first(where: { $0.title == Self.listName && $0.allowsContentModifications }) {
            defaults.set(existing.calendarIdentifier, forKey: SyncSettings.Keys.reminderListID)
            return existing
        }

        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = Self.listName
        calendar.cgColor = UIColor.systemIndigo.cgColor
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first(where: { $0.sourceType == .local })
        else { throw SyncError.noWritableStore("Reminders") }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        defaults.set(calendar.calendarIdentifier, forKey: SyncSettings.Keys.reminderListID)
        return calendar
    }

    private func fetchLocalReminders(in calendar: EKCalendar) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            let predicate = store.predicateForReminders(in: [calendar])
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    // MARK: - Per-task sync

    private func syncOne(
        _ task: MonicaTask,
        list: EKCalendar,
        adoptionIndex: [Int: EKReminder],
        summary: inout TaskSyncSummary
    ) async throws {
        let key = SyncMappingStore.key("task", task.id)
        let remoteFingerprint = Fingerprint.of(Self.remoteParts(of: task))

        var record = mappings[key]
        var existing = record.flatMap {
            $0.deletedLocally ? nil : store.calendarItem(withIdentifier: $0.localIdentifier) as? EKReminder
        }

        if let current = record {
            if current.deletedLocally { return }
            if existing == nil {
                var tombstone = current
                tombstone.deletedLocally = true
                mappings[key] = tombstone
                return
            }
        }

        if record == nil, let adopted = adoptionIndex[task.id] {
            record = SyncRecord(
                localIdentifier: adopted.calendarItemIdentifier,
                remoteFingerprint: "",
                localFingerprint: ""
            )
            existing = adopted
        }

        if let currentRecord = record, let reminder = existing {
            let localFingerprint = Fingerprint.of(Self.localParts(of: reminder))
            let remoteChanged = remoteFingerprint != currentRecord.remoteFingerprint
            let localChanged = localFingerprint != currentRecord.localFingerprint

            if !remoteChanged && !localChanged { return }

            if localChanged && !remoteChanged {
                // The user completed/renamed the reminder on the device —
                // write it back to Monica.
                let newTitle = reminder.title?.isEmpty == false
                    ? reminder.title!
                    : (task.title ?? "Task")
                try await client.updateTask(task, title: newTitle, completed: reminder.isCompleted)
                summary.pushedToServer += 1
                let assumedRemote = Fingerprint.of([
                    newTitle,
                    task.description,
                    reminder.isCompleted ? "1" : "0",
                    task.contact?.displayName,
                ])
                mappings[key] = SyncRecord(
                    localIdentifier: currentRecord.localIdentifier,
                    remoteFingerprint: assumedRemote,
                    localFingerprint: localFingerprint
                )
                return
            }

            // Server change (possibly alongside a local one): Monica wins.
            Self.apply(task, to: reminder)
            try store.save(reminder, commit: false)
            try store.commit()
            summary.updated += 1
            mappings[key] = SyncRecord(
                localIdentifier: reminder.calendarItemIdentifier,
                remoteFingerprint: remoteFingerprint,
                localFingerprint: Fingerprint.of(Self.localParts(of: reminder))
            )
            return
        }

        // Brand new task: create its reminder.
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        Self.apply(task, to: reminder)
        try store.save(reminder, commit: false)
        try store.commit()
        summary.created += 1
        mappings[key] = SyncRecord(
            localIdentifier: reminder.calendarItemIdentifier,
            remoteFingerprint: remoteFingerprint,
            localFingerprint: Fingerprint.of(Self.localParts(of: reminder))
        )
    }

    private static func apply(_ task: MonicaTask, to reminder: EKReminder) {
        reminder.title = task.title ?? "Task"
        reminder.isCompleted = task.isCompleted

        var noteLines: [String] = []
        if let description = task.description, !description.isEmpty {
            noteLines.append(description)
        }
        if let contact = task.contact {
            noteLines.append("For: \(contact.displayName)")
        }
        noteLines.append(SyncTag.task(task.id))
        reminder.notes = noteLines.joined(separator: "\n")
    }

    // MARK: - Orphan removal

    private func removeOrphans(remoteIDs: Set<Int>) -> Int {
        var removed = 0
        for key in mappings.keys(withPrefix: "task:") {
            guard let id = Int(key.split(separator: ":")[1]), !remoteIDs.contains(id),
                  let record = mappings[key]
            else { continue }
            if !record.deletedLocally,
               let reminder = store.calendarItem(withIdentifier: record.localIdentifier) as? EKReminder {
                if (try? store.remove(reminder, commit: true)) != nil { removed += 1 }
            }
            mappings.remove(key)
        }
        return removed
    }

    // MARK: - Adoption

    /// Finds reminders that carry our `monica://task/<id>` marker so a
    /// reinstall re-links instead of duplicating.
    private static func adoptionIndex(of reminders: [EKReminder]) -> [Int: EKReminder] {
        var index: [Int: EKReminder] = [:]
        for reminder in reminders {
            if let id = SyncTag.taskID(fromNotes: reminder.notes) {
                index[id] = reminder
            }
        }
        return index
    }

    // MARK: - Fingerprints

    private static func remoteParts(of task: MonicaTask) -> [String?] {
        [
            task.title,
            task.description,
            task.isCompleted ? "1" : "0",
            task.contact?.displayName,
        ]
    }

    private static func localParts(of reminder: EKReminder) -> [String?] {
        [
            reminder.title,
            reminder.isCompleted ? "1" : "0",
        ]
    }
}
