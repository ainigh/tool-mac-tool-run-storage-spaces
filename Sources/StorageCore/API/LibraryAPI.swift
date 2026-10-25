import Foundation

/// An operation: what it does, and what it takes.
public struct Operation: Sendable {
    public let name: String
    public let summary: String
    /// Its fields: "name", "text"?… (a ? is optional).
    public let fields: [String]
    /// Its own route, when it has one.
    public let route: String?
    /// It changes what's stored.
    public let changes: Bool
}

/// A notes store over HTTP (the person's library, MEMORY, Super Face's prompt…): its notes, by
/// name, as Tool Mac Tool Run's `/api/library` served them (moved here, as they were). Nothing
/// waits for a click: it's notes, not programs, and a delete only moves a note to the store's own
/// Trash. Every call gets an id (`X-Request-Id`, and `request` in its JSON), and
/// `GET /api/operations/{id}` says what it did.
///
/// Every operation is one `op` of `POST /api/spaces/{space}/{store}` (`{"op": "read", "name":
/// "groceries"}`), and the usual ones have a route of their own too (`GET …/files/groceries`).
/// The routes below are the person's library's (`/api/library` is short for
/// `/api/spaces/user/library`); every notes store has the same under its own path.
public enum LibraryAPI {
    public static let operations: [Operation] = [
        Operation(name: "list", summary: "every note: name, title, size, created, modified (with \"content\": true, its text too)",
                  fields: ["sort?: name|modified|created|size", "order?: asc|desc", "q?: words in the name", "limit?", "offset?", "content?"], route: "GET /api/library/files", changes: false),
        Operation(name: "names", summary: "the names alone, A to Z", fields: [], route: "GET /api/library/names", changes: false),
        Operation(name: "read", summary: "a note's text, and what's known about it", fields: ["name"], route: "GET /api/library/files/{name} (?format=text: the text alone)", changes: false),
        Operation(name: "read_many", summary: "several notes at once: each one's text, and the names not found", fields: ["names: [names]"], route: nil, changes: false),
        Operation(name: "exists", summary: "whether a note of that name is there", fields: ["name"], route: "GET /api/library/files/{name}/exists", changes: false),
        Operation(name: "write", summary: "creates the note, or replaces its text (a key's value, set)", fields: ["name", "text"], route: "PUT /api/library/files/{name}", changes: true),
        Operation(name: "create", summary: "a new note; 409 already_exists if the name is taken", fields: ["name", "text?"], route: "POST /api/library/files", changes: true),
        Operation(name: "append", summary: "adds text at its end, on a line of its own (creating it if it isn't there)", fields: ["name", "text"], route: "POST /api/library/files/{name}/append", changes: true),
        Operation(name: "rename", summary: "another name; 409 if it's taken (\"overwrite\": true moves that one to the Trash first)", fields: ["name", "to", "overwrite?"], route: "POST /api/library/files/{name}/rename", changes: true),
        Operation(name: "copy", summary: "a copy under another name (not taken)", fields: ["name", "to"], route: "POST /api/library/files/{name}/copy", changes: true),
        Operation(name: "delete", summary: "moves it to the library's Trash, as name (1), name (2)…, to restore later", fields: ["name"], route: "DELETE /api/library/files/{name}", changes: true),
        Operation(name: "search", summary: "full text: the notes with the words in their name or text, the best first, with the lines they're on",
                  fields: ["q", "match?: all|any", "case_sensitive?", "whole_words?", "names_only?", "lines?", "limit?"], route: "GET /api/library/search?q=…", changes: false),
        Operation(name: "find", summary: "the same search, giving back only the names, the best first", fields: ["q", "match?", "case_sensitive?", "whole_words?", "names_only?", "limit?"],
                  route: "GET /api/library/find?q=…", changes: false),
        Operation(name: "recent", summary: "the latest changed, newest first", fields: ["limit?"], route: "GET /api/library/recent", changes: false),
        Operation(name: "outline", summary: "a note's headings, with their levels and lines", fields: ["name"], route: "GET /api/library/files/{name}/outline", changes: false),
        Operation(name: "backlinks", summary: "the notes that link to it ([[name]], or a Markdown link to its file)", fields: ["name"], route: "GET /api/library/files/{name}/backlinks", changes: false),
        Operation(name: "stats", summary: "how many notes, bytes, words, how many in the Trash, the newest", fields: [], route: "GET /api/library/stats", changes: false),
        Operation(name: "trash", summary: "what's in the library's Trash, the latest deleted first", fields: [], route: "GET /api/library/trash", changes: false),
        Operation(name: "restore", summary: "brings one back: the latest of that name, or its number; \"as\" another name if it's taken", fields: ["name", "number?", "as?"],
                  route: "POST /api/library/trash/restore", changes: true),
        Operation(name: "empty_trash", summary: "deletes what's in the library's Trash for good (or what was deleted more than older_than_days ago)", fields: ["older_than_days?"],
                  route: "POST /api/library/trash/empty", changes: true),
    ]

