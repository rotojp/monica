import Foundation

/// Marker lines embedded in the notes of mirrored Reminders/Calendar items.
/// They tie a device item back to its Monica record even when the mapping
/// file is gone (fresh install), preventing duplicates.
enum SyncTag {
    static func task(_ id: String) -> String { "monica://task/\(id)" }
    static func reminder(_ id: String) -> String { "monica://reminder/\(id)" }
    static func activity(_ id: String) -> String { "monica://activity/\(id)" }

    static func taskID(fromNotes notes: String?) -> String? {
        id(fromNotes: notes, prefix: "monica://task/")
    }

    private static func id(fromNotes notes: String?, prefix: String) -> String? {
        guard let notes else { return nil }
        for line in notes.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                let id = String(trimmed.dropFirst(prefix.count))
                if !id.isEmpty { return id }
            }
        }
        return nil
    }
}
