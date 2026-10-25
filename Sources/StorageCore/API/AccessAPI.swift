import Foundation

// Access over HTTP: what a client may do, asking for more, saying yes or no (Peter, the person,
// a space's owner), changes held until they're approved, and clients claiming their names.
//
// What's waiting is kept in PENDING as records, so it outlasts a restart and can be read like
// any other: PENDING/REQUESTS (request-1, request-2…) and PENDING/WRITES (write-1…). Once
// decided, each stays a week (so its asker can see how it went), then goes.
extension StorageAPI {
    static let decidedKeptFor: TimeInterval = 7 * 24 * 3600

    var requestsStore: RecordStore { storage.records(storage.spec(.pending, "requests")!) }
    var writesStore: RecordStore { storage.records(storage.spec(.pending, "writes")!) }

    /// The next number for a key in a store of PENDING (request-7 → 8).
    static func nextNumber(_ store: RecordStore, prefix: String) -> Int {
        (store.keys(prefix: prefix + "-").compactMap { Int($0.dropFirst(prefix.count + 1)) }.max() ?? 0) + 1
    }

    /// Takes out what was decided over a week ago.
    static func prune(_ store: RecordStore, now: Date = Date()) {
        for r in store.list() {
            guard let v = r.value as? [String: Any], let state = v["state"] as? String, state != "open", state != "waiting" else { continue }
            if now.timeIntervalSince(r.updated) > decidedKeptFor { _ = try? store.delete(r.key) }
        }
    }

    // MARK: requests for access

    /// The requests still open, oldest first (their values).
    func openRequests() throws -> [[String: Any]] {
        requestsStore.list().compactMap { $0.value as? [String: Any] }.filter { $0["state"] as? String == "open" }
            .sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
    }

    func heldWrites() -> [RecordStore.Record] {
        writesStore.list().sorted { ((($0.value as? [String: Any])?["id"] as? Int) ?? 0) < ((($1.value as? [String: Any])?["id"] as? Int) ?? 0) }
    }

