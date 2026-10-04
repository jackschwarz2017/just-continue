import Foundation

typealias JSONObject = [String: Any]

enum JSONLines {
    /// Parses the last `maxBytes` of a JSONL file. A partial first line is dropped.
    static func tail(of url: URL, maxBytes: Int = 512 * 1024) -> [JSONObject] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [] }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { parse(Data($0)) }
    }

    static func firstLine(of url: URL, maxBytes: Int = 64 * 1024) -> JSONObject? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        guard let line = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first else { return nil }
        return parse(Data(line))
    }

    static func parse(_ data: Data) -> JSONObject? {
        (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
    }

    static func parse(_ line: String) -> JSONObject? { parse(Data(line.utf8)) }

    /// True if an id read from a log is safe to use in a file name (no path separators or "..").
    static func isSafeFileName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 128 && !s.contains("..")
            && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." }
    }
}

extension Dictionary where Key == String, Value == Any {
    subscript(path path: String...) -> Any? {
        var current: Any? = self
        for key in path { current = (current as? JSONObject)?[key] }
        return current
    }
}

enum ISO8601 {
    // ISO8601DateFormatter is thread-safe.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let whole = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return fractional.date(from: s) ?? whole.date(from: s)
    }
}

func epochDate(_ value: Any?) -> Date? {
    if let n = value as? NSNumber, n.doubleValue > 0 { return Date(timeIntervalSince1970: n.doubleValue) }
    if let s = value as? String, let d = Double(s), d > 0 { return Date(timeIntervalSince1970: d) }
    return nil
}
