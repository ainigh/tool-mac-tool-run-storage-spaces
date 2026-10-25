import Foundation

/// MEMORY: an opinionated library. It comes with a file for each kind of thing worth remembering
/// (PEOPLE, ORGANIZATIONS, EVENT-DATES, BIRTHDAYS, LOCATIONS, IDEAS, LEVERAGE, STRATEGIES and
/// OTHERS), and every file in it is a node of the mind, in its root scope: the mind indexes the
/// memory. What's in a file is the detail (a section per person); what's in the mind is how things
/// link (`| PEOPLE | ada lovelace`, `| ada lovelace - works at | acme`).
public struct Memory: Sendable {
    public let files: FileLibrary
    public let mind: MindStore

    public init(files: FileLibrary, mind: MindStore) {
        self.files = files
        self.mind = mind
    }

    /// A file it comes with: its name, what it holds, and how to write in it.
    public struct Default: Sendable {
        public let name: String
        public let holds: String
        public let how: String
        /// A line for the mind, as an example of linking to it.
        public let example: String
    }

    public static let defaults: [Default] = [
        Default(name: "PEOPLE", holds: "Who's who: a section for each person, with how you know them, how to reach them, and what matters to them.",
                how: "## Ada Lovelace\n- met at the 2026 conference; works at Acme\n- likes: short emails, mornings",
                example: "| PEOPLE | ada lovelace\n| ada lovelace - works at | acme"),
        Default(name: "ORGANIZATIONS", holds: "Companies, teams, clubs, agencies: what each does, who you know there, and your history with it.",
                how: "## Acme\n- makes rockets; Ada is the lead engineer\n- account manager: Sam",
                example: "| ORGANIZATIONS | acme\n| acme - employs | ada lovelace"),
        Default(name: "EVENT-DATES", holds: "Things that happen on a day: a line each, the day first (2026-11-03), then what and who.",
                how: "- 2026-11-03 — Ana reviews the paper\n- 2026-12-01 — rent goes up",
                example: "| EVENT-DATES | paper review @date 2026-11-03"),
        Default(name: "BIRTHDAYS", holds: "Birthdays and anniversaries: a line each, the day first (03-14 comes round every year; 1990-03-14 if the year is known).",
                how: "- 03-14 — Ada Lovelace\n- 1988-07-02 — Sam",
                example: "| BIRTHDAYS | ada lovelace @birthday 03-14"),
        Default(name: "LOCATIONS", holds: "Places: addresses, offices, favourite spots, where things are kept.",
                how: "## Acme HQ\n- 1 Rocket Way, Lagos\n- park in the back",
                example: "| LOCATIONS | acme hq\n| acme - is at | acme hq"),
        Default(name: "IDEAS", holds: "Ideas worth keeping: a section each, with where it came from and what would test it.",
                how: "## A newsletter for the club\n- from: the 2026-10 meeting\n- test: ask five members",
                example: "| IDEAS | club newsletter\n| club newsletter - inspired by | sam"),
        Default(name: "LEVERAGE", holds: "What gives you an edge: skills, assets, relationships, favours owed, timing.",
                how: "## Ada owes a favour\n- helped her move in 2026-09",
                example: "| LEVERAGE | ada owes a favour\n| ada owes a favour - about | ada lovelace"),
        Default(name: "STRATEGIES", holds: "Plans and approaches: the goal, the steps, what's been tried and how it went.",
                how: "## Win the Acme contract\n1. intro through Ada\n2. demo in November",
                example: "| STRATEGIES | win the acme contract\n| win the acme contract - uses | ada owes a favour"),
        Default(name: "OTHERS", holds: "Anything that doesn't fit the rest (yet): when a kind of thing keeps coming up here, give it a file of its own.",
                how: "- the wifi password is on the fridge",
                example: "| OTHERS | wifi password @src kitchen"),
    ]

    public static var defaultNames: [String] { defaults.map(\.name) }

