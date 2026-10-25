import Foundation

/// A folder of notes (the person's LIBRARY, MEMORY, Super Face's PROMPT…), each a Markdown file,
/// and each known by its name alone: `groceries` is LIBRARY/groceries.md. A name is a key and the file's
/// text its value: list them, read one, write one (created or replaced), create one (only if it
/// isn't there), append to one, rename, copy, and delete one, which moves it to the library's own
/// Trash folder as `groceries (1).md`, `groceries (2).md`… so several of the same name can wait
/// there to be restored. Searching reads every file: the words anywhere in the name or the text.
///
/// Moved from Tool Mac Tool Run, as it was. The HTTP API serves every notes store with it
/// (`/api/spaces/user/library`, `/api/library`…). What kind of folder it is (`Shelf`) says how its
/// notes are spoken of: MEMORY's names are nodes of the mind too, so a name can't be one the
/// mind's notation can't write; a read-only one can't be changed.
public struct FileLibrary: Sendable {
    public let root: URL
    /// The extension its files have (without the dot): `md`.
    public let ext: String
    /// Which shelf it is (its words, and what it allows).
    public let shelf: Shelf

    public static let defaultExtension = "md"
    /// The person's library's folder name.
    public static let folderName = "LIBRARY"
    /// Where deleted notes go, inside the library: a folder of its own, never listed as a note.
    public static let trashName = "Trash"

    public init(root: URL, ext: String = FileLibrary.defaultExtension, shelf: Shelf = .library) {
        self.root = root
        self.ext = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        self.shelf = shelf
    }

    /// "the library", "MEMORY", "PROMPT".
    var place: String { shelf.place }
    private var Place: String { place.prefix(1).uppercased() + place.dropFirst() }

    public var trashFolder: URL { root.appendingPathComponent(Self.trashName, isDirectory: true) }
    private var trashIndex: URL { trashFolder.appendingPathComponent(".index.json") }

    // MARK: what's in it

    /// A note: its name, its file, and what the folder says about it.
    public struct Note: Sendable, Equatable {
        public var name: String
        public var url: URL
        public var size: Int
        public var modified: Date
        public var created: Date?
        /// Its first heading (`# Groceries`), else its first line that has words.
        public var title: String?
    }

    /// A note in the library's Trash: the name it had, its number there (the 1 of `groceries (1).md`),
    /// its file, and when it was deleted.
    public struct Trashed: Sendable, Equatable {
        public var name: String
        public var number: Int
        public var url: URL
        public var size: Int
        public var deleted: Date
    }

    public enum Sort: String, CaseIterable, Sendable {
        case name, modified, created, size
    }

    /// Makes the folder (and its Trash) if it isn't there.
    public func ensure() throws {
        do {
            // A shelf that can't be changed has nothing to put in a Trash.
            try FileManager.default.createDirectory(at: shelf.readOnly ? root : trashFolder, withIntermediateDirectories: true)
        } catch {
            throw LibraryError(.failed, "Couldn't make the \(shelf.folderName) folder \(root.path): \(error.localizedDescription)")
        }
    }