    func accessRoute(_ req: HTTPRequest, _ rest: [String], _ method: String, _ fields: [String: Any], _ caller: Caller) async throws -> HTTPResponse {
        let f = Fields(values: fields)
        switch (method, rest.first, rest.count) {
        case ("GET", nil, _):
            // What a client may do with every store (the caller, or another: Peter and the person).
            let who = f.text("for") ?? f.text("of") ?? caller.name
            guard Clients.same(who, caller.name) || Policy.seesEverything(caller.name) else {
                throw HTTPError(status: 403, code: "not_yours", message: "only Peter (or the person) can see what another app may do")
            }
            var out: [String: Any] = ["ok": true, "client": who,
                                      "stores": storage.allStores.map { ["path": $0.path, "access": access(who, $0.space, $0.name).word] },
                                      "grants": grants.filter { Clients.same($0.client, who) }.map(Self.grantJSON),
                                      "rules": [
                                          "Peter may read and write every space; he's the one who lets other apps in",
                                          "an app may read and write its own space (Super Face: SUPER; any other: OTHER/<its name>)",
                                          "the rest it asks for: POST /api/access/requests; Peter or the person says yes or no",
                                          "a change without the access can wait for approval: send it with \"hold\": true",
                                      ]]
            if Policy.seesEverything(caller.name) {
                out["all_grants"] = grants.map(Self.grantJSON)
                out["open_requests"] = try openRequests()
            }
            return JSON.response(out)
        case ("GET", "check", 1):
            let who = f.text("for") ?? f.text("of") ?? caller.name
            guard let spaceWord = f.text("space"), let space = SpaceID(word: spaceWord) else {
                throw HTTPError(status: 400, code: "bad_request", message: "check takes \"space\" (user, super, peter, pending, other) and \"store\"")
            }
            let store = f.text("store")?.lowercased()
            let a = access(who, space, store)
            let need = f.text("access").flatMap(Access.init(word:)) ?? .read
            return JSON.response(["ok": true, "client": who, "space": space.rawValue, "store": store as Any, "access": a.word, "allowed": a >= need, "need": need.word])
        case ("GET", "grants", 1):
            let list = Policy.seesEverything(caller.name) ? grants : grants.filter { Clients.same($0.client, caller.name) || Policy.mayGrant(caller.name, $0.space, $0.store) }
            return JSON.response(["ok": true, "count": list.count, "grants": list.map(Self.grantJSON)])
        case ("POST", "grants", 1):
            return try await grant(f, caller)
        case ("DELETE", "grants", 2):
            guard let id = Int(rest[1]), let g = grants.first(where: { $0.id == id }) else {
                throw HTTPError(status: 404, code: "not_found", message: "there's no grant \(rest[1]) (GET /api/access/grants lists them)")
            }
            guard Policy.mayGrant(caller.name, g.space, g.store) || Clients.same(g.client, caller.name) else {
                throw HTTPError(status: 403, code: "not_yours", message: "only Peter, the person, \(g.space.folderName)'s owner or \(g.client) itself can take this grant back")
            }
            _ = try removeGrant(id)
            await changed(g.space, g.store, op: "revoked", name: g.client, caller.name)
            return JSON.response(["ok": true, "revoked": Self.grantJSON(g), "message": "Taken back: \(g.client) may no longer \(g.access.word) \(g.store.map { "\(g.space.folderName)/\($0.uppercased())" } ?? g.space.folderName) (unless the rules let it)"])
        case ("GET", "requests", 1):
            Self.prune(requestsStore)
            var list = requestsStore.list().compactMap { $0.value as? [String: Any] }
            if !Policy.seesEverything(caller.name) {
                list = list.filter { r in
                    Clients.same(r["client"] as? String, caller.name)
                        || (SpaceID(rawValue: r["space"] as? String ?? "").map { Policy.mayGrant(caller.name, $0, r["store"] as? String) } ?? false)
                }
            }
            if let state = f.text("state") { list = list.filter { $0["state"] as? String == state } }
            list.sort { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
            return JSON.response(["ok": true, "count": list.count, "requests": list])
        case ("POST", "requests", 1):
            return try await askForAccess(f, caller)
        case (_, "requests", 2):
            guard let id = Int(rest[1]) else { throw HTTPError(status: 404, code: "not_found", message: "a request is known by its number (request 3: /api/access/requests/3)") }
            let r = try requestRecord(id)
            switch method {
            case "GET":
                guard Clients.same(r["client"] as? String, caller.name) || mayDecide(r, caller) else { throw notYours(id) }
                return JSON.response(["ok": true].merging(r) { a, _ in a })
            case "DELETE":
                guard Clients.same(r["client"] as? String, caller.name) || caller.isPerson else {
                    throw HTTPError(status: 403, code: "not_yours", message: "only \(r["client"] as? String ?? "its asker") can take its request back")
                }
                return try await decideRequest(id, r, state: "withdrawn", caller, f)
            default:
                throw HTTPError(status: 405, code: "bad_request", message: "a request takes GET, DELETE (taken back), or POST …/approve, …/deny")
            }
        case ("POST", "requests", 3) where rest[2] == "approve" || rest[2] == "deny":
            guard let id = Int(rest[1]) else { throw HTTPError(status: 404, code: "not_found", message: "a request is known by its number") }
            let r = try requestRecord(id)
            guard mayDecide(r, caller) else {
                throw HTTPError(status: 403, code: "not_yours", message: "Peter or the person says yes or no (or the space's owner, for its own space)")
            }
            return try await decideRequest(id, r, state: rest[2] == "approve" ? "approved" : "denied", caller, f)
        default:
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.method) \(req.path) (GET /api/access says what there is)")
        }
    }

    func notYours(_ id: Int) -> HTTPError {
        HTTPError(status: 404, code: "not_found", message: "there's no request \(id) of yours")
    }

    func requestRecord(_ id: Int) throws -> [String: Any] {
        guard let r = try requestsStore.get("request-\(id)"), let v = r.value as? [String: Any] else {
            throw HTTPError(status: 404, code: "not_found", message: "there's no request \(id) (GET /api/access/requests lists them)")
        }
        return v
    }

    func mayDecide(_ r: [String: Any], _ caller: Caller) -> Bool {
        guard let space = SpaceID(rawValue: r["space"] as? String ?? "") else { return false }
        return Policy.mayGrant(caller.name, space, r["store"] as? String) && !Clients.same(r["client"] as? String, caller.name) || caller.isPerson || Clients.same(caller.name, Clients.peter)
    }

