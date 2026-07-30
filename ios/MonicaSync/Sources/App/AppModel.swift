import Foundation
import Observation

// MARK: - Sync settings

/// User-tunable sync behavior, persisted in UserDefaults.
struct SyncSettings {
    private static let defaults = UserDefaults.standard

    enum Keys {
        static let syncContacts = "sync.contacts.enabled"
        static let syncTasks = "sync.tasks.enabled"
        static let syncCalendar = "sync.calendar.enabled"
        static let pushLocalContactChanges = "sync.contacts.pushLocal"
        static let removeOrphans = "sync.removeOrphans"
        static let lastSyncDate = "sync.lastDate"
        static let serverURL = "server.url"
        static let accountName = "server.accountName"
        static let reminderListID = "sync.reminderListIdentifier"
        static let eventCalendarID = "sync.eventCalendarIdentifier"
    }

    /// Mirror Monica people into the iPhone address book.
    var syncContacts: Bool
    /// Mirror Monica tasks into the Reminders app (two-way completion).
    var syncTasks: Bool
    /// Mirror Monica reminders and activities into a device calendar.
    var syncCalendar: Bool
    /// Push email/phone edits made on the iPhone back to the Monica server.
    var pushLocalContactChanges: Bool
    /// Delete device mirrors whose Monica record was removed on the server.
    var removeOrphans: Bool

    static func load() -> SyncSettings {
        SyncSettings(
            syncContacts: defaults.object(forKey: Keys.syncContacts) as? Bool ?? true,
            syncTasks: defaults.object(forKey: Keys.syncTasks) as? Bool ?? true,
            syncCalendar: defaults.object(forKey: Keys.syncCalendar) as? Bool ?? true,
            pushLocalContactChanges: defaults.bool(forKey: Keys.pushLocalContactChanges),
            removeOrphans: defaults.object(forKey: Keys.removeOrphans) as? Bool ?? true
        )
    }

    func persist() {
        Self.defaults.set(syncContacts, forKey: Keys.syncContacts)
        Self.defaults.set(syncTasks, forKey: Keys.syncTasks)
        Self.defaults.set(syncCalendar, forKey: Keys.syncCalendar)
        Self.defaults.set(pushLocalContactChanges, forKey: Keys.pushLocalContactChanges)
        Self.defaults.set(removeOrphans, forKey: Keys.removeOrphans)
    }
}

// MARK: - App model

/// Session state: which server we talk to and with which token.
@MainActor
@Observable
final class AppModel {
    private static let tokenKey = "monica.api.token"

    private(set) var client: MonicaAPIClient?
    private(set) var serverURLString: String?
    private(set) var accountName: String?
    var settings: SyncSettings {
        didSet { settings.persist() }
    }

    var isConfigured: Bool { client != nil }

    init() {
        settings = SyncSettings.load()
        let defaults = UserDefaults.standard
        serverURLString = defaults.string(forKey: SyncSettings.Keys.serverURL)
        accountName = defaults.string(forKey: SyncSettings.Keys.accountName)
        if let serverURLString,
           let url = URL(string: serverURLString),
           let token = KeychainStore.read(Self.tokenKey) {
            client = MonicaAPIClient(config: MonicaServerConfig(baseURL: url, token: token))
        }
    }

    /// Validates the pair against the server, then persists it.
    func signIn(serverInput: String, token: String) async throws {
        guard let baseURL = MonicaServerConfig.normalizedBaseURL(from: serverInput) else {
            throw MonicaAPIError.invalidURL
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { throw MonicaAPIError.unauthorized }

        let candidate = MonicaAPIClient(
            config: MonicaServerConfig(baseURL: baseURL, token: trimmedToken)
        )
        let name = try await candidate.validateCredentials()

        KeychainStore.save(trimmedToken, for: Self.tokenKey)
        let defaults = UserDefaults.standard
        defaults.set(baseURL.absoluteString, forKey: SyncSettings.Keys.serverURL)
        defaults.set(name, forKey: SyncSettings.Keys.accountName)
        serverURLString = baseURL.absoluteString
        accountName = name
        client = candidate
    }

    /// Clears credentials and sync bookkeeping. Mirrored data already on the
    /// device is left in place — the user owns it from here on.
    func signOut() {
        KeychainStore.delete(Self.tokenKey)
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: SyncSettings.Keys.serverURL)
        defaults.removeObject(forKey: SyncSettings.Keys.accountName)
        defaults.removeObject(forKey: SyncSettings.Keys.lastSyncDate)
        SyncMappingStore().reset()
        client = nil
        serverURLString = nil
        accountName = nil
    }
}
