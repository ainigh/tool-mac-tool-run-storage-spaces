import Foundation

/// Storage Spaces over HTTP, on 127.0.0.1:8771 (API.md is its contract). Bytes in, an answer out:
/// the app's server hands every request to `route`, and the tests do the same.
///
/// Every store of every space has its routes under `/api/spaces/{space}/{store}` (and the
/// person's three as Tool Mac Tool Run had them: `/api/library`, `/api/memory`, `/api/mind`).
/// Each call is checked against who's asking (`client`): Peter may do anything, an app its own
/// space, and the rest it asks for (`/api/access/requests`) or holds for approval (`"hold": true`).
public actor StorageAPI {
    public static let port = 8771

    public let storage: Storage
    public let version: String
    /// Where the docs are (API.md, MIND-NOTATION.md…), searched in order.
    public let docs: [URL]
    public let changes = Changes()
    public let log = OperationLog()
    var book: AccessBook
    var importSource = ToolMacImport.defaultSource
    var importPeter = ToolMacImport.defaultPeter
    /// Called after anything is changed by a request (the app's window shows it).
    private var onChange: (@Sendable () -> Void)?

    public init(storage: Storage = Storage(), version: String = "dev", docs: [URL] = []) {
        self.storage = storage
        self.version = version
        self.docs = docs
        let file = storage.system.appendingPathComponent("access.json")
        if let kept = AccessBook.load(file) {
            book = kept
        } else {
            book = AccessBook.starting()
            if storage.exists { try? book.save(file) }
        }
    }

    var bookFile: URL { storage.system.appendingPathComponent("access.json") }

    public func setOnChange(_ f: @escaping @Sendable () -> Void) { onChange = f }

    /// Makes every space ready (and keeps the access rules with them).
    public func start() throws {
        try storage.ensure()
        if !FileManager.default.fileExists(atPath: bookFile.path) { try book.save(bookFile) }
    }

    // MARK: who's asking

    /// Who a request is from: a client by name (checked against its key, when it has one), or the
    /// person in the app's own window.
    public struct Caller: Sendable {
        public var name: String
        public var isPerson: Bool

        public static let person = Caller(name: Clients.person, isPerson: true)
    }

    /// The client a request names: `client` (in its query or body), else its X-Client header,
    /// else its User-Agent's first word.
    static func clientName(_ req: HTTPRequest, _ fields: [String: Any]) -> String? {
        if let c = Fields.text(fields["client"]), !c.trimmingCharacters(in: .whitespaces).isEmpty { return c.trimmingCharacters(in: .whitespaces) }
        if let c = req.header("x-client"), !c.trimmingCharacters(in: .whitespaces).isEmpty { return c.trimmingCharacters(in: .whitespaces) }
        if let ua = req.header("user-agent"), let first = ua.split(separator: "/").first?.split(separator: " ").first, !first.isEmpty { return String(first) }
        return nil
    }

    static func key(_ req: HTTPRequest) -> String? {
        if let k = req.header("x-storage-key"), !k.isEmpty { return k.trimmingCharacters(in: .whitespaces) }
        if let a = req.header("authorization"), a.lowercased().hasPrefix("bearer ") { return String(a.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        return nil
    }

    func caller(_ req: HTTPRequest, _ fields: [String: Any]) throws -> Caller {
        guard let name = Self.clientName(req, fields) else {
            throw HTTPError(status: 401, code: "who_are_you", message: "say who's asking: \"client\": \"<your app's name>\" (or an X-Client header)")
        }
        if Clients.same(name, Clients.person) || Clients.same(name, Clients.storage) {
            throw HTTPError(status: 403, code: "reserved_name", message: "\(name) is Storage Spaces' own name for the person or itself: use your app's name")
        }
        guard book.keyMatches(name, Self.key(req)) else {
            throw HTTPError(status: 401, code: "bad_key", message: "\(name) has a key: send it as X-Storage-Key (or Authorization: Bearer). Lost it? The person can forget it in the Storage Spaces window, and you register again")
        }
        return Caller(name: name, isPerson: false)
    }

    /// What `caller` may do with a store.
    public func access(_ caller: String, _ space: SpaceID, _ store: String?) -> Access {
        Policy.access(caller, space, store, grants: book.grants)
    }

    // MARK: answering

    /// One request, from the HTTP server.
    public func route(_ req: HTTPRequest) async -> HTTPResponse {
        guard req.fromLoopback else {
            return JSON.response(["ok": false, "code": "forbidden", "error": "Storage Spaces answers this Mac only"], status: 403)
        }
        do {
            return try await handle(req, as: nil)
        } catch {
            let m = Self.mistake(error)
            var out: [String: Any] = ["ok": false, "code": m.code, "error": m.message]
            if let fix = m.fix { out["fix"] = fix }
            out.merge(m.extra) { a, _ in a }
            return JSON.response(out, status: m.status)
        }
    }

    /// The same, as the person in the app's window (who may do anything the API can, and decide
    /// what's waiting). The answer's status and JSON.
    public func asPerson(_ method: String, _ path: String, _ body: [String: Any]? = nil) async -> (status: Int, json: [String: Any]) {
        let data = body.map { JSON.data($0) } ?? Data()
        let req = HTTPRequest(method: method, target: path, headers: body == nil ? [:] : ["Content-Type": "application/json"], body: data)
        let r: HTTPResponse
        do {
            r = try await handle(req, as: .person)
        } catch {
            let m = Self.mistake(error)
            return (m.status, ["ok": false, "code": m.code, "error": m.message])
        }
        let json = r.bodyData.flatMap(JSON.object) ?? ["text": r.bodyData.map { String(decoding: $0, as: UTF8.self) } ?? ""]
        return (r.status, json)
    }

    /// `as`: who's asking, when it's known already (the person, or a held change being applied).
    func handle(_ req: HTTPRequest, as known: Caller?, approved: (SpaceID, String)? = nil) async throws -> HTTPResponse {
        var parts = req.path.split(separator: "/").map(String.init)
        // Tool Mac Tool Run's routes for the person's three stores.
        if parts.count >= 2, parts[0] == "api", ["library", "memory", "mind"].contains(parts[1]) {
            parts = ["api", "spaces", "user"] + parts.dropFirst()
        }
        let method = req.method == "HEAD" ? "GET" : req.method
        if parts.isEmpty || parts == ["api"] {
            if parts.isEmpty, method == "GET" { return statusPage() }
            return JSON.response(overview())
        }
        guard parts[0] == "api" else { throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.path) (GET /api lists them)") }
        let fields = try Self.fields(req)
        switch parts[1] {
        case "health":
            return JSON.response(health())
        case "doc":
            return try doc("API")
        case "docs":
            if parts.count == 2 { return JSON.response(["ok": true, "docs": docNames(), "how": "GET /api/docs/{name}: one, as Markdown"]) }
            return try doc(parts[2])
        case "spaces":
            let caller = try known ?? self.caller(req, fields)
            return try await spacesRoute(req, Array(parts.dropFirst(2)), method, fields, caller, approved: approved)
        case "access":
            let caller = try known ?? self.caller(req, fields)
            return try await accessRoute(req, Array(parts.dropFirst(2)), method, fields, caller)
        case "pending":
            let caller = try known ?? self.caller(req, fields)
            return try await pendingRoute(req, Array(parts.dropFirst(2)), method, fields, caller)
        case "clients":
            return try await clientsRoute(req, Array(parts.dropFirst(2)), method, fields, known)
        case "changes":
            let caller = try known ?? self.caller(req, fields)
            return await changesRoute(fields, caller)
        case "operations":
            let caller = try known ?? self.caller(req, fields)
            return try await operationsRoute(Array(parts.dropFirst(2)), fields, caller)
        case "import":
            let caller = try known ?? self.caller(req, fields)
            return try await importRoute(method, caller)
        default:
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.method) \(req.path) (GET /api lists them)")
        }
    }

    /// The request's fields: its query, then its JSON body (or its text, as "text").
    static func fields(_ req: HTTPRequest) throws -> [String: Any] {
        var fields: [String: Any] = [:]
        for (k, v) in req.query { fields[k] = v }
        if !req.body.isEmpty {
            if req.contentType.hasPrefix("text/") {
                fields["text"] = String(decoding: req.body, as: UTF8.self)
            } else if let body = JSON.object(req.body) {
                fields.merge(body) { _, b in b }
            } else if (try? JSONSerialization.jsonObject(with: req.body, options: [.fragmentsAllowed])) != nil {
                // A JSON value that isn't an object: a record's value (PUT), taken from the body there.
            } else {
                throw HTTPError(status: 400, code: "bad_request", message: "send a JSON object (Content-Type: application/json), or text as text/plain")
            }
        }
        return fields
    }

    // MARK: the spaces

    func spacesRoute(_ req: HTTPRequest, _ rest: [String], _ method: String, _ fields: [String: Any], _ caller: Caller,
                     approved: (SpaceID, String)?) async throws -> HTTPResponse {
        guard let first = rest.first else {
            return JSON.response(["ok": true, "folder": storage.root.path, "spaces": SpaceID.allCases.map { spaceJSON($0, for: caller.name) }])
        }
        guard let space = SpaceID(word: first) else {
            throw HTTPError(status: 404, code: "no_such_space", message: "there's no space called \(first) (the spaces: \(SpaceID.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        if rest.count == 1 {
            guard method == "GET" else { throw HTTPError(status: 405, code: "bad_request", message: "a space takes GET (what's in it); its stores take the rest") }
            return JSON.response(["ok": true].merging(spaceJSON(space, for: caller.name)) { a, _ in a })
        }
        if rest.count == 2, rest[1] == "reset" {
            guard method == "POST" else { throw HTTPError(status: 405, code: "bad_request", message: "POST to reset a space") }
            return try await resetSpace(space, caller)
        }
        guard let spec = storage.spec(space, rest[1]) else {
            throw HTTPError(status: 404, code: "no_such_store", message: "\(space.folderName) has no store called \(rest[1]) (its stores: \(storage.stores(in: space).map(\.name).joined(separator: ", ")))")
        }
        let tail = Array(rest.dropFirst(2))
        switch spec.kind {
        case .notes, .memory: return try await notesRoute(spec, req, tail, method, fields, caller, approved: approved)
        case .mind: return try await mindRoute(spec, req, tail, method, fields, caller, approved: approved)
        case .records: return try await recordsRoute(spec, req, tail, method, fields, caller, approved: approved)
        }
    }

    func spaceJSON(_ space: SpaceID, for client: String) -> [String: Any] {
        var out: [String: Any] = ["space": space.rawValue, "title": space.title, "purpose": space.purpose, "folder": storage.folder(space).path,
                                  "stores": storage.stores(in: space).map { storeJSON($0, for: client) }]
        if let owner = space.owner { out["owner"] = owner }
        if space == .other { out["how"] = "your own: /api/spaces/other/\(Clients.slug(client) ?? "your-app") (made the first time you write there)" }
        return out
    }

    func storeJSON(_ spec: StoreSpec, for client: String) -> [String: Any] {
        var out: [String: Any] = ["store": spec.name, "path": spec.path, "kind": spec.kind.rawValue, "purpose": spec.purpose,
                                  "folder": storage.folder(spec).path, "url": "/api/spaces/\(spec.path)",
                                  "your_access": access(client, spec.space, spec.name).word]
        switch spec.kind {
        case .notes, .memory: out["notes"] = storage.notes(spec).list().count
        case .records: out["records"] = storage.records(spec).keys().count
        case .mind:
            let g = storage.mind.graph()
            out["nodes"] = g.nodes.count
            out["edges"] = g.edges.count
        }
        return out
    }

    /// Checks `caller` may do `op` (changing, or only reading) with a store. One that may not,
    /// and asked to hold it (`"hold": true`), has the change kept in PENDING for approval.
    func check(_ spec: StoreSpec, changes: Bool, _ caller: Caller, op: String, _ req: HTTPRequest, _ fields: [String: Any],
               approved: (SpaceID, String)?) throws -> HTTPResponse? {
        if let a = approved, a.0 == spec.space, a.1 == spec.name { return nil }
        if spec.space == .pending, changes {
            throw HTTPError(status: 403, code: "read_only", message: "PENDING changes as requests are decided: POST /api/access/requests/{id}/approve, /api/pending/{id}/approve")
        }
        if spec.space == .pending, !Policy.seesEverything(caller.name) {
            throw AccessDenied(client: caller.name, spec: spec, need: .read, has: .none,
                               fix: "Your own requests: GET /api/access/requests and GET /api/pending")
        }
        let has = access(caller.name, spec.space, spec.name)
        let need: Access = changes ? .write : .read
        if has >= need { return nil }
        let hold = Fields(values: fields).bool("hold") == true || req.header("x-hold").map { ["true", "1", "yes"].contains($0.lowercased()) } == true
        if changes, hold { return try holdChange(spec, op, req, fields, caller) }
        throw AccessDenied(client: caller.name, spec: spec, need: need, has: has, fix: nil)
    }

    // MARK: notes and MEMORY

    /// The operations a notes store has: the library's (only those that read, on one that can't
    /// change), and MEMORY's own on MEMORY.
    static func operations(_ spec: StoreSpec) -> [Operation] {
        if spec.kind == .memory { return LibraryAPI.operations + MemoryAPI.operations }
        if spec.shelf.readOnly { return LibraryAPI.operations.filter { !$0.changes && $0.name != "trash" } }
        return LibraryAPI.operations
    }

    func notesRoute(_ spec: StoreSpec, _ req: HTTPRequest, _ rest: [String], _ method: String, _ fieldsIn: [String: Any], _ caller: Caller,
                    approved: (SpaceID, String)?) async throws -> HTTPResponse {
        var fields = fieldsIn
        let op: String
        let base = "/api/spaces/\(spec.path)"
        let isMemory = spec.kind == .memory
        switch (method, rest.first, rest.count) {
        case ("GET", nil, _):
            _ = try check(spec, changes: false, caller, op: "overview", req, fields, approved: approved)
            return JSON.response(notesOverview(spec))
        case ("POST", nil, _):
            let names = Self.operations(spec).map(\.name).joined(separator: ", ")
            guard let named = Fields.text(fields["op"] ?? fields["operation"]), !named.isEmpty else {
                throw HTTPError(status: 400, code: "missing_op", message: "send {\"op\": \"<one of \(names)>\", …} (GET \(base) says what each takes)")
            }
            op = named.lowercased().replacingOccurrences(of: "-", with: "_")
        case ("GET", "files", 1): op = "list"
        case ("POST", "files", 1): op = "create"
        case (_, "files", 2):
            fields["name"] = rest[1]
            switch method {
            case "GET": op = req.query["format"] == "text" || req.query["format"] == "raw" ? "raw" : "read"
            case "PUT": op = "write"
            case "DELETE": op = "delete"
            case "POST": op = "create"
            default: throw HTTPError(status: 405, code: "bad_request", message: "a note takes GET (read), PUT (write) or DELETE (to the Trash)")
            }
        case (_, "files", 3):
            fields["name"] = rest[1]
            let action = rest[2]
            let reads = ["outline", "backlinks", "exists"]
            guard ["append", "rename", "copy"].contains(action) || reads.contains(action) else {
                throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.path) (a note's routes: append, rename, copy, outline, backlinks, exists)")
            }
            guard method == (reads.contains(action) ? "GET" : "POST") else {
                throw HTTPError(status: 405, code: "bad_request", message: "\(req.path) takes \(reads.contains(action) ? "GET" : "POST")")
            }
            op = action
        case ("GET", "names", 1): op = "names"
        case ("GET", "search", 1): op = "search"
        case ("GET", "find", 1): op = "find"
        case ("GET", "recent", 1): op = "recent"
        case ("GET", "stats", 1): op = "stats"
        case ("GET", "trash", 1): op = "trash"
        case ("POST", "trash", 2) where rest[1] == "restore": op = "restore"
        case ("POST", "trash", 2) where rest[1] == "empty": op = "empty_trash"
        // MEMORY's own.
        case ("POST", "remember", 1) where isMemory: op = "remember"
        case ("GET", "recall", 1) where isMemory, ("POST", "recall", 1) where isMemory: op = "recall"
        case ("GET", "categories", 1) where isMemory: op = "categories"
        case ("GET", "categories", 3) where isMemory && rest[2] == "members":
            fields["name"] = rest[1]
            op = "members"
        case ("GET", "upcoming", 1) where isMemory: op = "upcoming"
        case ("POST", "sync", 1) where isMemory: op = "sync"
        case ("POST", "defaults", 1) where isMemory: op = "defaults"
        default:
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.method) \(req.path) (GET \(base) lists its routes)")
        }
        let known = Self.operations(spec).map(\.name) + ["raw"]
        let changes = (LibraryAPI.byName[op] ?? MemoryAPI.byName[op])?.changes ?? false
        if known.contains(op), let held = try check(spec, changes: changes, caller, op: op, req, fields, approved: approved) { return held }
        let lib = storage.notes(spec)
        let memory = storage.userMemory
        if isMemory, !memory.folderExists || !memory.mind.exists { _ = try? memory.ensure() } else if !FileManager.default.fileExists(atPath: lib.root.path) { try? lib.ensure() }
        let f = Fields(values: fields)
        return await logged(spec.path, op, f, caller) {
            if op == "raw" {
                let r = try lib.read(try f.name())
                return .raw(HTTPResponse(status: 200, contentType: "text/markdown; charset=utf-8", data: Data(r.text.utf8)), name: r.note.name, summary: "read \(r.note.name)")
            }
            guard known.contains(op) else {
                if spec.shelf.readOnly, LibraryAPI.byName[op]?.changes == true { try lib.writable() }
                throw LibraryError(.badName, "There's no \(spec.path) operation called \(op).", fix: "The operations: \(known.filter { $0 != "raw" }.joined(separator: ", "))")
            }
            var out: [String: Any]
            if MemoryAPI.byName[op] != nil {
                out = try MemoryAPI.perform(op, f, memory: memory, client: caller.name)
            } else {
                // A memory file renamed: its node follows (by the name it had).
                let before = op == "rename" ? (try? f.name()).flatMap { lib.find($0)?.name } : nil
                out = try LibraryAPI.perform(op, f, library: lib)
                if isMemory {
                    let mind = memory.mind
                    if op == "rename", let before, let now = out["name"] as? String {
                        out["mind"] = try mind.renamed(before, to: now, who: caller.name)
                    }
                    if ["write", "create", "append", "copy", "restore", "rename"].contains(op) {
                        let added = try mind.index(lib, who: caller.name)
                        if !added.isEmpty { out["mind"] = ((out["mind"] as? [String]) ?? []) + added }
                    }
                }
            }
            if changes {
                await self.changed(spec.space, spec.name, op: op, name: out["name"] as? String ?? f.text("name"), caller.name)
                if isMemory, out["mind"] != nil || ["remember", "sync"].contains(op) { await self.changed(.user, "mind", op: op, name: out["node"] as? String, caller.name) }
            }
            let summary = MemoryAPI.byName[op] != nil ? MemoryAPI.memorySummary(op, out) : LibraryAPI.summary(op, out)
            return .json(out, summary: summary)
        }
    }

    /// GET /api/spaces/{space}/{store}, for notes: where it is, what's in it, and every operation.
    func notesOverview(_ spec: StoreSpec) -> [String: Any] {
        let lib = storage.notes(spec)
        let base = "/api/spaces/\(spec.path)"
        var out: [String: Any] = [
            "ok": true, "space": spec.space.rawValue, "store": spec.name, "kind": spec.kind.rawValue, "purpose": spec.purpose,
            "folder": lib.root.path, "extension": lib.ext, "exists": FileManager.default.fileExists(atPath: lib.root.path),
            "notes": lib.list().count, "trashed": lib.trash().count, "read_only": spec.shelf.readOnly,
            "names": "a note's name is its file's name without .\(lib.ext): groceries is \(spec.folderName)/groceries.\(lib.ext)",
            "how": "POST \(base) {\"op\": \"<operation>\", …its fields}, or the operation's own route",
            "operations": Self.operations(spec).map { o -> [String: Any] in
                var d: [String: Any] = ["op": o.name, "summary": o.summary, "fields": o.fields, "changes": o.changes]
                if let r = o.route { d["route"] = r.replacingOccurrences(of: "/api/library", with: base).replacingOccurrences(of: "/api/memory", with: base) }
                return d
            },
        ]
        if spec.kind == .memory {
            out["mind"] = "each file is a node of the mind (GET /api/spaces/user/mind/nodes/PEOPLE); remember links what's learnt to them"
            out["defaults"] = Memory.defaultNames
        }
        return out
    }

    // MARK: the mind

    func mindRoute(_ spec: StoreSpec, _ req: HTTPRequest, _ rest: [String], _ method: String, _ fieldsIn: [String: Any], _ caller: Caller,
                   approved: (SpaceID, String)?) async throws -> HTTPResponse {
        var fields = fieldsIn
        let op: String
        let reads: [String: String] = ["stats": "stats", "nodes": "nodes", "path": "path", "find": "find", "edges": "edges", "notes": "notes", "dates": "dates",
                                       "scopes": "scopes", "graph": "graph", "layout": "layout", "log": "log", "canonical": "canonical", "problems": "problems",
                                       "query": "query", "context": "context", "prompt": "prompt"]
        let posts = ["query", "context", "prompt", "check", "add", "append", "note", "rename", "forget", "comment", "compact"]
        switch (method, rest.first, rest.count) {
        case ("GET", nil, _):
            _ = try check(spec, changes: false, caller, op: "overview", req, fields, approved: approved)
            return JSON.response(mindOverview())
        case ("POST", nil, _):
            guard let named = Fields.text(fields["op"] ?? fields["operation"]), !named.isEmpty else {
                throw HTTPError(status: 400, code: "missing_op", message: "send {\"op\": \"<one of \(MindAPI.names)>\", …} (GET /api/mind says what each takes)")
            }
            op = named.lowercased().replacingOccurrences(of: "-", with: "_")
        case ("GET", "nodes", 2):
            fields["name"] = rest[1]
            op = "about"
        case ("GET", "nodes", 3) where rest[2] == "neighbors" || rest[2] == "neighbours":
            fields["name"] = rest[1]
            op = "neighbors"
        case ("GET", let first?, 1) where reads[first] != nil:
            op = reads[first]!
        case ("POST", let first?, 1) where posts.contains(first):
            op = first
        default:
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.method) \(req.path) (GET /api/mind lists the mind's routes)")
        }
        let changes = MindAPI.byName[op]?.changes ?? false
        if MindAPI.byName[op] != nil || op == "neighbours" || op == "search",
           let held = try check(spec, changes: changes, caller, op: op, req, fields, approved: approved) { return held }
        let f = Fields(values: fields)
        let memory = storage.userMemory
        if !memory.folderExists || !memory.mind.exists { _ = try? memory.ensure() }
        return await logged(spec.path, op, f, caller) {
            guard MindAPI.byName[op] != nil || op == "neighbours" || op == "search" else {
                throw MindError(.badRequest, "There's no mind operation called \(op).", fix: "The operations: \(MindAPI.names) (GET /api/mind says what each takes)")
            }
            let done = try MindAPI.perform(op, f, memory: memory, client: caller.name, req: req)
            if changes { await self.changed(.user, "mind", op: op, name: f.text("name"), caller.name) }
            return done
        }
    }

    func mindOverview() -> [String: Any] {
        let mind = storage.mind
        let g = mind.graph()
        return [
            "ok": true, "space": "user", "store": "mind", "kind": "mind", "file": mind.file.path, "exists": mind.exists, "nodes": g.nodes.count, "edges": g.edges.count,
            "scopes": g.scopes, "current_scope": g.current, "problems": g.problems.count,
            "notation": "the text mind-map notation: GET /api/docs/MIND-NOTATION (the rules), /api/docs/MIND-GUIDE (how to use the mind)",
            "memory": "each MEMORY file is a node in the root scope (PEOPLE, ORGANIZATIONS, …)",
            "append_only": "nothing is ever taken out of the log: a rename or a forget is a line appended",
            "how": "POST /api/mind {\"op\": \"<operation>\", …its fields}, or the operation's own route (/api/mind is /api/spaces/user/mind)",
            "operations": MindAPI.operations.map { o -> [String: Any] in
                var d: [String: Any] = ["op": o.name, "summary": o.summary, "fields": o.fields, "changes": o.changes]
                if let r = o.route { d["route"] = r }
                return d
            },
        ]
    }

    // MARK: records

    static let recordOperations: [Operation] = [
        Operation(name: "list", summary: "every record, with its value (?prefix: only keys starting with it; ?values=false: without values)", fields: ["prefix?", "values?", "limit?"],
                  route: "GET …/records", changes: false),
        Operation(name: "keys", summary: "the keys alone, A to Z", fields: ["prefix?"], route: "GET …/keys", changes: false),
        Operation(name: "get", summary: "one record: its value, version, when it was made and last written, by whom", fields: ["key"], route: "GET …/records/{key}", changes: false),
        Operation(name: "put", summary: "writes a record's value (made if it isn't there); with \"expect\": only if it's at that version (0: only if it's new)",
                  fields: ["key", "value", "expect?"], route: "PUT …/records/{key} (the body is the value; If-Match or ?expect for the version)", changes: true),
        Operation(name: "patch", summary: "merges fields into a record that's an object (null takes a field out)", fields: ["key", "fields", "expect?"],
                  route: "PATCH …/records/{key} (the body is the fields)", changes: true),
        Operation(name: "append", summary: "adds items at the end of a record that's a list (made if it isn't there), keeping the latest \"keep\"",
                  fields: ["key", "items | item", "keep?", "expect?"], route: "POST …/records/{key}/append", changes: true),
        Operation(name: "delete", summary: "deletes a record for good (with \"expect\": only if it's at that version)", fields: ["key", "expect?"],
                  route: "DELETE …/records/{key}", changes: true),
    ]

    func recordsRoute(_ spec: StoreSpec, _ req: HTTPRequest, _ rest: [String], _ method: String, _ fieldsIn: [String: Any], _ caller: Caller,
                      approved: (SpaceID, String)?) async throws -> HTTPResponse {
        var fields = fieldsIn
        let base = "/api/spaces/\(spec.path)"
        let op: String
        switch (method, rest.first, rest.count) {
        case ("GET", nil, _):
            _ = try check(spec, changes: false, caller, op: "overview", req, fields, approved: approved)
            let store = storage.records(spec)
            return JSON.response([
                "ok": true, "space": spec.space.rawValue, "store": spec.name, "kind": "records", "purpose": spec.purpose, "folder": store.root.path,
                "records": store.keys().count, "keys": Array(store.keys().prefix(200)),
                "how": "POST \(base) {\"op\": \"<operation>\", …its fields}, or the operation's own route. Every write raises the record's version by one: send the version you read as \"expect\" and a write that would overwrite someone else's is turned down (409)",
                "operations": Self.recordOperations.map { o -> [String: Any] in
                    var d: [String: Any] = ["op": o.name, "summary": o.summary, "fields": o.fields, "changes": o.changes]
                    if let r = o.route { d["route"] = r.replacingOccurrences(of: "…", with: base) }
                    return d
                },
            ])
        case ("POST", nil, _):
            guard let named = Fields.text(fields["op"] ?? fields["operation"]), !named.isEmpty else {
                throw HTTPError(status: 400, code: "missing_op", message: "send {\"op\": \"<one of \(Self.recordOperations.map(\.name).joined(separator: ", "))>\", …} (GET \(base) says what each takes)")
            }
            op = named.lowercased()
        case ("GET", "records", 1): op = "list"
        case ("GET", "keys", 1): op = "keys"
        case (_, "records", 2):
            // The body of a PUT or PATCH is the record's, not fields of the request: only the query is.
            if method == "PUT" || method == "PATCH" {
                fields = [:]
                for (k, v) in req.query { fields[k] = v }
            }
            fields["key"] = rest[1]
            switch method {
            case "GET": op = "get"
            case "PUT":
                op = "put"
                fields["value"] = try Self.bodyValue(req)
            case "PATCH":
                op = "patch"
                guard let o = JSON.object(req.body) else { throw HTTPError(status: 400, code: "bad_request", message: "PATCH takes a JSON object: the fields to merge in") }
                fields["fields"] = o
            case "DELETE": op = "delete"
            default: throw HTTPError(status: 405, code: "bad_request", message: "a record takes GET, PUT (its value), PATCH (fields merged in) or DELETE")
            }
            if let m = req.header("if-match") { fields["expect"] = m.trimmingCharacters(in: CharacterSet(charactersIn: "\" W/")) }
        case ("POST", "records", 3) where rest[2] == "append":
            fields["key"] = rest[1]
            op = "append"
        default:
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.method) \(req.path) (GET \(base) lists its routes)")
        }
        let changes = Self.recordOperations.first { $0.name == op }?.changes ?? false
        if Self.recordOperations.contains(where: { $0.name == op }), let held = try check(spec, changes: changes, caller, op: op, req, fields, approved: approved) { return held }
        let f = Fields(values: fields)
        let store = storage.records(spec)
        return await logged(spec.path, op, f, caller) {
            func key() throws -> String {
                guard let k = f.text("key") ?? f.text("name") else { throw LibraryError(.badName, "Say which record: \"key\".") }
                return k
            }
            let expect = f.int("expect")
            var out: [String: Any]
            let summary: String
            switch op {
            case "list":
                let values = f.bool("values") ?? true
                var list = store.list(prefix: f.text("prefix"))
                let total = list.count
                list = Array(list.prefix(max(0, f.int("limit") ?? Int.max)))
                out = ["total": total, "count": list.count, "records": list.map { Self.recordJSON($0, value: values) }]
                summary = "listed \(list.count) records"
            case "keys":
                let keys = store.keys(prefix: f.text("prefix"))
                out = ["count": keys.count, "keys": keys]
                summary = "\(keys.count) keys"
            case "get":
                let k = try key()
                guard let r = try store.get(k) else {
                    throw LibraryError(.notFound, "There's no record \(k) in \(spec.path).", fix: "GET \(base)/keys lists them.")
                }
                return .raw(JSON.response(["ok": true, "op": op].merging(Self.recordJSON(r)) { a, _ in a }, headers: [("ETag", "\"\(r.version)\"")]), name: k, summary: "read \(k)")
            case "put":
                guard f.values.keys.contains("value") else { throw LibraryError(.badName, "put takes \"value\": what the record holds (any JSON).") }
                let r = try store.put(try key(), f.values["value"] ?? NSNull(), expect: expect, by: caller.name)
                out = Self.recordJSON(r.record, value: false).merging(["new": r.created, "action": r.created ? "created" : "replaced"]) { a, _ in a }
                summary = "\(r.created ? "created" : "replaced") \(r.record.key) (version \(r.record.version))"
            case "patch":
                guard let fields = f.values["fields"] as? [String: Any] else { throw LibraryError(.badName, "patch takes \"fields\": an object of the fields to merge in.") }
                let r = try store.patch(try key(), fields, expect: expect, by: caller.name)
                out = Self.recordJSON(r.record).merging(["new": r.created, "action": r.created ? "created" : "patched"]) { a, _ in a }
                summary = "patched \(r.record.key) (version \(r.record.version))"
            case "append":
                let items: [Any] = (f.values["items"] as? [Any]) ?? (f.values["item"].map { [$0] } ?? [])
                guard !items.isEmpty else { throw LibraryError(.badName, "append takes \"items\" (a list) or \"item\": what to add at the end.") }
                let r = try store.append(try key(), items, keep: f.int("keep"), expect: expect, by: caller.name)
                out = Self.recordJSON(r.record, value: false).merging(["new": r.created, "action": r.created ? "created" : "appended", "length": (r.record.value as? [Any])?.count ?? 0]) { a, _ in a }
                summary = "appended \(items.count) to \(r.record.key)"
            case "delete":
                let k = try key()
                let was = try store.delete(k, expect: expect)
                out = ["key": k, "deleted": was]
                summary = was ? "deleted \(k)" : "\(k) wasn't there"
            default:
                throw LibraryError(.badName, "There's no records operation called \(op).", fix: "The operations: \(Self.recordOperations.map(\.name).joined(separator: ", "))")
            }
            if changes { await self.changed(spec.space, spec.name, op: op, name: f.text("key"), caller.name) }
            out["name"] = f.text("key")
            return .json(out, summary: summary)
        }
    }

    /// A PUT's body as a record's value: any JSON, or text as a string.
    static func bodyValue(_ req: HTTPRequest) throws -> Any {
        if req.contentType.hasPrefix("text/") { return String(decoding: req.body, as: UTF8.self) }
        guard !req.body.isEmpty, let v = try? JSONSerialization.jsonObject(with: req.body, options: [.fragmentsAllowed]) else {
            throw HTTPError(status: 400, code: "bad_request", message: "PUT takes the record's value as its body: any JSON (or text, as text/plain)")
        }
        return v
    }

    static func recordJSON(_ r: RecordStore.Record, value: Bool = true) -> [String: Any] {
        var out: [String: Any] = ["key": r.key, "version": r.version, "created": JSON.date(r.created), "updated": JSON.date(r.updated)]
        if let by = r.by { out["by"] = by }
        if value { out["value"] = r.value }
        return out
    }

    // MARK: doing an operation, and saying how it went

    public enum Done {
        case json([String: Any], summary: String)
        case raw(HTTPResponse, name: String?, summary: String)
    }

    /// Does `work`, logs it under a new id, and answers: the JSON with "ok", "op" and "request",
    /// or the mistake with its code and fix.
    func logged(_ path: String, _ op: String, _ fields: Fields, _ caller: Caller, _ work: () async throws -> Done) async -> HTTPResponse {
        let id = UUID()
        let started = Date()
        let tagged: [(String, String)] = [("X-Request-Id", id.uuidString)]
        func entry(ok: Bool, status: Int, name: String?, code: String? = nil, error: String? = nil, summary: String) -> OperationLog.Entry {
            .init(id: id, path: path, op: op == "raw" ? "read" : op, name: name, client: caller.name, at: started,
                  seconds: Date().timeIntervalSince(started), ok: ok, status: status, code: code, error: error, summary: summary)
        }
        do {
            switch try await work() {
            case .raw(var response, let name, let summary):
                await log.add(entry(ok: response.status < 400, status: response.status, name: name, summary: summary))
                response.headers += tagged
                return response
            case .json(var out, let summary):
                await log.add(entry(ok: true, status: 200, name: out["name"] as? String ?? fields.text("name"), summary: summary))
                out["ok"] = true
                out["op"] = op
                out["request"] = id.uuidString
                return JSON.response(out, headers: tagged)
            }
        } catch {
            let m = Self.mistake(error)
            await log.add(entry(ok: false, status: m.status, name: fields.text("name") ?? fields.text("key"), code: m.code, error: m.message, summary: "\(op): \(m.message)"))
            var out: [String: Any] = ["ok": false, "op": op, "code": m.code, "error": m.message, "request": id.uuidString]
            if let fix = m.fix { out["fix"] = fix }
            out.merge(m.extra) { a, _ in a }
            return JSON.response(out, status: m.status, headers: tagged)
        }
    }

    struct Mistake {
        var status: Int
        var code: String
        var message: String
        var fix: String?
        var extra: [String: Any] = [:]
    }

    static func mistake(_ error: Error) -> Mistake {
        switch error {
        case let e as LibraryError:
            let unknown = e.code == .badName && e.message.hasPrefix("There's no") && e.message.contains("operation called")
            return Mistake(status: unknown ? 400 : e.status, code: unknown ? "unknown_op" : e.code.rawValue, message: e.message, fix: e.fix)
        case let e as MindError:
            var extra: [String: Any] = [:]
            if !e.problems.isEmpty { extra["problems"] = e.problems.map(MindAPI.problemJSON) }
            return Mistake(status: e.status, code: e.code.rawValue, message: e.message, fix: e.problems.isEmpty ? e.fix : "Each problem says its fix.", extra: extra)
        case let e as RecordStore.Conflict:
            let now = e.version == 0 ? "there's none" : "it's at version \(e.version) now"
            return Mistake(status: 409, code: "version_conflict", message: "\(e.key) has changed since it was read (expected version \(e.expected); \(now)).",
                           fix: "Read it again (its value and version), then write with that version.", extra: ["version": e.version, "expected": e.expected])
        case let e as AccessDenied:
            return Mistake(status: 403, code: "no_access", message: e.message, fix: e.fixText, extra: e.extra)
        case let e as HTTPError:
            return Mistake(status: e.status, code: e.code, message: e.message)
        default:
            return Mistake(status: 500, code: "failed", message: "\(error)")
        }
    }

    // MARK: what changed

    func changed(_ space: SpaceID, _ store: String?, op: String, name: String?, _ client: String) async {
        await changes.add(space, store, op: op, name: name, client: client)
        onChange?()
    }

    func changesRoute(_ fields: [String: Any], _ caller: Caller) async -> HTTPResponse {
        let f = Fields(values: fields)
        let after = max(0, f.int("after") ?? f.int("since") ?? 0)
        let space = f.text("space").flatMap(SpaceID.init(word:))
        let store = f.text("store")?.lowercased()
        let wait = f.double("wait") ?? 0
        let list = await changes.wait(after: after, space: space, store: store, seconds: wait)
        // Only what the caller may read (PENDING: Peter and the person, and anyone about its own).
        let seen = list.filter { c in
            if Policy.seesEverything(caller.name) { return true }
            if c.space == .pending { return Clients.same(c.client, caller.name) || Clients.same(c.name, caller.name) }
            return access(caller.name, c.space, c.store) >= .read || Clients.same(c.client, caller.name)
        }
        let last = await changes.seq
        return JSON.response(["ok": true, "after": after, "last": last, "oldest": await changes.oldest, "count": seen.count, "changes": seen.map(\.json),
                              "next": "GET /api/changes?after=\(list.last?.seq ?? max(after, last))&wait=25"])
    }

    func operationsRoute(_ rest: [String], _ fields: [String: Any], _ caller: Caller) async throws -> HTTPResponse {
        let f = Fields(values: fields)
        if let first = rest.first {
            guard let id = UUID(uuidString: first), let e = await log.entry(id), Policy.seesEverything(caller.name) || Clients.same(e.client, caller.name) else {
                throw HTTPError(status: 404, code: "unknown_request", message: "no operation \(first) (the latest \(log.capacity) are kept while the app runs)")
            }
            return JSON.response(e.json, headers: [("X-Request-Id", id.uuidString)])
        }
        let limit = min(500, max(1, f.int("limit") ?? 20))
        let mine = await log.recent(500).filter { Policy.seesEverything(caller.name) || Clients.same($0.client, caller.name) }
        return JSON.response(["ok": true, "operations": mine.prefix(limit).map(\.json)])
    }

    // MARK: bringing in Tool Mac Tool Run's

    /// GET /api/import: what there is to bring in; POST: brings it in (the person, or Peter).
    func importRoute(_ method: String, _ caller: Caller) async throws -> HTTPResponse {
        if method == "GET" {
            return JSON.response(["ok": true, "available": ToolMacImport.available(source: importSource, peter: importPeter), "done_before": ToolMacImport.done(in: storage),
                                  "from": [importSource.path, importPeter.path]])
        }
        guard method == "POST" else { throw HTTPError(status: 405, code: "bad_request", message: "GET says what there is to bring in; POST brings it in") }
        guard caller.isPerson || Clients.same(caller.name, Clients.peter) else {
            throw HTTPError(status: 403, code: "not_yours", message: "only the person (or Peter) brings Tool Mac Tool Run's things in")
        }
        let report = try ToolMacImport.run(into: storage, source: importSource, peter: importPeter)
        if !report.copied.isEmpty {
            for space in [SpaceID.user, .super, .peter] { await changed(space, nil, op: "imported", name: nil, caller.name) }
        }
        return JSON.response(["ok": true].merging(report.json) { a, _ in a })
    }

    /// Where Tool Mac Tool Run's and Peter's things are brought in from (a test sets them).
    public func setImportSources(toolMac: URL, peter: URL) {
        importSource = toolMac
        importPeter = peter
    }

    // MARK: resetting a space

    func resetSpace(_ space: SpaceID, _ caller: Caller) async throws -> HTTPResponse {
        // The person's own space is theirs alone to reset (in the window); another, its owner's or Peter's.
        let may = caller.isPerson || (space != .user && space != .pending && (Clients.same(caller.name, Clients.peter) || Clients.same(space.owner, caller.name)))
        guard may else {
            throw HTTPError(status: 403, code: "not_yours", message: space == .user ? "only you can reset your own space, in the Storage Spaces window" : "only \(space.owner ?? "its owner") or Peter can reset \(space.folderName)")
        }
        let moved = try storage.reset(space)
        await changed(space, nil, op: "reset", name: nil, caller.name)
        return JSON.response(["ok": true, "space": space.rawValue, "trashed": moved, "message": "\(space.folderName) is back as it came; what was in it is in the Trash"])
    }

    // MARK: the overview, health, docs

    func overview() -> [String: Any] {
        [
            "ok": true, "name": "Storage Spaces", "version": version, "folder": storage.root.path,
            "doc": "GET /api/doc: the whole contract, as Markdown",
            "who": "say who you are with every request: \"client\": \"<your app's name>\" (or the X-Client header)",
            "spaces": SpaceID.allCases.map { ["space": $0.rawValue, "title": $0.title, "purpose": $0.purpose, "url": "/api/spaces/\($0.rawValue)"] },
            "routes": [
                "GET /api/health", "GET /api/doc", "GET /api/docs/{name}", "GET /api/spaces", "GET /api/spaces/{space}",
                "/api/spaces/{space}/{store}…  (notes, MEMORY, the mind, records: GET one for its routes)",
                "/api/library…, /api/memory…, /api/mind…  (the person's three, as Tool Mac Tool Run had them)",
                "GET /api/access, GET /api/access/check, /api/access/grants…, /api/access/requests…",
                "GET /api/pending, /api/pending/{id}…", "POST /api/clients/register", "GET /api/changes?after=N&wait=25", "GET /api/operations",
                "GET /api/import, POST /api/import  (Tool Mac Tool Run's library, MEMORY and mind, and Peter's schedule, copied in)",
            ],
        ]
    }

    public func health() -> [String: Any] {
        var counts: [String: Any] = [:]
        for spec in StoreSpec.builtIn {
            switch spec.kind {
            case .notes, .memory: counts[spec.path] = storage.notes(spec).list().count
            case .records: counts[spec.path] = storage.records(spec).keys().count
            case .mind: counts[spec.path] = storage.mind.graph().nodes.count
            }
        }
        let open = (try? openRequests()) ?? []
        let held = heldWrites().filter { ($0.value as? [String: Any])?["state"] as? String == "waiting" }
        return ["ok": true, "name": "Storage Spaces", "version": version, "port": Self.port, "folder": storage.root.path, "exists": storage.exists,
                "counts": counts, "other_apps": storage.stores(in: .other).map(\.name), "grants": book.grants.count,
                "waiting": ["requests": open.count, "writes": held.count]]
    }

    func docNames() -> [String] {
        var names: [String] = []
        for folder in docs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where f.hasSuffix(".md") {
                let n = String(f.dropLast(3))
                if !names.contains(n), n.uppercased() == n { names.append(n) }
            }
        }
        return names.sorted()
    }

    func doc(_ name: String) throws -> HTTPResponse {
        let n = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        for folder in docs {
            for candidate in [n, n.uppercased()] {
                let url = folder.appendingPathComponent(candidate + ".md")
                if let data = try? Data(contentsOf: url) {
                    var text = String(decoding: data, as: UTF8.self)
                    if candidate == "API" { text = text.replacingOccurrences(of: "{{VERSION}}", with: version) }
                    return HTTPResponse(status: 200, contentType: "text/markdown; charset=utf-8", data: Data(text.utf8))
                }
            }
        }
        throw HTTPError(status: 404, code: "not_found", message: "there's no doc called \(name) (GET /api/docs lists them)")
    }

    func statusPage() -> HTTPResponse {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var rows = ""
        for space in SpaceID.allCases {
            let stores = storage.stores(in: space).map { s -> String in
                let n: Int
                switch s.kind {
                case .notes, .memory: n = storage.notes(s).list().count
                case .records: n = storage.records(s).keys().count
                case .mind: n = storage.mind.graph().nodes.count
                }
                return "<li><b>\(esc(s.folderName))</b> \(n) \(s.kind == .mind ? "nodes" : s.kind == .records ? "records" : "notes") — \(esc(s.purpose))</li>"
            }.joined()
            rows += "<h2>\(esc(space.folderName)) · \(esc(space.title))</h2><p>\(esc(space.purpose))</p><ul>\(stores.isEmpty ? "<li>nothing yet</li>" : stores)</ul>"
        }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Storage Spaces</title>
        <style>:root{color-scheme:light dark}body{font:15px -apple-system,system-ui,sans-serif;max-width:760px;margin:2em auto;padding:0 16px;line-height:1.45}h1{margin-bottom:0}h2{margin-top:1.6em;font-size:17px}code{font:13px ui-monospace,monospace}li{margin:.2em 0}.muted{opacity:.7}</style></head>
        <body><h1>Storage Spaces</h1><p class="muted">\(esc(version)) · \(esc(storage.root.path)) · <a href="/api/doc">the API</a> · <a href="/api/health">health</a></p>
        \(rows)</body></html>
        """
        return HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", data: Data(html.utf8))
    }

    // MARK: access, pending and clients (Access+API.swift)

    func saveBook() throws {
        book.dropExpired()
        try book.save(bookFile)
    }

    var grants: [Grant] {
        book.dropExpired()
        return book.grants
    }

    func addGrant(_ g: Grant) throws -> Grant {
        let made = book.add(g)
        try saveBook()
        return made
    }

    func removeGrant(_ id: Int) throws -> Grant? {
        guard let g = book.grants.first(where: { $0.id == id }) else { return nil }
        book.grants.removeAll { $0.id == id }
        try saveBook()
        return g
    }

    func setKey(_ client: String, hash: String?) throws {
        if let hash {
            book.keys[Clients.fold(client)] = AccessBook.Key(client: client, hash: hash, created: Date())
        } else {
            book.keys[Clients.fold(client)] = nil
        }
        try saveBook()
    }

    var keys: [AccessBook.Key] { Array(book.keys.values).sorted { $0.client < $1.client } }
}

/// A request turned down because the client may not do it.
struct AccessDenied: Error {
    let client: String
    let spec: StoreSpec
    let need: Access
    let has: Access
    let fix: String?

    var message: String {
        let place = "\(spec.space.folderName)/\(spec.folderName)"
        return has == .none ? "\(client) may not \(need == .read ? "read" : "change") \(place)." : "\(client) may only read \(place), not change it."
    }

    var fixText: String {
        fix ?? "Ask for it: POST /api/access/requests {\"space\": \"\(spec.space.rawValue)\", \"store\": \"\(spec.name)\", \"access\": \"\(need.word)\", \"why\": \"…\"}: Peter (or the person) says yes or no. Or send the change again with \"hold\": true, to have it wait in PENDING until it's approved."
    }

    var extra: [String: Any] {
        ["space": spec.space.rawValue, "store": spec.name, "need": need.word, "has": has.word,
         "ask": ["method": "POST", "path": "/api/access/requests", "body": ["space": spec.space.rawValue, "store": spec.name, "access": need.word]] as [String: Any]]
    }
}
