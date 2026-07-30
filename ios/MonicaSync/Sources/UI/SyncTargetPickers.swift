import EventKit
import SwiftUI

// MARK: - Contact selection

/// Pick which Monica contacts get mirrored to the iPhone.
struct ContactSelectionView: View {
    @Environment(AppModel.self) private var model

    @State private var contacts: [SyncContact] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filtered: [SyncContact] {
        let sorted = contacts.sorted { $0.displayName < $1.displayName }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            if let errorMessage, contacts.isEmpty {
                ErrorBanner(message: errorMessage) { Task { await load() } }
            } else if contacts.isEmpty && isLoading {
                ProgressView("Loading people…")
            } else {
                List(filtered) { contact in
                    Button {
                        toggle(contact.id)
                    } label: {
                        HStack(spacing: 12) {
                            InitialsAvatar(initials: contact.initials, size: 32)
                            Text(contact.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if model.settings.selectedContactIDs.contains(contact.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .searchable(text: $searchText, prompt: "Search your contacts")
            }
        }
        .navigationTitle("Contacts to sync")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Select all") {
                        model.settings.selectedContactIDs = Set(contacts.map(\.id))
                    }
                    Button("Select none") {
                        model.settings.selectedContactIDs = []
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await load() }
    }

    private func toggle(_ id: String) {
        if model.settings.selectedContactIDs.contains(id) {
            model.settings.selectedContactIDs.remove(id)
        } else {
            model.settings.selectedContactIDs.insert(id)
        }
    }

    private func load() async {
        guard let backend = model.backend else { return }
        isLoading = true
        errorMessage = nil
        do {
            contacts = try await backend.fetchContacts()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Reminders list / calendar pickers

/// Pick which Reminders list Monica tasks sync into.
struct ReminderListPickerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        EKTargetPicker(
            entityType: .reminder,
            title: "Reminders list",
            dedicatedOptionLabel: "Dedicated “Monica” list",
            dedicatedOptionFootnote: "The app creates a “Monica” list in the Reminders app and keeps your Monica tasks there.",
            selection: Binding(
                get: { model.settings.reminderTargetID },
                set: { model.settings.reminderTargetID = $0 }
            )
        )
    }
}

/// Pick which calendar Monica reminders and activities sync into.
struct CalendarPickerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        EKTargetPicker(
            entityType: .event,
            title: "Calendar",
            dedicatedOptionLabel: "Dedicated “Monica” calendar",
            dedicatedOptionFootnote: "The app creates a “Monica” calendar and keeps your Monica reminders (and activities) there.",
            selection: Binding(
                get: { model.settings.calendarTargetID },
                set: { model.settings.calendarTargetID = $0 }
            )
        )
    }
}

/// Shared list-of-EKCalendars picker. Only items the app created are ever
/// modified inside the chosen target, so picking an existing list is safe.
private struct EKTargetPicker: View {
    let entityType: EKEntityType
    let title: String
    let dedicatedOptionLabel: String
    let dedicatedOptionFootnote: String
    @Binding var selection: String?

    @State private var calendars: [EKCalendar] = []
    @State private var accessDenied = false

    var body: some View {
        List {
            Section {
                row(label: dedicatedOptionLabel, id: nil, color: .accentColor)
            } footer: {
                Text(dedicatedOptionFootnote)
            }

            if accessDenied {
                Section {
                    Label(
                        "Allow access in Settings → Privacy & Security to choose an existing one.",
                        systemImage: "lock"
                    )
                    .foregroundStyle(.secondary)
                }
            } else if !calendars.isEmpty {
                Section("Your \(entityType == .reminder ? "lists" : "calendars")") {
                    ForEach(calendars, id: \.calendarIdentifier) { calendar in
                        row(
                            label: calendar.title,
                            id: calendar.calendarIdentifier,
                            color: Color(cgColor: calendar.cgColor),
                            subtitle: calendar.source?.title
                        )
                    }
                }
            }
        }
        .navigationTitle(title)
        .task { await load() }
    }

    @ViewBuilder
    private func row(label: String, id: String?, color: Color, subtitle: String? = nil) -> some View {
        Button {
            selection = id
        } label: {
            HStack(spacing: 12) {
                Circle().fill(color).frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selection == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private func load() async {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: entityType)
        if status == .notDetermined {
            let granted: Bool
            if entityType == .reminder {
                granted = (try? await store.requestFullAccessToReminders()) ?? false
            } else {
                granted = (try? await store.requestFullAccessToEvents()) ?? false
            }
            guard granted else {
                accessDenied = true
                return
            }
        } else if status != .fullAccess {
            accessDenied = true
            return
        }
        calendars = store.calendars(for: entityType)
            .filter(\.allowsContentModifications)
            .sorted { $0.title < $1.title }
    }
}
