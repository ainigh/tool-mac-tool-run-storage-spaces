import Foundation

/// Asking the mind things. A query in the notation itself (the ```mmq of the notation's section
/// 10: a path where a name that isn't in the graph is a variable), and the questions asked most,
/// each its own call, so a caller needn't know the notation: what's known about a name, its
/// neighbours, the way from one to another, the nodes with some words, the edges with a label,
/// the notes of a kind, the dates coming up, and the part of the mind a conversation touches.
public enum MindQuery {
    // MARK: names

    /// The nodes a name means, the likeliest first: written exactly (in the root scope first),
    /// then the same but for case and spaces, then without an article (the, a, an) or a plural
    /// s, then a few letters off.
    public static func lookup(_ text: String, in g: MindGraph, scope: String? = nil) -> [MindNodeID] {
        let ref = (try? MindNotation.name(MindNotation.collapse(text))) ?? MindNotation.NameRef(MindNotation.collapse(text))
        let all = g.nodeList.map(\.id)
        let inScope: (MindNodeID) -> Bool = { id in
            switch ref.scope {
            case .root: return id.isRoot
            case .named(let s): return id.scope == s
            case .current: return scope.map { id.scope == $0 } ?? true
            }
        }
        let pool = all.filter(inScope)
        let rootFirst: ([MindNodeID]) -> [MindNodeID] = { ids in ids.sorted { ($0.isRoot ? 0 : 1, $0.scope) < ($1.isRoot ? 0 : 1, $1.scope) } }
        let exact = pool.filter { $0.name == ref.name }
        if !exact.isEmpty { return rootFirst(exact) }
        let want = fold(ref.name)
        let same = pool.filter { fold($0.name) == want }
        if !same.isEmpty { return rootFirst(same) }
        let bare = stem(want)
        let stemmed = pool.filter { stem(fold($0.name)) == bare }
        if !stemmed.isEmpty { return rootFirst(stemmed) }
        // A word or two of the name: "ada" is "ada lovelace".
        let words = pool.filter { (" " + fold($0.name) + " ").contains(" " + want + " ") }
        if !words.isEmpty { return rootFirst(words) }
        guard want.count >= 4 else { return [] }
        let near = pool.compactMap { id -> (MindNodeID, Int)? in
            let d = FileLibrary.distance(Array(want), Array(fold(id.name)))
            return d <= max(1, want.count / 4) ? (id, d) : nil
        }
        return near.sorted { ($0.1, $0.0) < ($1.1, $1.0) }.map(\.0)
    }

