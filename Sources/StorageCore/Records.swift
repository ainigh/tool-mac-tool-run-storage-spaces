import Foundation

/// A folder of records: JSON values by key (`schedule-12`, `settings`), a file each (`KEY.json`),
/// each with a version that goes up by one every time it's written. A write can say which
/// version it read (`expect`): if the record has moved on since, nothing is written and the
/// answer says so (409), so two writers never overwrite each other unseen.
///
/// Peter keeps what he needs to work in these (his schedule, how things stand, the runs he's
/// following, his settings); PENDING keeps what's waiting.
public struct RecordStore: Sendable {
    public let root: URL
    /// How it's named in messages ("peter/schedule").
    public let name: String

    public static let ext = "json"
    /// The most a record's value may be, written out.
    public static let maxBytes = 1024 * 1024
    /// The most records a store may hold.
    public static let maxRecords = 10_000

    public init(root: URL, name: String) {
        self.root = root
        self.name = name
    }

    /// A record: its key, its value, and what's known about it.
    public struct Record: Sendable {
        public var key: String
        public var version: Int
        public var created: Date
        public var updated: Date
        /// Who wrote it last.
        public var by: String?
        /// The JSON value (an object, a list, a string, a number, true or false).
        public var value: Any {
            get { box.value }
            set { box = Box(newValue) }
        }

        var box: Box

        struct Box: @unchecked Sendable {
            let value: Any
            init(_ v: Any) { value = v }
        }

        public init(key: String, value: Any, version: Int, created: Date, updated: Date, by: String?) {
            self.key = key
            box = Box(value)
            self.version = version
            self.created = created
            self.updated = updated
            self.by = by
        }
    }

