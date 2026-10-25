import Foundation

/// MEMORY's own operations, beside the library's (which it has too: it's a library).
public enum MemoryAPI {
    public static let operations: [Operation] = [
        .init(name: "remember", summary: "remembers something: a line in a file (PEOPLE…) and, in the mind, the file linked to what it's about, with links and notes",
              fields: ["category: PEOPLE|ORGANIZATIONS|…", "about: the name", "text?", "links?: [{label?, to, category?}]", "notes?: [\"birthday 03-14\"]"], route: "POST /api/memory/remember", changes: true),
        .init(name: "recall", summary: "what's known about a name: its node in the mind (links, notes), the files it's filed under, the lines that mention it",
              fields: ["name"], route: "GET /api/memory/recall?name=…", changes: false),
        .init(name: "categories", summary: "every file, whether it's one MEMORY comes with, and how many things the mind files under it", fields: [], route: "GET /api/memory/categories", changes: false),
        .init(name: "members", summary: "what the mind files under a category (PEOPLE: the people)", fields: ["name"], route: "GET /api/memory/categories/{name}/members", changes: false),
        .init(name: "upcoming", summary: "the days coming up: dated notes in the mind, and lines in EVENT-DATES, BIRTHDAYS (any file) that start with a day",
              fields: ["days?: 30"], route: "GET /api/memory/upcoming", changes: false),
        .init(name: "sync", summary: "makes each file a node of the mind (the ones that aren't yet)", fields: [], route: "POST /api/memory/sync", changes: true),
        .init(name: "defaults", summary: "puts back any of the files MEMORY comes with that isn't there", fields: [], route: "POST /api/memory/defaults", changes: true),
    ]

    static let byName: [String: Operation] = Dictionary(uniqueKeysWithValues: operations.map { ($0.name, $0) })

    static func perform(_ op: String, _ f: Fields, memory: Memory, client: String) throws -> [String: Any] {
        switch op {
        case "remember":
            guard let category = f.text("category") ?? f.text("file") ?? f.text("in") else {
                throw MindError(.badRequest, "remember takes \"category\": the file it goes in (\(Memory.defaultNames.joined(separator: ", "))).")
            }
            guard let about = f.text("about") ?? f.text("name") ?? f.text("node") else {
                throw MindError(.badRequest, "remember takes \"about\": who or what it's about (\"Ada Lovelace\").")
            }
            var links: [(label: String?, to: String, category: String?)] = []
            for l in (f.values["links"] as? [Any]) ?? [] {
                if let d = l as? [String: Any], let to = Fields.text(d["to"]) {
                    links.append((Fields.text(d["label"]), to, Fields.text(d["category"])))
                } else if let to = Fields.text(l) {
                    links.append((nil, to, nil))
                }
            }
            let r = try memory.remember(category: category, about: about, text: f.text("text"), links: links, notes: f.list("notes") ?? f.list("note") ?? [], who: client)
            return ["name": r.file, "file": r.file, "node": r.node, "added_to_file": r.text, "added_to_mind": r.mind]
        case "recall":
            let name = try f.name()
            let r = memory.recall(name)
            let files = Set(memory.files.names())
            return ["name": name, "found": !r.nodes.isEmpty || !r.mentions.isEmpty, "nodes": r.nodes.map { MindAPI.nodeJSON($0, files: files) },
                    "about": r.about.map { MindAPI.aboutJSON($0, files: files) }, "categories": r.categories,
                    "mentions": r.mentions.map(LibraryAPI.hitJSON),
                    "lines": r.about.flatMap(\.lines) + r.mentions.flatMap { h in h.lines.map { "\(h.note.name), line \($0.number): \($0.text)" } }]
        case "categories":
            return ["categories": memory.files.list().map { n -> [String: Any] in
                ["name": n.name, "default": Memory.isDefault(n.name), "members": memory.members(of: n.name).count, "size": n.size, "modified": JSON.date(n.modified)]
            }]
        case "members":
            let name = try f.name()
            guard let file = memory.files.find(name) else {
                throw LibraryError(.notFound, "There's no memory file called \(name).", fix: "The files: " + memory.files.names().joined(separator: ", "))
            }
            let ids = memory.members(of: file.name)
            return ["name": file.name, "count": ids.count, "members": ids.map(\.description)]
        case "upcoming":
            let days = max(0, min(3660, f.int("days") ?? 30))
            let list = memory.upcoming(days: days)
            return ["days": days, "count": list.count, "upcoming": list.map { ["day": JSON.day($0.day), "in_days": $0.days, "what": $0.what, "source": $0.source, "yearly": $0.yearly] as [String: Any] },
                    "lines": list.map { "\(JSON.day($0.day)) (in \($0.days) day\($0.days == 1 ? "" : "s")): \($0.what) — \($0.source)" }]
        case "sync":
            let added = try memory.mind.index(memory.files, who: client)
            return ["added_to_mind": added, "count": added.count]
        case "defaults":
            let added = try memory.addDefaults()
            return ["added": added, "count": added.count]
        default:
            throw LibraryError(.badName, "There's no memory operation called \(op).")
        }
    }

    static func memorySummary(_ op: String, _ out: [String: Any]) -> String {
        switch op {
        case "remember": return "remembered \(out["node"] ?? "") in \(out["file"] ?? "")"
        case "recall": return "recalled \(out["name"] ?? "")"
        case "members": return "\(out["count"] ?? 0) in \(out["name"] ?? "")"
        case "upcoming": return "\(out["count"] ?? 0) in the next \(out["days"] ?? 30) days"
        case "sync": return "\(out["count"] ?? 0) files made nodes"
        case "defaults": return "put back \(out["count"] ?? 0) files"
        default: return op
        }
    }
}
