import Foundation

/// The mind over HTTP (`/api/mind…`): ask it (in plain fields, or in the notation's own query
/// lines) and add to it (in plain fields, or in the notation). Nothing is asked on the Mac, and
/// nothing is ever taken out of its log: adding is appending, and even a rename or a forget is a
/// line appended (the notation's `old = new`, `old =`). A scope delete or merge is the person's.
public enum MindAPI {
    public static let operations: [Operation] = [
        // Asking.
        .init(name: "stats", summary: "how many nodes, edges, scopes, comments, lines, problems; the scope the log is in", fields: [], route: "GET /api/mind/stats", changes: false),
        .init(name: "nodes", summary: "every node (?scope, ?q: words in the name, ?memory=true: only MEMORY's files)", fields: ["scope?", "q?", "memory?", "limit?"], route: "GET /api/mind/nodes", changes: false),
        .init(name: "about", summary: "a node: its notes, and each link (out, in, both, undirected) with its labels; the lines about it. The name is looked up as a person would mean it (case, plurals, a few letters off)",
              fields: ["name"], route: "GET /api/mind/nodes/{name}", changes: false),
        .init(name: "neighbors", summary: "the nodes within a few steps (?depth=1, ?direction=out|in|both)", fields: ["name", "depth?", "direction?"], route: "GET /api/mind/nodes/{name}/neighbors", changes: false),
        .init(name: "path", summary: "the shortest way from one node to another, and its lines", fields: ["from", "to", "direction?"], route: "GET /api/mind/path?from=…&to=…", changes: false),
        .init(name: "find", summary: "the nodes with the words in their name, notes or links' labels, the best first", fields: ["q", "match?: all|any", "limit?"], route: "GET /api/mind/find?q=…", changes: false),
        .init(name: "edges", summary: "every edge (?label=works at: the ones with that label; ?contains=true: a label with it in it)", fields: ["label?", "contains?"], route: "GET /api/mind/edges", changes: false),
        .init(name: "notes", summary: "the notes of a kind (?kind=date finds @date 2026-11-03), on nodes and edges", fields: ["kind"], route: "GET /api/mind/notes?kind=…", changes: false),
        .init(name: "dates", summary: "the days coming up in the notes (2026-11-03; 03-14 and birthday notes come round every year)", fields: ["days?: 30", "past?: 0"], route: "GET /api/mind/dates", changes: false),
        .init(name: "query", summary: "the notation's own query lines (```mmq): | sam | x every edge from sam, | x - reviews | y, | paper @x, | @ talk; a name not in the mind is a variable",
              fields: ["q: lines"], route: "POST /api/mind/query", changes: false),
        .init(name: "context", summary: "the part of the mind some text is about (the nodes named in it and one step out), as lines: what to give a model with a conversation",
              fields: ["text", "limit?: 200"], route: "POST /api/mind/context", changes: false),
        .init(name: "prompt", summary: "the notation's prompt for a model, filled in: the rules, the nodes and memory the messages touch, and the messages; with its grammar",
              fields: ["messages", "scope?"], route: "POST /api/mind/prompt", changes: false),
        .init(name: "scopes", summary: "the scopes, each with how many nodes", fields: [], route: "GET /api/mind/scopes", changes: false),
        .init(name: "graph", summary: "everything: nodes, edges, comments, scopes (?scope: one of them)", fields: ["scope?"], route: "GET /api/mind/graph", changes: false),
        .init(name: "layout", summary: "where each node goes in a picture (0…1 both ways), the same each time", fields: [], route: "GET /api/mind/layout", changes: false),
        .init(name: "log", summary: "the log itself, every line as written (text/plain; ?format=json: its lines)", fields: [], route: "GET /api/mind/log", changes: false),
        .init(name: "canonical", summary: "the mind in its shortest form: one line a fact (text/plain; ?format=json: its lines)", fields: [], route: "GET /api/mind/canonical", changes: false),
        .init(name: "problems", summary: "the lines of the log that couldn't be read, each with its fix", fields: [], route: "GET /api/mind/problems", changes: false),
        .init(name: "check", summary: "what lines would add, without adding them: the lines that are new, the ones known already, the mistakes", fields: ["lines | text", "scope?"],
              route: "POST /api/mind/check", changes: false),
        // Adding (appending).
        .init(name: "add", summary: "adds facts without the notation: {from, to, label?, undirected?, notes?}, or {node, notes}, or {facts: [those]}; names are matched to the mind's",
              fields: ["from", "to?", "label?", "undirected?", "notes?", "facts?", "scope?", "keep_case?"], route: "POST /api/mind/add", changes: true),
        .init(name: "append", summary: "appends lines of the notation ({lines: [...]}, or {text} with a ```mm block, as a model writes it); a mistake adds nothing (\"partial\": true adds the rest)",
              fields: ["lines | text", "scope?", "comment?", "partial?"], route: "POST /api/mind/append", changes: true),
        .init(name: "note", summary: "adds a note to a node (made if it isn't there): @date 2026-11-03, @todo call back…", fields: ["name", "note"], route: "POST /api/mind/note", changes: true),
        .init(name: "rename", summary: "appends `old = new`: the node is called new from here on (merging into new if it's there)", fields: ["name", "to"], route: "POST /api/mind/rename", changes: true),
        .init(name: "forget", summary: "appends `name =`: the node and its edges are gone from the mind (still in the log's history)", fields: ["name"], route: "POST /api/mind/forget", changes: true),
        .init(name: "comment", summary: "appends a comment line (any text; it's in the scope the log is in)", fields: ["text"], route: "POST /api/mind/comment", changes: true),
        .init(name: "compact", summary: "rewrites the log in its shortest form, keeping the old one in MIND/Archive", fields: [], route: "POST /api/mind/compact", changes: true),
    ]

