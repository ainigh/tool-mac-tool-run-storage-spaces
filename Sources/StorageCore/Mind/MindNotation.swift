import Foundation

/// The text mind-map notation (docs/Text mind-map notation.md): an append-only log of lines that
/// compiles to a graph. A line starting with `|` is a statement, anything else a comment. Four
/// symbols (`|` `-` `@` `=`), each active only after whitespace (or first on the line), so
/// `well-known` and `2026-11-03` are plain text. This is the parser: a line in, a statement (or
/// the mistake, with its fix) out. `MindGraph` compiles statements; `MindStore` keeps the log.
public enum MindNotation {
    /// Which scope a name is in.
    public enum ScopeRef: Equatable, Sendable {
        /// Unqualified: the current scope.
        case current
        /// `name@`: the root scope.
        case root
        /// `name@scope`.
        case named(String)
    }

    /// A name as written: its text, and which scope it means.
    public struct NameRef: Equatable, Sendable {
        public var name: String
        public var scope: ScopeRef

        public init(_ name: String, scope: ScopeRef = .current) {
            self.name = name
            self.scope = scope
        }
    }

    /// The part between two names: its labels, its notes, and whether it's undirected (`- |`).
    public struct Link: Equatable, Sendable {
        public var labels: [String] = []
        public var notes: [String] = []
        public var undirected = false

        public init(labels: [String] = [], notes: [String] = [], undirected: Bool = false) {
            self.labels = labels
            self.notes = notes
            self.undirected = undirected
        }
    }

    public enum Statement: Equatable, Sendable {
        /// `| @ name`: switch the current scope.
        case scope(String)
        /// `| @ a = @ b`: move everything in `a` into `b`.
        case mergeScope(String, into: String)
        /// `| @ a =`: remove scope `a` with everything in it.
        case deleteScope(String)
        /// `| a - label | b @note`: names, the links between them (one fewer), and notes on the last name.
        case path(names: [NameRef], links: [Link], notes: [String])
        /// `| old = new`, or `| old =` (no new: removed).
        case edit(NameRef, NameRef?)
    }

    /// A line, read: a comment, a statement, or a blank line (ignored).
    public enum Line: Equatable, Sendable {
        case blank
        case comment(String)
        case statement(Statement)
    }

    /// A mistake on a line: what's wrong, and what to write instead.
    public struct Mistake: Error, Equatable, Sendable, CustomStringConvertible {
        public var message: String
        public var fix: String

        public init(_ message: String, fix: String) {
            self.message = message
            self.fix = fix
        }

        public var description: String { "\(message) \(fix)" }
    }

    /// The four symbols.
    public static let symbols: Set<Character> = ["|", "-", "@", "="]

