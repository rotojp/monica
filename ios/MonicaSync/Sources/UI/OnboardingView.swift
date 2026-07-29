import SwiftUI

/// First-run screen: pick the server (monicahq.com or self-hosted) and paste
/// an API token.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    @State private var server = "https://app.monicahq.com"
    @State private var token = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "person.2.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                        Text("Connect to Monica")
                            .font(.title2.bold())
                        Text("Works with monicahq.com and self-hosted Monica instances. Your data syncs with the iPhone's Contacts, Reminders and Calendar apps.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Server") {
                    TextField("https://monica.example.org", text: $server)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section {
                    SecureField("API token", text: $token)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("API token")
                } footer: {
                    Text("Create one on your Monica server under Settings → API → Create a token, then paste it here. The token is stored in the iPhone's Keychain.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        connect()
                    } label: {
                        if isConnecting {
                            HStack {
                                ProgressView()
                                Text("Connecting…")
                            }
                        } else {
                            Text("Connect")
                        }
                    }
                    .disabled(isConnecting || token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Monica")
        }
    }

    private func connect() {
        errorMessage = nil
        isConnecting = true
        Task {
            do {
                try await model.signIn(serverInput: server, token: token)
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }
}
