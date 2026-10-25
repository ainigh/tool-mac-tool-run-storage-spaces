import Foundation
@testable import StorageCore
import XCTest

/// The text mind-map notation (docs/Text mind-map notation.md): its lines, its graph, its
/// canonical form, its queries; the mind on disk (append only); and MEMORY, which it indexes.
final class MindTests: XCTestCase {
    /// The notation's own example (its section 7), line for line.
    static let example = """
    plan for the paper
    | idea | draft | review
    | idea - inspired by - | notes
    | notes - cites - supports | draft
    | draft - sent on @date 2026-11-03 | review
    | review | draft
    | review @owner sam @tag weekly
    | well-known | q&a
    this line was a mistake
    | this line was a mistake =
    | draft = manuscript
    | draft | manuscript
    | notes =
    | @ talk
    | outline | slides
    | manuscript@ - feeds | outline
    | @ meeting
    | sam | slides@talk
    | @ talk = @ meeting
    """

    func testTheNotationsOwnExampleCompilesToWhatItSays() throws {
        let g = MindGraph(log: Self.example)
        XCTAssertEqual(g.problems, [])
        let root = Set(g.nodes.keys.filter(\.isRoot).map(\.name))
        XCTAssertEqual(root, ["idea", "manuscript", "review", "well-known", "q&a", "draft"])
        XCTAssertEqual(g.scopes, ["meeting"], "talk was merged into meeting")
        XCTAssertEqual(g.current, "meeting")
        let m = MindNodeID("manuscript"), r = MindNodeID("review")
        let e = try XCTUnwrap(g.edge(m, r))
        XCTAssertTrue(e.forward && e.backward, "two-way: draft→review, then review→draft, both renamed")
        XCTAssertEqual(e.labels, ["sent on"])
        XCTAssertEqual(e.notes, ["date 2026-11-03"])
        XCTAssertNotNil(g.edge(MindNodeID("idea"), m))
        XCTAssertTrue(g.edge(MindNodeID("idea"), m)!.leads(from: MindNodeID("idea")))
        XCTAssertNotNil(g.edge(MindNodeID("draft"), m))
        XCTAssertNotNil(g.edge(MindNodeID("well-known"), MindNodeID("q&a")))
        XCTAssertEqual(g.node(r)?.notes, ["owner sam", "tag weekly"])
        XCTAssertNil(g.node(MindNodeID("notes")), "notes = removed it, with its edges")
        XCTAssertEqual(g.edges.count, 7)
        XCTAssertEqual(g.comments.map(\.text), ["plan for the paper"], "the mistaken comment was removed by its edit")
        let outline = MindNodeID("outline", scope: "meeting"), slides = MindNodeID("slides", scope: "meeting")
        XCTAssertNotNil(g.edge(outline, slides))
        XCTAssertNotNil(g.edge(MindNodeID("sam", scope: "meeting"), slides))
        XCTAssertEqual(g.edge(m, outline)?.labels, ["feeds"])
    }

    func testTheCanonicalFormIsTheSameMind() {
        let g = MindGraph(log: Self.example)
        let again = MindGraph(log: g.canonical)
        XCTAssertEqual(again.problems, [], g.canonical)
        XCTAssertEqual(again.canonical, g.canonical)
        XCTAssertEqual(Set(again.nodes.keys), Set(g.nodes.keys))
        XCTAssertEqual(again.edges.count, g.edges.count)
        XCTAssertTrue(g.canonical.contains("| manuscript - sent on @date 2026-11-03 | review | manuscript"), g.canonical)
        XCTAssertTrue(g.canonical.contains("| manuscript@ - feeds | outline"), "a root node, from the meeting scope: \(g.canonical)")
    }

    func testSymbolsAreOnlySymbolsAfterASpace() throws {
        guard case .statement(.path(let names, let links, let notes)) = try MindNotation.parse("|  well-known   |  a=b  @date 2026-11-03") else { return XCTFail() }
        XCTAssertEqual(names.map(\.name), ["well-known", "a=b"])
        XCTAssertEqual(links, [MindNotation.Link()])
        XCTAssertEqual(notes, ["date 2026-11-03"])
        XCTAssertEqual(try MindNotation.parse("just words"), .comment("just words"))
        XCTAssertEqual(try MindNotation.parse("   "), .blank)
        XCTAssertEqual(try MindNotation.parse("| @ a = @ b"), .statement(.mergeScope("a", into: "b")))
        XCTAssertEqual(try MindNotation.parse("| @ a ="), .statement(.deleteScope("a")))
        XCTAssertEqual(try MindNotation.parse("| x@ = y@s"), .statement(.edit(.init("x", scope: .root), .init("y", scope: .named("s")))))
    }