    static let byName: [String: Operation] = Dictionary(uniqueKeysWithValues: operations.map { ($0.name, $0) })
    static var names: String { operations.map(\.name).joined(separator: ", ") }

    // MARK: JSON

    static func nodeJSON(_ id: MindNodeID, files: Set<String> = []) -> [String: Any] {
        var out: [String: Any] = ["name": id.name, "scope": id.scope, "id": id.description]
        if id.isRoot, files.contains(id.name) { out["memory"] = "MEMORY/\(id.name).md" }
        return out
    }

    static func nodeJSON(_ n: MindGraph.Node, in g: MindGraph, files: Set<String>) -> [String: Any] {
        var out = nodeJSON(n.id, files: files)
        out["notes"] = n.notes
        out["line"] = n.line
        out["links"] = g.edges(at: n.id).count
        return out
    }

    static func edgeJSON(_ e: MindGraph.Edge) -> [String: Any] {
        let (from, to) = e.backward && !e.forward ? (e.b, e.a) : (e.a, e.b)
        return ["from": from.description, "to": to.description, "direction": e.undirected ? "undirected" : e.forward && e.backward ? "both" : "one way",
                "labels": e.labels, "notes": e.notes, "line": MindGraph.line(e, current: "")]
    }

    static func aboutJSON(_ a: MindQuery.About, files: Set<String> = []) -> [String: Any] {
        var out = nodeJSON(a.id, files: files)
        out["notes"] = a.notes
        out["links"] = a.links.map { l -> [String: Any] in
            ["node": l.node.description, "direction": l.direction, "labels": l.labels, "notes": l.notes, "memory": l.node.isRoot && files.contains(l.node.name)]
        }
        out["lines"] = a.lines
        return out
    }

    static func problemJSON(_ p: MindGraph.Problem) -> [String: Any] {
        ["line": p.line, "text": p.text, "error": p.message, "fix": p.fix]
    }

    // MARK: the prompt

