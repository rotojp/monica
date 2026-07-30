import EventKit
import Foundation
import UIKit

struct TaskSyncSummary {
    var created = 0
    var updated = 0
    var deleted = 0
    var pushedToServer = 0
}

/// Mirrors Monica tasks into the Reminders app.
///
/// The target list is chosen by the user in Settings — either an existing
/// Reminders list or a dedicated "Monica" list the app creates. Only items
/// the app put there are ever touched; the user's own reminders in a shared
/// list are ignored.
///
/// Sync is two-way for what Reminders can edit: completing (and, on servers
/// that support it, renaming) a reminder on the iPhone is pushed back to
/// Monica, while server-side changes update the reminder. When both sides
/// changed since the last sync, the server wins.
final class RemindersSyncEngine {
    private let backend: any MonicaBackend
    private let mappings: SyncMappingStore
    private let settings: SyncSettings
    private let store: EKEventStore

    private static let dedicatedListName = "Monica"

    init(backend: any MonicaBackend, mappings: SyncMappingStore, settings: SyncSettings, store: EKEventStore) {
        self.backend = backend
        self.mappings = mappings
        self.settings = settings
        self.store = store
    }

    // MARK: - Entry point

    func sync() async throws -> TaskSyncSummary {
        try await ensureAccess()
        let list = try resolveTargetList()

        var summary = TaskSyncSummary()
        let remoteTasks = try await backend.fetchTasks()
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

    /// The user-chosen Reminders list, or a dedicated "Monica" list when no
    /// choice was made (created on first use, reused afterwards).
    private func resolveTargetList() throws -> EKCalendar {
        if let chosenID = settings.reminderTargetID {
            if let calendar = store.calendar(withIdentifier: chosenID),
               calendar.allowsContentModifications {
                return calendar
            }
            // The chosen list is gone — fall back to the dedicated list
            // rather than silently writing somewhere unexpected.
        }

        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: SyncSettings.Keys.reminderListID),
           let calendar = store.calendar(withIdentifier: id),
           calendar.allowsContentModifications {
            return calendar
        }
        if let existing = store.calendars(for: .reminder)
            .first(where: { $0.title == Self.dedicatedListName && $0.allowsContentModifications }) {
            defaults.set(existing.calendarIdentifier, forKey: SyncSettings.Keys.reminderListID)
            return existing
        }

        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = Self.dedicatedListName
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
        _ task: SyncTask,
        list: EKCalendar,
        adoptionIndex: [String: EKReminder],
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
                let newTitle: String = {
                    guard backend.supportsTaskRename,
                          let title = reminder.title, !title.isEmpty
                    else { return task.title }
                    return title
                }()
                try await backend.setTask(task, title: newTitle, completed: reminder.isCompleted)
                summary.pushedToServer += 1
                let assumedRemote = Fingerprint.of([
                    newTitle,
                    task.details,
                    reminder.isCompleted ? "1" : "0",
                    task.contactName,
                ])
                mappings[key] = SyncRecord(
                    localIdentifier: currentRecord.localIdentifier,
                    remoteFingerprint: assumedRemote,
                    localFingerprint: Fingerprint.of([
                        newTitle,
                        reminder.isCompleted ? "1" : "0",
                    ])
                )
                return
            }

            // Server change (possibly alongside a local one): Monica wins.
            Self.apply(task, to: reminder)
            try store.save(reminder, commit: true)
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
        try store.save(reminder, commit: true)
        summary.created += 1
        mappings[key] = SyncRecord(
            localIdentifier: reminder.calendarItemIdentifier,
            remoteFingerprint: remoteFingerprint,
            localFingerprint: Fingerprint.of(Self.localParts(of: reminder))
        )
    }

    private static func apply(_ task: SyncTask, to reminder: EKReminder) {
        reminder.title = task.title
        reminder.isCompleted = task.isCompleted

        var noteLines: [String] = []
        if let details = task.details, !details.isEmpty {
            noteLines.append(details)
        }
        if let contactName = task.contactName {
            noteLines.append("For: \(contactName)")
        }
        noteLines.append(SyncTag.task(task.id))
        reminder.notes = noteLines.joined(separator: "\n")
    }

    // MARK: - Orphan removal

    private func removeOrphans(remoteIDs: Set<String>) -> Int {
        var removed = 0
        for key in mappings.keys(withPrefix: "task:") {
            let id = String(key.dropFirst("task:".count))
            guard !remoteIDs.contains(id), let record = mappings[key] else { continue }
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
    private static func adoptionIndex(of reminders: [EKReminder]) -> [String: EKReminder] {
        var index: [String: EKReminder] = [:]
        for reminder in reminders {
            if let id = SyncTag.taskID(fromNotes: reminder.notes) {
                index[id] = reminder
            }
        }
        return index
    }

    // MARK: - Fingerprints

    private static func remoteParts(of task: SyncTask) -> [String?] {
        [
            task.title,
            task.details,
            task.isCompleted ? "1" : "0",
            task.contactName,
        ]
    }

    private static func localParts(of reminder: EKReminder) -> [String?] {
        [
            reminder.title,
            reminder.isCompleted ? "1" : "0",
        ]
    }
}