    func testMistakesSayTheFixAndChangeNothing() {
        for bad in ["|", "| a |", "| a - label", "| a - | ", "| a - b - c", "| - x | y", "| a @", "| a = b | c", "| x@nowhere | y", "| @", "| @ a = b"] {
            var g = MindGraph()
            XCTAssertThrowsError(try g.apply(bad), bad) { e in
                let m = e as? MindNotation.Mistake
                XCTAssertNotNil(m, bad)
                XCTAssertFalse(m?.fix.isEmpty ?? true, bad)
            }
            XCTAssertTrue(g.nodes.isEmpty, bad)
        }
        let g = MindGraph(log: "| a | b\n| c - d\n| e")
        XCTAssertEqual(g.problems.map(\.line), [2])
        XCTAssertEqual(g.nodes.count, 3, "the lines around it still count")
    }

    func testUndirectedAndDirectedMerge() throws {
        let g = MindGraph(log: "| a - knows - | b\n| b | a\n| c - | d")
        let ab = try XCTUnwrap(g.edge(MindNodeID("a"), MindNodeID("b")))
        XCTAssertTrue(ab.leads(from: MindNodeID("b")))
        XCTAssertFalse(ab.leads(from: MindNodeID("a")), "undirected ∪ b→a is b→a")
        XCTAssertTrue(g.edge(MindNodeID("c"), MindNodeID("d"))!.undirected)
    }

    func testQueriesInTheNotation() {
        let g = MindGraph(log: """
        | sam - writes | paper
        | ana - reviews | paper
        | paper @date 2026-11-03 review by ana
        | sam | talk
        """)
        let from = MindQuery.run("| sam | x", in: g)[0]
        XCTAssertEqual(from.variables, ["x"])
        XCTAssertEqual(Set(from.matches.compactMap { $0.bindings["x"]?.name }), ["paper", "talk"])
        let reviews = MindQuery.run("| x - reviews | y", in: g)[0]
        XCTAssertEqual(reviews.lines, ["| ana - reviews | paper"])
        let notes = MindQuery.run("| paper @x", in: g)[0]
        XCTAssertEqual(notes.lines, ["| paper @date 2026-11-03 review by ana"])
        let dated = MindQuery.run("| paper @date", in: g)[0]
        XCTAssertEqual(dated.lines.count, 1, "a note's kind finds it")
        let block = MindQuery.run("```mmq\n| x - writes | paper\n| @ nowhere\n```", in: g)
        XCTAssertEqual(block.count, 2)
        XCTAssertEqual(block[0].matches.first?.bindings["x"]?.name, "sam")
        XCTAssertNotNil(block[1].problem)
        let all = MindQuery.run("| sam", in: g)[0]
        XCTAssertEqual(all.lines.count, 2)
    }

    func testTheUsualQuestions() throws {
        let g = MindGraph(log: """
        | PEOPLE | ada lovelace
        | ada lovelace - works at | acme
        | acme - is at | lagos
        | ada lovelace @birthday 03-14
        | review @date 2026-11-03
        """)
        XCTAssertEqual(MindQuery.lookup("Ada Lovelace", in: g), [MindNodeID("ada lovelace")])
        XCTAssertEqual(MindQuery.lookup("the acmes", in: g), [MindNodeID("acme")])
        XCTAssertEqual(MindQuery.lookup("ada lovelaec", in: g), [MindNodeID("ada lovelace")])
        let about = try XCTUnwrap(MindQuery.about(MindNodeID("ada lovelace"), in: g))
        XCTAssertEqual(about.notes, ["birthday 03-14"])
        XCTAssertEqual(Set(about.links.map(\.direction)), ["in", "out"])
        XCTAssertEqual(MindQuery.neighbours(MindNodeID("ada lovelace"), in: g, depth: 2).map(\.id.name), ["PEOPLE", "acme", "lagos"])
        XCTAssertEqual(MindQuery.path(from: MindNodeID("PEOPLE"), to: MindNodeID("lagos"), in: g)?.nodes.map(\.name), ["PEOPLE", "ada lovelace", "acme", "lagos"])
        XCTAssertNil(MindQuery.path(from: MindNodeID("lagos"), to: MindNodeID("PEOPLE"), in: g, direction: .out))
        XCTAssertEqual(MindQuery.find("acme", in: g).first?.id.name, "acme")
        XCTAssertEqual(MindQuery.edges(labelled: "Works At", in: g).count, 1)
        XCTAssertEqual(MindQuery.notes(kind: "birthday", in: g).count, 1)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 24))!
        let soon = MindQuery.dates(in: g, today: today, days: 30, calendar: cal)
        XCTAssertEqual(soon.map(\.id.name), ["review"])
        XCTAssertEqual(soon.first?.days, 10)
        let year = MindQuery.dates(in: g, today: today, days: 200, calendar: cal)
        XCTAssertEqual(year.last?.id.name, "ada lovelace")
        XCTAssertEqual(year.last?.yearly, true)

        let ctx = MindQuery.context("Did Ada Lovelace call back?", in: g)
        XCTAssertTrue(ctx.nodes.contains(MindNodeID("acme")))
        XCTAssertTrue(ctx.lines.contains("| ada lovelace - works at | acme"))
    }

    func testTheLayoutIsTheSameEveryTime() {
        let g = MindGraph(log: Self.example)
        let one = MindLayout.positions(g)
        let two = MindLayout.positions(g)
        XCTAssertEqual(one, two)
        XCTAssertEqual(one.count, g.nodes.count)
        XCTAssertTrue(one.values.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        let pinned = MindLayout.positions(g, fixed: [MindNodeID("idea"): .init(x: 0.1, y: 0.2)])
        XCTAssertEqual(pinned[MindNodeID("idea")], .init(x: 0.1, y: 0.2))
    }

    func testNamesAndTextMadeSafe() {
        XCTAssertNil(MindNotation.nameProblem("well-known"))
        XCTAssertNil(MindNotation.nameProblem("EVENT-DATES"))
        XCTAssertNotNil(MindNotation.nameProblem("a - b"))
        XCTAssertNotNil(MindNotation.nameProblem("me@example.com"))
        XCTAssertNotNil(MindNotation.nameProblem("-x"))
        XCTAssertEqual(MindNotation.safeText("met at 3 - then | left @ noon = fun").text, "met at 3 – then / left at noon is fun")
        XCTAssertEqual(MindNotation.normalize("Sure!\n```mm\n| a -| b\nnot a line\n|  c   |  d\n```\nbye"), ["| a - | b", "| c | d"])
    }
}