    public func ensure() throws {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw LibraryError(.failed, "Couldn't make \(name) (\(root.path)): \(error.localizedDescription)")
        }
    }

    // MARK: keys

    /// A key as it's kept: letters, digits, spaces, dots, dashes and underscores, up to 128,
    /// not starting with a dot. Throws with what's wrong.
    public static func key(_ text: String) throws -> String {
        let k = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fix = "A key is up to 128 letters, digits, spaces, dots, dashes and underscores (schedule-12, last run, settings.model)."
        guard !k.isEmpty else { throw LibraryError(.badName, "Say which record: \"key\".", fix: fix) }
        guard k.count <= 128 else { throw LibraryError(.badName, "That key is too long (at most 128 characters).", fix: fix) }
        guard !k.hasPrefix(".") else { throw LibraryError(.badName, "A key can't start with a dot.", fix: fix) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        guard k.unicodeScalars.allSatisfy(allowed.contains) else {
            throw LibraryError(.badName, "\"\(k)\" can't be a key: it has a character other than letters, digits, spaces, dots, dashes and underscores.", fix: fix)
        }
        return k
    }

    func file(_ key: String) -> URL { root.appendingPathComponent(key + "." + Self.ext) }

    // MARK: reading

    /// Every key, A to Z (only those starting with `prefix`, when there's one).
    public func keys(prefix: String? = nil) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var keys = names.filter { $0.hasSuffix("." + Self.ext) && !$0.hasPrefix(".") }.map { String($0.dropLast(Self.ext.count + 1)) }
        if let p = prefix, !p.isEmpty { keys = keys.filter { $0.lowercased().hasPrefix(p.lowercased()) } }
        return keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// One record, or nil when there's none of that key.
    public func get(_ key: String) throws -> Record? {
        let k = try Self.key(key)
        guard let data = try? Data(contentsOf: file(k)) else { return nil }
        return Self.decode(data, key: k)
    }

    /// Every record (only those whose key starts with `prefix`, when there's one), by key.
    public func list(prefix: String? = nil) -> [Record] {
        keys(prefix: prefix).compactMap { k in (try? Data(contentsOf: file(k))).flatMap { Self.decode($0, key: k) } }
    }

    // MARK: writing

    /// A write that couldn't go ahead because the record isn't at the version the writer read.
    public struct Conflict: Error, Sendable {
        public var key: String
        /// The version it is at (0: there's none).
        public var version: Int
        public var expected: Int
    }

    /// Writes a record's value: version 1 when it's new, one more than it was otherwise. With
    /// `expect`, only if the record is at that version now (0: only if there's none yet).
    @discardableResult
    public func put(_ key: String, _ value: Any, expect: Int? = nil, by: String? = nil, now: Date = Date()) throws -> (record: Record, created: Bool) {
        let k = try Self.key(key)
        RecordLock.shared.lock()
        defer { RecordLock.shared.unlock() }
        try ensure()
        let before = (try? Data(contentsOf: file(k))).flatMap { Self.decode($0, key: k) }
        if let expect, expect != (before?.version ?? 0) {
            throw Conflict(key: k, version: before?.version ?? 0, expected: expect)
        }
        if before == nil, keys().count >= Self.maxRecords {
            throw LibraryError(.failed, "\(name) is full (\(Self.maxRecords) records).", fix: "Delete the ones no longer needed.")
        }
        let record = Record(key: k, value: value, version: (before?.version ?? 0) + 1, created: before?.created ?? now, updated: now, by: by)
        let data = try Self.encode(record)
        guard data.count <= Self.maxBytes + 512 else {
            throw LibraryError(.badName, "That value is too big for a record (\(data.count / 1024) KB; at most \(Self.maxBytes / 1024) KB).",
                               fix: "Split it over several records, or keep it as a note.")
        }
        do {
            try data.write(to: file(k), options: .atomic)
        } catch {
            throw LibraryError(.failed, "Couldn't write \(k) in \(name): \(error.localizedDescription)")
        }
        return (record, before == nil)
    }

    /// Merges fields into a record that's an object (a field set to null is taken out); a record
    /// that isn't there starts as {}.
    @discardableResult
    public func patch(_ key: String, _ fields: [String: Any], expect: Int? = nil, by: String? = nil, now: Date = Date()) throws -> (record: Record, created: Bool) {
        RecordLock.shared.lock()
        defer { RecordLock.shared.unlock() }
        let current = try get(key)
        guard var object = (current?.value ?? [String: Any]()) as? [String: Any] else {
            throw LibraryError(.badName, "\(key) isn't an object, so it can't take fields.", fix: "Write it whole instead (put).")
        }
        for (k, v) in fields {
            if v is NSNull { object[k] = nil } else { object[k] = v }
        }
        return try put(key, object, expect: expect, by: by, now: now)
    }

    /// Adds items at the end of a record that's a list (made if it isn't there), keeping the
    /// latest `keep` when there's a limit.
    @discardableResult
    public func append(_ key: String, _ items: [Any], keep: Int? = nil, expect: Int? = nil, by: String? = nil, now: Date = Date()) throws -> (record: Record, created: Bool) {
        RecordLock.shared.lock()
        defer { RecordLock.shared.unlock() }
        let current = try get(key)
        guard var list = (current?.value ?? [Any]()) as? [Any] else {
            throw LibraryError(.badName, "\(key) isn't a list, so nothing can be added to its end.", fix: "Write it whole instead (put).")
        }
        list += items
        if let keep, keep >= 0, list.count > keep { list = Array(list.suffix(keep)) }
        return try put(key, list, expect: expect, by: by, now: now)
    }

    /// Deletes a record for good. With `expect`, only if it's at that version. Returns whether
    /// there was one.
    @discardableResult
    public func delete(_ key: String, expect: Int? = nil) throws -> Bool {
        let k = try Self.key(key)
        RecordLock.shared.lock()
        defer { RecordLock.shared.unlock() }
        let before = (try? Data(contentsOf: file(k))).flatMap { Self.decode($0, key: k) }
        if let expect, expect != (before?.version ?? 0) {
            throw Conflict(key: k, version: before?.version ?? 0, expected: expect)
        }
        guard before != nil else { return false }
        do {
            try FileManager.default.removeItem(at: file(k))
        } catch {
            throw LibraryError(.failed, "Couldn't delete \(k) in \(name): \(error.localizedDescription)")
        }
        return true
    }

    // MARK: on disk

    /// A record's file: {"key", "version", "created", "updated", "by", "value"}, readable as it is.
    static func encode(_ r: Record) throws -> Data {
        var out: [String: Any] = ["key": r.key, "version": r.version, "created": JSON.date(r.created), "updated": JSON.date(r.updated), "value": r.value]
        if let by = r.by { out["by"] = by }
        guard JSONSerialization.isValidJSONObject(out) else {
            throw LibraryError(.badName, "That value isn't something JSON can hold.")
        }
        return try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }

    /// A record's file read back. A file written by hand that's just a JSON value is taken as
    /// that value, at version 1.
    static func decode(_ data: Data, key: String) -> Record? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        if let o = any as? [String: Any], let version = o["version"] as? Int, o.keys.contains("value") {
            return Record(key: key, value: o["value"] ?? NSNull(), version: version,
                          created: (o["created"] as? String).flatMap(JSON.parseDate) ?? Date(timeIntervalSince1970: 0),
                          updated: (o["updated"] as? String).flatMap(JSON.parseDate) ?? Date(timeIntervalSince1970: 0),
                          by: o["by"] as? String)
        }
        return Record(key: key, value: any, version: 1, created: Date(timeIntervalSince1970: 0), updated: Date(timeIntervalSince1970: 0), by: nil)
    }
}

/// One lock for every record write, so a version check and its write can't interleave with another.
enum RecordLock {
    static let shared = NSRecursiveLock()
}

extension JSON {
    /// A date as the API writes it, read back (with or without milliseconds).
    public static func parseDate(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        return try? Date(s, strategy: Date.ISO8601FormatStyle())
    }

    /// A day, as 2026-11-03.
    public static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
