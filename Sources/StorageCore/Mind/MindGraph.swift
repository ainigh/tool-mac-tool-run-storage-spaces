import Foundation

/// A node's identity: its scope ("" is the root scope) and its name. Names are compared exactly
/// (after the notation trims them and collapses their spaces): `Sam` and `sam` are two nodes.
public struct MindNodeID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var scope: String
    public var name: String

    public init(_ name: String, scope: String = "") {
        self.scope = scope
        self.name = name
    }

    public var isRoot: Bool { scope.isEmpty }

    public static func < (a: MindNodeID, b: MindNodeID) -> Bool {
        (a.scope, a.name) < (b.scope, b.name)
    }

    /// `name` in the root scope, `name@scope` elsewhere.
    public var description: String { scope.isEmpty ? name : "\(name)@\(scope)" }
}

/// The compiled mind: its nodes, the edges between them, the comments, and the scopes, as the log
/// says after every line of it (each line read in order; an edit changes what came before it).
public struct MindGraph: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        public var id: MindNodeID
        /// Its notes, in the order first seen, without repeats.
        public var notes: [String]
        /// The line it first appeared on (from 1).
        public var line: Int
    }

    /// The edge between two nodes (one per pair, whatever the statements' order): `a` is the
    /// lesser of the two. Directed one way, the other, both, or neither (undirected).
    public struct Edge: Sendable, Equatable {
        public var a: MindNodeID
        public var b: MindNodeID
        /// a → b.
        public var forward: Bool
        /// b → a.
        public var backward: Bool
        public var labels: [String]
        public var notes: [String]
        public var line: Int

        public var undirected: Bool { !forward && !backward }

        public func other(_ id: MindNodeID) -> MindNodeID { id == a ? b : a }

        /// Whether it can be followed from `from` (directed that way, or undirected).
        public func leads(from: MindNodeID) -> Bool {
            if undirected { return from == a || from == b }
            return (from == a && forward) || (from == b && backward)
        }
    }

    public struct EdgeKey: Hashable, Sendable {
        public let a: MindNodeID
        public let b: MindNodeID

        init(_ x: MindNodeID, _ y: MindNodeID) {
            if x <= y { a = x; b = y } else { a = y; b = x }
        }
    }

    public struct Comment: Sendable, Equatable {
        public var scope: String
        public var text: String
        public var line: Int
    }

    /// A line the log has that couldn't be read: its number, its text, what's wrong, the fix.
    public struct Problem: Sendable, Equatable {
        public var line: Int
        public var text: String
        public var message: String
        public var fix: String
    }

    public private(set) var nodes: [MindNodeID: Node] = [:]
    public private(set) var edges: [EdgeKey: Edge] = [:]
    public private(set) var comments: [Comment] = []
    /// Every scope there is (the root scope isn't listed), in the order made.
    public private(set) var scopes: [String] = []
    /// The scope the next line is in.
    public private(set) var current = ""
    /// Lines that couldn't be read (they changed nothing).
    public private(set) var problems: [Problem] = []
    /// How many lines were read.
    public private(set) var lines = 0

    public init() {}

    /// The log, compiled.
    public init(log: String) {
        self.init()
        for raw in log.components(separatedBy: "\n") { read(raw) }
    }

    /// Reads the next line of the log; a line with a mistake is kept as a problem.
    public mutating func read(_ raw: String) {
        lines += 1
        do {
            try apply(raw)
        } catch let m as MindNotation.Mistake {
            problems.append(Problem(line: lines, text: raw.trimmingCharacters(in: .whitespaces), message: m.message, fix: m.fix))
        } catch {
            problems.append(Problem(line: lines, text: raw, message: "\(error)", fix: ""))
        }
    }

    /// Applies one line, or throws its mistake (changing nothing). It counts as a line read only
    /// through `read`.
    public mutating func apply(_ raw: String, line: Int? = nil) throws {
        let n = line ?? lines
        switch try MindNotation.parse(raw) {
        case .blank:
            return
        case .comment(let text):
            comments.append(Comment(scope: current, text: text, line: n))
        case .statement(let s):
            try apply(s, line: n)
        }
    }

    public func hasScope(_ s: String) -> Bool { s.isEmpty || scopes.contains(s) }

    /// The node a name means here, in its scope (which must be one there is).
    public func resolve(_ ref: MindNotation.NameRef) throws -> MindNodeID {
        switch ref.scope {
        case .current: return MindNodeID(ref.name, scope: current)
        case .root: return MindNodeID(ref.name)
        case .named(let s):
            guard scopes.contains(s) else {
                throw MindNotation.Mistake("There's no scope called \(s) yet.", fix: "Make it first with | @ \(s) (or write \(ref.name)@ for the root scope).")
            }
            return MindNodeID(ref.name, scope: s)
        }
    }

    mutating func apply(_ s: MindNotation.Statement, line n: Int) throws {
        switch s {
        case .scope(let name):
            if !scopes.contains(name) { scopes.append(name) }
            current = name
        case .path(let refs, let links, let notes):
            let ids = try refs.map(resolve)
            for id in ids { touch(id, line: n) }
            for (k, link) in links.enumerated() {
                addEdge(ids[k], ids[k + 1], directed: !link.undirected, labels: link.labels, notes: link.notes, line: n)
            }
            if let last = ids.last { addNotes(notes, to: last) }
        case .edit(let oldRef, let newRef):
            let old = try resolve(oldRef)
            let new = try newRef.map(resolve)
            // Comments in old's scope that are old's text: replaced, or (with nothing) removed.
            if let new {
                for k in comments.indices where comments[k].scope == old.scope && comments[k].text == old.name { comments[k].text = new.name }
            } else {
                comments.removeAll { $0.scope == old.scope && $0.text == old.name }
            }
            if let new { rename(old, to: new) } else { remove(old) }
        case .mergeScope(let a, let b):
            guard scopes.contains(a) else { throw MindNotation.Mistake("There's no scope called \(a).", fix: "The scopes: \(scopeList)") }
            guard a != b else { return }
            if !scopes.contains(b) { scopes.append(b) }
            for id in nodes.keys.filter({ $0.scope == a }).sorted(by: { nodes[$0]!.line < nodes[$1]!.line }) {
                rename(id, to: MindNodeID(id.name, scope: b))
            }
            for k in comments.indices where comments[k].scope == a { comments[k].scope = b }
            scopes.removeAll { $0 == a }
            if current == a { current = b }
        case .deleteScope(let a):
            guard scopes.contains(a) else { throw MindNotation.Mistake("There's no scope called \(a).", fix: "The scopes: \(scopeList)") }
            for id in nodes.keys where id.scope == a { remove(id) }
            comments.removeAll { $0.scope == a }
            scopes.removeAll { $0 == a }
            if current == a { current = "" }
        }
    }

    private var scopeList: String { scopes.isEmpty ? "none yet" : scopes.joined(separator: ", ") }

    private mutating func touch(_ id: MindNodeID, line n: Int) {
        if nodes[id] == nil { nodes[id] = Node(id: id, notes: [], line: n) }
    }

    private mutating func addNotes(_ notes: [String], to id: MindNodeID) {
        guard var node = nodes[id] else { return }
        for note in notes where !node.notes.contains(note) { node.notes.append(note) }
        nodes[id] = node
    }

    private mutating func addEdge(_ from: MindNodeID, _ to: MindNodeID, directed: Bool, labels: [String], notes: [String], line n: Int) {
        let key = EdgeKey(from, to)
        var e = edges[key] ?? Edge(a: key.a, b: key.b, forward: false, backward: false, labels: [], notes: [], line: n)
        if directed {
            // A loop (a node to itself) is one way.
            if from == key.a { e.forward = true }
            if to == key.a, from != to { e.backward = true }
        }
        for l in labels where !e.labels.contains(l) { e.labels.append(l) }
        for x in notes where !e.notes.contains(x) { e.notes.append(x) }
        edges[key] = e
    }

    /// Renames a node (merging it into the one of the new name, when there's one already).
    private mutating func rename(_ old: MindNodeID, to new: MindNodeID) {
        guard old != new, let node = nodes.removeValue(forKey: old) else { return }
        if var there = nodes[new] {
            for x in node.notes where !there.notes.contains(x) { there.notes.append(x) }
            there.line = min(there.line, node.line)
            nodes[new] = there
        } else {
            nodes[new] = Node(id: new, notes: node.notes, line: node.line)
        }
        for (key, e) in edges where key.a == old || key.b == old {
            edges[key] = nil
            let a = e.a == old ? new : e.a
            let b = e.b == old ? new : e.b
            if e.undirected {
                addEdge(a, b, directed: false, labels: e.labels, notes: e.notes, line: e.line)
            } else {
                if e.forward { addEdge(a, b, directed: true, labels: e.labels, notes: e.notes, line: e.line) }
                if e.backward { addEdge(b, a, directed: true, labels: e.labels, notes: e.notes, line: e.line) }
            }
        }
    }

    private mutating func remove(_ id: MindNodeID) {
        nodes[id] = nil
        for key in edges.keys where key.a == id || key.b == id { edges[key] = nil }
    }

    // MARK: reading it

    /// The nodes, in the order they first appeared.
    public var nodeList: [Node] { nodes.values.sorted { ($0.line, $0.id) < ($1.line, $1.id) } }

    /// The edges, in the order they first appeared.
    public var edgeList: [Edge] { edges.values.sorted { ($0.line, $0.a, $0.b) < ($1.line, $1.a, $1.b) } }

    /// The edges at a node.
    public func edges(at id: MindNodeID) -> [Edge] { edgeList.filter { $0.a == id || $0.b == id } }

    public func node(_ id: MindNodeID) -> Node? { nodes[id] }

    /// The edge between two nodes, if there's one.
    public func edge(_ x: MindNodeID, _ y: MindNodeID) -> Edge? { edges[EdgeKey(x, y)] }

    // MARK: the canonical form

    /// The graph as a log again, the shortest that compiles to the same graph (the "optimized"
    /// log): for each scope (the root first, then A to Z) its comments, each node with nothing
    /// else to say about it, each note on a node, and each edge, a line each. An edge between two
    /// scopes is written with the later one, so both are there by then.
    public var canonical: String { canonicalLines().joined(separator: "\n") + (nodes.isEmpty && comments.isEmpty && scopes.isEmpty ? "" : "\n") }

    public func canonicalLines(scopes only: Set<String>? = nil) -> [String] {
        let order = [""] + scopes.sorted()
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        var out: [String] = []
        for scope in order where only?.contains(scope) ?? true {
            if !scope.isEmpty { out.append("| @ " + scope) }
            out += comments.filter { $0.scope == scope }.map(\.text)
            let here = nodes.values.filter { $0.id.scope == scope }.sorted { $0.id.name < $1.id.name }
            let linked = Set(edges.keys.flatMap { [$0.a, $0.b] })
            for n in here {
                if n.notes.isEmpty, !linked.contains(n.id) { out.append("| " + n.id.name) }
                for note in n.notes { out.append("| \(n.id.name) @\(note)") }
            }
            let mine = edges.values.filter { order[max(rank[$0.a.scope] ?? 0, rank[$0.b.scope] ?? 0)] == scope }
                .sorted { ($0.a, $0.b) < ($1.a, $1.b) }
            for e in mine { out.append(Self.line(e, current: scope)) }
        }
        return out
    }

    /// One edge as one statement, in a line whose current scope is `current`.
    public static func line(_ e: Edge, current: String) -> String {
        let a = MindNotation.written(e.a, current: current)
        let b = MindNotation.written(e.b, current: current)
        if e.undirected { return MindNotation.line(from: a, to: b, labels: e.labels, notes: e.notes, undirected: true) }
        if e.forward, e.backward { return MindNotation.line(from: a, to: b, labels: e.labels, notes: e.notes) + " | " + a }
        if e.forward { return MindNotation.line(from: a, to: b, labels: e.labels, notes: e.notes) }
        return MindNotation.line(from: b, to: a, labels: e.labels, notes: e.notes)
    }

    /// A node's note as a line.
    public static func line(_ id: MindNodeID, note: String, current: String) -> String {
        "| \(MindNotation.written(id, current: current)) @\(note)"
    }
}