    /// For comparing: no case, no accents, one space.
    static func fold(_ s: String) -> String {
        MindNotation.collapse(s).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Without a leading article or a trailing plural s.
    static func stem(_ s: String) -> String {
        var t = s
        for article in ["the ", "a ", "an "] where t.hasPrefix(article) { t = String(t.dropFirst(article.count)) }
        if t.hasSuffix("ies"), t.count > 4 { t = String(t.dropLast(3)) + "y" } else if t.hasSuffix("s"), !t.hasSuffix("ss"), t.count > 3 { t = String(t.dropLast()) }
        return t
    }

    // MARK: what's known about a node

    public struct Link: Sendable, Equatable {
        /// The node at the other end.
        public var node: MindNodeID
        /// "out" (this → it), "in" (it → this), "both", or "undirected".
        public var direction: String
        public var labels: [String]
        public var notes: [String]
    }

    public struct About: Sendable, Equatable {
        public var id: MindNodeID
        public var notes: [String]
        public var links: [Link]
        /// Every line about it, in the canonical form.
        public var lines: [String]
    }

    public static func about(_ id: MindNodeID, in g: MindGraph) -> About? {
        guard let node = g.node(id) else { return nil }
        var links: [Link] = []
        var lines = node.notes.map { MindGraph.line(id, note: $0, current: "") }
        for e in g.edges(at: id) {
            let other = e.other(id)
            let direction: String
            if e.undirected { direction = "undirected" } else if e.a == e.b { direction = "out" } else {
                let out = e.leads(from: id), back = e.leads(from: other)
                direction = out && back ? "both" : out ? "out" : "in"
            }
            links.append(Link(node: other, direction: direction, labels: e.labels, notes: e.notes))
            lines.append(MindGraph.line(e, current: ""))
        }
        if node.notes.isEmpty, links.isEmpty { lines.append("| " + MindNotation.written(id, current: "")) }
        return About(id: id, notes: node.notes, links: links, lines: lines)
    }

    // MARK: around a node, and between two

    public enum Direction: String, CaseIterable, Sendable {
        /// Following edges the way they go (and undirected ones).
        case out
        /// Against the way they go (and undirected ones).
        case `in`
        /// Any way.
        case both
    }

    public struct Neighbour: Sendable, Equatable {
        public var id: MindNodeID
        /// How many steps away.
        public var distance: Int
        /// The node it was reached from.
        public var via: MindNodeID
        public var labels: [String]
    }

    /// The nodes within `depth` steps, the nearest first.
    public static func neighbours(_ id: MindNodeID, in g: MindGraph, depth: Int = 1, direction: Direction = .both) -> [Neighbour] {
        var seen: Set<MindNodeID> = [id]
        var frontier = [id]
        var out: [Neighbour] = []
        for d in 1...max(1, depth) {
            var next: [MindNodeID] = []
            for from in frontier {
                for e in g.edges(at: from) {
                    let to = e.other(from)
                    guard !seen.contains(to), follows(e, from: from, direction) else { continue }
                    seen.insert(to)
                    next.append(to)
                    out.append(Neighbour(id: to, distance: d, via: from, labels: e.labels))
                }
            }
            frontier = next.sorted()
            if frontier.isEmpty { break }
        }
        return out
    }

    static func follows(_ e: MindGraph.Edge, from: MindNodeID, _ direction: Direction) -> Bool {
        switch direction {
        case .both: return true
        case .out: return e.leads(from: from)
        case .in: return e.leads(from: e.other(from))
        }
    }

    /// The shortest way from one node to another: the nodes on it, in order, and its edges as
    /// lines (nil: there's none).
    public static func path(from: MindNodeID, to: MindNodeID, in g: MindGraph, direction: Direction = .both) -> (nodes: [MindNodeID], lines: [String])? {
        guard g.node(from) != nil, g.node(to) != nil else { return nil }
        if from == to { return ([from], []) }
        var back: [MindNodeID: MindNodeID] = [:]
        var seen: Set<MindNodeID> = [from]
        var frontier = [from]
        while !frontier.isEmpty {
            var next: [MindNodeID] = []
            for x in frontier {
                for e in g.edges(at: x) {
                    let y = e.other(x)
                    guard !seen.contains(y), follows(e, from: x, direction) else { continue }
                    seen.insert(y)
                    back[y] = x
                    if y == to {
                        var way = [to]
                        while let p = back[way[0]] { way.insert(p, at: 0) }
                        let lines = zip(way, way.dropFirst()).compactMap { g.edge($0, $1).map { MindGraph.line($0, current: "") } }
                        return (way, lines)
                    }
                    next.append(y)
                }
            }
            frontier = next.sorted()
        }
        return nil
    }

    // MARK: finding

    public struct Found: Sendable, Equatable {
        public var id: MindNodeID
        public var score: Int
        /// Where the words were: "name", "note", "label".
        public var places: [String]
    }

    /// The nodes with every one of the words in their name, their notes, or their edges' labels
    /// (any of them, with `all` false), the best first.
    public static func find(_ words: String, in g: MindGraph, all: Bool = true) -> [Found] {
        let terms = FileLibrary.terms(words).map(fold)
        guard !terms.isEmpty else { return [] }
        var found: [Found] = []
        for n in g.nodeList {
            let name = fold(n.id.name)
            let notes = n.notes.map(fold).joined(separator: "\n")
            let labels = g.edges(at: n.id).flatMap(\.labels).map(fold).joined(separator: "\n")
            var score = 0, present = 0
            var places: [String] = []
            for t in terms {
                let a = name.contains(t) ? 1 : 0, b = notes.contains(t) ? 1 : 0, c = labels.contains(t) ? 1 : 0
                if a + b + c > 0 { present += 1 }
                score += a * 10 + b * 3 + c
                if a > 0, !places.contains("name") { places.append("name") }
                if b > 0, !places.contains("note") { places.append("note") }
                if c > 0, !places.contains("label") { places.append("label") }
            }
            if name == terms.joined(separator: " ") { score += 50 }
            guard all ? present == terms.count : present > 0 else { continue }
            found.append(Found(id: n.id, score: score, places: places))
        }
        return found.sorted { ($1.score, $0.id) < ($0.score, $1.id) }
    }

    /// The edges with a label (the same but for case; with `contains`, a label that has it in it).
    public static func edges(labelled label: String, in g: MindGraph, contains: Bool = false) -> [MindGraph.Edge] {
        let want = fold(label)
        return g.edgeList.filter { e in e.labels.contains { contains ? fold($0).contains(want) : fold($0) == want } }
    }

    /// The notes of a kind (`date` finds `@date 2026-11-03`), on nodes and on edges: the node
    /// (or the edge's first node), and the note.
    public static func notes(kind: String, in g: MindGraph) -> [(id: MindNodeID, note: String, edge: MindGraph.Edge?)] {
        let k = fold(kind)
        let has: (String) -> Bool = { note in
            let f = fold(note)
            return f == k || f.hasPrefix(k + " ") || f.hasPrefix(k + ":")
        }
        var out: [(MindNodeID, String, MindGraph.Edge?)] = []
        for n in g.nodeList { for note in n.notes where has(note) { out.append((n.id, note, nil)) } }
        for e in g.edgeList { for note in e.notes where has(note) { out.append((e.a, note, e)) } }
        return out
    }

    // MARK: dates

    public struct Dated: Sendable, Equatable {
        public var id: MindNodeID
        public var note: String
        /// The day it falls on next (or fell on, for a day that's past and doesn't come round).
        public var day: Date
        /// Days from today (negative: past).
        public var days: Int
        /// It comes round every year (a birthday, or a day written without its year).
        public var yearly: Bool
        public var edge: MindGraph.Edge?
    }

    /// Every note with a day in it (2026-11-03; or 11-03 / --11-03 for one every year, as is any
    /// day in a note of kind birthday or anniversary): when it next falls, the soonest first.
    /// Within `days` from `today` (and `past` days before it).
    public static func dates(in g: MindGraph, today: Date = Date(), days: Int = 30, past: Int = 0, calendar: Calendar = .current) -> [Dated] {
        let start = calendar.startOfDay(for: today)
        var out: [Dated] = []
        func consider(_ id: MindNodeID, _ note: String, _ edge: MindGraph.Edge?) {
            guard let (month, day, year) = dayIn(note) else { return }
            let f = fold(note)
            let yearly = year == nil || f.hasPrefix("birthday") || f.hasPrefix("anniversary") || f.hasPrefix("yearly")
            let thisYear = calendar.component(.year, from: start)
            var when: Date?
            if yearly {
                for y in [thisYear - 1, thisYear, thisYear + 1] {
                    guard let d = calendar.date(from: DateComponents(year: y, month: month, day: day)) else { continue }
                    let n = calendar.dateComponents([.day], from: start, to: d).day ?? 0
                    if n >= -past { when = d; break }
                }
            } else {
                when = calendar.date(from: DateComponents(year: year, month: month, day: day))
            }
            guard let d = when else { return }
            let n = calendar.dateComponents([.day], from: start, to: d).day ?? 0
            guard n >= -past, n <= days else { return }
            out.append(Dated(id: id, note: note, day: d, days: n, yearly: yearly, edge: edge))
        }
        for n in g.nodeList { for note in n.notes { consider(n.id, note, nil) } }
        for e in g.edgeList { for note in e.notes { consider(e.a, note, e) } }
        return out.sorted { ($0.days, $0.id) < ($1.days, $1.id) }
    }

    /// The first day written in a text: (month, day, year?) from 2026-11-03, --11-03 or 11-03.
    static func dayIn(_ text: String) -> (Int, Int, Int?)? {
        let full = try? NSRegularExpression(pattern: #"(?<![\d-])(\d{4})-(\d{2})-(\d{2})(?!\d)"#)
        let yearly = try? NSRegularExpression(pattern: #"(?<![\d-])(?:--)?(\d{2})-(\d{2})(?![\d-])"#)
        let r = NSRange(text.startIndex..., in: text)
        func int(_ m: NSTextCheckingResult, _ k: Int) -> Int? { Range(m.range(at: k), in: text).flatMap { Int(text[$0]) } }
        if let m = full?.firstMatch(in: text, range: r), let y = int(m, 1), let mo = int(m, 2), let d = int(m, 3), (1...12).contains(mo), (1...31).contains(d) {
            return (mo, d, y)
        }
        if let m = yearly?.firstMatch(in: text, range: r), let mo = int(m, 1), let d = int(m, 2), (1...12).contains(mo), (1...31).contains(d) {
            return (mo, d, nil)
        }
        return nil
    }

    // MARK: what a conversation touches

    /// The part of the mind some text is about (the notation's "before the model"): the nodes
    /// whose names are in it, with everything one step from them, as canonical lines (at most
    /// `limit`), and the names.
    public static func context(_ text: String, in g: MindGraph, limit: Int = 200) -> (nodes: [MindNodeID], lines: [String]) {
        let hay = " " + fold(text).map { $0.isLetter || $0.isNumber ? $0 : " " }.reduce(into: "") { $0.append($1) } + " "
        let spaced = { (s: String) in " " + fold(s).map { $0.isLetter || $0.isNumber ? $0 : " " }.reduce(into: "") { $0.append($1) } + " " }
        let named = g.nodeList.map(\.id).filter { id in
            let n = MindNotation.collapse(spaced(id.name))
            return !n.isEmpty && hay.contains(" " + n + " ")
        }
        var keep = Set(named)
        for id in named { for e in g.edges(at: id) { keep.insert(e.other(id)) } }
        var lines: [String] = []
        for id in named.sorted() {
            if let a = about(id, in: g) {
                for l in a.lines where !lines.contains(l) { lines.append(l) }
            }
        }
        // The notes of the nodes one step out, after.
        for id in keep.subtracting(named).sorted() {
            for note in g.node(id)?.notes ?? [] {
                let l = MindGraph.line(id, note: note, current: "")
                if !lines.contains(l) { lines.append(l) }
            }
        }
        return (keep.sorted(), Array(lines.prefix(max(0, limit))))
    }

    // MARK: the notation's own queries

    public struct Match: Sendable, Equatable {
        /// What each variable stands for.
        public var bindings: [String: MindNodeID]
        public var lines: [String]
    }

    public struct Answer: Sendable, Equatable {
        public var query: String
        public var matches: [Match]
        /// Every line that matched, once each, in order.
        public var lines: [String]
        /// The names taken as variables (not in the mind).
        public var variables: [String]
        public var problem: String?
    }

    /// Answers each statement line of a query (an ```mmq block, or lines): `| sam | x` every
    /// edge from sam, `| x - reviews | y` every edge labelled reviews, `| paper @x` every note on
    /// paper, `| @ talk` the whole scope. A name that's in the mind is itself; any other is a
    /// variable (the same variable twice is the same node).
    public static func run(_ query: String, in g: MindGraph, scope: String? = nil) -> [Answer] {
        let lines = MindNotation.normalize(query.contains("|") ? query : "| " + query)
        return lines.map { answer($0, in: g, scope: scope) }
    }

    enum Term {
        case node(Set<MindNodeID>)
        case variable(String)
    }

    static func answer(_ line: String, in g: MindGraph, scope: String?) -> Answer {
        var a = Answer(query: line, matches: [], lines: [], variables: [], problem: nil)
        let statement: MindNotation.Statement
        do {
            guard case .statement(let s) = try MindNotation.parse(line) else {
                a.problem = "A query is a statement line: | sam | x"
                return a
            }
            statement = s
        } catch {
            a.problem = "\(error)"
            return a
        }
        switch statement {
        case .scope(let s):
            guard g.hasScope(s) else {
                a.problem = "There's no scope called \(s)."
                return a
            }
            a.lines = g.canonicalLines(scopes: [s])
            a.matches = [Match(bindings: [:], lines: a.lines)]
            return a
        case .path(let names, let links, let notes):
            var terms: [Term] = []
            for ref in names {
                let ids = constant(ref, in: g, scope: scope)
                if ids.isEmpty {
                    terms.append(.variable(ref.name))
                    if !a.variables.contains(ref.name) { a.variables.append(ref.name) }
                } else {
                    terms.append(.node(Set(ids)))
                }
            }
            a.matches = match(terms, links, notes, in: g)
            for m in a.matches { for l in m.lines where !a.lines.contains(l) { a.lines.append(l) } }
            return a
        default:
            a.problem = "A query is a path (| sam | x) or a scope (| @ talk), not an edit."
            return a
        }
    }

    /// The nodes a name in a query is (none: it's a variable).
    static func constant(_ ref: MindNotation.NameRef, in g: MindGraph, scope: String?) -> [MindNodeID] {
        let all = g.nodeList.map(\.id)
        switch ref.scope {
        case .root: return all.filter { $0.isRoot && $0.name == ref.name }
        case .named(let s): return all.filter { $0.scope == s && $0.name == ref.name }
        case .current:
            let inScope = { (id: MindNodeID) in scope.map { id.scope == $0 } ?? true }
            let exact = all.filter { $0.name == ref.name && inScope($0) }
            if !exact.isEmpty { return exact }
            return all.filter { fold($0.name) == fold(ref.name) && inScope($0) }
        }
    }

    /// Whether a note is what a query's note asks for: the same, or of that kind (`@date` is
    /// `@date 2026-11-03`); a query's note that's no note in the mind stands for any.
    static func noteMatcher(_ pattern: String, in g: MindGraph) -> (String) -> Bool {
        let p = fold(pattern)
        let fits: (String) -> Bool = { note in
            let f = fold(note)
            return f == p || f.hasPrefix(p + " ") || f.hasPrefix(p + ":")
        }
        let known = g.nodeList.contains { $0.notes.contains(where: fits) } || g.edgeList.contains { $0.notes.contains(where: fits) }
        return known ? fits : { _ in true }
    }

    static func match(_ terms: [Term], _ links: [MindNotation.Link], _ nodeNotes: [String], in g: MindGraph) -> [Match] {
        let all = Set(g.nodes.keys)
        var results: [Match] = []
        let noteTests = nodeNotes.map { noteMatcher($0, in: g) }
        let linkNoteTests = links.map { $0.notes.map { noteMatcher($0, in: g) } }

        func candidates(_ t: Term, _ b: [String: MindNodeID]) -> [MindNodeID] {
            switch t {
            case .node(let ids): return ids.sorted()
            case .variable(let v): return b[v].map { [$0] } ?? all.sorted()
            }
        }

        func fits(_ t: Term, _ id: MindNodeID, _ b: inout [String: MindNodeID]) -> Bool {
            switch t {
            case .node(let ids): return ids.contains(id)
            case .variable(let v):
                if let had = b[v] { return had == id }
                b[v] = id
                return true
            }
        }

        func step(_ k: Int, at id: MindNodeID, _ b: [String: MindNodeID], _ lines: [String]) {
            if k == links.count {
                // The last node: its notes, when the query asks about them.
                guard !noteTests.isEmpty || links.isEmpty else {
                    results.append(Match(bindings: b, lines: lines))
                    return
                }
                let notes = g.node(id)?.notes ?? []
                let picked = notes.filter { n in noteTests.allSatisfy { $0(n) } }
                if noteTests.isEmpty {
                    // `| sam`: all there is about it.
                    results.append(Match(bindings: b, lines: about(id, in: g)?.lines ?? []))
                } else if !picked.isEmpty {
                    results.append(Match(bindings: b, lines: lines + picked.map { MindGraph.line(id, note: $0, current: "") }))
                }
                return
            }
            let link = links[k]
            for e in g.edges(at: id) {
                let to = e.other(id)
                if !link.undirected, !e.leads(from: id) { continue }
                let want = link.labels.map(fold)
                guard want.allSatisfy({ w in e.labels.contains { fold($0) == w } }) else { continue }
                guard linkNoteTests[k].allSatisfy({ test in e.notes.contains(where: test) }) else { continue }
                var nb = b
                guard fits(terms[k + 1], to, &nb) else { continue }
                let l = MindGraph.line(e, current: "")
                step(k + 1, at: to, nb, lines.contains(l) ? lines : lines + [l])
            }
        }

        for start in candidates(terms[0], [:]) {
            var b: [String: MindNodeID] = [:]
            guard fits(terms[0], start, &b) else { continue }
            step(0, at: start, b, [])
        }
        return results
    }
}