    /// Trimmed, with every run of whitespace one space.
    public static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Reads one line of the log.
    public static func parse(_ raw: String) throws -> Line {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return .blank }
        guard line.first == "|" else { return .comment(collapse(line)) }
        return .statement(try statement(String(line.dropFirst())))
    }

    /// The text after the leading `|`, as its first text and then each active symbol with its text.
    static func tokens(_ body: String) -> (head: String, rest: [(symbol: Character, text: String)]) {
        var head = ""
        var rest: [(Character, String)] = []
        var current = ""
        var afterSpace = true  // right after the statement marker counts as the start
        for c in body {
            if afterSpace, symbols.contains(c) {
                if rest.isEmpty { head = current } else { rest[rest.count - 1].1 = current }
                rest.append((c, ""))
                current = ""
                afterSpace = false
                continue
            }
            current.append(c)
            afterSpace = c.isWhitespace
        }
        if rest.isEmpty { head = current } else { rest[rest.count - 1].1 = current }
        return (collapse(head), rest.map { ($0.0, collapse($0.1)) })
    }

    static func statement(_ body: String) throws -> Statement {
        let (head, rest) = tokens(body)
        if head.isEmpty {
            guard let first = rest.first else {
                throw Mistake("A `|` with nothing after it.", fix: "Write a name after it: | sam")
            }
            if first.symbol == "@" { return try scopeStatement(rest) }
            throw Mistake("A statement starts with a name, not `\(first.symbol)`.", fix: "Write the name first: | sam - writes | paper")
        }
        let first = try name(head)
        // `old = new`: an edit.
        if let eq = rest.first, eq.symbol == "=" {
            guard rest.count == 1 else {
                throw Mistake("An edit is `old = new` (or `old =`), nothing after it.", fix: "Put anything else on a line of its own: | \(head) = \(eq.text)")
            }
            return .edit(first, eq.text.isEmpty ? nil : try name(eq.text))
        }
        var names = [first]
        var links: [Link] = []
        var link = Link()
        var pendingDash = false
        for (symbol, text) in rest {
            if pendingDash, symbol != "|" {
                throw Mistake("A `-` with nothing after it must come right before `|` (it makes the link undirected).", fix: "Write a label after the `-`, or put `- |` together: | idea - | notes")
            }
            switch symbol {
            case "-":
                if text.isEmpty { pendingDash = true } else { link.labels.append(text) }
            case "@":
                guard !text.isEmpty else { throw Mistake("A note `@` needs text after it.", fix: "Write what the note says: | paper @date 2026-11-03") }
                link.notes.append(text)
            case "|":
                guard !text.isEmpty else { throw Mistake("`|` needs a name after it.", fix: "Write the name it links to: | sam | paper") }
                link.undirected = pendingDash
                pendingDash = false
                links.append(link)
                link = Link()
                names.append(try name(text))
            case "=":
                throw Mistake("`=` comes right after the first name (`old = new`), not in a path.", fix: "Put the edit on a line of its own: | old = new")
            default:
                break
            }
        }
        if pendingDash || !link.labels.isEmpty {
            throw Mistake("A label needs `|` and a name after it.", fix: "Say what it links to: | \(head) - \(link.labels.first ?? "knows") | someone")
        }
        return .path(names: names, links: links, notes: link.notes)
    }

    static func scopeStatement(_ rest: [(symbol: Character, text: String)]) throws -> Statement {
        let scopeFix = "A scope line is `| @ name`, `| @ old = @ new` or `| @ name =`."
        guard !rest[0].text.isEmpty else { throw Mistake("A scope needs a name.", fix: scopeFix) }
        let a = rest[0].text
        if rest.count == 1 { return .scope(a) }
        guard rest[1].symbol == "=", rest[1].text.isEmpty else { throw Mistake("After `| @ \(a)` only `=` may come.", fix: scopeFix) }
        if rest.count == 2 { return .deleteScope(a) }
        guard rest.count == 3, rest[2].symbol == "@", !rest[2].text.isEmpty else { throw Mistake("A scope merges into another scope: `| @ \(a) = @ other`.", fix: scopeFix) }
        return .mergeScope(a, into: rest[2].text)
    }

    /// A name's text: `name`, `name@scope`, or `name@` (the root scope).
    static func name(_ text: String) throws -> NameRef {
        guard let at = text.firstIndex(of: "@") else { return NameRef(text) }
        let n = collapse(String(text[..<at]))
        let s = collapse(String(text[text.index(after: at)...]))
        guard !n.isEmpty else { throw Mistake("\"\(text)\" has no name before its `@`.", fix: "Write the name, then @ and its scope: slides@talk") }
        guard !s.contains("@") else { throw Mistake("\"\(text)\" has more than one `@`.", fix: "A name has at most one: name@scope (put emails and handles in notes)") }
        return NameRef(n, scope: s.isEmpty ? .root : .named(s))
    }

    // MARK: writing it

    /// Why a text can't be a name (nil: it can): it's empty, has an `@` (that names a scope), or
    /// has a symbol after a space (` -` would start a label).
    public static func nameProblem(_ text: String) -> String? {
        let t = collapse(text)
        if t.isEmpty { return "A name can't be empty." }
        if t.contains("@") { return "\"\(t)\" has an @ in it: in the mind, @ names a scope (put emails and handles in a note)." }
        if let bad = activeSymbol(in: t) { return "\"\(t)\" has \"\(bad)\" after a space (or first), which the notation reads as a symbol: write it without the space (well-known), or with other words." }
        return nil
    }

    /// The first symbol in `text` that would be active (after whitespace, or first).
    static func activeSymbol(in text: String) -> Character? {
        var afterSpace = true
        for c in text {
            if afterSpace, symbols.contains(c) { return c }
            afterSpace = c.isWhitespace
        }
        return nil
    }

    /// A label's or a note's text, made safe to write: a symbol after a space would start
    /// something else, so ` - ` becomes ` – `, ` | ` ` / `, ` @` ` at `, ` = ` ` is `. Returns the
    /// text and whether it had to change.
    public static func safeText(_ text: String) -> (text: String, changed: Bool) {
        var out = ""
        var afterSpace = true
        var changed = false
        for c in collapse(text) {
            if afterSpace, symbols.contains(c) {
                changed = true
                switch c {
                case "-": out.append("–")
                case "|": out.append("/")
                case "@": out.append("at ")
                default: out.append("is")
                }
                afterSpace = false
                continue
            }
            out.append(c)
            afterSpace = c.isWhitespace
        }
        return (collapse(out), changed)
    }

    /// How a name is written in a line whose current scope is `current`.
    public static func written(_ id: MindNodeID, current: String) -> String {
        if id.scope == current { return id.name }
        return id.name + "@" + id.scope
    }

    /// The line for a path: `| a - label @note | b`.
    public static func line(from a: String, to b: String, labels: [String] = [], notes: [String] = [], undirected: Bool = false) -> String {
        var s = "| " + a
        for l in labels { s += " - " + l }
        for n in notes { s += " @" + n }
        s += undirected ? " - | " : " | "
        return s + b
    }

    /// Lines from a model: only those starting with `|`, the `-|` variants written `- |`, inside
    /// an ```mm block if there is one.
    public static func normalize(_ text: String) -> [String] {
        var lines = text.components(separatedBy: .newlines)
        if let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            let after = lines[(open + 1)...]
            let close = after.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") } ?? lines.endIndex
            lines = Array(lines[(open + 1)..<close])
        }
        return lines.compactMap { raw in
            var l = raw.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("|") else { return nil }
            l = l.replacingOccurrences(of: #"\s-\s*\|"#, with: " - |", options: .regularExpression)
            return collapse(l)
        }
    }
}
