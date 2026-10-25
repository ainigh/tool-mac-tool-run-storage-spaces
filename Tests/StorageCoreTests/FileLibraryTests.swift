import Foundation
@testable import StorageCore
import XCTest

/// The file library: notes by name (no extension), written, read, appended to, renamed, copied,
/// deleted into a Trash of its own (numbered, so several of a name can wait there), restored,
/// and searched.
final class FileLibraryTests: XCTestCase {
    var folder: URL!
    var lib: FileLibrary!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        lib = FileLibrary(root: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testANameIsAKeyAndItsTextTheValue() throws {
        XCTAssertEqual(lib.list(), [])
        let made = try lib.write("groceries", "# Groceries\n\n- eggs\n")
        XCTAssertTrue(made.created)
        XCTAssertEqual(made.note.name, "groceries")
        XCTAssertEqual(made.note.url.lastPathComponent, "groceries.md")
        XCTAssertEqual(made.note.title, "Groceries")
        XCTAssertEqual(try lib.read("groceries").text, "# Groceries\n\n- eggs\n")
        // The extension, case and accents don't matter when it's found.
        XCTAssertEqual(try lib.read("groceries.md").note.name, "groceries")
        XCTAssertEqual(try lib.read("GROCERIES").note.name, "groceries")
        XCTAssertFalse(try lib.write("groceries", "- milk\n").created, "a second write replaces it")
        XCTAssertEqual(try lib.read("groceries").text, "- milk\n")
        XCTAssertEqual(lib.names(), ["groceries"])

        XCTAssertThrowsError(try lib.write("groceries", "x", mode: .create)) { e in XCTAssertEqual((e as? LibraryError)?.code, .exists) }
        XCTAssertThrowsError(try lib.write("nothing", "x", mode: .replace)) { e in XCTAssertEqual((e as? LibraryError)?.code, .notFound) }
        XCTAssertThrowsError(try lib.read("grocery")) { e in
            let le = e as? LibraryError
            XCTAssertEqual(le?.code, .notFound)
            XCTAssertEqual(le?.fix, "Near it: groceries")
        }
        for bad in ["", "a/b", "x:y", ".hidden", "line\nbreak", "Trash", String(repeating: "x", count: 300)] {
            XCTAssertThrowsError(try lib.write(bad, "x"), bad) { e in XCTAssertEqual((e as? LibraryError)?.code, .badName, bad) }
        }
        // Only the extension's files are notes; folders and other files aren't.
        try "not a note".write(to: folder.appendingPathComponent("photo.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub.md"), withIntermediateDirectories: true)
        XCTAssertEqual(lib.names(), ["groceries"])
    }

    func testAppendRenameCopyAndTheOrder() throws {
        try lib.append("log", "first")
        try lib.append("log", "second\n")
        XCTAssertEqual(try lib.read("log").text, "first\nsecond\n")
        try lib.write("b", "bee", mode: .create)
        try lib.write("A note", "a")
        XCTAssertEqual(lib.names(), ["A note", "b", "log"])

        try lib.rename("b", to: "Bee")
        XCTAssertEqual(lib.names(), ["A note", "Bee", "log"], "only the case changes, and it does")
        XCTAssertThrowsError(try lib.rename("Bee", to: "log")) { e in XCTAssertEqual((e as? LibraryError)?.code, .exists) }
        try lib.rename("Bee", to: "log", overwrite: true)
        XCTAssertEqual(try lib.read("log").text, "bee")
        XCTAssertEqual(lib.trash().map(\.name), ["log"], "the one it replaced went to the Trash")

        try lib.copy("log", to: "log copy")
        XCTAssertEqual(try lib.read("log copy").text, "bee")
        XCTAssertThrowsError(try lib.copy("log", to: "A note"))

        let old = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: try lib.read("A note").note.url.path)
        XCTAssertEqual(lib.list(sort: .modified).last?.name, "A note", "the latest changed first")
        XCTAssertEqual(lib.list(sort: .name, descending: true).map(\.name), ["log copy", "log", "A note"])
    }

