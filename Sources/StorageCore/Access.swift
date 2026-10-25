import Foundation

// Who may read and write what.
//
// Each space has its own: the person's (USER), Super Face's (SUPER), Peter's (PETER), an app's
// own folder in OTHER. Peter may read and write every one: he's the one who gets things done, and
// the one who lets other apps in. Any other app may use its own space, and asks for the rest:
// Peter (or the person, in the Storage Spaces window) says yes or no, for a while or for good. A
// change asked for without the access to make it can wait in PENDING until it's approved.
//
// An app is known by its name (`client`, or the X-Client header). A name can be claimed with a
// key (POST /api/clients/register): from then on, a request in that name without its key is
// turned down, so no other app can pass itself off as Peter.

/// How much a client may do with a store.
public enum Access: Int, Comparable, Codable, Sendable, CaseIterable {
    case none = 0, read = 1, write = 2

    public static func < (a: Access, b: Access) -> Bool { a.rawValue < b.rawValue }

    public var word: String {
        switch self {
        case .none: "none"
        case .read: "read"
        case .write: "write"
        }
    }

    public init?(word: String) {
        switch word.lowercased().trimmingCharacters(in: .whitespaces) {
        case "none", "no", "off": self = .none
        case "read", "r", "read-only", "readonly": self = .read
        case "write", "w", "read-write", "readwrite", "rw", "read/write", "all", "full": self = .write
        default: return nil
        }
    }
}

/// The apps Storage Spaces knows by name, and how names are compared.
public enum Clients {
    public static let peter = "Peter"
    public static let superFace = "Super Face"
    public static let toolMac = "Tool Mac Tool Run"
    /// The person, in the Storage Spaces window (never over HTTP).
    public static let person = "you"
    /// Storage Spaces itself (the grants it comes with, what it imports).
    public static let storage = "Storage Spaces"

    /// For comparing: no case, no accents, spaces collapsed.
    public static func fold(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return fold(a) == fold(b)
    }

    /// A name as a folder in OTHER: lower case, words joined by dashes ("Super Voice" → super-voice).
    /// Nil when nothing of it is left.
    public static func slug(_ name: String) -> String? {
        var out = ""
        var dash = false
        for ch in fold(name).unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch), ch.isASCII {
                if dash, !out.isEmpty { out += "-" }
                out.unicodeScalars.append(ch)
                dash = false
            } else {
                dash = true
            }
        }
        let s = String(out.prefix(64))
        return s.isEmpty ? nil : s
    }
}

/// A yes, kept: a client may read (or write) a space, or one store in it, until a time or for good.
public struct Grant: Codable, Sendable, Equatable {
    public var id: Int
    public var client: String
    public var space: SpaceID
    /// One store in the space (nil: all of it).
    public var store: String?
    public var access: Access
    /// Who said yes (Peter, you, the space's owner, Storage Spaces).
    public var by: String
    public var why: String?
    public var created: Date
    public var until: Date?

    public func covers(_ space: SpaceID, _ store: String?, at now: Date) -> Bool {
        guard self.space == space else { return false }
        if let until, until <= now { return false }
        guard let mine = self.store else { return true }
        return store.map { $0.lowercased() == mine.lowercased() } ?? false
    }

    /// "Super Face may read USER/MEMORY until 14:00".
    public var line: String {
        let place = store.map { "\(space.folderName)/\($0.uppercased())" } ?? space.folderName
        let when = until.map { " until \(JSON.date($0))" } ?? ""
        return "\(client) may \(access.word) \(place)\(when) (said yes: \(by))"
    }
}

/// Everything kept about access: the grants, and the clients' keys. In .storage/access.json.
public struct AccessBook: Codable, Sendable {
    public var next = 1
    public var grants: [Grant] = []
    /// A client's key, by its name folded: its hash, and when it was made.
    public var keys: [String: Key] = [:]

    public struct Key: Codable, Sendable, Equatable {
        public var client: String
        public var hash: String
        public var created: Date
    }

    public init() {}

