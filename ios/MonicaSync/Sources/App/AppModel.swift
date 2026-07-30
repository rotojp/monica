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
        static let serverGeneration = "server.generation"
        static let accountName = "server.accountName"
        static let vaultID = "server.vaultID"
        static let vaultName = "server.vaultName"
        static let contactSelectionEnabled = "sync.contacts.selectionEnabled"
        static let selectedContactIDs = "sync.contacts.selectedIDs"
        static let reminderTargetID = "sync.reminderTargetIdentifier"
        static let calendarTargetID = "sync.calendarTargetIdentifier"
        static let reminderListID = "sync.reminderListIdentifier"
        static let eventCalendarID = "sync.eventCalendarIdentifier"
    }

    /// Mirror Monica people into the iPhone address book.
    var syncContacts: Bool
    /// Mirror Monica tasks into the Reminders app (two-way completion).
    var syncTasks: Bool
    /// Mirror Monica reminders (and activities on v4) into a device calendar.
    var syncCalendar: Bool
    /// Push email/phone edits made on the iPhone back to the Monica server.
    var pushLocalContactChanges: Bool
    /// Delete device mirrors whose Monica record was removed on the server.
    var removeOrphans: Bool
    /// When true, only the contacts in `selectedContactIDs` are mirrored.
    var contactSelectionEnabled: Bool
    /// Monica IDs of the contacts chosen for import.
    var selectedContactIDs: Set<String>
    /// Identifier of the Reminders list tasks sync into.
    /// Nil = create/use a dedicated "Monica" list.
    var reminderTargetID: String?
    /// Identifier of the calendar reminders/activities sync into.
    /// Nil = create/use a dedicated "Monica" calendar.
    var calendarTargetID: String?

    static func load() -> SyncSettings {
        SyncSettings(
            syncContacts: defaults.object(forKey: Keys.syncContacts) as? Bool ?? true,
            syncTasks: defaults.object(forKey: Keys.syncTasks) as? Bool ?? true,
            syncCalendar: defaults.object(forKey: Keys.syncCalendar) as? Bool ?? true,
            pushLocalContactChanges: defaults.bool(forKey: Keys.pushLocalContactChanges),
            removeOrphans: defaults.object(forKey: Keys.removeOrphans) as? Bool ?? true,
            contactSelectionEnabled: defaults.bool(forKey: Keys.contactSelectionEnabled),
            selectedContactIDs: Set(
                defaults.stringArray(forKey: Keys.selectedContactIDs) ?? []
            ),
            reminderTargetID: defaults.string(forKey: Keys.reminderTargetID),
            calendarTargetID: defaults.string(forKey: Keys.calendarTargetID)
        )
    }

    func persist() {
        Self.defaults.set(syncContacts, forKey: Keys.syncContacts)
        Self.defaults.set(syncTasks, forKey: Keys.syncTasks)
        Self.defaults.set(syncCalendar, forKey: Keys.syncCalendar)
        Self.defaults.set(pushLocalContactChanges, forKey: Keys.pushLocalContactChanges)
        Self.defaults.set(removeOrphans, forKey: Keys.removeOrphans)
        Self.defaults.set(contactSelectionEnabled, forKey: Keys.contactSelectionEnabled)
        Self.defaults.set(Array(selectedContactIDs).sorted(), forKey: Keys.selectedContactIDs)
        Self.defaults.set(reminderTargetID, forKey: Keys.reminderTargetID)
        Self.defaults.set(calendarTargetID, forKey: Keys.calendarTargetID)
        if reminderTargetID == nil {
            Self.defaults.removeObject(forKey: Keys.reminderTargetID)
        }
        if calendarTargetID == nil {
            Self.defaults.removeObject(forKey: Keys.calendarTargetID)
        }
    }

    /// True when this contact should be mirrored under the current selection.
    func includesContact(id: String) -> Bool {
        !contactSelectionEnabled || selectedContactIDs.contains(id)
    }
}

// MARK: - App model

/// Session state: which server (and vault, on v5) we talk to, with which token.
@MainActor
@Observable
final class AppModel {
    private static let tokenKey = "monica.api.token"

    private(set) var backend: (any MonicaBackend)?
    private(set) var serverURLString: String?
    private(set) var generation: ServerGeneration?
    private(set) var accountName: String?
    private(set) var vaultID: String?
    private(set) var vaultName: String?

    /// Set while sign-in waits for the user to pick a vault (v5, multi-vault).
    private(set) var pendingVaults: [MonicaVault]?
    private var pendingBaseURL: URL?
    private var pendingToken: String?

    var settings: SyncSettings {
        didSet { settings.persist() }
    }

    var isConfigured: Bool { backend != nil }

