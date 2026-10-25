import Foundation

/// The mind on disk: MIND in the user space, holding the log (mind.txt, the notation's lines, read
/// top to bottom) and an Archive of the logs compaction replaced. The log is only ever added to:
/// what's sent is checked against the mind as it is (a line with a mistake is said with its fix,
/// and nothing is written), lines that would add nothing are left out, and the rest go at the
/// end, after a comment saying when and from whom. The log is the record; the graph is read from it.
public struct MindStore: Sendable {
    public let root: URL

    public static let folderName = "MIND"
    public static let logName = "mind.txt"
    public static let archiveName = "Archive"

    public init(root: URL) {
        self.root = root
    }

    public var file: URL { root.appendingPathComponent(Self.logName) }
    public var archive: URL { root.appendingPathComponent(Self.archiveName, isDirectory: true) }

    /// What a new log starts with: what it is, in comments.
    public static let seed = """
    The mind: what's known, as names and the links between them, in the text mind-map notation (MIND-GUIDE, in Storage Spaces' docs).
    Append only: add lines at the end, never change the ones above. A line starting with | is a statement; any other line is a comment.
    Each file in MEMORY is a node here, in the root scope (PEOPLE, ORGANIZATIONS, …): link what's learnt to them.

    """

    public var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// Makes the folder and the log (with its seed) when they aren't there.
    public func ensure() throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: file.path) { try Data(Self.seed.utf8).write(to: file, options: .atomic) }
        } catch {
            throw MindError(.failed, "Couldn't make the mind (\(file.path)): \(error.localizedDescription)")
        }
    }

    /// The log as it is ("" when there's none yet).
    public func log() -> String {
        guard let data = try? Data(contentsOf: file) else { return "" }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// The mind, compiled from the log (read again only when the file has changed).
    public func graph() -> MindGraph {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)/\(values?.fileSize ?? -1)"
        if let hit = MindCache.shared.get(file.path, stamp) { return hit }
        let g = MindGraph(log: log())
        MindCache.shared.put(file.path, stamp, g)
        return g
    }

    // MARK: adding to it

    public struct Appended: Sendable {
        /// The lines written (the stamp comment first, when there was one).
        public var written: [String]
        /// The statements written.
        public var added: [String]
        /// Lines left out because they'd add nothing (an edge, a note, a node already known).
        public var known: [String]
        /// Lines with a mistake (left out, when `partial`).
        public var problems: [MindGraph.Problem]
        /// The scope the lines went into.
        public var scope: String
        /// The mind after.
        public var graph: MindGraph
    }

    /// Adds statement lines at the end of the log. `scope` first switches to it (a line of its
    /// own, when the log isn't in it already); `stamp` is a comment written before them. A
    /// mistake in any line writes nothing (with `partial`, the others are written). A line that
    /// isn't a statement (no `|` first) is a mistake here: comments go in `comment`. A scope
    /// delete or merge is the person's to do, refused unless `scopeChanges`.
    @discardableResult
    public func append(_ lines: [String], scope: String? = nil, comment: String? = nil, stamp: String? = nil,
                       partial: Bool = false, scopeChanges: Bool = false, dryRun: Bool = false) throws -> Appended {
        MindCache.lock.lock()
        defer { MindCache.lock.unlock() }
        if !dryRun { try ensure() }
        let before = log()
        var g = MindGraph(log: before)
        var n = g.lines
        var out: [String] = []
        var added: [String] = []
        var known: [String] = []
        var problems: [MindGraph.Problem] = []

        func take(_ raw: String, isComment: Bool = false) {
            let line = MindNotation.collapse(raw)
            guard !line.isEmpty else { return }
            n += 1
            do {
                let parsed = try MindNotation.parse(line)
                if case .comment = parsed, !isComment {
                    throw MindNotation.Mistake("\"\(line)\" isn't a statement (it doesn't start with |), so it would only be a comment.",
                                               fix: "Start it with | (| sam - writes | paper), or send it as \"comment\".")
                }
                if case .statement(let s) = parsed {
                    switch s {
                    case .deleteScope(let a) where !scopeChanges, .mergeScope(let a, _) where !scopeChanges:
                        throw MindNotation.Mistake("Deleting or merging a scope (\(a)) is the person's to do, not an app's.",
                                                   fix: "Do it on the Mind board (its text view), or leave the scope as it is.")
                    case .scope(let s) where s == g.current:
                        return
                    default: break
                    }
                }
                let was = g.canonical
                let current = g.current
                try g.apply(line, line: n)
                if case .statement(let s) = parsed {
                    if case .scope = s {} else if g.canonical == was, g.current == current {
                        known.append(line)
                        return
                    }
                    added.append(line)
                }
                out.append(line)
            } catch let m as MindNotation.Mistake {
                problems.append(MindGraph.Problem(line: n, text: line, message: m.message, fix: m.fix))
            } catch {
                problems.append(MindGraph.Problem(line: n, text: line, message: "\(error)", fix: ""))
            }
        }

        if let comment, !comment.trimmingCharacters(in: .whitespaces).isEmpty {
            for c in comment.components(separatedBy: .newlines) {
                let t = MindNotation.collapse(c)
                // A comment line can't start with | (it would be a statement).
                if !t.isEmpty { take(t.hasPrefix("|") ? "¦" + t.dropFirst() : t, isComment: true) }
            }
        }
        if let scope {
            let s = MindNotation.collapse(scope)
            if s.isEmpty || s == "@" {
                if !g.current.isEmpty {
                    problems.append(MindGraph.Problem(line: n + 1, text: "(the root scope)", message: "The log is in scope \(g.current) now, and the notation has no line back to the root scope.",
                                                      fix: "Write root names with an @ after them (sam@), or leave scope out."))
                }
            } else {
                take("| @ " + s)
            }
        }
        for raw in lines { take(raw) }

        if !problems.isEmpty, !partial {
            throw MindError(.badLines, problems.count == 1 ? "A line has a mistake, so nothing was added." : "\(problems.count) lines have mistakes, so nothing was added.",
                            fix: problems.map { "line \($0.line) (\($0.text)): \($0.message) \($0.fix)" }.joined(separator: "\n"), problems: problems)
        }
        // Only a scope line, or nothing at all: nothing to write.
        guard !added.isEmpty || out.contains(where: { !$0.hasPrefix("|") }) else {
            return Appended(written: [], added: [], known: known, problems: problems, scope: MindGraph(log: before).current, graph: MindGraph(log: before))
        }
        var written = out
        if let stamp, !stamp.isEmpty { written.insert(MindNotation.collapse(stamp.hasPrefix("|") ? String(stamp.dropFirst()) : stamp), at: 0) }
        var text = before
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += written.joined(separator: "\n") + "\n"
        // Only checking: what would be written, and the mind it would make.
        if dryRun { return Appended(written: written, added: added, known: known, problems: problems, scope: g.current, graph: g) }
        do {
            try Data(text.utf8).write(to: file, options: .atomic)
            MindCache.shared.drop(file.path)
        } catch {
            throw MindError(.failed, "Couldn't add to the mind (\(file.path)): \(error.localizedDescription)")
        }
        let after = MindGraph(log: text)
        return Appended(written: written, added: added, known: known, problems: problems, scope: after.current, graph: after)
    }

    /// The comment written before what an app adds: when, and who.
    public static func stamp(_ who: String?, at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "— \(f.string(from: date))" + (who.map { " · \($0)" } ?? "")
    }

    // MARK: keeping it small

    /// Replaces the log with its canonical form (the same mind, one line a fact), keeping the old
    /// log in the Archive (compaction loses the replay of its edits: the archive keeps it). Returns
    /// the archived file.
    @discardableResult
    public func compact(at date: Date = Date()) throws -> URL {
        MindCache.lock.lock()
        defer { MindCache.lock.unlock() }
        let text = log()
        let g = MindGraph(log: text)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: archive, withIntermediateDirectories: true)
            var target = archive.appendingPathComponent("mind-\(f.string(from: date)).txt")
            var k = 2
            while fm.fileExists(atPath: target.path) {
                target = archive.appendingPathComponent("mind-\(f.string(from: date))-\(k).txt")
                k += 1
            }
            try Data(text.utf8).write(to: target, options: .atomic)
            try Data(g.canonical.utf8).write(to: file, options: .atomic)
            MindCache.shared.drop(file.path)
            return target
        } catch {
            throw MindError(.failed, "Couldn't compact the mind: \(error.localizedDescription)")
        }
    }

    /// The logs compaction put away, the latest first.
    public func archived() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: MEMORY's files, as nodes

    /// Each MEMORY file, as a node of the root scope: the ones that aren't nodes yet are added
    /// (a line each). Returns the lines added.
    @discardableResult
    public func index(_ memory: FileLibrary, who: String? = nil) throws -> [String] {
        let g = exists ? graph() : MindGraph()
        let missing = memory.names().filter { name in g.node(MindNodeID(name)) == nil && MindNotation.nameProblem(name) == nil }
        guard !missing.isEmpty else { return [] }
        let current = g.current
        let lines = missing.map { "| " + MindNotation.written(MindNodeID($0), current: current) }
        return try append(lines, stamp: Self.stamp(who ?? "MEMORY's files, each a node")).added
    }

    /// A MEMORY file renamed: its node too (merging into one of the new name, if there is one).
    @discardableResult
    public func renamed(_ old: String, to new: String, who: String? = nil) throws -> [String] {
        guard exists, old != new else { return [] }
        let g = graph()
        guard g.node(MindNodeID(old)) != nil else { return [] }
        let line = "| " + MindNotation.written(MindNodeID(old), current: g.current) + " = " + MindNotation.written(MindNodeID(new), current: g.current)
        return try append([line], stamp: Self.stamp(who ?? "a MEMORY file renamed")).added
    }
}