    /// The notation's prompt for a small model (its section 9), with `{scope}`, `{nodes}`,
    /// `{memory}` and `{messages}` filled in.
    static func prompt(scope: String, nodes: [String], memory: [String], messages: String) -> String {
        """
        You keep a memory graph of this chat. After reading the recent messages, output ONLY the new lines to append, inside one ```mm block. If nothing new was said, output an empty block.

        Line forms:
        | name | name              a step or direction
        | name - verb | name       a link with a short label, max 4 words
        | name @kind text          a note on a node; kinds: date, todo, pref, src
        | old = new                these two are the same thing; merge them
        | old =                    forget this

        Names are lowercase. Reuse a name from the list exactly when it is the same thing. Write only what was actually said. Never explain.

        Example
        messages:
        user: I'm Sam. I'm writing a paper, Ana reviews it on Nov 3.
        ```mm
        | sam - writes | paper
        | ana - reviews | paper
        | paper @date 2026-11-03 review by ana
        ```

        Example
        messages:
        user: thanks, that's all for now
        ```mm
        ```

        Example
        nodes: sam, paper, the paper
        messages:
        user: the paper is actually a thesis
        ```mm
        | the paper = paper
        | paper = thesis
        ```

        Scope: \(scope.isEmpty ? "(root)" : scope)
        Existing nodes: \(nodes.joined(separator: ", "))
        Memory:
        \(memory.joined(separator: "\n"))
        Recent messages:
        \(messages)
        """
    }