    /// A default file's first text.
    public static func text(of d: Default) -> String {
        """
        # \(d.name)

        \(d.holds)

        In the mind, \(d.name) is a node: link what's in here to it, so the mind can find it. For example (not real; write yours below the line):

        ```mm
        \(d.example)
        ```

        ```text
        \(d.how)
        ```

        ---

        """
    }

    public var folderExists: Bool { FileManager.default.fileExists(atPath: files.root.path) }

    /// Makes MEMORY (with its files, the first time) and the mind, and makes each file a node.
    /// Safe to run again: a file already there is left as it is, and one deleted isn't put back
    /// (`addDefaults` does that).
    @discardableResult
    public func ensure() throws -> [String] {
        let isNew = !folderExists
        try files.ensure()
        try mind.ensure()
        if isNew { try addDefaults(index: false) }
        return try mind.index(files)
    }

    /// Puts back any of the files it comes with that isn't there. Returns their names.
    @discardableResult
    public func addDefaults(index: Bool = true) throws -> [String] {
        var added: [String] = []
        for d in Self.defaults where !files.exists(d.name) {
            try files.write(d.name, Self.text(of: d), mode: .create)
            added.append(d.name)
        }
        if index, !added.isEmpty { try mind.index(files) }
        return added
    }

    /// Whether a name is one of the files it comes with.
    public static func isDefault(_ name: String) -> Bool {
        defaults.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: remembering

    public struct Remembered: Sendable {
        /// The file it went in.
        public var file: String
        /// The line (or section) added to the file.
        public var text: String
        /// The lines added to the mind.
        public var mind: [String]
        /// The node it's known by in the mind.
        public var node: String
    }

    /// Remembers something: a line in a file (`category`: PEOPLE…, made if it isn't there), and in
    /// the mind, the category linked to what it's about (`| PEOPLE | ada lovelace`), with any
    /// links and notes given. `about` is how the mind knows it: an existing node of the same name
    /// (but for case) is used as it is; a new one is written in lower case, as the notation's
    /// convention has it.
    @discardableResult
    public func remember(category: String, about: String, text: String?, links: [(label: String?, to: String, category: String?)] = [],
                         notes: [String] = [], who: String? = nil) throws -> Remembered {
        let file = try files.find(category)?.name ?? files.key(category)
        if !files.exists(file) { try files.write(file, "# \(file)\n\n", mode: .create) }
        let g = mind.exists ? mind.graph() : MindGraph()
        let node = try Self.nodeName(about, in: g)
        var lines = ["| " + MindNotation.written(MindNodeID(file), current: g.current) + " | " + node]
        let safeNotes = notes.map { MindNotation.safeText($0).text }.filter { !$0.isEmpty }
        if !safeNotes.isEmpty { lines.append("| " + node + safeNotes.map { " @" + $0 }.joined()) }
        for link in links {
            let to = try Self.nodeName(link.to, in: g)
            let label = link.label.map { MindNotation.safeText($0).text }.flatMap { $0.isEmpty ? nil : $0 }
            lines.append(MindNotation.line(from: node, to: to, labels: label.map { [$0] } ?? []))
            if let c = link.category {
                let cat = try files.find(c)?.name ?? files.key(c)
                if !files.exists(cat) { try files.write(cat, "# \(cat)\n\n", mode: .create) }
                lines.append("| " + MindNotation.written(MindNodeID(cat), current: g.current) + " | " + to)
            }
        }
        var added = ""
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            added = t.contains("\n") || t.hasPrefix("#") ? t : "- \(about): \(t)"
            try files.append(file, added)
        }
        try mind.index(files)
        let r = try mind.append(lines, stamp: MindStore.stamp(who))
        return Remembered(file: file, text: added, mind: r.added, node: node)
    }

