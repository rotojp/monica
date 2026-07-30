import EventKit
import Foundation
import Observation

// MARK: - Errors

enum SyncError: LocalizedError {
    case permissionDenied(String)
    case noWritableStore(String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let what):
            return "Access to \(what) was denied. Allow it under Settings → Privacy & Security → \(what)."
        case .noWritableStore(let what):
            return "No writable \(what) account was found on this device."
        case .notConfigured:
            return "Connect to a Monica server first."
        }
    }
}

// MARK: - State

enum EngineState: Equatable {
    case idle
    case disabled
    case running
    case success(String)
    case failure(String)
}

// MARK: - Coordinator

/// Runs the three sync engines in sequence and publishes their progress to
/// the UI. Used by both the manual "Sync now" button and background refresh.
@MainActor
@Observable
final class SyncCoordinator {
    private(set) var isSyncing = false
    private(set) var contactsState: EngineState = .idle
    private(set) var tasksState: EngineState = .idle
    private(set) var calendarState: EngineState = .idle
    private(set) var lastSyncDate: Date?

    init() {
        lastSyncDate = UserDefaults.standard
            .object(forKey: SyncSettings.Keys.lastSyncDate) as? Date
    }

    func sync(model: AppModel) async {
        guard !isSyncing else { return }
        guard let backend = model.backend else { return }

        isSyncing = true
        defer { isSyncing = false }

        let settings = model.settings
        let mappings = SyncMappingStore()
        let eventStore = EKEventStore()

        if settings.syncContacts {
            contactsState = .running
            do {
                let engine = ContactsSyncEngine(
                    backend: backend, mappings: mappings, settings: settings
                )
                let summary = try await engine.sync()
                var text = "\(summary.created) added · \(summary.updated) updated · \(summary.deleted) removed"
                if summary.pushedToServer > 0 {
                    text += " · \(summary.pushedToServer) pushed to Monica"
                }
                contactsState = .success(text)
            } catch {
                contactsState = .failure(error.localizedDescription)
            }
        } else {
            contactsState = .disabled
        }

        if settings.syncTasks {
            tasksState = .running
            do {
                let engine = RemindersSyncEngine(
                    backend: backend, mappings: mappings, settings: settings, store: eventStore
                )
                let summary = try await engine.sync()
                var text = "\(summary.created) added · \(summary.updated) updated · \(summary.deleted) removed"
                if summary.pushedToServer > 0 {
                    text += " · \(summary.pushedToServer) pushed to Monica"
                }
                tasksState = .success(text)
            } catch {
                tasksState = .failure(error.localizedDescription)
            }
        } else {
            tasksState = .disabled
        }

        if settings.syncCalendar {
            calendarState = .running
            do {
                let engine = CalendarSyncEngine(
                    backend: backend, mappings: mappings, settings: settings, store: eventStore
                )
                let summary = try await engine.sync()
                calendarState = .success(
                    "\(summary.created) added · \(summary.updated) updated · \(summary.deleted) removed"
                )
            } catch {
                calendarState = .failure(error.localizedDescription)
            }
        } else {
            calendarState = .disabled
        }

        lastSyncDate = Date()
        UserDefaults.standard.set(lastSyncDate, forKey: SyncSettings.Keys.lastSyncDate)
    }
}