/// What went wrong with the mind, in words, with the fix (and the lines, for mistakes in them).
public struct MindError: Error, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable {
        case badLines = "bad_lines"
        case notFound = "not_found"
        case badRequest = "bad_request"
        case failed
    }

    public var code: Code
    public var message: String
    public var fix: String?
    public var problems: [MindGraph.Problem]

    public init(_ code: Code, _ message: String, fix: String? = nil, problems: [MindGraph.Problem] = []) {
        self.code = code
        self.message = message
        self.fix = fix
        self.problems = problems
    }

    public var description: String { fix.map { "\(message) \($0)" } ?? message }

    public var status: Int {
        switch code {
        case .badLines, .badRequest: 400
        case .notFound: 404
        case .failed: 500
        }
    }
}

/// The compiled mind, kept while its file is unchanged; and the lock that keeps two appends
/// from interleaving.
final class MindCache: @unchecked Sendable {
    static let shared = MindCache()
    static let lock = NSRecursiveLock()

    private let guardLock = NSLock()
    private var entries: [String: (String, MindGraph)] = [:]

    func get(_ path: String, _ stamp: String) -> MindGraph? {
        guardLock.lock()
        defer { guardLock.unlock() }
        guard let e = entries[path], e.0 == stamp else { return nil }
        return e.1
    }

    func drop(_ path: String) {
        guardLock.lock()
        entries[path] = nil
        guardLock.unlock()
    }

    func put(_ path: String, _ stamp: String, _ g: MindGraph) {
        guardLock.lock()
        entries[path] = (stamp, g)
        guardLock.unlock()
    }
}