    /// The space, store and access a request names (checked).
    func target(_ f: Fields) throws -> (SpaceID, String?, Access) {
        guard let word = f.text("space"), let space = SpaceID(word: word) else {
            throw HTTPError(status: 400, code: "bad_request", message: "say which space: \"space\": user, super, peter, pending or other")
        }
        var store: String?
        if let s = f.text("store"), !s.isEmpty {
            guard let spec = storage.spec(space, s) else {
                throw HTTPError(status: 404, code: "no_such_store", message: "\(space.folderName) has no store called \(s) (its stores: \(storage.stores(in: space).map(\.name).joined(separator: ", ")))")
            }
            store = spec.name
        }
        if space == .pending { throw HTTPError(status: 403, code: "read_only", message: "PENDING is the system's: what's yours there you see at /api/access/requests and /api/pending") }
        let a = f.text("access").flatMap(Access.init(word:)) ?? .read
        guard a != .none else { throw HTTPError(status: 400, code: "bad_request", message: "\"access\" is read or write") }
        return (space, store, a)
    }

    /// When a grant runs out: `until` (a date), `minutes`, `hours` or `days` from now; nil: never.
    static func until(_ f: Fields, now: Date = Date()) throws -> Date? {
        if let u = f.text("until"), !u.isEmpty {
            guard let d = JSON.parseDate(u) else { throw HTTPError(status: 400, code: "bad_request", message: "\"until\" is a date like 2026-11-03T17:00:00Z") }
            return d
        }
        if let m = f.double("minutes") ?? f.double("for_minutes") { return now.addingTimeInterval(m * 60) }
        if let h = f.double("hours") { return now.addingTimeInterval(h * 3600) }
        if let d = f.double("days") { return now.addingTimeInterval(d * 86400) }
        return nil
    }

    static func grantJSON(_ g: Grant) -> [String: Any] {
        var out: [String: Any] = ["id": g.id, "client": g.client, "space": g.space.rawValue, "access": g.access.word, "by": g.by, "created": JSON.date(g.created), "line": g.line]
        if let s = g.store { out["store"] = s }
        if let w = g.why { out["why"] = w }
        if let u = g.until { out["until"] = JSON.date(u) }
        return out
    }

    /// POST /api/access/grants: Peter, the person or a space's owner says yes, without being asked.
    func grant(_ f: Fields, _ caller: Caller) async throws -> HTTPResponse {
        guard let client = f.text("to") ?? f.text("for") ?? f.text("grantee") else {
            throw HTTPError(status: 400, code: "bad_request", message: "say who may: \"to\": the app's name")
        }
        let (space, store, a) = try target(f)
        guard Policy.mayGrant(caller.name, space, store) else {
            throw HTTPError(status: 403, code: "not_yours", message: "only Peter or the person can let an app into \(space.folderName)\(space.owner.map { " (or \($0), its owner)" } ?? "")")
        }
        let g = try addGrant(Grant(id: 0, client: client, space: space, store: store, access: a, by: caller.name, why: f.text("why"), created: Date(), until: try Self.until(f)))
        await changed(space, store, op: "granted", name: client, caller.name)
        return JSON.response(["ok": true, "grant": Self.grantJSON(g), "message": g.line])
    }

    /// POST /api/access/requests: a client asks to read or write a space it can't.
    func askForAccess(_ f: Fields, _ caller: Caller) async throws -> HTTPResponse {
        let (space, store, a) = try target(f)
        let has = access(caller.name, space, store)
        if has >= a {
            return JSON.response(["ok": true, "state": "already", "access": has.word, "message": "\(caller.name) may \(has.word) that already"])
        }
        // The same request still open: that one, not another.
        if let same = try openRequests().first(where: {
            Clients.same($0["client"] as? String, caller.name) && $0["space"] as? String == space.rawValue && ($0["store"] as? String) == store && $0["access"] as? String == a.word
        }) {
            return JSON.response(["ok": true, "state": "open", "request": same, "message": "Already asked (request \(same["id"] ?? "")): waiting for Peter or the person"], status: 202)
        }
        let store_ = requestsStore
        Self.prune(store_)
        let id = Self.nextNumber(store_, prefix: "request")
        var r: [String: Any] = ["id": id, "client": caller.name, "space": space.rawValue, "access": a.word, "state": "open", "asked": JSON.date(Date()),
                                "url": "/api/access/requests/\(id)"]
        if let store { r["store"] = store }
        if let why = f.text("why") ?? f.text("reason") { r["why"] = String(why.prefix(600)) }
        if let u = try Self.until(f) { r["until"] = JSON.date(u) }
        try store_.put("request-\(id)", r, expect: 0, by: caller.name)
        await changed(.pending, "requests", op: "requested", name: caller.name, caller.name)
        return JSON.response(["ok": true, "state": "open", "request": r,
                              "message": "Asked: Peter or the person says yes or no. GET /api/access/requests/\(id) says how it went (or wait on GET /api/changes?space=pending)"],
                             status: 202)
    }

