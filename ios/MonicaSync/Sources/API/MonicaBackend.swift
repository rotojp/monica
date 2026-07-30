import Foundation

/// Device-side email/phone edits to push back to the server.
struct ContactFieldChanges {
    var addedEmails: [String] = []
    var removedEmails: [String] = []
    var addedPhones: [String] = []
    var removedPhones: [String] = []

    var isEmpty: Bool {
        addedEmails.isEmpty && removedEmails.isEmpty
            && addedPhones.isEmpty && removedPhones.isEmpty
    }
}

/// Everything the app needs from a Monica server, independent of generation.
protocol MonicaBackend: AnyObject {
    var generation: ServerGeneration { get }
    var baseURL: URL { get }
    /// v4 logs "activities"; v5 replaced them with journal entries that have
    /// no read API yet.
    var supportsActivities: Bool { get }
    /// Whether renaming a task on the device can be written back.
    var supportsTaskRename: Bool { get }

    func fetchContacts() async throws -> [SyncContact]
    func fetchContact(id: String) async throws -> SyncContact
    func fetchTasks() async throws -> [SyncTask]
    func fetchReminders() async throws -> [SyncReminder]
    func fetchActivities() async throws -> [SyncActivity]
    func fetchContactTasks(contactID: String) async throws -> [SyncTask]
    func fetchContactReminders(contactID: String) async throws -> [SyncReminder]
    func fetchContactActivities(contactID: String) async throws -> [SyncActivity]
    func fetchContactCalls(contactID: String) async throws -> [SyncCall]

    func setTask(_ task: SyncTask, title: String, completed: Bool) async throws
    func createTask(contactID: String, title: String, details: String?) async throws
    func logCall(contactID: String, content: String, date: Date) async throws
    func pushContactFieldChanges(contact: SyncContact, changes: ContactFieldChanges) async throws

    func fetchAvatarData(from urlString: String) async -> Data?
}

// MARK: - Server detection

enum ServerProbeResult {
    /// Classic v4 server; ready to go.
    case v4(accountName: String?)
    /// v5 server; a vault must be chosen before syncing.
    case v5(vaults: [MonicaVault])
}

enum BackendFactory {
    /// Figures out which Monica generation answers at `baseURL`.
    ///
    /// v5 exposes `/api/vaults` (v4 does not); v4 exposes `/api/contacts`
    /// at the root (v5 does not). Auth failures surface immediately since
    /// they mean the token is wrong regardless of generation.
    static func probe(baseURL: URL, token: String) async throws -> ServerProbeResult {
        let v5 = MonicaV5Client(baseURL: baseURL, token: token)
        do {
            let vaults = try await v5.fetchVaults()
            return .v5(vaults: vaults)
        } catch MonicaAPIError.unauthorized {
            throw MonicaAPIError.unauthorized
        } catch {
            // Fall through and try v4.
        }

        let v4 = MonicaAPIClient(
            config: MonicaServerConfig(baseURL: baseURL, token: token)
        )
        let accountName = try await v4.validateCredentials()
        return .v4(accountName: accountName)
    }

    /// Builds the backend for a stored session.
    static func make(
        generation: ServerGeneration,
        baseURL: URL,
        token: String,
        vaultID: String?
    ) -> any MonicaBackend {
        switch generation {
        case .v4:
            return MonicaV4Backend(
                client: MonicaAPIClient(
                    config: MonicaServerConfig(baseURL: baseURL, token: token)
                )
            )
        case .v5:
            return MonicaV5Backend(
                client: MonicaV5Client(baseURL: baseURL, token: token),
                vaultID: vaultID ?? ""
            )
        }
    }
}
