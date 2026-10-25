import Foundation

/// What changed, as it happens: each change numbered, the latest thousand kept while the app
/// runs. An app that wants to know (Peter, about a request for access; Super Face, about its
/// prompt) asks for the changes after the last number it saw, and waits for one if there's none
/// yet (`GET /api/changes?after=41&wait=25`).
public actor Changes {
    public struct Change: Sendable, Equatable {
        public let seq: Int
        public let space: SpaceID
        /// The store (nil: the whole space, or the access rules).
        public let store: String?
        /// What was done (write, append, delete, put, add, granted, requested…).
        public let op: String
        /// The note, record or node it was done to.
        public let name: String?
        public let client: String
        public let at: Date

        public var json: [String: Any] {
            var out: [String: Any] = ["seq": seq, "space": space.rawValue, "op": op, "client": client, "at": JSON.date(at)]
            if let store { out["store"] = store; out["path"] = "\(space.rawValue)/\(store)" }
            if let name { out["name"] = name }
            return out
        }
    }

    public let capacity: Int
    public private(set) var seq = 0
    private var recent: [Change] = []
    private var observers: [@Sendable (Change) -> Void] = []

    public init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    public func add(_ space: SpaceID, _ store: String?, op: String, name: String?, client: String) {
        seq += 1
        let c = Change(seq: seq, space: space, store: store, op: op, name: name, client: client, at: Date())
        recent.append(c)
        if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
        for o in observers { o(c) }
    }

    /// Called with every change from now on (the app's window).
    public func observe(_ f: @escaping @Sendable (Change) -> Void) {
        observers.append(f)
    }

    /// The changes after `after` (in `space`, or one store of it, when given), the oldest first.
    public func since(_ after: Int, space: SpaceID? = nil, store: String? = nil, limit: Int = 200) -> [Change] {
        Array(recent.filter { $0.seq > after && (space == nil || $0.space == space) && (store == nil || $0.store == store) }.prefix(limit))
    }

    /// The oldest number still kept (a client that saw an older one may have missed some).
    public var oldest: Int { recent.first?.seq ?? seq + 1 }

    /// The changes after `after`; when there are none yet, waits for one up to `wait` seconds.
    public func wait(after: Int, space: SpaceID?, store: String?, seconds: Double, limit: Int = 200) async -> [Change] {
        let deadline = Date().addingTimeInterval(min(max(seconds, 0), 60))
        while true {
            let found = since(after, space: space, store: store, limit: limit)
            if !found.isEmpty || Date() >= deadline || Task.isCancelled { return found }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}

/// Every operation, by its id, while the app runs (the latest 500): what it was, who asked, and
/// how it went (`GET /api/operations/{id}`).
public actor OperationLog {
    public struct Entry: Sendable {
        public let id: UUID
        /// The store's path ("user/library"), or what else it was done to ("access", "pending").
        public let path: String
        public let op: String
        public let name: String?
        public let client: String
        public let at: Date
        public let seconds: Double
        public let ok: Bool
        public let status: Int
        public let code: String?
        public let error: String?
        public let summary: String

        var json: [String: Any] {
            var out: [String: Any] = [
                "request": id.uuidString, "path": path, "op": op, "ok": ok, "status": status, "state": ok ? "done" : "failed",
                "client": client, "asked": JSON.date(at), "seconds": JSON.round(seconds), "summary": summary,
                "url": "/api/operations/\(id.uuidString)",
            ]
            if let name { out["name"] = name }
            if let code { out["code"] = code }
            if let error { out["error"] = error }
            return out
        }
    }

    public let capacity: Int
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    public func add(_ e: Entry) {
        entries[e.id] = e
        order.append(e.id)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
    }

    public func entry(_ id: UUID) -> Entry? { entries[id] }

    public func recent(_ limit: Int) -> [Entry] { order.suffix(limit).reversed().compactMap { entries[$0] } }
}