    init() {
        settings = SyncSettings.load()
        let defaults = UserDefaults.standard
        serverURLString = defaults.string(forKey: SyncSettings.Keys.serverURL)
        accountName = defaults.string(forKey: SyncSettings.Keys.accountName)
        vaultID = defaults.string(forKey: SyncSettings.Keys.vaultID)
        vaultName = defaults.string(forKey: SyncSettings.Keys.vaultName)
        generation = defaults.string(forKey: SyncSettings.Keys.serverGeneration)
            .flatMap(ServerGeneration.init(rawValue:))

        if let serverURLString,
           let url = URL(string: serverURLString),
           let generation,
           let token = KeychainStore.read(Self.tokenKey) {
            backend = BackendFactory.make(
                generation: generation, baseURL: url, token: token, vaultID: vaultID
            )
        }
    }

    /// Validates the pair against the server. On a v5 server with several
    /// vaults, sign-in pauses and `pendingVaults` is populated; complete it
    /// with `selectVault(_:)`.
    func signIn(serverInput: String, token: String) async throws {
        guard let baseURL = MonicaServerConfig.normalizedBaseURL(from: serverInput) else {
            throw MonicaAPIError.invalidURL
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { throw MonicaAPIError.unauthorized }

        switch try await BackendFactory.probe(baseURL: baseURL, token: trimmedToken) {
        case .v4(let name):
            persistSession(
                baseURL: baseURL, token: trimmedToken, generation: .v4,
                accountName: name, vault: nil
            )

        case .v5(let vaults):
            guard let first = vaults.first else {
                throw MonicaAPIError.http(
                    status: 404,
                    message: "No vault found on this server. Create one in Monica first."
                )
            }
            if vaults.count == 1 {
                persistSession(
                    baseURL: baseURL, token: trimmedToken, generation: .v5,
                    accountName: nil, vault: first
                )
            } else {
                pendingBaseURL = baseURL
                pendingToken = trimmedToken
                pendingVaults = vaults
            }
        }
    }

    /// Completes a v5 sign-in after the user picked a vault.
    func selectVault(_ vault: MonicaVault) {
        guard let baseURL = pendingBaseURL, let token = pendingToken else { return }
        persistSession(
            baseURL: baseURL, token: token, generation: .v5,
            accountName: nil, vault: vault
        )
        pendingVaults = nil
        pendingBaseURL = nil
        pendingToken = nil
    }

    /// Switches to a different vault on the same v5 server. Sync bookkeeping
    /// is reset since the mirrored data set changes entirely.
    func switchVault(_ vault: MonicaVault) {
        guard generation == .v5,
              let serverURLString,
              let baseURL = URL(string: serverURLString),
              let token = KeychainStore.read(Self.tokenKey)
        else { return }
        SyncMappingStore().reset()
        settings.selectedContactIDs = []
        persistSession(
            baseURL: baseURL, token: token, generation: .v5,
            accountName: nil, vault: vault
        )
    }

    /// Lists the vaults available on the connected v5 server.
    func fetchVaults() async throws -> [MonicaVault] {
        guard let serverURLString,
              let baseURL = URL(string: serverURLString),
              let token = KeychainStore.read(Self.tokenKey)
        else { return [] }
        return try await MonicaV5Client(baseURL: baseURL, token: token).fetchVaults()
    }

    private func persistSession(
        baseURL: URL,
        token: String,
        generation: ServerGeneration,
        accountName: String?,
        vault: MonicaVault?
    ) {
        KeychainStore.save(token, for: Self.tokenKey)
        let defaults = UserDefaults.standard
        defaults.set(baseURL.absoluteString, forKey: SyncSettings.Keys.serverURL)
        defaults.set(generation.rawValue, forKey: SyncSettings.Keys.serverGeneration)
        defaults.set(accountName, forKey: SyncSettings.Keys.accountName)
        defaults.set(vault?.id, forKey: SyncSettings.Keys.vaultID)
        defaults.set(vault?.name, forKey: SyncSettings.Keys.vaultName)

        serverURLString = baseURL.absoluteString
        self.generation = generation
        self.accountName = accountName
        vaultID = vault?.id
        vaultName = vault?.name
        backend = BackendFactory.make(
            generation: generation, baseURL: baseURL, token: token, vaultID: vault?.id
        )
    }

    /// Clears credentials and sync bookkeeping. Mirrored data already on the
    /// device is left in place — the user owns it from here on.
    func signOut() {
        KeychainStore.delete(Self.tokenKey)
        let defaults = UserDefaults.standard
        for key in [
            SyncSettings.Keys.serverURL,
            SyncSettings.Keys.serverGeneration,
            SyncSettings.Keys.accountName,
            SyncSettings.Keys.vaultID,
            SyncSettings.Keys.vaultName,
            SyncSettings.Keys.lastSyncDate,
            SyncSettings.Keys.selectedContactIDs,
        ] {
            defaults.removeObject(forKey: key)
        }
        SyncMappingStore().reset()
        backend = nil
        serverURLString = nil
        generation = nil
        accountName = nil
        vaultID = nil
        vaultName = nil
        settings.selectedContactIDs = []
        settings.contactSelectionEnabled = false
    }
}