    /// What a new book comes with: Tool Mac Tool Run may read and write your space, as it did
    /// when the library, MEMORY and the mind were its own.
    public static func starting(now: Date = Date()) -> AccessBook {
        var b = AccessBook()
        b.add(Grant(id: 0, client: Clients.toolMac, space: .user, store: nil, access: .write, by: Clients.storage,
                    why: "Your library, MEMORY and the mind moved here from Tool Mac Tool Run: it reads and writes them for you, as it did.",
                    created: now, until: nil))
        return b
    }

    @discardableResult
    public mutating func add(_ g: Grant) -> Grant {
        var g = g
        g.id = next
        next += 1
        // A new yes for the same thing replaces the one there was.
        grants.removeAll { Clients.same($0.client, g.client) && $0.space == g.space && $0.store?.lowercased() == g.store?.lowercased() }
        grants.append(g)
        return g
    }

    public mutating func dropExpired(now: Date = Date()) {
        grants.removeAll { $0.until.map { $0 <= now } ?? false }
    }

    // MARK: on disk

    public static func load(_ file: URL) -> AccessBook? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(AccessBook.self, from: data)
    }

    public func save(_ file: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: file, options: .atomic)
    }

    // MARK: keys

    /// A new key for a client (its hash is what's kept).
    public static func newKey() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    public func key(for client: String) -> Key? { keys[Clients.fold(client)] }

    /// Whether a request in `client`'s name may go ahead: a name with no key, any request; one
    /// with a key, only with that key.
    public func keyMatches(_ client: String, _ key: String?) -> Bool {
        guard let kept = self.key(for: client) else { return true }
        guard let key, !key.isEmpty else { return false }
        return SHA256.hex(Data(key.utf8)) == kept.hash
    }
}

/// The rule: what a client may do with a store, before and after the grants.
public enum Policy {
    /// What `client` may do with `store` in `space`, by the rules and by the grants.
    public static func access(_ client: String?, _ space: SpaceID, _ store: String?, grants: [Grant], now: Date = Date()) -> Access {
        guard let client, !client.trimmingCharacters(in: .whitespaces).isEmpty else { return .none }
        if let own = own(client, space, store) { return own }
        return grants.filter { Clients.same($0.client, client) && $0.covers(space, store, at: now) }.map(\.access).max() ?? .none
    }

    /// What the rules alone give: Peter and the person everything, an app its own space. PENDING
    /// is the system's: an app reads its own requests there (the API sees to that), nothing more.
    static func own(_ client: String, _ space: SpaceID, _ store: String?) -> Access? {
        if Clients.same(client, Clients.peter) || Clients.same(client, Clients.person) { return .write }
        if let owner = space.owner, Clients.same(owner, client) { return .write }
        if space == .other, let store, Clients.slug(client) == store.lowercased() { return .write }
        return nil
    }

    /// Who may say yes to `client` having access to `space`: Peter, the person, and the space's
    /// owner (for its own space).
    public static func mayGrant(_ by: String?, _ space: SpaceID, _ store: String?) -> Bool {
        guard let by else { return false }
        if Clients.same(by, Clients.peter) || Clients.same(by, Clients.person) { return true }
        if let owner = space.owner, Clients.same(owner, by) { return true }
        if space == .other, let store, Clients.slug(by) == store.lowercased() { return true }
        return false
    }

    /// Who may see and decide everything waiting (every request, every held change).
    public static func seesEverything(_ client: String?) -> Bool {
        Clients.same(client, Clients.peter) || Clients.same(client, Clients.person)
    }
}

/// SHA-256, for keeping clients' keys as hashes (Foundation has none on every platform).
public enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func hex(_ data: Data) -> String {
        digest(data).map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var bytes = [UInt8](data)
        let bits = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for i in (0..<8).reversed() { bytes.append(UInt8((bits >> (UInt64(i) * 8)) & 0xff)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: bytes.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(bytes[j]) << 24 | UInt32(bytes[j + 1]) << 16 | UInt32(bytes[j + 2]) << 8 | UInt32(bytes[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { v in (0..<4).reversed().map { UInt8((v >> (UInt32($0) * 8)) & 0xff) } }
    }
}
