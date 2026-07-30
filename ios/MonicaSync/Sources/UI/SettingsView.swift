import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var showSignOutConfirmation = false
    @State private var showVaultPicker = false

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section("Account") {
                    if let accountName = model.accountName {
                        LabeledContent("Signed in as", value: accountName)
                    }
                    if let server = model.serverURLString {
                        LabeledContent("Server", value: server)
                    }
                    if let generation = model.generation {
                        LabeledContent(
                            "Server version",
                            value: generation == .v5 ? "Monica v5" : "Monica v4 (classic)"
                        )
                    }
                    if model.generation == .v5 {
                        LabeledContent("Vault", value: model.vaultName ?? "—")
                        Button("Change vault…") {
                            showVaultPicker = true
                        }
                    }
                }

                Section {
                    Toggle(
                        "Sync only selected contacts",
                        isOn: $model.settings.contactSelectionEnabled
                    )
                    if model.settings.contactSelectionEnabled {
                        NavigationLink {
                            ContactSelectionView()
                        } label: {
                            LabeledContent(
                                "Contacts to sync",
                                value: "\(model.settings.selectedContactIDs.count) selected"
                            )
                        }
                    }
                    NavigationLink {
                        ReminderListPickerView()
                    } label: {
                        LabeledContent(
                            "Reminders list",
                            value: model.settings.reminderTargetID == nil ? "Monica (dedicated)" : "Custom"
                        )
                    }
                    NavigationLink {
                        CalendarPickerView()
                    } label: {
                        LabeledContent(
                            "Calendar",
                            value: model.settings.calendarTargetID == nil ? "Monica (dedicated)" : "Custom"
                        )
                    }
                } header: {
                    Text("What syncs where")
                } footer: {
                    Text("When syncing into an existing list or calendar, the app only ever touches the items it created itself.")
                }

                Section {
                    Toggle(
                        "Push local contact edits to Monica",
                        isOn: $model.settings.pushLocalContactChanges
                    )
                } header: {
                    Text("Two-way sync")
                } footer: {
                    Text("When enabled, email addresses and phone numbers you add or remove on a synced iPhone contact are written back to your Monica account. Completing a synced reminder is always pushed back.")
                }

                Section {
                    Toggle("Remove items deleted in Monica", isOn: $model.settings.removeOrphans)
                } footer: {
                    Text("When something is deleted on the server (or deselected above), its mirrored contact, reminder or event is removed from this iPhone on the next sync. Items you delete on the iPhone are never re-created.")
                }

                Section {
                    NavigationLink {
                        DAVSetupView()
                    } label: {
                        Label("Native CardDAV/CalDAV sync", systemImage: "arrow.triangle.2.circlepath.circle")
                    }
                } footer: {
                    Text("Monica also speaks CardDAV/CalDAV. iOS can sync contacts and calendars natively — no app needed — in parallel or instead of this app's sync.")
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        showSignOutConfirmation = true
                    }
                } footer: {
                    Text("Signing out removes the API token and sync bookkeeping from this device. Contacts, reminders and events that were already synced stay on your iPhone.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Sign out of Monica?",
                isPresented: $showSignOutConfirmation,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) { model.signOut() }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showVaultPicker) {
                VaultPickerSheet()
            }
        }
    }
}

// MARK: - Vault picker (v5)

private struct VaultPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var vaults: [MonicaVault] = []
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading vaults…")
                } else if let errorMessage {
                    ErrorBanner(message: errorMessage) { Task { await load() } }
                } else {
                    List(vaults) { vault in
                        Button {
                            if vault.id != model.vaultID {
                                model.switchVault(vault)
                            }
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vault.name).foregroundStyle(.primary)
                                    if let description = vault.description, !description.isEmpty {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if vault.id == model.vaultID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose a vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            vaults = try await model.fetchVaults()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - CardDAV/CalDAV helper

/// Walks the user through adding their Monica server as a native iOS
/// CardDAV/CalDAV account.
struct DAVSetupView: View {
    @Environment(AppModel.self) private var model

    private var davURL: String {
        guard let server = model.serverURLString else { return "" }
        return server + "/dav"
    }

    var body: some View {
        Form {
            Section {
                Text("Your Monica server exposes contacts as CardDAV and calendars/tasks as CalDAV. Adding it as a native account lets iOS itself keep Contacts, Calendar and Reminders in sync — continuously and in both directions, without opening this app.")
                    .font(.callout)
            }

            Section("Server address") {
                LabeledContent("DAV endpoint", value: davURL)
                Button {
                    UIPasteboard.general.string = davURL
                } label: {
                    Label("Copy address", systemImage: "doc.on.doc")
                }
            }

            Section("Contacts (CardDAV)") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Open Settings → Apps → Contacts → Accounts (on older iOS: Settings → Contacts → Accounts).")
                    Text("2. Add Account → Other → Add CardDAV Account.")
                    Text("3. Server: paste the address above. Enter your Monica email and password.")
                }
                .font(.callout)
            }

            Section("Calendars & reminders (CalDAV)") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Open Settings → Apps → Calendar → Accounts.")
                    Text("2. Add Account → Other → Add CalDAV Account.")
                    Text("3. Server: paste the address above. Enter your Monica email and password.")
                }
                .font(.callout)
            }

            Section {
                Text("If your account uses two-factor authentication or an SSO login, native DAV accounts may not be able to sign in — in that case keep using this app's built-in sync.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Native DAV sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}