/// The mind on disk, and MEMORY.
final class MindStoreTests: XCTestCase {
    var home: URL!
    var memory: Memory!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tmr-home-\(UUID().uuidString)", isDirectory: true)
        memory = Memory(files: FileLibrary(root: home.appendingPathComponent("MEMORY"), shelf: .memory),
                        mind: MindStore(root: home.appendingPathComponent("MIND")))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testAppendingOnlyAddsWhatsNewAndAMistakeAddsNothing() throws {
        let mind = memory.mind
        let r = try mind.append(["| sam - writes | paper", "| ana | paper"], stamp: MindStore.stamp("Test"))
        XCTAssertEqual(r.added, ["| sam - writes | paper", "| ana | paper"])
        XCTAssertTrue(mind.log().hasPrefix(MindStore.seed), "it starts with what it is")
        XCTAssertTrue(r.written.first?.hasPrefix("— ") == true, "the stamp comes first")
        let again = try mind.append(["| sam - writes | paper", "| sam | paper @date 2026-11-03"])
        XCTAssertEqual(again.known, ["| sam - writes | paper"])
        XCTAssertEqual(again.added, ["| sam | paper @date 2026-11-03"])
        let before = mind.log()
        XCTAssertThrowsError(try mind.append(["| ok | fine", "| broken -"])) { e in
            XCTAssertEqual((e as? MindError)?.code, .badLines)
            XCTAssertEqual((e as? MindError)?.problems.count, 1)
        }
        XCTAssertEqual(mind.log(), before, "nothing was written")
        XCTAssertThrowsError(try mind.append(["plain words"]), "a line that isn't a statement is a mistake here")
        let partial = try mind.append(["| ok | fine", "| broken -"], partial: true)
        XCTAssertEqual(partial.added, ["| ok | fine"])
        XCTAssertEqual(partial.problems.count, 1)
        let nothing = try mind.append(["| ok | fine"], stamp: "— later")
        XCTAssertTrue(nothing.written.isEmpty, "nothing new: not even the stamp")
    }

    func testScopesAndTheThingsOnlyThePersonDoes() throws {
        let mind = memory.mind
        try mind.append(["| a | b"], scope: "work")
        XCTAssertEqual(mind.graph().current, "work")
        try mind.append(["| c | d"], scope: "work")
        XCTAssertEqual(mind.log().components(separatedBy: "| @ work").count, 2, "already in it: no second scope line")
        XCTAssertThrowsError(try mind.append(["| @ work ="]))
        XCTAssertThrowsError(try mind.append(["| x | y"], scope: "")) { e in
            XCTAssertTrue((e as? MindError)?.fix?.contains("@") == true)
        }
        try mind.append(["| @ work ="], scopeChanges: true)
        XCTAssertTrue(mind.graph().nodes.isEmpty)
    }

    func testCompactingKeepsTheOldLog() throws {
        let mind = memory.mind
        try mind.append(["| a | b", "| a = c", "| c | b"])
        let old = mind.log()
        let archived = try mind.compact()
        XCTAssertEqual(try String(contentsOf: archived, encoding: .utf8), old)
        XCTAssertEqual(mind.graph().canonical, MindGraph(log: old).canonical)
        XCTAssertEqual(mind.archived().map(\.lastPathComponent), [archived.lastPathComponent])
    }

