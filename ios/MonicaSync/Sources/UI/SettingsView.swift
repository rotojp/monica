import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var showSignOutConfirmation = false

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
                }

                Section {
                    Toggle(
                        "Push local contact edits to Monica",
                        isOn: $model.settings.pushLocalContactChanges
                    )
                } header: {
                    Text("Two-way sync")
                } footer: {
                    Text("When enabled, email addresses and phone numbers you add or remove on a synced iPhone contact are written back to your Monica account. Completing or renaming a synced reminder is always pushed back.")
                }

                Section {
                    Toggle("Remove items deleted in Monica", isOn: $model.settings.removeOrphans)
                } footer: {
                    Text("When something is deleted on the server, its mirrored contact, reminder or event is removed from this iPhone on the next sync. Items you delete on the iPhone are never re-created.")
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
        }
    }
}