    static let byName: [String: Operation] = Dictionary(uniqueKeysWithValues: operations.map { ($0.name, $0) })

    /// The operations' names, for a message.
    static var names: String { operations.map(\.name).joined(separator: ", ") }

    /// Does one operation; what it gives back (without "ok", "op" and "request", added by the caller).
    static func perform(_ op: String, _ f: Fields, library lib: FileLibrary) throws -> [String: Any] {
        switch op {
        case "list":
            let sort = try f.choice("sort", FileLibrary.Sort.allCases.map(\.rawValue)).flatMap(FileLibrary.Sort.init(rawValue:)) ?? .name
            let order = try f.choice("order", ["asc", "desc"])
            var notes = lib.list(sort: sort, descending: order.map { $0 == "desc" })
            if let q = f.text("q") ?? f.text("prefix"), !q.isEmpty {
                let folded = FileLibrary.fold(q)
                notes = notes.filter { FileLibrary.fold($0.name).contains(folded) }
            }
            let total = notes.count
            let offset = max(0, f.int("offset") ?? 0)
            notes = Array(notes.dropFirst(offset).prefix(max(0, f.int("limit") ?? Int.max)))
            let content = f.bool("content") ?? false
            return ["folder": lib.root.path, "total": total, "count": notes.count,
                    "notes": notes.map { n in content ? noteJSON(n, text: (try? lib.read(n.name).text) ?? "") : noteJSON(n) }]
        case "names":
            return ["names": lib.names()]
        case "read":
            let r = try lib.read(try f.name())
            return noteJSON(r.note, text: r.text)
        case "read_many":
            guard let names = f.list("names") else { throw LibraryError(.badName, "read_many takes \"names\": a list of names.") }
            var notes: [[String: Any]] = []
            var missing: [String] = []
            for name in names {
                if let r = try? lib.read(name) { notes.append(noteJSON(r.note, text: r.text)) } else { missing.append(name) }
            }
            return ["notes": notes, "missing": missing]
        case "exists":
            let name = try f.name()
            if let n = lib.find(name) { return ["exists": true, "name": n.name] }
            _ = try FileLibrary.key(name)
            return ["exists": false, "name": name]
        case "write", "create":
            let name = try f.name()
            guard let text = f.text("text") ?? f.text("content") ?? (op == "create" ? "" : nil) else {
                throw LibraryError(.badName, "write takes \"text\": what goes in the note (\"\" for nothing).", fix: "{\"op\": \"write\", \"name\": \"\(name)\", \"text\": \"…\"}")
            }
            let mode: FileLibrary.WriteMode = op == "create" ? .create : (f.bool("only_if_new") == true ? .create : .write)
            let r = try lib.write(name, text, mode: mode)
            return noteJSON(r.note).merging(["new": r.created, "action": r.created ? "created" : "replaced"]) { a, _ in a }
        case "append":
            let name = try f.name()
            guard let text = f.text("text") ?? f.text("content") else { throw LibraryError(.badName, "append takes \"text\": what to add.") }
            let r = try lib.append(name, text)
            return noteJSON(r.note).merging(["new": r.created, "action": r.created ? "created" : "appended"]) { a, _ in a }
        case "rename":
            let name = try f.name()
            guard let to = f.text("to") ?? f.text("new_name") else { throw LibraryError(.badName, "rename takes \"to\": the new name.") }
            let n = try lib.rename(name, to: to, overwrite: f.bool("overwrite") ?? false)
            return noteJSON(n).merging(["from": name]) { a, _ in a }
        case "copy":
            let name = try f.name()
            guard let to = f.text("to") ?? f.text("new_name") else { throw LibraryError(.badName, "copy takes \"to\": the copy's name.") }
            return noteJSON(try lib.copy(name, to: to)).merging(["from": name]) { a, _ in a }
        case "delete":
            let t = try lib.delete(try f.name())
            return ["name": t.name, "trash": trashedJSON(t), "message": "Moved to the library's Trash as \(t.url.lastPathComponent): {\"op\": \"restore\", \"name\": \"\(t.name)\"} brings it back"]
        case "search", "find":
            guard let q = f.text("q") ?? f.text("query") ?? f.text("text"), !q.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw LibraryError(.badName, "\(op) takes \"q\": the words to look for (a phrase in quotes).")
            }
            let match = try f.choice("match", ["all", "any"]) ?? "all"
            let options = FileLibrary.SearchOptions(all: match == "all", caseSensitive: f.bool("case_sensitive") ?? false,
                                                    wholeWords: f.bool("whole_words") ?? false, lines: max(0, f.int("lines") ?? 5),
                                                    namesOnly: f.bool("names_only") ?? false)
            let hits = Array(lib.search(q, options).prefix(max(0, f.int("limit") ?? Int.max)))
            if op == "find" { return ["query": q, "count": hits.count, "names": hits.map(\.note.name)] }
            return ["query": q, "terms": FileLibrary.terms(q), "count": hits.count, "results": hits.map(hitJSON)]
        case "recent":
            return ["notes": lib.recent(max(0, f.int("limit") ?? 10)).map { noteJSON($0) }]
        case "outline":
            let name = try f.name()
            let headings = try lib.outline(name)
            return ["name": lib.find(name)?.name ?? name, "headings": headings.map { ["level": $0.level, "text": $0.text, "line": $0.line] }]
        case "backlinks":
            let name = try f.name()
            let hits = try lib.backlinks(name)
            return ["name": lib.find(name)?.name ?? name, "count": hits.count, "results": hits.map(hitJSON)]
        case "stats":
            let s = lib.stats()
            var out: [String: Any] = ["folder": lib.root.path, "notes": s.notes, "bytes": s.bytes, "words": s.words, "trashed": s.trashed, "extension": lib.ext]
            if let n = s.newest { out["newest"] = noteJSON(n) }
            return out
        case "trash":
            return ["trash": lib.trash().map(trashedJSON)]
        case "restore":
            let n = try lib.restore(try f.name(), number: f.int("number"), as: f.text("as"))
            return noteJSON(n)
        case "empty_trash":
            let days = f.double("older_than_days")
            return ["deleted": try lib.emptyTrash(olderThan: days.map { $0 * 86400 })]
        default:
            throw LibraryError(.badName, "There's no library operation called \(op).", fix: "The operations: \(names) (GET /api/library lists them, with what each takes)")
        }
    }

    // MARK: JSON

    static func noteJSON(_ n: FileLibrary.Note, text: String? = nil) -> [String: Any] {
        var out: [String: Any] = ["name": n.name, "file": n.url.lastPathComponent, "size": n.size, "modified": JSON.date(n.modified)]
        if let c = n.created { out["created"] = JSON.date(c) }
        if let t = n.title { out["title"] = t }
        if let text {
            out["text"] = text
            out["words"] = text.split(whereSeparator: \.isWhitespace).count
            out["lines"] = text.isEmpty ? 0 : text.components(separatedBy: "\n").count - (text.hasSuffix("\n") ? 1 : 0)
        }
        return out
    }

    static func trashedJSON(_ t: FileLibrary.Trashed) -> [String: Any] {
        ["name": t.name, "number": t.number, "file": t.url.lastPathComponent, "size": t.size, "deleted": JSON.date(t.deleted)]
    }

    static func hitJSON(_ h: FileLibrary.Hit) -> [String: Any] {
        var out = noteJSON(h.note)
        out["score"] = h.score
        out["lines"] = h.lines.map { ["line": $0.number, "text": $0.text] }
        return out
    }

    /// What a finished operation says in a few words (its log line).
    static func summary(_ op: String, _ out: [String: Any]) -> String {
        let name = out["name"] as? String
        switch op {
        case "list": return "listed \(out["count"] ?? 0) of \(out["total"] ?? 0) notes"
        case "names": return "listed \((out["names"] as? [Any])?.count ?? 0) names"
        case "read": return "read \(name ?? "")"
        case "read_many": return "read \((out["notes"] as? [Any])?.count ?? 0) notes"
        case "write", "create", "append":
            let verb = (out["action"] as? String).map { $0 == "appended" ? "appended to" : $0 } ?? op
            return "\(verb) \(name ?? "") (\(out["size"] ?? 0) bytes)"
        case "rename": return "renamed \(out["from"] ?? "") to \(name ?? "")"
        case "copy": return "copied \(out["from"] ?? "") to \(name ?? "")"
        case "delete": return "moved \(name ?? "") to the Trash"
        case "restore": return "restored \(name ?? "")"
        case "search", "find": return "\(op) \"\(out["query"] ?? "")\": \(out["count"] ?? 0) found"
        case "empty_trash": return "deleted \(out["deleted"] ?? 0) from the Trash for good"
        default: return op
        }
    }
}