    /// Deleting moves it to the library's Trash as name (1), name (2)…; restoring brings back the
    /// latest (or the one asked for), and a name that's taken now is said.
    func testTheTrashKeepsEveryOneOfAName() throws {
        try lib.write("draft", "one")
        let first = try lib.delete("draft")
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(first.url.lastPathComponent, "draft (1).md")
        XCTAssertFalse(lib.exists("draft"))
        try lib.write("draft", "two")
        let second = try lib.delete("draft")
        XCTAssertEqual(second.number, 2)
        XCTAssertEqual(lib.trash().map(\.number), [2, 1], "the latest deleted first")
        XCTAssertEqual(lib.names(), [], "the Trash isn't a note")

        try lib.write("draft", "three")
        XCTAssertThrowsError(try lib.restore("draft")) { e in XCTAssertEqual((e as? LibraryError)?.code, .exists) }
        let back = try lib.restore("draft", number: 1, as: "draft one")
        XCTAssertEqual(back.name, "draft one")
        XCTAssertEqual(try lib.read("draft one").text, "one")
        XCTAssertEqual(lib.trash().map(\.number), [2])
        XCTAssertThrowsError(try lib.restore("draft", number: 7)) { e in XCTAssertTrue("\(e)".contains("draft (2)"), "\(e)") }

        // A third delete is (3): the numbers aren't reused while (2) is there.
        XCTAssertEqual(try lib.delete("draft").number, 3)
        // One put in the Trash by hand still reads, by its file's name.
        let byHand = lib.trashFolder.appendingPathComponent("old (9).md")
        try "by hand".write(to: byHand, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: byHand.path)
        XCTAssertTrue(lib.trash().contains { $0.name == "old" && $0.number == 9 })
        XCTAssertEqual(try lib.emptyTrash(olderThan: 3600), 1, "only the one put there by hand is old (its file's date)")
        XCTAssertEqual(try lib.emptyTrash(), 2)
        XCTAssertEqual(lib.trash(), [])
    }

    func testSearchingEveryNote() throws {
        try lib.write("Trip to Lagos", "# Trip\n\nBook the flight.\nCall the bank about cards.\n")
        try lib.write("bank", "# Bank\nThe bank's number is 0800.\nOpen a savings account.\n")
        try lib.write("café ideas", "Coffee and cake.\nA category of its own.\n")

        // Every word, in the name or the text; the name counts more.
        let bank = lib.search("bank")
        XCTAssertEqual(bank.map(\.note.name), ["bank", "Trip to Lagos"])
        XCTAssertEqual(bank.first?.lines.map(\.number), [1, 2])
        XCTAssertEqual(lib.search("bank flight").map(\.note.name), ["Trip to Lagos"], "every word")
        XCTAssertEqual(Set(lib.search("flight savings", .init(all: false)).map(\.note.name)), ["Trip to Lagos", "bank"], "any word")
        XCTAssertEqual(lib.search("\"call the bank\"").map(\.note.name), ["Trip to Lagos"], "a phrase")
        XCTAssertEqual(lib.search("cafe").map(\.note.name), ["café ideas"], "accents don't count")
        XCTAssertEqual(lib.search("CAKE").map(\.note.name), ["café ideas"])
        XCTAssertEqual(lib.search("CAKE", .init(caseSensitive: true)), [])
        XCTAssertEqual(lib.search("cat").map(\.note.name), ["café ideas"], "category has cat in it")
        XCTAssertEqual(lib.search("cat", .init(wholeWords: true)), [])
        XCTAssertEqual(lib.search("trip", .init(namesOnly: true)).map(\.note.name), ["Trip to Lagos"])
        XCTAssertEqual(lib.search("   "), [])
        XCTAssertEqual(FileLibrary.terms("a \"b c\" d"), ["a", "b c", "d"])

        XCTAssertEqual(try lib.outline("Trip to Lagos").map(\.text), ["Trip"])
        try lib.write("index", "See [[bank]] and [the trip](Trip%20to%20Lagos.md).\n```\n# not a heading\n```\n## Notes\n")
        XCTAssertEqual(try lib.outline("index").map(\.text), ["Notes"], "a # in a code block isn't a heading")
        XCTAssertEqual(try lib.backlinks("bank").map(\.note.name), ["index"])
        XCTAssertEqual(try lib.backlinks("Trip to Lagos").map(\.note.name), ["index"])

        let stats = lib.stats()
        XCTAssertEqual(stats.notes, 4)
        XCTAssertGreaterThan(stats.words, 20)
        XCTAssertEqual(stats.newest?.name, "index")
    }
}
