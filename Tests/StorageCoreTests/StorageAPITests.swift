import Foundation
@testable import StorageCore
import XCTest

/// The spaces over HTTP: each comes ready; who may read and write what; asking, saying yes,
/// holding a change for approval; records and their versions; keys; bringing in Tool Mac Tool
/// Run's things; resetting a space; and the changes, as they happen.
final class StorageAPITests: XCTestCase {
    var home: URL!
    var storage: Storage!
    var api: StorageAPI!

    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-\(UUID().uuidString)", isDirectory: true)
        storage = Storage(root: home.appendingPathComponent("STORAGE-SPACES"))
        api = StorageAPI(storage: storage, version: "0.1.0", docs: [Self.repo, Self.repo.appendingPathComponent("docs")])
        try await api.start()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// A request as `client` (nil: none said), its status and JSON.
    @discardableResult
    func send(_ method: String, _ path: String, _ body: Any? = nil, as client: String? = "Peter", key: String? = nil,
              headers: [String: String] = [:], text: String? = nil) async -> (Int, [String: Any], HTTPResponse) {
        var h = headers
        if let client { h["X-Client"] = client }
        if let key { h["X-Storage-Key"] = key }
        var data = Data()
        if let text {
            data = Data(text.utf8)
            h["Content-Type"] = h["Content-Type"] ?? "text/plain"
        } else if let body {
            data = (try? JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])) ?? Data()
            h["Content-Type"] = "application/json"
        }
        let r = await api.route(HTTPRequest(method: method, target: path, headers: h, body: data))
        return (r.status, r.bodyData.flatMap(JSON.object) ?? [:], r)
    }

    func testEverySpaceComesReady() async throws {
        let fm = FileManager.default
        for p in ["USER/LIBRARY", "USER/MEMORY/PEOPLE.md", "USER/MIND/mind.txt", "SUPER/PROMPT/instructions.md", "SUPER/MEMORY/playbook.md",
                  "PETER/SCHEDULE", "PETER/STATUS", "PETER/FOLLOWING", "PETER/SETTINGS", "PENDING/REQUESTS", "PENDING/WRITES", "OTHER", "README.md", ".storage/access.json"] {
            XCTAssertTrue(fm.fileExists(atPath: storage.root.appendingPathComponent(p).path), p)
        }
        let (s, health, _) = await send("GET", "/api/health", as: nil)
        XCTAssertEqual(s, 200)
        XCTAssertEqual((health["counts"] as? [String: Any])?["user/memory"] as? Int, 9)
        let (_, spaces, _) = await send("GET", "/api/spaces")
        XCTAssertEqual((spaces["spaces"] as? [[String: Any]])?.map { $0["space"] as? String }, ["user", "super", "peter", "pending", "other"])
        // The same again changes nothing.
        try await api.start()
        let (_, prompt, _) = await send("GET", "/api/spaces/super/prompt/files/instructions", as: "Super Face")
        XCTAssertEqual(prompt["text"] as? String, SuperFace.instructionsHead)
        let (d, _, doc) = await send("GET", "/api/doc", as: nil)
        XCTAssertEqual(d, 200)
        XCTAssertTrue(String(decoding: doc.bodyData ?? Data(), as: UTF8.self).contains("Storage Spaces"))
        let (n, _, notation) = await send("GET", "/api/docs/MIND-NOTATION", as: nil)
        XCTAssertEqual(n, 200)
        XCTAssertTrue(String(decoding: notation.bodyData ?? Data(), as: UTF8.self).contains("|"))
    }

    func testToolMacsRoutesStillWorkForThePersonsThreeStores() async throws {
        // Tool Mac Tool Run comes with a yes for your space, as it had it.
        let tm = Clients.toolMac
        var (s, j, r) = await send("PUT", "/api/library/files/groceries", ["text": "# Groceries\n\n- eggs\n"], as: tm)
        XCTAssertEqual(s, 200, "\(j)")
        XCTAssertEqual(j["action"] as? String, "created")
        XCTAssertNotNil(r.header("X-Request-Id"))
        (s, j, _) = await send("GET", "/api/spaces/user/library/files/groceries", as: "Peter")
        XCTAssertEqual(j["text"] as? String, "# Groceries\n\n- eggs\n")
        (s, j, _) = await send("POST", "/api/memory/remember", ["category": "PEOPLE", "about": "Ada Lovelace", "text": "met at the conference", "links": [["label": "works at", "to": "Acme", "category": "ORGANIZATIONS"]]], as: tm)
        XCTAssertEqual(s, 200, "\(j)")
        XCTAssertEqual(j["node"] as? String, "ada lovelace")
        (s, j, _) = await send("GET", "/api/memory/recall?name=ada", as: tm)
        XCTAssertEqual(j["found"] as? Bool, true)
        XCTAssertEqual(j["categories"] as? [String], ["PEOPLE"])
        (s, j, _) = await send("GET", "/api/mind/nodes/ada lovelace", as: tm)
        XCTAssertEqual(s, 200, "\(j)")
        (s, j, _) = await send("POST", "/api/mind/add", ["from": "sam", "label": "writes", "to": "paper"], as: tm)
        XCTAssertEqual(j["added"] as? [String], ["| sam - writes | paper"])
        // Not yours: Peter's.
        (s, j, _) = await send("GET", "/api/spaces/peter/schedule", as: tm)
        XCTAssertEqual(s, 403)
        XCTAssertEqual(j["code"] as? String, "no_access")
        // The changes say what happened, in order.
        let (_, c, _) = await send("GET", "/api/changes?after=0")
        let paths = (c["changes"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
        XCTAssertEqual(paths.first, "user/library")
        XCTAssertTrue(paths.contains("user/memory") && paths.contains("user/mind"), "\(paths)")
    }

    func testAnAppAsksPeterSaysYesAndTakesItBack() async throws {
        let app = "Super Voice"
        var (s, j, _) = await send("GET", "/api/spaces/user/memory/files/PEOPLE", as: app)
        XCTAssertEqual(s, 403)
        XCTAssertEqual(j["code"] as? String, "no_access")
        XCTAssertNotNil(j["ask"])
        (s, j, _) = await send("POST", "/api/access/requests", ["space": "user", "store": "memory", "access": "read", "why": "to greet people by name"], as: app)
        XCTAssertEqual(s, 202)
        let id = try XCTUnwrap((j["request"] as? [String: Any])?["id"] as? Int)
        // Asking again is the same request.
        (s, j, _) = await send("POST", "/api/access/requests", ["space": "user", "store": "memory", "access": "read"], as: app)
        XCTAssertEqual((j["request"] as? [String: Any])?["id"] as? Int, id)
        // Only Peter (or the person) says yes.
        (s, j, _) = await send("POST", "/api/access/requests/\(id)/approve", as: app)
        XCTAssertEqual(s, 403)
        (s, j, _) = await send("GET", "/api/access/requests?state=open")
        XCTAssertEqual(j["count"] as? Int, 1)
        (s, j, _) = await send("POST", "/api/access/requests/\(id)/approve", ["hours": 2])
        XCTAssertEqual(s, 200, "\(j)")
        let grant = try XCTUnwrap(((j["request"] as? [String: Any])?["grant"] as? [String: Any])?["id"] as? Int)
        (s, j, _) = await send("GET", "/api/spaces/user/memory/files/PEOPLE", as: app)
        XCTAssertEqual(s, 200)
        // A read is a read: not a write.
        (s, j, _) = await send("PUT", "/api/spaces/user/memory/files/PEOPLE", ["text": "mine"], as: app)
        XCTAssertEqual(s, 403)
        XCTAssertEqual(j["has"] as? String, "read")
        (s, j, _) = await send("GET", "/api/access/check?space=user&store=memory&for=Super%20Voice")
        XCTAssertEqual(j["access"] as? String, "read")
        // Its own request says how it went.
        (s, j, _) = await send("GET", "/api/access/requests/\(id)", as: app)
        XCTAssertEqual(j["state"] as? String, "approved")
        (s, j, _) = await send("DELETE", "/api/access/grants/\(grant)")
        XCTAssertEqual(s, 200)
        (s, j, _) = await send("GET", "/api/spaces/user/memory/files/PEOPLE", as: app)
        XCTAssertEqual(s, 403)
        // Peter saw it all as it happened.
        let (_, c, _) = await send("GET", "/api/changes?after=0&space=pending")
        XCTAssertEqual((c["changes"] as? [[String: Any]])?.compactMap { $0["op"] as? String }, ["requested", "approved"])
    }

    func testEachAppHasItsOwnSpace() async throws {
        var (s, j, _) = await send("POST", "/api/spaces/super/memory/files/playbook/append", ["text": "- the weather: weather.py with the city"], as: "Super Face")
        XCTAssertEqual(s, 200, "\(j)")
        (s, j, _) = await send("PUT", "/api/spaces/peter/status/records/now", ["doing": "nothing"], as: "Super Face")
        XCTAssertEqual(s, 403)
        (s, j, _) = await send("GET", "/api/spaces/super/memory/files/playbook", as: "Super Voice")
        XCTAssertEqual(s, 403)
        // OTHER: an app's own folder, made the first time it writes.
        (s, j, _) = await send("PUT", "/api/spaces/other/super-voice/files/notes", ["text": "hello"], as: "Super Voice")
        XCTAssertEqual(s, 200, "\(j)")
        (s, j, _) = await send("GET", "/api/spaces/other")
        XCTAssertEqual((j["stores"] as? [[String: Any]])?.compactMap { $0["store"] as? String }, ["super-voice"])
        (s, j, _) = await send("GET", "/api/spaces/other/super-voice/files/notes", as: "Super Face")
        XCTAssertEqual(s, 403)
        // Super Face lets Super Voice read its playbook (its own space, its own say).
        (s, j, _) = await send("POST", "/api/access/grants", ["to": "Super Voice", "space": "super", "store": "memory", "access": "read"], as: "Super Face")
        XCTAssertEqual(s, 200, "\(j)")
        (s, j, _) = await send("GET", "/api/spaces/super/memory/files/playbook", as: "Super Voice")
        XCTAssertEqual(s, 200)
        // …but not into someone else's.
        (s, j, _) = await send("POST", "/api/access/grants", ["to": "Super Voice", "space": "user", "access": "write"], as: "Super Face")
        XCTAssertEqual(s, 403)
    }

    func testAChangeHeldUntilItsApproved() async throws {
        let app = "Super Voice"
        var (s, j, _) = await send("POST", "/api/library", ["op": "write", "name": "shopping", "text": "- milk", "hold": true, "why": "you asked me to keep a list"], as: app)
        XCTAssertEqual(s, 202, "\(j)")
        XCTAssertEqual(j["held"] as? Bool, true)
        let id = try XCTUnwrap((j["pending"] as? [String: Any])?["id"] as? Int)
        XCTAssertFalse(storage.notes(storage.spec(.user, "library")!).exists("shopping"))
        (s, j, _) = await send("GET", "/api/pending/\(id)", as: app)
        XCTAssertEqual(j["state"] as? String, "waiting")
        XCTAssertEqual(j["what"] as? String, "write shopping in USER/LIBRARY")
        (s, j, _) = await send("GET", "/api/pending/\(id)", as: "Somebody Else")
        XCTAssertEqual(s, 404)
        (s, j, _) = await send("POST", "/api/pending/\(id)/approve", as: app)
        XCTAssertEqual(s, 403, "an app doesn't approve its own")
        (s, j, _) = await send("POST", "/api/pending/\(id)/approve")
        XCTAssertEqual(s, 200, "\(j)")
        XCTAssertEqual((j["pending"] as? [String: Any])?["state"] as? String, "applied")
        XCTAssertEqual(try storage.notes(storage.spec(.user, "library")!).read("shopping").text, "- milk")
        // Only once.
        (s, j, _) = await send("POST", "/api/pending/\(id)/approve")
        XCTAssertEqual(s, 409)
        // A PUT held, then turned down: nothing written.
        (s, j, _) = await send("PUT", "/api/spaces/user/library/files/secret?hold=true", ["text": "x"], as: app)
        XCTAssertEqual(s, 202)
        let id2 = try XCTUnwrap((j["pending"] as? [String: Any])?["id"] as? Int)
        (s, j, _) = await send("POST", "/api/pending/\(id2)/deny", ["why": "not now"])
        XCTAssertEqual((j["pending"] as? [String: Any])?["state"] as? String, "denied")
        XCTAssertFalse(storage.notes(storage.spec(.user, "library")!).exists("secret"))
        // The person sees them in the window, and does the same.
        (s, j, _) = await send("PUT", "/api/spaces/user/library/files/third", ["text": "3", "hold": true], as: app)
        let id3 = try XCTUnwrap((j["pending"] as? [String: Any])?["id"] as? Int)
        let mine = await api.asPerson("GET", "/api/pending?state=waiting")
        XCTAssertEqual((mine.json["writes"] as? [[String: Any]])?.count, 1)
        let done = await api.asPerson("POST", "/api/pending/\(id3)/approve")
        XCTAssertEqual(done.status, 200, "\(done.json)")
        XCTAssertEqual(try storage.notes(storage.spec(.user, "library")!).read("third").text, "3")
    }

    func testRecordsAndTheirVersions() async throws {
        let base = "/api/spaces/peter/schedule/records"
        var (s, j, r) = await send("PUT", "\(base)/item-1", ["text": "stand up", "due": "2026-11-03T09:00:00Z"])
        XCTAssertEqual(s, 200, "\(j)")
        XCTAssertEqual(j["version"] as? Int, 1)
        (s, j, r) = await send("GET", "\(base)/item-1")
        XCTAssertEqual(r.header("ETag"), "\"1\"")
        XCTAssertEqual((j["value"] as? [String: Any])?["text"] as? String, "stand up")
        XCTAssertEqual(j["by"] as? String, "Peter")
        // Written by someone else since it was read: turned down.
        (s, j, _) = await send("PUT", "\(base)/item-1", ["text": "sit down"], headers: ["If-Match": "\"1\""])
        XCTAssertEqual(j["version"] as? Int, 2)
        (s, j, _) = await send("PUT", "\(base)/item-1?expect=1", ["text": "lie down"])
        XCTAssertEqual(s, 409)
        XCTAssertEqual(j["code"] as? String, "version_conflict")
        XCTAssertEqual(j["version"] as? Int, 2)
        // Only if it's new.
        (s, j, _) = await send("POST", "/api/spaces/peter/schedule", ["op": "put", "key": "item-1", "value": 1, "expect": 0])
        XCTAssertEqual(s, 409)
        (s, j, _) = await send("PATCH", "\(base)/item-1", ["done": true, "text": NSNull()])
        XCTAssertEqual(j["value"] as? [String: Any] as NSDictionary?, ["done": true] as NSDictionary)
        // A list that keeps the latest.
        for n in 1...5 { await send("POST", "/api/spaces/peter/status/records/log/append", ["item": "line \(n)", "keep": 3]) }
        (s, j, _) = await send("GET", "/api/spaces/peter/status/records/log")
        XCTAssertEqual(j["value"] as? [String], ["line 3", "line 4", "line 5"])
        // Any JSON, and text.
        (s, j, _) = await send("PUT", "/api/spaces/peter/settings/records/model", text: "qwen3:8b")
        (s, j, _) = await send("GET", "/api/spaces/peter/settings/records/model")
        XCTAssertEqual(j["value"] as? String, "qwen3:8b")
        (s, j, _) = await send("GET", "/api/spaces/peter/schedule/keys")
        XCTAssertEqual(j["keys"] as? [String], ["item-1"])
        (s, j, _) = await send("DELETE", "\(base)/item-1")
        XCTAssertEqual(j["deleted"] as? Bool, true)
        (s, j, _) = await send("GET", "\(base)/item-1")
        XCTAssertEqual(s, 404)
        // A value is kept as it is, whatever its fields are called.
        (s, j, _) = await send("PUT", "\(base)/odd", ["expect": 7, "hold": true, "key": "other"])
        XCTAssertEqual(s, 200, "\(j)")
        (s, j, _) = await send("GET", "\(base)/odd")
        XCTAssertEqual(j["value"] as? NSDictionary, ["expect": 7, "hold": true, "key": "other"] as NSDictionary)
        await send("DELETE", "\(base)/odd")
        (s, j, _) = await send("PUT", "\(base)/..secret", ["x": 1])
        XCTAssertEqual(s, 400)
        // On disk, readable as it is.
        let file = storage.root.appendingPathComponent("PETER/STATUS/log.json")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("\"version\" : 5"))
        // PENDING changes only as requests are decided.
        (s, j, _) = await send("PUT", "/api/spaces/pending/requests/records/request-9", ["state": "approved"])
        XCTAssertEqual(s, 403)
    }

    func testANameClaimedWithAKey() async throws {
        var (s, j, _) = await send("POST", "/api/clients/register")
        XCTAssertEqual(s, 200, "\(j)")
        let key = try XCTUnwrap(j["key"] as? String)
        (s, j, _) = await send("GET", "/api/spaces/peter/schedule")
        XCTAssertEqual(s, 401)
        XCTAssertEqual(j["code"] as? String, "bad_key")
        (s, j, _) = await send("GET", "/api/spaces/peter/schedule", key: "wrong")
        XCTAssertEqual(s, 401)
        (s, j, _) = await send("GET", "/api/spaces/peter/schedule", key: key)
        XCTAssertEqual(s, 200)
        (s, j, _) = await send("GET", "/api/spaces/peter/schedule", headers: ["Authorization": "Bearer \(key)"])
        XCTAssertEqual(s, 200)
        // Someone else can't take the name.
        (s, j, _) = await send("POST", "/api/clients/register")
        XCTAssertEqual(s, 409)
        XCTAssertFalse(String(data: try Data(contentsOf: storage.system.appendingPathComponent("access.json")), encoding: .utf8)!.contains(key), "only its hash is kept")
        // The person forgets it: it can register again.
        let forgot = await api.asPerson("POST", "/api/clients/forget", ["name": "Peter"])
        XCTAssertEqual(forgot.status, 200)
        (s, j, _) = await send("GET", "/api/spaces/peter/schedule")
        XCTAssertEqual(s, 200)
        // Names that aren't an app's.
        (s, j, _) = await send("GET", "/api/spaces", as: "you")
        XCTAssertEqual(s, 403)
        (s, j, _) = await send("GET", "/api/spaces", as: nil)
        XCTAssertEqual(s, 401)
        XCTAssertEqual(j["code"] as? String, "who_are_you")
        let far = await api.route(HTTPRequest(method: "GET", target: "/api/health", fromLoopback: false))
        XCTAssertEqual(far.status, 403)
    }

    func testBringingInToolMacsAndPetersThings() async throws {
        let tmr = home.appendingPathComponent("TOOL-MAC-RUN"), peter = home.appendingPathComponent("Peter")
        let theirLib = FileLibrary(root: tmr.appendingPathComponent("LIBRARY"))
        try theirLib.write("groceries", "- eggs\n")
        try theirLib.write("Super Face instructions", SuperFace.instructionsHead + "- call me Sam\n")
        try theirLib.write("Super Face playbook", SuperFace.playbookHead + "- the weather: weather.py\n")
        let theirMemory = Memory(files: FileLibrary(root: tmr.appendingPathComponent("MEMORY"), shelf: .memory), mind: MindStore(root: tmr.appendingPathComponent("MIND")))
        try theirMemory.ensure()
        try theirMemory.remember(category: "PEOPLE", about: "Ada", text: "met at the conference")
        try FileManager.default.createDirectory(at: peter, withIntermediateDirectories: true)
        try Data(#"{"next": 2, "items": [{"id": 1, "text": "stand up"}]}"#.utf8).write(to: peter.appendingPathComponent("schedule.json"))
        // A note of the same name, already here and different: theirs comes in beside it.
        try storage.notes(storage.spec(.user, "library")!).write("groceries", "- milk\n")

        await api.setImportSources(toolMac: tmr, peter: peter)
        var (s, j, _) = await send("GET", "/api/import", as: "Super Voice")
        XCTAssertEqual(j["available"] as? Bool, true)
        (s, j, _) = await send("POST", "/api/import", as: "Super Voice")
        XCTAssertEqual(s, 403)
        (s, j, _) = await send("POST", "/api/import")
        XCTAssertEqual(s, 200, "\(j)")
        let copied = j["copied"] as? [String] ?? []
        XCTAssertTrue(copied.contains("SUPER/PROMPT/instructions"), "\(copied)")
        XCTAssertTrue(copied.contains("PETER/SCHEDULE/schedule"), "\(copied)")
        let lib = storage.notes(storage.spec(.user, "library")!)
        XCTAssertEqual(try lib.read("groceries").text, "- milk\n")
        XCTAssertEqual(try lib.read("groceries (from Tool Mac Tool Run)").text, "- eggs\n")
        XCTAssertTrue(lib.exists("Super Face instructions"), "Super Face's stay in the library too, while it reads them there")
        XCTAssertTrue(try storage.notes(storage.spec(.super, "prompt")!).read("instructions").text.contains("call me Sam"))
        XCTAssertTrue(try storage.notes(storage.spec(.super, "memory")!).read("playbook").text.contains("weather.py"))
        XCTAssertTrue(try storage.userMemory.files.read("PEOPLE").text.contains("Ada: met at the conference"))
        XCTAssertFalse(storage.userMemory.recall("Ada").nodes.isEmpty, "the mind came too")
        let schedule = try XCTUnwrap(try storage.records(storage.spec(.peter, "schedule")!).get("schedule"))
        XCTAssertEqual((schedule.value as? [String: Any])?["next"] as? Int, 2)
        XCTAssertTrue(ToolMacImport.done(in: storage))
        // Again: nothing new.
        (s, j, _) = await send("POST", "/api/import")
        XCTAssertEqual(j["copied"] as? [String], [])
        XCTAssertTrue(TMRStillThere(tmr), "the originals stay as they were")
    }

    func TMRStillThere(_ tmr: URL) -> Bool {
        FileManager.default.fileExists(atPath: tmr.appendingPathComponent("LIBRARY/groceries.md").path)
    }

    func testResettingASpace() async throws {
        await send("POST", "/api/spaces/super/memory/files/playbook/append", ["text": "- learned"], as: "Super Face")
        var (s, j, _) = await send("POST", "/api/spaces/super/reset", as: "Super Voice")
        XCTAssertEqual(s, 403)
        (s, j, _) = await send("POST", "/api/spaces/super/reset", as: "Super Face")
        XCTAssertEqual(s, 200, "\(j)")
        XCTAssertEqual(try storage.notes(storage.spec(.super, "memory")!).read("playbook").text, SuperFace.playbookHead)
        XCTAssertEqual((j["trashed"] as? [String])?.count, 2)
        // Yours is yours alone to reset.
        (s, j, _) = await send("POST", "/api/spaces/user/reset")
        XCTAssertEqual(s, 403)
        try storage.notes(storage.spec(.user, "library")!).write("keep", "x")
        let r = await api.asPerson("POST", "/api/spaces/user/reset")
        XCTAssertEqual(r.status, 200, "\(r.json)")
        XCTAssertFalse(storage.notes(storage.spec(.user, "library")!).exists("keep"))
        XCTAssertTrue(storage.userMemory.files.exists("PEOPLE"), "MEMORY comes with its files again")
    }

    func testWaitingForAChange() async throws {
        let api = self.api!
        let started = Date()
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            _ = await api.route(HTTPRequest(method: "PUT", target: "/api/spaces/peter/status/records/now", headers: ["X-Client": "Peter", "Content-Type": "application/json"],
                                            body: Data(#"{"doing": "the weather"}"#.utf8)))
        }
        let (s, j, _) = await send("GET", "/api/changes?after=0&wait=5&space=peter", as: "Super Face")
        XCTAssertEqual(s, 200)
        XCTAssertEqual(j["count"] as? Int, 0, "Super Face may not read Peter's status, so it isn't told about it")
        let (_, mine, _) = await send("GET", "/api/changes?after=0&wait=5")
        XCTAssertEqual((mine["changes"] as? [[String: Any]])?.first?["name"] as? String, "now")
        XCTAssertLessThan(Date().timeIntervalSince(started), 9)
    }

    func testEditsOnDiskAreChangesToo() async throws {
        let api = self.api!
        _ = await api.checkDisk()
        var n = await api.checkDisk()
        XCTAssertEqual(n, 0, "the first look only learns what's there")
        // Through the API: told once, not again by the watch.
        await send("PUT", "/api/library/files/groceries", ["text": "- eggs"])
        n = await api.checkDisk()
        XCTAssertEqual(n, 0)
        // As Tool Mac Tool Run's boards (or the person) do: the files themselves.
        try "- milk".write(to: storage.root.appendingPathComponent("USER/LIBRARY/groceries.md"), atomically: true, encoding: .utf8)
        try "# new".write(to: storage.root.appendingPathComponent("SUPER/PROMPT/tone.md"), atomically: true, encoding: .utf8)
        n = await api.checkDisk()
        XCTAssertEqual(n, 2)
        let (_, j, _) = await send("GET", "/api/changes?after=1")
        let seen = (j["changes"] as? [[String: Any]] ?? []).map { "\($0["path"] ?? "") \($0["op"] ?? "") \($0["name"] ?? "") \($0["client"] ?? "")" }
        XCTAssertEqual(Set(seen), ["user/library edited groceries on disk", "super/prompt added tone on disk"])
    }

    func testTheSmallThings() throws {
        XCTAssertEqual(SHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(Data(String(repeating: "a", count: 1000).utf8)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
        XCTAssertEqual(Clients.slug("Super Voice"), "super-voice")
        XCTAssertEqual(Clients.slug("  Café  Bot 2! "), "cafe-bot-2")
        XCTAssertNil(Clients.slug("!!"))
        XCTAssertEqual(Access(word: "read/write"), .write)
        XCTAssertEqual(SpaceID(word: "Super Face"), .super)
        let user = URL(fileURLWithPath: "/Users/sam")
        XCTAssertTrue(FactoryReset.mayRemove(URL(fileURLWithPath: "/Users/sam/Desktop/STORAGE-SPACES"), user: user))
        XCTAssertFalse(FactoryReset.mayRemove(URL(fileURLWithPath: "/Users/sam/Desktop"), user: user))
        XCTAssertFalse(FactoryReset.mayRemove(user, user: user))
        let g = Grant(id: 1, client: "A", space: .user, store: "memory", access: .read, by: "Peter", why: nil, created: Date(), until: Date().addingTimeInterval(-1))
        XCTAssertEqual(Policy.access("A", .user, "memory", grants: [g]), .none, "a grant that has run out")
    }
}