    func decideRequest(_ id: Int, _ r: [String: Any], state: String, _ caller: Caller, _ f: Fields) async throws -> HTTPResponse {
        guard r["state"] as? String == "open" else {
            return JSON.response(["ok": false, "code": "already_decided", "error": "request \(id) was \(r["state"] ?? "decided") already", "request": r], status: 409)
        }
        var out = r
        out["state"] = state
        out["decided"] = JSON.date(Date())
        out["by"] = caller.name
        if let why = f.text("why") ?? f.text("reason") { out["answer"] = String(why.prefix(600)) }
        if state == "approved", let space = SpaceID(rawValue: r["space"] as? String ?? "") {
            let a = (f.text("access").flatMap(Access.init(word:))).map { min($0, Access(word: r["access"] as? String ?? "read") ?? .read) } ?? Access(word: r["access"] as? String ?? "read") ?? .read
            let until = try Self.until(f) ?? (r["until"] as? String).flatMap(JSON.parseDate)
            let g = try addGrant(Grant(id: 0, client: r["client"] as? String ?? "", space: space, store: r["store"] as? String, access: a,
                                       by: caller.name, why: r["why"] as? String, created: Date(), until: until))
            out["grant"] = Self.grantJSON(g)
            await changed(space, r["store"] as? String, op: "granted", name: g.client, caller.name)
        }
        try requestsStore.put("request-\(id)", out, by: caller.name)
        await changed(.pending, "requests", op: state, name: r["client"] as? String, caller.name)
        return JSON.response(["ok": true, "request": out])
    }

    // MARK: changes held for approval

    /// Keeps a change a client may not make in PENDING/WRITES, until Peter or the person says yes.
    func holdChange(_ spec: StoreSpec, _ op: String, _ req: HTTPRequest, _ fields: [String: Any], _ caller: Caller) throws -> HTTPResponse {
        let store = writesStore
        Self.prune(store)
        let id = Self.nextNumber(store, prefix: "write")
        // What it was, to do as it was asked once it's approved (without "hold", which would only hold it again).
        var query = req.query
        query["hold"] = nil
        let target = req.path + (query.isEmpty ? "" : "?" + query.map { "\(Self.escape($0.key))=\(Self.escape($0.value))" }.sorted().joined(separator: "&"))
        var body = req.body
        // A record's PUT or PATCH body is its value, kept as it is.
        let bodyIsValue = spec.kind == .records && (op == "put" || op == "patch") && req.method != "POST"
        if !bodyIsValue, var o = JSON.object(req.body), o["hold"] != nil {
            o["hold"] = nil
            body = JSON.data(o)
        }
        var w: [String: Any] = ["id": id, "client": caller.name, "space": spec.space.rawValue, "store": spec.name, "op": op, "state": "waiting",
                                "method": req.method, "target": target, "content_type": req.header("content-type") ?? "", "asked": JSON.date(Date()),
                                "url": "/api/pending/\(id)", "what": Self.describe(op, fields, spec)]
        if let text = String(data: body, encoding: .utf8) { w["body"] = text } else { w["body_base64"] = body.base64EncodedString() }
        if let why = Fields.text(fields["why"]) ?? Fields.text(fields["reason"]) { w["why"] = String(why.prefix(600)) }
        try store.put("write-\(id)", w, expect: 0, by: caller.name)
        Task { await self.changed(.pending, "writes", op: "held", name: caller.name, caller.name) }
        var shown = w
        shown["body"] = nil
        shown["body_base64"] = nil
        return JSON.response(["ok": true, "held": true, "state": "waiting", "pending": shown,
                              "message": "Held in PENDING (write \(id)): it's done once Peter or the person approves it. GET /api/pending/\(id) says how it went"],
                             status: 202)
    }