    func testMemoryComesWithItsFilesEachANode() throws {
        let added = try memory.ensure()
        XCTAssertEqual(Set(memory.files.names()), Set(Memory.defaultNames))
        XCTAssertEqual(Set(added.map { $0.replacingOccurrences(of: "| ", with: "") }), Set(Memory.defaultNames))
        let g = memory.mind.graph()
        for name in Memory.defaultNames { XCTAssertNotNil(g.node(MindNodeID(name)), name) }
        XCTAssertEqual(try memory.ensure(), [], "safe to run again")
        // A file deleted isn't put back by ensure, but is by addDefaults.
        try memory.files.delete("OTHERS")
        XCTAssertEqual(try memory.ensure(), [])
        XCTAssertFalse(memory.files.exists("OTHERS"))
        XCTAssertEqual(try memory.addDefaults(), ["OTHERS"])
        // A file of its own is a node too, once indexed.
        try memory.files.write("Recipes", "# Recipes\n")
        XCTAssertEqual(try memory.mind.index(memory.files), ["| Recipes"])
        // A name the mind can't have can't be a memory file.
        XCTAssertThrowsError(try memory.files.write("me@home", "x")) { e in XCTAssertEqual((e as? LibraryError)?.code, .badName) }
        XCTAssertThrowsError(try memory.files.write("a - b", "x"))
        // Renamed: the node follows.
        _ = try memory.files.rename("Recipes", to: "COOKING")
        try memory.mind.renamed("Recipes", to: "COOKING")
        XCTAssertNotNil(memory.mind.graph().node(MindNodeID("COOKING")))
        XCTAssertNil(memory.mind.graph().node(MindNodeID("Recipes")))
    }

    func testRememberAndRecall() throws {
        try memory.ensure()
        let r = try memory.remember(category: "people", about: "Ada Lovelace", text: "Met at the conference",
                                    links: [(label: "works at", to: "Acme", category: "ORGANIZATIONS")], notes: ["birthday 03-14"], who: "Test")
        XCTAssertEqual(r.file, "PEOPLE")
        XCTAssertEqual(r.node, "ada lovelace")
        XCTAssertTrue(r.mind.contains("| PEOPLE | ada lovelace"), "\(r.mind)")
        XCTAssertTrue(r.mind.contains("| ada lovelace - works at | acme"))
        XCTAssertTrue(r.mind.contains("| ORGANIZATIONS | acme"))
        XCTAssertTrue(try memory.files.read("PEOPLE").text.contains("- Ada Lovelace: Met at the conference"))
        // The same person again, written another way: the same node.
        let again = try memory.remember(category: "PEOPLE", about: "ADA LOVELACE", text: nil)
        XCTAssertEqual(again.node, "ada lovelace")
        XCTAssertEqual(again.mind, [], "known already")

        let recalled = memory.recall("Ada")
        XCTAssertEqual(recalled.nodes.first?.name, "ada lovelace", "a part of the name, found")
        XCTAssertEqual(recalled.categories, ["PEOPLE"])
        XCTAssertEqual(recalled.mentions.first?.note.name, "PEOPLE")
        XCTAssertEqual(memory.members(of: "people"), [MindNodeID("ada lovelace")])

        try memory.files.append("EVENT-DATES", "- 2026-11-03 — Ana reviews the paper")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 24))!
        let soon = memory.upcoming(days: 30, today: today, calendar: cal)
        XCTAssertEqual(soon.map(\.source), ["EVENT-DATES"])
        XCTAssertEqual(soon.first?.days, 10)
        XCTAssertEqual(memory.upcoming(days: 160, today: today, calendar: cal).last?.what, "ada lovelace: birthday 03-14")
    }

}

/// What SYSTEM-DOCS ships with: every ```mm example in it is notation the mind reads.
final class DocsContentTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testEveryNotationExampleInTheDocsReads() throws {
        let folder = Self.repo.appendingPathComponent("docs", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "md" }
        XCTAssertTrue(files.contains { $0.lastPathComponent == "MIND-GUIDE.md" })
        var blocks = 0
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            var inside: [String]?
            for line in text.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if inside == nil, t == "```mm" { inside = []; continue }
                if inside != nil, t.hasPrefix("```") {
                    blocks += 1
                    var g = MindGraph()
                    for l in inside! where l.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                        // A line's own comment (after the notation) is two spaces or more on.
                        let statement = l.components(separatedBy: "  ").first ?? l
                        XCTAssertNoThrow(try g.apply(statement), "\(f.lastPathComponent): \(statement)")
                    }
                    inside = nil
                    continue
                }
                inside?.append(line)
            }
        }
        XCTAssertGreaterThan(blocks, 3)
    }

}
