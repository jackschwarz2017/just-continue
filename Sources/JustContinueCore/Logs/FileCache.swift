import Foundation

/// Keeps a value computed from a file until the file's size or modification date changes.
/// Discovery runs every few seconds; this avoids re-parsing logs that haven't changed.
final class FileCache<Value>: @unchecked Sendable {
    private struct Entry {
        var size: UInt64
        var modified: Date
        var value: Value
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let limit: Int

    init(limit: Int = 512) { self.limit = limit }

    /// `key` defaults to the file's path; pass one when several values come from the same file.
    func value(for url: URL, key: String? = nil, compute: () -> Value) -> Value {
        // FileManager, not URL.resourceValues: URL caches resource values per instance.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return compute() }
        let key = key ?? url.path
        if let hit = lock.withLock({ entries[key] }), hit.size == size, hit.modified == modified {
            return hit.value
        }
        let value = compute()
        lock.withLock {
            if entries.count >= limit { entries.removeAll() }
            entries[key] = Entry(size: size, modified: modified, value: value)
        }
        return value
    }
}