    /// Every note, by name (A to Z) unless asked otherwise.
    public func list(sort: Sort = .name, descending: Bool? = nil) -> [Note] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey],
                                                       options: [.skipsHiddenFiles]) else { return [] }
        let notes = files.compactMap { url -> Note? in
            guard url.pathExtension.lowercased() == ext.lowercased(),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            return note(at: url)
        }
        let down = descending ?? (sort != .name)
        func less(_ a: Note, _ b: Note) -> Bool {
            switch sort {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .modified: return a.modified < b.modified
            case .created: return (a.created ?? a.modified) < (b.created ?? b.modified)
            case .size: return a.size < b.size
            }
        }
        return notes.sorted { down ? less($1, $0) : less($0, $1) }
    }

    /// The names alone.
    public func names() -> [String] { list().map(\.name) }

    /// The note with this name: exactly, else the one whose name is the same but for case and
    /// accents (on a Mac, `Groceries` and `groceries` are the same file). Nil when there's none.
    public func find(_ name: String) -> Note? {
        guard let key = try? self.key(name) else { return nil }
        // From the folder's own list, so the name is the file's (on a Mac, GROCERIES.md is
        // groceries.md too, and would come back as typed).
        let all = list()
        if let exact = all.first(where: { $0.name == key }) { return exact }
        let folded = Self.fold(key)
        return all.first { Self.fold($0.name) == folded }
    }

    public func exists(_ name: String) -> Bool { find(name) != nil }

    /// A note's text. Throws `not_found` (with the names nearest to it) when there's none.
    public func read(_ name: String) throws -> (note: Note, text: String) {
        let n = try existing(name)
        do {
            return (n, try String(contentsOf: n.url, encoding: .utf8))
        } catch {
            // Not UTF-8: as Latin-1, so a note written elsewhere still reads.
            if let data = try? Data(contentsOf: n.url), let text = String(data: data, encoding: .isoLatin1) { return (n, text) }
            throw LibraryError(.failed, "Couldn't read \(n.name): \(error.localizedDescription)")
        }
    }

    public enum WriteMode: String, Sendable {
        /// Create it, or replace what's in it.
        case write
        /// Create it; it mustn't be there already.
        case create
        /// Replace what's in it; it must be there already.
        case replace
    }

    /// Writes a note: (the note, whether it was created).
    @discardableResult
    public func write(_ name: String, _ text: String, mode: WriteMode = .write) throws -> (note: Note, created: Bool) {
        try writable()
        let key = try self.key(name)
        let found = find(key)
        if mode == .create, let found {
            throw LibraryError(.exists, "There's already a \(shelf.noun) called \(found.name).", fix: "Pick another name, or write it to replace what's in it.")
        }
        if mode == .replace, found == nil { _ = try existing(key) }
        try ensure()
        let url = found?.url ?? root.appendingPathComponent(key + "." + ext)
        try save(text, to: url)
        return (note(at: url) ?? Note(name: key, url: url, size: text.utf8.count, modified: Date()), found == nil)
    }

    /// Adds text to the end of a note (on a line of its own), creating it if it isn't there.
    @discardableResult
    public func append(_ name: String, _ text: String) throws -> (note: Note, created: Bool) {
        try writable()
        let key = try self.key(name)
        guard let found = find(key) else { return try write(key, text.hasSuffix("\n") ? text : text + "\n", mode: .create) }
        var now = try read(found.name).text
        if !now.isEmpty, !now.hasSuffix("\n") { now += "\n" }
        now += text
        if !now.hasSuffix("\n") { now += "\n" }
        try save(now, to: found.url)
        return (note(at: found.url) ?? found, false)
    }

    /// Gives a note another name. Throws `exists` when one has that name already (unless `overwrite`,
    /// which moves the one there to the Trash first).
    @discardableResult
    public func rename(_ name: String, to newName: String, overwrite: Bool = false) throws -> Note {
        try writable()
        let from = try existing(name)
        let key = try self.key(newName)
        let target = root.appendingPathComponent(key + "." + ext)
        if let there = find(key), there.url.standardizedFileURL != from.url.standardizedFileURL {
            guard overwrite else {
                throw LibraryError(.exists, "There's already a \(shelf.noun) called \(there.name).", fix: "Pick another name, or send \"overwrite\": true to move that one to the Trash first.")
            }
            try delete(there.name)
        }
        do {
            if from.url.lastPathComponent.lowercased() == target.lastPathComponent.lowercased() {
                // Only the case changes: through a name of its own, as case-insensitive disks need.
                let step = root.appendingPathComponent(".renaming-\(UUID().uuidString).\(ext)")
                try FileManager.default.moveItem(at: from.url, to: step)
                try FileManager.default.moveItem(at: step, to: target)
            } else {
                try FileManager.default.moveItem(at: from.url, to: target)
            }
        } catch {
            throw LibraryError(.failed, "Couldn't rename \(from.name) to \(key): \(error.localizedDescription)")
        }
        return note(at: target) ?? from
    }

    /// A copy of a note under another name (which mustn't be taken).
    @discardableResult
    public func copy(_ name: String, to newName: String) throws -> Note {
        let text = try read(name).text
        return try write(newName, text, mode: .create).note
    }

    /// Moves a note to the library's Trash, numbered after any of the same name already there.
    @discardableResult
    public func delete(_ name: String) throws -> Trashed {
        try writable()
        let n = try existing(name)
        try ensure()
        var index = loadIndex()
        let taken = Set(trash().filter { Self.fold($0.name) == Self.fold(n.name) }.map(\.number))
        var number = (taken.max() ?? 0) + 1
        var target = trashFolder.appendingPathComponent("\(n.name) (\(number)).\(ext)")
        while FileManager.default.fileExists(atPath: target.path) {
            number += 1
            target = trashFolder.appendingPathComponent("\(n.name) (\(number)).\(ext)")
        }
        do {
            try FileManager.default.moveItem(at: n.url, to: target)
        } catch {
            throw LibraryError(.failed, "Couldn't move \(n.name) to the Trash: \(error.localizedDescription)")
        }
        let now = Date()
        index[target.lastPathComponent] = IndexEntry(name: n.name, number: number, deleted: now)
        saveIndex(index)
        return Trashed(name: n.name, number: number, url: target, size: n.size, deleted: now)
    }

    /// What's in the library's Trash, the latest deleted first.
    public func trash() -> [Trashed] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: trashFolder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                       options: [.skipsHiddenFiles]) else { return [] }
        let index = loadIndex()
        let pattern = try? NSRegularExpression(pattern: #"^(.*) \((\d+)\)$"#)
        let found = files.compactMap { url -> Trashed? in
            guard url.pathExtension.lowercased() == ext.lowercased() else { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let base = url.deletingPathExtension().lastPathComponent
            if let known = index[url.lastPathComponent] {
                return Trashed(name: known.name, number: known.number, url: url, size: size, deleted: known.deleted)
            }
            // Put there by hand (or the index is gone): its name and number from the file's name.
            var name = base, number = 1
            if let m = pattern?.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
               let r1 = Range(m.range(at: 1), in: base), let r2 = Range(m.range(at: 2), in: base) {
                name = String(base[r1])
                number = Int(base[r2]) ?? 1
            }
            return Trashed(name: name, number: number, url: url, size: size, deleted: values?.contentModificationDate ?? Date.distantPast)
        }
        return found.sorted { ($0.deleted, $0.number) > ($1.deleted, $1.number) }
    }

    /// Brings a note back from the Trash: the latest deleted of that name, or its `number`; as its
    /// own name, or `as` another. Throws `exists` when a note has that name now.
    @discardableResult
    public func restore(_ name: String, number: Int? = nil, as newName: String? = nil) throws -> Note {
        try writable()
        let folded = Self.fold((try? self.key(name)) ?? name)
        let candidates = trash().filter { Self.fold($0.name) == folded }
        guard let pick = number.map({ n in candidates.first { $0.number == n } }) ?? candidates.first else {
            let what = number.map { "\(name) (\($0))" } ?? name
            let there = trash().prefix(20).map { "\($0.name) (\($0.number))" }
            throw LibraryError(.notFound, "There's no \(what) in \(place)'s Trash.",
                               fix: there.isEmpty ? "The Trash is empty." : "In the Trash: " + there.joined(separator: ", "))
        }
        let key = try self.key(newName ?? pick.name)
        if let there = find(key) {
            throw LibraryError(.exists, "There's a \(shelf.noun) called \(there.name) now.", fix: "Restore it as another name (\"as\": \"\(key) restored\").")
        }
        let target = root.appendingPathComponent(key + "." + ext)
        do {
            try FileManager.default.moveItem(at: pick.url, to: target)
        } catch {
            throw LibraryError(.failed, "Couldn't restore \(pick.name): \(error.localizedDescription)")
        }
        var index = loadIndex()
        index[pick.url.lastPathComponent] = nil
        saveIndex(index)
        return note(at: target) ?? Note(name: key, url: target, size: pick.size, modified: Date())
    }

    /// Deletes what's in the library's Trash for good: everything, or what was deleted more than
    /// `olderThan` seconds ago. Returns how many.
    @discardableResult
    public func emptyTrash(olderThan: TimeInterval? = nil) throws -> Int {
        try writable()
        let cutoff = olderThan.map { Date().addingTimeInterval(-$0) }
        var index = loadIndex()
        var removed = 0
        for t in trash() where cutoff.map({ t.deleted < $0 }) ?? true {
            do {
                try FileManager.default.removeItem(at: t.url)
                index[t.url.lastPathComponent] = nil
                removed += 1
            } catch {
                throw LibraryError(.failed, "Couldn't delete \(t.url.lastPathComponent) from the Trash: \(error.localizedDescription)")
            }
        }
        saveIndex(index)
        return removed
    }

    // MARK: searching

    public struct Hit: Sendable, Equatable {
        public var note: Note
        /// How many times the words are in it (its name counts more).
        public var score: Int
        /// The lines they're on: (its number, from 1; the line).
        public var lines: [(number: Int, text: String)]

        public static func == (a: Hit, b: Hit) -> Bool {
            a.note == b.note && a.score == b.score && a.lines.map(\.number) == b.lines.map(\.number) && a.lines.map(\.text) == b.lines.map(\.text)
        }
    }

    public struct SearchOptions: Sendable {
        /// Every word must be in the note (else any of them).
        public var all = true
        public var caseSensitive = false
        /// Whole words only (`cat` isn't in `category`).
        public var wholeWords = false
        /// The lines given back for each note, at most.
        public var lines = 5
        /// Only the names count (not the text).
        public var namesOnly = false

        public init(all: Bool = true, caseSensitive: Bool = false, wholeWords: Bool = false, lines: Int = 5, namesOnly: Bool = false) {
            self.all = all
            self.caseSensitive = caseSensitive
            self.wholeWords = wholeWords
            self.lines = lines
            self.namesOnly = namesOnly
        }
    }

    /// The notes with the words in them (in their name or their text), the best first: the words of
    /// `query`, each on its own, or a phrase in quotes ("call the bank"). Accents never count.
    public func search(_ query: String, _ options: SearchOptions = SearchOptions()) -> [Hit] {
        let terms = Self.terms(query)
        guard !terms.isEmpty else { return [] }
        let fold = { (s: String) in s.folding(options: options.caseSensitive ? [.diacriticInsensitive] : [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let wanted = terms.map(fold)
        var hits: [Hit] = []
        for n in list(sort: .modified) {
            let name = fold(n.name)
            let original = options.namesOnly ? "" : ((try? read(n.name).text) ?? "")
            let text = fold(original)
            var score = 0
            var present = 0
            for w in wanted {
                let inName = Self.count(w, in: name, wholeWords: options.wholeWords)
                let inText = Self.count(w, in: text, wholeWords: options.wholeWords)
                if inName + inText > 0 { present += 1 }
                score += inName * 10 + inText
            }
            guard options.all ? present == wanted.count : present > 0 else { continue }
            var lines: [(Int, String)] = []
            if !options.namesOnly, options.lines > 0 {
                for (k, line) in original.components(separatedBy: "\n").enumerated() where lines.count < options.lines {
                    let folded = fold(line)
                    if wanted.contains(where: { Self.count($0, in: folded, wholeWords: options.wholeWords) > 0 }) {
                        let t = line.trimmingCharacters(in: .whitespaces)
                        lines.append((k + 1, t.count > 240 ? String(t.prefix(239)) + "…" : t))
                    }
                }
            }
            hits.append(Hit(note: n, score: score, lines: lines))
        }
        // The best first; of the same, the latest changed (the list is that already).
        return hits.enumerated().sorted { a, b in a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset }.map(\.element)
    }

    /// The latest changed, newest first.
    public func recent(_ limit: Int = 10) -> [Note] { Array(list(sort: .modified).prefix(max(0, limit))) }

    /// A note's headings, in order: (its level, 1 for `#`; the heading; its line).
    public func outline(_ name: String) throws -> [(level: Int, text: String, line: Int)] {
        let text = try read(name).text
        var out: [(Int, String, Int)] = []
        var fenced = false
        for (k, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            guard !fenced, line.hasPrefix("#") else { continue }
            let level = line.prefix { $0 == "#" }.count
            let rest = line.dropFirst(level)
            guard level <= 6, rest.first == " " else { continue }
            out.append((level, rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces), k + 1))
        }
        return out
    }

    /// The notes that link to this one: `[[name]]` (or `[[name|words]]`), or a Markdown link to its file.
    public func backlinks(_ name: String) throws -> [Hit] {
        let n = try existing(name)
        let wiki = Self.fold("[[" + n.name)
        let file = Self.fold("(" + (n.name + "." + ext).replacingOccurrences(of: " ", with: "%20"))
        let plainFile = Self.fold("(" + n.name + "." + ext)
        var hits: [Hit] = []
        for other in list(sort: .modified) where other.url != n.url {
            guard let text = try? read(other.name).text else { continue }
            var lines: [(Int, String)] = []
            for (k, line) in text.components(separatedBy: "\n").enumerated() {
                let f = Self.fold(line)
                let linked = f.contains(wiki + "]]") || f.contains(wiki + "|") || f.contains(file + ")") || f.contains(plainFile + ")")
                if linked { lines.append((k + 1, line.trimmingCharacters(in: .whitespaces))) }
            }
            if !lines.isEmpty { hits.append(Hit(note: other, score: lines.count, lines: Array(lines.prefix(5)))) }
        }
        return hits
    }

    public struct Stats: Sendable, Equatable {
        public var notes: Int
        public var bytes: Int
        public var words: Int
        public var trashed: Int
        public var newest: Note?
    }

    public func stats() -> Stats {
        let all = list(sort: .modified)
        let words = all.reduce(0) { sum, n in sum + ((try? read(n.name).text)?.split(whereSeparator: \.isWhitespace).count ?? 0) }
        return Stats(notes: all.count, bytes: all.reduce(0) { $0 + $1.size }, words: words, trashed: trash().count, newest: all.first)
    }

    // MARK: names

    /// A name as a key: what's typed, trimmed, without the extension if it was given (`groceries.md`
    /// is `groceries`). Throws `bad_name` for one that can't be a file's name.
    public static func key(_ name: String, ext: String = FileLibrary.defaultExtension) throws -> String {
        var key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased().hasSuffix("." + ext.lowercased()) { key = String(key.dropLast(ext.count + 1)).trimmingCharacters(in: .whitespaces) }
        key = key.precomposedStringWithCanonicalMapping
        let fix = "A name is any words but / and :, not starting with a dot (such as \"groceries\" or \"Trip to Lagos 2026\")."
        if key.isEmpty { throw LibraryError(.badName, "A note needs a name.", fix: fix) }
        if key.contains("/") || key.contains(":") || key.contains("\\") { throw LibraryError(.badName, "\"\(key)\" can't be a name: it has a / or a : in it.", fix: fix) }
        if key.hasPrefix(".") { throw LibraryError(.badName, "\"\(key)\" can't be a name: names starting with a dot are hidden.", fix: fix) }
        if key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { throw LibraryError(.badName, "A name can't have tabs or line breaks in it.", fix: fix) }
        if key.utf8.count + ext.utf8.count + 1 > 250 { throw LibraryError(.badName, "That name is too long (at most about 240 letters).", fix: fix) }
        if key.caseInsensitiveCompare(trashName) == .orderedSame { throw LibraryError(.badName, "\(trashName) is the library's own Trash folder.", fix: fix) }
        return key
    }

    /// A name as a key on this shelf: on MEMORY, also one the mind can have as a node (its spaces
    /// one each, no @, no symbol after a space), since each memory file is one.
    public func key(_ name: String) throws -> String {
        var key = try Self.key(name, ext: ext)
        if shelf.mindNames {
            key = MindNotation.collapse(key)
            if let why = MindNotation.nameProblem(key) {
                throw LibraryError(.badName, why, fix: "A memory file's name is a node of the mind too: words, with no @ and no -, | or = after a space (such as PEOPLE or Trip ideas).")
            }
        }
        return key
    }

    /// Throws `read_only` on a shelf that can't be changed.
    public func writable() throws {
        guard shelf.readOnly else { return }
        throw LibraryError(.readOnly, "\(shelf.folderName) can't be changed: the app writes it, from what it ships with.",
                           fix: "Read it, search it, copy from it; to keep your own version of a doc, copy its text into the library (/api/spaces/user/library).")
    }

    /// The same for comparing: no case, no accents, the same Unicode form.
    static func fold(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// A query's words, a phrase in quotes as one.
    static func terms(_ query: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        for c in query {
            if c == "\"" || c == "“" || c == "”" {
                if quoted, !current.isEmpty { out.append(current) }
                if !quoted, !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append(contentsOf: current.split(separator: " ").map(String.init)) }
                current = ""
                quoted.toggle()
            } else if c.isWhitespace, !quoted {
                if !current.isEmpty { out.append(current) }
                current = ""
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { out.append(contentsOf: quoted ? [current] : current.split(separator: " ").map(String.init)) }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// How many times `word` is in `text` (both folded already).
    static func count(_ word: String, in text: String, wholeWords: Bool) -> Int {
        guard !word.isEmpty, !text.isEmpty else { return 0 }
        if wholeWords {
            let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}_])"
            guard let re = try? NSRegularExpression(pattern: pattern) else { return 0 }
            return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        var n = 0
        var from = text.startIndex
        while let r = text.range(of: word, range: from..<text.endIndex) {
            n += 1
            from = r.upperBound
        }
        return n
    }

    // MARK: inside

    private func existing(_ name: String) throws -> Note {
        let key = try self.key(name)
        if let n = find(key) { return n }
        let all = names()
        let near = Self.near(key, in: all)
        throw LibraryError(.notFound, "There's no \(shelf.noun) called \(key).",
                           fix: near.isEmpty ? (all.isEmpty ? "\(Place) is empty." : "The \(shelf.noun)s: " + all.prefix(20).joined(separator: ", ") + (all.count > 20 ? ", …" : ""))
                                              : "Near it: " + near.joined(separator: ", "))
    }

    /// The names like it (a few letters off, starting the same, or one inside the other), the nearest first.
    static func near(_ name: String, in names: [String], limit: Int = 5) -> [String] {
        let want = Array(fold(name))
        let scored = names.compactMap { other -> (String, Int)? in
            let have = fold(other)
            if have.contains(String(want)) || String(want).contains(have) { return (other, 0) }
            let d = distance(want, Array(have))
            // Starting the same way counts too: "grocery" is near "groceries".
            let same = zip(want, have).prefix { $0 == $1 }.count
            return d <= max(2, want.count / 3) || (want.count >= 4 && same >= min(5, want.count)) ? (other, d) : nil
        }
        return scored.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }

    /// How many letters must change to turn one into the other (Levenshtein).
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let kept = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : 1 + min(previous, row[j], row[j - 1])
                previous = kept
            }
        }
        return row[b.count]
    }

    private func note(at url: URL) -> Note? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey]) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
        return Note(name: name, url: url, size: values.fileSize ?? 0, modified: values.contentModificationDate ?? Date(),
                    created: values.creationDate, title: Self.title(of: url))
    }

    /// Its first heading, else its first line with words (from the first 4 KB).
    static func title(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 4096)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        var first: String?
        var fenced = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---", first == nil { continue }
            if line.hasPrefix("```") { fenced.toggle(); continue }
            if fenced || line.isEmpty { continue }
            if line.hasPrefix("#") {
                let heading = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty { return String(heading.prefix(120)) }
            }
            if first == nil { first = String(line.prefix(120)) }
        }
        return first
    }

    private func save(_ text: String, to url: URL) throws {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw LibraryError(.failed, "Couldn't write \(url.deletingPathExtension().lastPathComponent): \(error.localizedDescription)")
        }
    }

    private struct IndexEntry: Codable {
        var name: String
        var number: Int
        var deleted: Date
    }

    private func loadIndex() -> [String: IndexEntry] {
        guard let data = try? Data(contentsOf: trashIndex) else { return [:] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: IndexEntry].self, from: data)) ?? [:]
    }

    private func saveIndex(_ index: [String: IndexEntry]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(index) { try? data.write(to: trashIndex, options: .atomic) }
    }
}

/// What went wrong in the library, in words, with the fix: the API answers with its `code`.
public struct LibraryError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable {
        case notFound = "not_found"
        case exists = "already_exists"
        case badName = "bad_name"
        case readOnly = "read_only"
        case failed
    }

    public var code: Code
    public var message: String
    public var fix: String?

    public init(_ code: Code, _ message: String, fix: String? = nil) {
        self.code = code
        self.message = message
        self.fix = fix
    }

    public var description: String { fix.map { "\(message) \($0)" } ?? message }

    /// The HTTP status it answers with.
    public var status: Int {
        switch code {
        case .notFound: 404
        case .exists: 409
        case .badName: 400
        case .readOnly: 403
        case .failed: 500
        }
    }
}