    static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?"))) ?? s
    }

    /// A held change, in words: "write the note groceries in USER/LIBRARY".
    static func describe(_ op: String, _ fields: [String: Any], _ spec: StoreSpec) -> String {
        let name = Fields.text(fields["name"]) ?? Fields.text(fields["key"]) ?? Fields.text(fields["about"])
        return "\(op.replacingOccurrences(of: "_", with: " "))\(name.map { " \($0)" } ?? "") in \(spec.space.folderName)/\(spec.folderName)"
    }

    func pendingRoute(_ req: HTTPRequest, _ rest: [String], _ method: String, _ fields: [String: Any], _ caller: Caller) async throws -> HTTPResponse {
        let f = Fields(values: fields)
        func visible(_ w: [String: Any]) -> Bool {
            Policy.seesEverything(caller.name) || Clients.same(w["client"] as? String, caller.name)
                || (SpaceID(rawValue: w["space"] as? String ?? "").map { Policy.mayGrant(caller.name, $0, w["store"] as? String) } ?? false)
        }
        func shown(_ w: [String: Any]) -> [String: Any] {
            var s = w
            if !Policy.seesEverything(caller.name), !Clients.same(w["client"] as? String, caller.name) { s["body"] = nil; s["body_base64"] = nil }
            return s
        }
        switch (method, rest.first, rest.count) {
        case ("GET", nil, _):
            Self.prune(writesStore)
            var list = heldWrites().compactMap { $0.value as? [String: Any] }.filter(visible)
            if let state = f.text("state") { list = list.filter { $0["state"] as? String == state } }
            var out: [String: Any] = ["ok": true, "count": list.count, "writes": list.map(shown)]
            if Policy.seesEverything(caller.name) { out["requests"] = try openRequests() }
            return JSON.response(out)
        case (_, let first?, _):
            guard let id = Int(first), let r = try writesStore.get("write-\(id)"), let w = r.value as? [String: Any], visible(w) else {
                throw HTTPError(status: 404, code: "not_found", message: "there's no held change \(first) (GET /api/pending lists them)")
            }
            switch (method, rest.count > 1 ? rest[1] : nil) {
            case ("GET", nil):
                return JSON.response(["ok": true].merging(shown(w)) { a, _ in a })
            case ("DELETE", nil):
                guard Clients.same(w["client"] as? String, caller.name) || caller.isPerson else {
                    throw HTTPError(status: 403, code: "not_yours", message: "only \(w["client"] as? String ?? "its asker") can take it back")
                }
                return try await decideHeld(id, w, approve: false, state: "withdrawn", caller, f)
            case ("POST", "approve"?), ("POST", "deny"?):
                let space = SpaceID(rawValue: w["space"] as? String ?? "") ?? .user
                guard Policy.mayGrant(caller.name, space, w["store"] as? String), !Clients.same(w["client"] as? String, caller.name) || caller.isPerson else {
                    throw HTTPError(status: 403, code: "not_yours", message: "Peter or the person approves it (or \(space.folderName)'s owner)")
                }
                let approve = rest[1] == "approve"
                return try await decideHeld(id, w, approve: approve, state: approve ? "applied" : "denied", caller, f)
            default:
                throw HTTPError(status: 405, code: "bad_request", message: "a held change takes GET, DELETE (taken back), POST …/approve or …/deny")
            }
        default:
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.method) \(req.path)")
        }
    }

    func decideHeld(_ id: Int, _ w: [String: Any], approve: Bool, state: String, _ caller: Caller, _ f: Fields) async throws -> HTTPResponse {
        guard w["state"] as? String == "waiting" else {
            return JSON.response(["ok": false, "code": "already_decided", "error": "held change \(id) was \(w["state"] ?? "decided") already", "pending": w], status: 409)
        }
        var out = w
        out["decided"] = JSON.date(Date())
        out["by"] = caller.name
        if let why = f.text("why") ?? f.text("reason") { out["answer"] = String(why.prefix(600)) }
        out["state"] = state
        if approve {
            // Done as it was asked, by its asker, with this store let in for this once.
            let body = (w["body"] as? String).map { Data($0.utf8) } ?? (w["body_base64"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            var headers = ["X-Client": w["client"] as? String ?? ""]
            if let ct = w["content_type"] as? String, !ct.isEmpty { headers["Content-Type"] = ct }
            let req = HTTPRequest(method: w["method"] as? String ?? "POST", target: w["target"] as? String ?? "/", headers: headers, body: body)
            let space = SpaceID(rawValue: w["space"] as? String ?? "") ?? .user
            let asker = Caller(name: w["client"] as? String ?? "", isPerson: false)
            let r: HTTPResponse
            do {
                r = try await handle(req, as: asker, approved: (space, w["store"] as? String ?? ""))
            } catch {
                let m = Self.mistake(error)
                r = JSON.response(["ok": false, "code": m.code, "error": m.message], status: m.status)
            }
            let json = r.bodyData.flatMap(JSON.object) ?? [:]
            out["result"] = ["status": r.status, "ok": r.status < 400, "answer": json] as [String: Any]
            if r.status >= 400 { out["state"] = "failed" }
        }
        try writesStore.put("write-\(id)", out, by: caller.name)
        await changed(.pending, "writes", op: out["state"] as? String ?? state, name: w["client"] as? String, caller.name)
        return JSON.response(["ok": true, "pending": out])
    }

    // MARK: clients

    func clientsRoute(_ req: HTTPRequest, _ rest: [String], _ method: String, _ fields: [String: Any], _ known: Caller?) async throws -> HTTPResponse {
        let f = Fields(values: fields)
        switch (method, rest.first, rest.count) {
        case ("GET", nil, _):
            let caller = try known ?? self.caller(req, fields)
            var names = Set(keys.map(\.client))
            for g in grants { names.insert(g.client) }
            for e in await log.recent(500) where e.client != Clients.person { names.insert(e.client) }
            let list = names.sorted().map { n -> [String: Any] in
                ["client": n, "has_key": book.key(for: n) != nil, "grants": grants.filter { Clients.same($0.client, n) }.count,
                 "own_space": SpaceID.allCases.first { Clients.same($0.owner, n) }?.rawValue ?? "other/\(Clients.slug(n) ?? "")"]
            }
            return JSON.response(["ok": true, "you": caller.name, "clients": list])
        case ("POST", "register", 1):
            guard let name = Self.clientName(req, fields) else {
                throw HTTPError(status: 400, code: "who_are_you", message: "register takes \"client\": the name your app goes by")
            }
            if Clients.same(name, Clients.person) || Clients.same(name, Clients.storage) {
                throw HTTPError(status: 403, code: "reserved_name", message: "\(name) is Storage Spaces' own name: use your app's")
            }
            if book.key(for: name) != nil {
                // Only with the key it has: a new one (the old one stops working).
                guard book.keyMatches(name, Self.key(req)) else {
                    throw HTTPError(status: 409, code: "name_taken", message: "\(name) has a key already. Send it (X-Storage-Key) to get a new one; lost it? The person can forget it in the Storage Spaces window")
                }
            }
            let key = AccessBook.newKey()
            try setKey(name, hash: SHA256.hex(Data(key.utf8)))
            return JSON.response(["ok": true, "client": name, "key": key,
                                  "message": "From now on, send this with every request as \(name): X-Storage-Key: <key> (or Authorization: Bearer <key>). Keep it: it isn't shown again"])
        case ("POST", "forget", 1):
            guard known?.isPerson == true else { throw HTTPError(status: 403, code: "not_yours", message: "only the person forgets an app's key, in the Storage Spaces window") }
            guard let name = f.text("name") ?? f.text("of") else { throw HTTPError(status: 400, code: "bad_request", message: "say whose key: \"name\"") }
            try setKey(name, hash: nil)
            return JSON.response(["ok": true, "client": name, "message": "\(name)'s key is forgotten: it can register again"])
        default:
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.method) \(req.path) (GET /api/clients, POST /api/clients/register)")
        }
    }
}