    /// The name a node is written with: one the mind has (the same but for case and spaces)
    /// as it is, else in lower case. Throws when it can't be a name.
    public static func nodeName(_ text: String, in g: MindGraph) throws -> String {
        let t = MindNotation.collapse(text)
        if let why = MindNotation.nameProblem(t) { throw MindError(.badRequest, why, fix: "A name is words: no @, and no -, | or = after a space.") }
        if let there = MindQuery.lookup(t, in: g).first(where: { MindQuery.fold($0.name) == MindQuery.fold(t) && $0.scope == g.current }) {
            return there.name
        }
        if let there = MindQuery.lookup(t, in: g).first(where: { MindQuery.fold($0.name) == MindQuery.fold(t) }) {
            return MindNotation.written(there, current: g.current)
        }
        return t.lowercased()
    }

    // MARK: recalling

    public struct Recalled: Sendable {
        /// The nodes it could mean, the likeliest first.
        public var nodes: [MindNodeID]
        public var about: [MindQuery.About]
        /// The lines in MEMORY's files with it on them.
        public var mentions: [FileLibrary.Hit]
        /// The files it's in (the categories linked to it).
        public var categories: [String]
    }

    /// What's known about a name: its node (what it links to, its notes), the MEMORY files it's
    /// filed under, and the lines that mention it in them.
    public func recall(_ name: String) -> Recalled {
        let g = mind.graph()
        let ids = MindQuery.lookup(name, in: g)
        let about = ids.prefix(3).compactMap { MindQuery.about($0, in: g) }
        let fileNames = Set(files.names())
        var categories: [String] = []
        for a in about {
            for l in a.links where l.node.isRoot && fileNames.contains(l.node.name) && !categories.contains(l.node.name) { categories.append(l.node.name) }
        }
        let words = ids.first?.name ?? name
        let mentions = files.search("\"\(words)\"", .init(lines: 5))
        return Recalled(nodes: ids, about: about, mentions: mentions, categories: categories)
    }

    /// The nodes filed under a category (linked from it, or to it with no direction), A to Z.
    public func members(of category: String) -> [MindNodeID] {
        let g = mind.graph()
        let name = files.find(category)?.name ?? category
        let id = MindNodeID(name)
        guard g.node(id) != nil else { return [] }
        return g.edges(at: id).filter { $0.leads(from: id) }.map { $0.other(id) }.filter { $0 != id }.sorted()
    }

    /// The days coming up: notes in the mind with a day in them, and lines in EVENT-DATES and
    /// BIRTHDAYS (any MEMORY file, really) that start with one. The soonest first.
    public func upcoming(days: Int = 30, today: Date = Date(), calendar: Calendar = .current) -> [(day: Date, days: Int, what: String, source: String, yearly: Bool)] {
        var out: [(Date, Int, String, String, Bool)] = []
        let g = mind.graph()
        for d in MindQuery.dates(in: g, today: today, days: days, calendar: calendar) {
            let what = d.edge.map { MindGraph.line($0, current: "") } ?? "\(d.id.description): \(d.note)"
            out.append((d.day, d.days, what, "mind", d.yearly))
        }
        let start = calendar.startOfDay(for: today)
        for note in files.list() {
            guard let text = try? files.read(note.name).text else { continue }
            let birthdays = MindQuery.fold(note.name).contains("birthday")
            var fenced = false
            for raw in text.components(separatedBy: "\n") {
                var line = raw.trimmingCharacters(in: .whitespaces)
                // Examples in a fence aren't days.
                if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
                if fenced { continue }
                for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) { line = String(line.dropFirst(2)) }
                guard let first = line.split(separator: " ").first, let (month, day, year) = MindQuery.dayIn(String(first)) else { continue }
                let yearly = year == nil || birthdays
                let thisYear = calendar.component(.year, from: start)
                let candidates = yearly ? [thisYear, thisYear + 1] : [year!]
                for y in candidates {
                    guard let when = calendar.date(from: DateComponents(year: y, month: month, day: day)) else { continue }
                    let n = calendar.dateComponents([.day], from: start, to: when).day ?? 0
                    if n >= 0 {
                        if n <= days { out.append((when, n, line, note.name, yearly)) }
                        break
                    }
                }
            }
        }
        return out.sorted { ($0.1, $0.2) < ($1.1, $1.2) }
    }
}
