import SwiftUI

/// The sync dashboard: what gets mirrored where, current status, and the
/// manual "Sync now" trigger.
struct SyncStatusView: View {
    @Environment(AppModel.self) private var model
    @Environment(SyncCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    Button {
                        Task { await coordinator.sync(model: model) }
                    } label: {
                        HStack {
                            if coordinator.isSyncing {
                                ProgressView()
                                Text("Syncing…")
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Sync now")
                            }
                        }
                    }
                    .disabled(coordinator.isSyncing)

                    if let lastSync = coordinator.lastSyncDate {
                        LabeledContent(
                            "Last sync",
                            value: lastSync.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                } footer: {
                    Text("Syncing also runs periodically in the background while the app is installed.")
                }

                Section("Contacts") {
                    Toggle("Sync people to Contacts", isOn: $model.settings.syncContacts)
                    EngineStateRow(state: coordinator.contactsState)
                }

                Section("Reminders") {
                    Toggle("Sync tasks to Reminders", isOn: $model.settings.syncTasks)
                    EngineStateRow(state: coordinator.tasksState)
                }

                Section {
                    Toggle("Sync reminders & activities to Calendar", isOn: $model.settings.syncCalendar)
                    EngineStateRow(state: coordinator.calendarState)
                } header: {
                    Text("Calendar")
                } footer: {
                    Text("Monica reminders (birthdays, stay in touch) become recurring all-day events with a morning alert. Logged activities appear on the day they happened. Everything lives in a dedicated “Monica” list, calendar and contact group.")
                }
            }
            .navigationTitle("Sync")
        }
    }
}

private struct EngineStateRow: View {
    let state: EngineState

    var body: some View {
        switch state {
        case .idle:
            Label("Waiting for first sync", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .disabled:
            Label("Turned off", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        case .running:
            HStack {
                ProgressView()
                Text("Syncing…").foregroundStyle(.secondary)
            }
        case .success(let summary):
            Label(summary, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}
