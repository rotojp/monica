import CryptoKit
import Foundation

/// One tracked link between a Monica record and its mirror on the device.
struct SyncRecord: Codable {
    /// Identifier of the mirrored item on the device
    /// (`CNContact.identifier` / `EKCalendarItem.calendarItemIdentifier`).
    var localIdentifier: String
    /// Hash of the remote payload as last applied — detects server-side edits.
    var remoteFingerprint: String
    /// Hash of the locally visible fields as last applied — detects on-device
    /// edits (the Contacts/EventKit stores expose no reliable change dates).
    var localFingerprint: String
    var lastSyncedAt: Date
    /// Set when the user deleted the mirror on the device so the sync does not
    /// resurrect it on the next pass.
    var deletedLocally: Bool

    init(
        localIdentifier: String,
        remoteFingerprint: String,
        localFingerprint: String,
        lastSyncedAt: Date = Date(),
        deletedLocally: Bool = false
    ) {
        self.localIdentifier = localIdentifier
        self.remoteFingerprint = remoteFingerprint
        self.localFingerprint = localFingerprint
        self.lastSyncedAt = lastSyncedAt
        self.deletedLocally = deletedLocally
    }
}

/// Persists Monica-ID → device-ID mappings between syncs. Keys are namespaced
/// per record type: `contact:12`, `task:5`, `reminder:7`, `activity:3`.
final class SyncMappingStore {
    private var records: [String: SyncRecord]
    private let fileURL: URL

    init(filename: String = "sync-state.json") {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MonicaSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(filename)

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: SyncRecord].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    static func key(_ type: String, _ id: Int) -> String { "\(type):\(id)" }

    subscript(key: String) -> SyncRecord? {
        get { records[key] }
        set { records[key] = newValue }
    }

    func keys(withPrefix prefix: String) -> [String] {
        records.keys.filter { $0.hasPrefix(prefix) }
    }

    func remove(_ key: String) {
        records[key] = nil
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Wipes all mappings — used on sign-out so a different account never
    /// reuses stale device links.
    func reset() {
        records = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - Fingerprints

enum Fingerprint {
    /// Stable hash over an ordered list of field values. Nil and empty values
    /// are normalized so cosmetic differences do not register as changes.
    static func of(_ parts: [String?]) -> String {
        let canonical = parts
            .map { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