/// The request's fields: its JSON body, its query, and the name from its path.
public struct Fields {
    public var values: [String: Any]

    public init(values: [String: Any]) {
        self.values = values
    }

    /// A value as text: a string as it is, a number as written (true and false as words).
    public static func text(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            #if canImport(Darwin)
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            #endif
            return n.stringValue
        default: return nil
        }
    }

    func text(_ key: String) -> String? { Fields.text(values[key]) }

    func name() throws -> String {
        guard let n = text("name") ?? text("key") ?? text("file"), !n.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LibraryError(.badName, "Say which note: \"name\" (its name without .md).")
        }
        return n
    }

    func int(_ key: String) -> Int? {
        if let n = values[key] as? Int { return n }
        if let n = values[key] as? Double { return Int(n) }
        return text(key).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    func double(_ key: String) -> Double? {
        if let n = values[key] as? Double { return n }
        if let n = values[key] as? Int { return Double(n) }
        return text(key).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    func bool(_ key: String) -> Bool? {
        if let b = values[key] as? Bool { return b }
        guard let t = text(key)?.lowercased() else { return nil }
        if ["true", "1", "yes", "on", ""].contains(t) { return true }
        if ["false", "0", "no", "off"].contains(t) { return false }
        return nil
    }

    func list(_ key: String) -> [String]? {
        if let l = values[key] as? [Any] { return l.compactMap { Fields.text($0) } }
        if let one = text(key) { return one.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return nil
    }

    func choice(_ key: String, _ allowed: [String]) throws -> String? {
        guard let t = text(key)?.lowercased(), !t.isEmpty else { return nil }
        guard allowed.contains(t) else { throw LibraryError(.badName, "\(key) is one of \(allowed.joined(separator: ", ")), not \(t).") }
        return t
    }
}