    /// The notation's grammar (GBNF), for decoding held to it.
    public static let grammar = #"""
    root  ::= line+
    line  ::= "| " (scope | path | edit) "\n"
    scope ::= "@ " text (" =" (" @ " text)?)?
    path  ::= name (link name)* note*
    link  ::= seg* term
    seg   ::= " - " text | note
    note  ::= " @" text
    term  ::= " | " | " - | "
    edit  ::= name " =" (" " name)?
    name  ::= text ("@" text?)?
    text  ::= word (" " word)*
    word  ::= [^ \n|@=-] [^ \n@]*
    """#

    // MARK: the operations

    static func perform(_ op: String, _ f: Fields, memory: Memory, client: String, req: HTTPRequest) throws -> StorageAPI.Done {
        let mind = memory.mind
        let g = mind.graph()
        let files = Set(memory.files.names())
        func node(_ key: String = "name") throws -> MindNodeID {
            guard let text = f.text(key) ?? (key == "name" ? f.text("node") ?? f.text("from") : nil), !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MindError(.badRequest, "Say which node: \"\(key)\".")
            }
            guard let id = MindQuery.lookup(text, in: g, scope: f.text("scope")).first else {
                let near = MindQuery.find(text, in: g, all: false).prefix(5).map(\.id.description)
                throw MindError(.notFound, "There's no node called \(text) in the mind.",
                                fix: near.isEmpty ? (g.nodes.isEmpty ? "The mind is empty: add to it (POST /api/mind/add)." : "GET /api/mind/nodes lists them.") : "Near it: " + near.joined(separator: ", "))
            }
            return id
        }
        func direction() throws -> MindQuery.Direction {
            try f.choice("direction", MindQuery.Direction.allCases.map(\.rawValue)).flatMap(MindQuery.Direction.init(rawValue:)) ?? .both
        }
        func appendLines() -> [String] {
            if let lines = f.values["lines"] as? [Any] { return lines.compactMap { Fields.text($0) } }
            if let one = f.text("lines") ?? f.text("line") { return one.components(separatedBy: .newlines) }
            if let text = f.text("text") { return MindNotation.normalize(text) }
            return []
        }
        let stamp = MindStore.stamp(client)
        func appended(_ r: MindStore.Appended, _ extra: [String: Any] = [:]) -> [String: Any] {
            var out: [String: Any] = ["added": r.added, "known": r.known, "written": r.written, "scope": r.scope,
                                      "nodes": r.graph.nodes.count, "edges": r.graph.edges.count]
            if !r.problems.isEmpty { out["problems"] = r.problems.map(problemJSON) }
            out.merge(extra) { a, _ in a }
            out["lines"] = r.added
            return out
        }

        switch op {
        case "stats":
            return .json(["file": mind.file.path, "nodes": g.nodes.count, "edges": g.edges.count, "scopes": g.scopes, "comments": g.comments.count,
                          "lines": g.lines, "problems": g.problems.count, "current_scope": g.current, "memory_nodes": g.nodes.keys.filter { $0.isRoot && files.contains($0.name) }.count,
                          "archived": mind.archived().count], summary: "\(g.nodes.count) nodes, \(g.edges.count) edges")
        case "nodes":
            var list = g.nodeList
            if let scope = f.text("scope") { list = list.filter { $0.id.scope == (scope == "@" || scope == "root" ? "" : scope) } }
            if let q = f.text("q"), !q.isEmpty { list = list.filter { MindQuery.fold($0.id.name).contains(MindQuery.fold(q)) } }
            if f.bool("memory") == true { list = list.filter { $0.id.isRoot && files.contains($0.id.name) } }
            let total = list.count
            list = Array(list.prefix(max(0, f.int("limit") ?? Int.max)))
            return .json(["total": total, "count": list.count, "nodes": list.map { nodeJSON($0, in: g, files: files) }, "names": list.map(\.id.description)],
                         summary: "listed \(list.count) nodes")
        case "about":
            let id = try node()
            guard let a = MindQuery.about(id, in: g) else { throw MindError(.notFound, "There's no node \(id).") }
            var out = aboutJSON(a, files: files)
            if id.isRoot, files.contains(id.name), let text = try? memory.files.read(id.name).text { out["memory_text"] = text }
            return .json(out, summary: "about \(id)")
        case "neighbors", "neighbours":
            let id = try node()
            let depth = max(1, min(6, f.int("depth") ?? 1))
            let list = MindQuery.neighbours(id, in: g, depth: depth, direction: try direction())
            return .json(["name": id.description, "depth": depth, "count": list.count,
                          "neighbors": list.map { ["node": $0.id.description, "distance": $0.distance, "via": $0.via.description, "labels": $0.labels, "memory": $0.id.isRoot && files.contains($0.id.name)] as [String: Any] },
                          "names": list.map(\.id.description)], summary: "\(list.count) around \(id)")
        case "path":
            let from = try node("from"), to = try node("to")
            guard let p = MindQuery.path(from: from, to: to, in: g, direction: try direction()) else {
                return .json(["from": from.description, "to": to.description, "found": false, "nodes": [String](), "lines": [String]()], summary: "no way from \(from) to \(to)")
            }
            return .json(["from": from.description, "to": to.description, "found": true, "steps": p.nodes.count - 1, "nodes": p.nodes.map(\.description), "lines": p.lines],
                         summary: "\(p.nodes.count - 1) steps from \(from) to \(to)")
        case "find", "search":
            guard let q = f.text("q") ?? f.text("query") ?? f.text("text"), !q.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MindError(.badRequest, "find takes \"q\": the words to look for.")
            }
            let match = try f.choice("match", ["all", "any"]) ?? "all"
            let found = Array(MindQuery.find(q, in: g, all: match == "all").prefix(max(0, f.int("limit") ?? 50)))
            return .json(["query": q, "count": found.count, "results": found.map { r -> [String: Any] in
                var d = nodeJSON(r.id, files: files)
                d["score"] = r.score
                d["in"] = r.places
                return d
            }, "names": found.map(\.id.description)], summary: "find \"\(q)\": \(found.count)")
        case "edges":
            let list = f.text("label").map { MindQuery.edges(labelled: $0, in: g, contains: f.bool("contains") ?? false) } ?? g.edgeList
            return .json(["count": list.count, "edges": list.map(edgeJSON), "lines": list.map { MindGraph.line($0, current: "") }], summary: "\(list.count) edges")
        case "notes":
            guard let kind = f.text("kind") ?? f.text("q"), !kind.isEmpty else { throw MindError(.badRequest, "notes takes \"kind\": date, todo, pref, src, birthday…") }
            let list = MindQuery.notes(kind: kind, in: g)
            let lines = list.map { $0.edge.map { MindGraph.line($0, current: "") } ?? MindGraph.line($0.id, note: $0.note, current: "") }
            return .json(["kind": kind, "count": list.count, "notes": list.map { ["node": $0.id.description, "note": $0.note, "on": $0.edge == nil ? "node" : "edge"] as [String: Any] },
                          "lines": lines], summary: "\(list.count) notes of kind \(kind)")
        case "dates":
            let days = max(0, min(3660, f.int("days") ?? 30)), past = max(0, min(3660, f.int("past") ?? 0))
            let list = MindQuery.dates(in: g, days: days, past: past)
            let lines = list.map { "\(JSON.day($0.day)) (\($0.days >= 0 ? "in \($0.days)" : "\(-$0.days) ago") day\(abs($0.days) == 1 ? "" : "s")): " + ($0.edge.map { MindGraph.line($0, current: "") } ?? MindGraph.line($0.id, note: $0.note, current: "")) }
            return .json(["days": days, "count": list.count, "dates": list.map { ["day": JSON.day($0.day), "in_days": $0.days, "node": $0.id.description, "note": $0.note, "yearly": $0.yearly] as [String: Any] },
                          "lines": lines], summary: "\(list.count) dates")
        case "query":
            guard let q = f.text("q") ?? f.text("query") ?? f.text("text") ?? f.text("lines"), !q.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MindError(.badRequest, "query takes \"q\": query lines in the notation (| sam | x).", fix: "A name that isn't in the mind is a variable: | sam | x is every edge from sam.")
            }
            let answers = MindQuery.run(q, in: g, scope: f.text("scope"))
            var lines: [String] = []
            for a in answers { for l in a.lines where !lines.contains(l) { lines.append(l) } }
            return .json(["count": lines.count, "lines": lines, "answers": answers.map { a -> [String: Any] in
                var d: [String: Any] = ["query": a.query, "lines": a.lines, "variables": a.variables,
                                        "matches": a.matches.map { m in ["bindings": m.bindings.mapValues(\.description), "lines": m.lines] as [String: Any] }]
                if let p = a.problem { d["problem"] = p }
                return d
            }], summary: "query: \(lines.count) lines")
        case "context":
            guard let text = f.text("text") ?? f.text("messages") ?? f.text("q"), !text.isEmpty else { throw MindError(.badRequest, "context takes \"text\": the conversation (or anything) to find the mind's part of.") }
            let c = MindQuery.context(text, in: g, limit: max(1, f.int("limit") ?? 200))
            return .json(["nodes": c.nodes.map(\.description), "lines": c.lines, "count": c.lines.count], summary: "context: \(c.nodes.count) nodes")
        case "prompt":
            guard let messages = f.text("messages") ?? f.text("text"), !messages.isEmpty else { throw MindError(.badRequest, "prompt takes \"messages\": the recent messages, as text.") }
            let c = MindQuery.context(messages, in: g, limit: max(1, f.int("limit") ?? 120))
            let scope = f.text("scope") ?? g.current
            let nodes = c.nodes.isEmpty ? Array(g.nodeList.prefix(60).map(\.id.description)) : c.nodes.map(\.description)
            let text = prompt(scope: scope, nodes: nodes, memory: c.lines, messages: messages)
            return .json(["prompt": text, "text": text, "grammar": grammar, "nodes": nodes, "memory": c.lines,
                          "then": "send the model's reply as {\"text\": \"<its reply>\"} to POST /api/mind/append: the ```mm block's lines are taken, checked, and the new ones added"],
                         summary: "a prompt for \(nodes.count) nodes")
        case "scopes":
            let all = [""] + g.scopes
            return .json(["current": g.current, "scopes": all.map { s in ["name": s.isEmpty ? "(root)" : s, "nodes": g.nodes.keys.filter { $0.scope == s }.count] as [String: Any] }],
                         summary: "\(g.scopes.count) scopes")
        case "graph":
            let scope = f.text("scope").map { $0 == "@" || $0 == "root" ? "" : $0 }
            let nodes = g.nodeList.filter { n in scope.map { n.id.scope == $0 } ?? true }
            let ids = Set(nodes.map(\.id))
            let edges = g.edgeList.filter { ids.contains($0.a) || ids.contains($0.b) }
            return .json(["nodes": nodes.map { nodeJSON($0, in: g, files: files) }, "edges": edges.map(edgeJSON),
                          "comments": g.comments.filter { c in scope.map { c.scope == $0 } ?? true }.map { ["scope": $0.scope, "text": $0.text, "line": $0.line] as [String: Any] },
                          "scopes": g.scopes, "current_scope": g.current], summary: "the graph")
        case "layout":
            let at = MindLayout.positions(g)
            return .json(["positions": g.nodeList.compactMap { n in at[n.id].map { ["node": n.id.description, "x": JSON.round($0.x), "y": JSON.round($0.y)] as [String: Any] } }],
                         summary: "laid out \(at.count) nodes")
        case "log", "canonical":
            let text = op == "log" ? mind.log() : g.canonical
            if f.text("format") == "json" || f.bool("copy") == true || f.bool("present") == true {
                let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
                return .json(["text": text, "lines": lines, "count": lines.count], summary: "the \(op)")
            }
            return .raw(HTTPResponse(status: 200, contentType: "text/plain; charset=utf-8", data: Data(text.utf8)), name: nil, summary: "the \(op)")
        case "problems":
            return .json(["count": g.problems.count, "problems": g.problems.map(problemJSON)], summary: "\(g.problems.count) problems")
        case "check":
            let lines = appendLines()
            guard !lines.isEmpty else { throw MindError(.badRequest, "check takes \"lines\" (a list), or \"text\" with a ```mm block.") }
            do {
                let r = try mind.append(lines, scope: f.text("scope"), partial: true, dryRun: true)
                return .json(["ok_to_add": r.problems.isEmpty, "would_add": r.added, "known": r.known, "problems": r.problems.map(problemJSON), "lines": r.added],
                             summary: "checked \(lines.count) lines")
            }
        case "append":
            let lines = appendLines()
            let comment = f.text("comment")
            guard !lines.isEmpty || !(comment ?? "").isEmpty else {
                throw MindError(.badRequest, "append takes \"lines\" (a list of lines like | sam - writes | paper), or \"text\" (a model's reply with a ```mm block).",
                                fix: "Not sure of the notation? POST /api/mind/add {\"from\": \"sam\", \"label\": \"writes\", \"to\": \"paper\"}")
            }
            let r = try mind.append(lines, scope: f.text("scope"), comment: comment, stamp: stamp, partial: f.bool("partial") ?? false)
            return .json(appended(r), summary: "appended \(r.added.count) lines (\(r.known.count) known)")
        case "add":
            let facts: [[String: Any]] = (f.values["facts"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [f.values]
            let keepCase = f.bool("keep_case") ?? false
            var lines: [String] = []
            var rewritten: [String] = []
            for fact in facts {
                let ff = Fields(values: fact)
                guard let fromText = ff.text("from") ?? ff.text("node") ?? ff.text("name") else {
                    throw MindError(.badRequest, "Each fact has \"from\" (a node), and \"to\" for a link: {\"from\": \"sam\", \"label\": \"writes\", \"to\": \"paper\"}.")
                }
                let from = try name(fromText, in: g, keepCase: keepCase)
                var labels: [String] = []
                for l in (ff.list("labels") ?? []) + [ff.text("label")].compactMap({ $0 }) where !l.isEmpty {
                    let safe = MindNotation.safeText(l)
                    if safe.changed { rewritten.append(l + " → " + safe.text) }
                    if !safe.text.isEmpty { labels.append(safe.text) }
                }
                var notes: [String] = []
                for n in (ff.list("notes") ?? []) + [ff.text("note")].compactMap({ $0 }) where !n.isEmpty {
                    let safe = MindNotation.safeText(n)
                    if safe.changed { rewritten.append(n + " → " + safe.text) }
                    if !safe.text.isEmpty { notes.append(safe.text) }
                }
                if let toText = ff.text("to") {
                    let to = try name(toText, in: g, keepCase: keepCase)
                    let undirected = ff.bool("undirected") == true || ff.bool("directed") == false
                    // Notes on a link go between its names: | a - label @note | b.
                    lines.append(MindNotation.line(from: from, to: to, labels: labels, notes: notes, undirected: undirected))
                } else {
                    guard labels.isEmpty else { throw MindError(.badRequest, "A label needs \"to\": what it links \(fromText) to.") }
                    lines.append("| " + from + notes.map { " @" + $0 }.joined())
                }
            }
            let r = try mind.append(lines, scope: f.text("scope"), stamp: stamp)
            var extra: [String: Any] = [:]
            if !rewritten.isEmpty { extra["rewritten"] = rewritten }
            return .json(appended(r, extra), summary: "added \(r.added.count) lines (\(r.known.count) known)")
        case "note":
            let id = MindQuery.lookup(f.text("name") ?? f.text("node") ?? "", in: g).first
            let written = try id.map { MindNotation.written($0, current: g.current) } ?? name(f.text("name") ?? f.text("node") ?? "", in: g, keepCase: f.bool("keep_case") ?? false)
            guard let note = f.text("note") ?? f.text("text"), !note.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MindError(.badRequest, "note takes \"note\": what it says, its kind first (date 2026-11-03, todo call back).")
            }
            let safe = MindNotation.safeText(note)
            let r = try mind.append(["| \(written) @\(safe.text)"], stamp: stamp)
            return .json(appended(r, safe.changed ? ["rewritten": [note + " → " + safe.text]] : [:]), summary: "noted on \(written)")
        case "rename":
            let id = try node()
            guard let toText = f.text("to") ?? f.text("new_name"), MindNotation.nameProblem(toText) == nil else {
                throw MindError(.badRequest, "rename takes \"to\": the new name (words: no @, and no -, | or = after a space).")
            }
            let to = MindNotation.collapse(toText)
            let r = try mind.append(["| \(MindNotation.written(id, current: g.current)) = \(to)"], stamp: stamp)
            return .json(appended(r, ["name": id.description, "to": to]), summary: "renamed \(id) to \(to)")
        case "forget":
            let id = try node()
            let r = try mind.append(["| \(MindNotation.written(id, current: g.current)) ="], stamp: stamp)
            return .json(appended(r, ["name": id.description]), summary: "forgot \(id)")
        case "comment":
            guard let text = f.text("text") ?? f.text("comment"), !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw MindError(.badRequest, "comment takes \"text\".") }
            let r = try mind.append([], comment: text)
            return .json(appended(r), summary: "a comment")
        case "compact":
            let archived = try mind.compact()
            let after = mind.graph()
            return .json(["archived": archived.path, "lines": after.lines, "nodes": after.nodes.count], summary: "compacted (the old log: \(archived.lastPathComponent))")
        default:
            throw MindError(.badRequest, "There's no mind operation called \(op).", fix: "The operations: \(names) (GET /api/mind says what each takes)")
        }
    }

    /// A name for a line: the mind's own (the same but for case), else in lower case (unless kept).
    static func name(_ text: String, in g: MindGraph, keepCase: Bool) throws -> String {
        let n = try Memory.nodeName(text, in: g)
        if keepCase, MindQuery.lookup(text, in: g).first.map({ MindQuery.fold($0.name) == MindQuery.fold(text) }) != true {
            return MindNotation.collapse(text)
        }
        return n
    }
}
