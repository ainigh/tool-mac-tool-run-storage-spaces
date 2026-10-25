import Foundation

/// Brings what Tool Mac Tool Run and Peter kept into the spaces, by copying it (the originals
/// stay where they are, as they were: Tool Mac Tool Run goes on using its own until it's changed
/// to use Storage Spaces):
///
/// - TOOL-MAC-RUN/LIBRARY → USER/LIBRARY, but for Super Face's two notes, which go to its own
///   space ("Super Face instructions" → SUPER/PROMPT/instructions, "Super Face playbook" →
///   SUPER/MEMORY/playbook);
/// - TOOL-MAC-RUN/MEMORY → USER/MEMORY (one of its files left as it came is replaced; one
///   written in comes in beside it, as "NAME (from Tool Mac Tool Run)");
/// - TOOL-MAC-RUN/MIND → USER/MIND, when the mind here has nothing in it yet (two minds aren't
///   merged: the report says so);
/// - Peter's schedule.json and model.json → PETER/SCHEDULE/schedule and PETER/SETTINGS/model, as
///   they were, for Peter to take up.
///
/// Running it again copies only what's new. What it did is kept in .storage/imported.json.
public enum ToolMacImport {
    /// ~/Desktop/TOOL-MAC-RUN, or `TMR_HOME` when it's set (as Tool Mac Tool Run has it).
    public static var defaultSource: URL {
        if let path = ProcessInfo.processInfo.environment["TMR_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/TOOL-MAC-RUN", isDirectory: true)
    }

    /// ~/Library/Application Support/Peter, or `PETER_HOME`.
    public static var defaultPeter: URL {
        if let path = ProcessInfo.processInfo.environment["PETER_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Peter", isDirectory: true)
    }

    public struct Report: Sendable, Equatable {
        /// What came in: "USER/LIBRARY/groceries".
        public var copied: [String] = []
        /// What didn't, and why.
        public var skipped: [String] = []
        /// Whether there was anything to import from at all.
        public var found = false

        public var summary: String {
            guard found else { return "There's nothing from Tool Mac Tool Run or Peter to bring in." }
            if copied.isEmpty { return "Nothing new to bring in from Tool Mac Tool Run or Peter." }
            return "Brought in \(copied.count) thing\(copied.count == 1 ? "" : "s") from Tool Mac Tool Run and Peter" + (skipped.isEmpty ? "." : " (\(skipped.count) left as they are).")
        }

        public var json: [String: Any] { ["found": found, "copied": copied, "skipped": skipped, "summary": summary] }
    }

    /// Whether there's anything to bring in.
    public static func available(source: URL = defaultSource, peter: URL = defaultPeter) -> Bool {
        let fm = FileManager.default
        return ["LIBRARY", "MEMORY", "MIND"].contains { fm.fileExists(atPath: source.appendingPathComponent($0).path) }
            || fm.fileExists(atPath: peter.appendingPathComponent("schedule.json").path)
    }

    public static func run(into storage: Storage, source: URL = defaultSource, peter: URL = defaultPeter, now: Date = Date()) throws -> Report {
        var report = Report()
        try storage.ensure()
        let fm = FileManager.default

        // The library, and Super Face's two notes out of it.
        let theirLibrary = FileLibrary(root: source.appendingPathComponent("LIBRARY"))
        if fm.fileExists(atPath: theirLibrary.root.path) {
            report.found = true
            let mine = storage.notes(storage.spec(.user, "library")!)
            for note in theirLibrary.list() {
                let folded = Clients.fold(note.name)
                if folded == Clients.fold("Super Face instructions") || folded == Clients.fold("Super Face playbook") {
                    let isInstructions = folded.hasSuffix("instructions")
                    let dest = isInstructions ? SuperFace.instructions : SuperFace.playbook
                    let lib = storage.notes(storage.spec(.super, dest.store)!)
                    let seed = isInstructions ? SuperFace.instructionsHead : SuperFace.playbookHead
                    let text = (try? theirLibrary.read(note.name).text) ?? ""
                    try bring(text, as: dest.note, into: lib, replacingIf: { $0 == seed }, label: "SUPER/\(dest.store.uppercased())", &report)
                    continue
                }
                let text = (try? theirLibrary.read(note.name).text) ?? ""
                try bring(text, as: note.name, into: mine, replacingIf: { _ in false }, label: "USER/LIBRARY", &report)
            }
        }

        // MEMORY.
        let theirMemory = FileLibrary(root: source.appendingPathComponent("MEMORY"), shelf: .memory)
        let memory = storage.userMemory
        if fm.fileExists(atPath: theirMemory.root.path) {
            report.found = true
            for note in theirMemory.list() {
                let text = (try? theirMemory.read(note.name).text) ?? ""
                let seed = Memory.defaults.first { $0.name.caseInsensitiveCompare(note.name) == .orderedSame }.map(Memory.text(of:))
                try bring(text, as: note.name, into: memory.files, replacingIf: { $0 == seed }, label: "USER/MEMORY", &report)
            }
        }

        // The mind: only into one that has nothing in it yet.
        let theirMind = MindStore(root: source.appendingPathComponent("MIND"))
        if theirMind.exists {
            report.found = true
            let theirs = theirMind.log()
            let mind = storage.mind
            if theirs == mind.log() {
                report.skipped.append("USER/MIND: the same as Tool Mac Tool Run's already")
            } else if isEmpty(mind.graph(), files: Set(memory.files.names())) {
                try Data(theirs.utf8).write(to: mind.file, options: .atomic)
                if fm.fileExists(atPath: theirMind.archive.path), !fm.fileExists(atPath: mind.archive.path) {
                    try? fm.copyItem(at: theirMind.archive, to: mind.archive)
                }
                MindCache.shared.drop(mind.file.path)
                try mind.index(memory.files, who: Clients.storage)
                report.copied.append("USER/MIND (\(MindGraph(log: theirs).nodes.count) nodes)")
            } else {
                report.skipped.append("USER/MIND: the mind here has things in it already, so Tool Mac Tool Run's isn't merged in (its log is \(theirMind.file.path))")
            }
        } else if fm.fileExists(atPath: theirMemory.root.path) {
            try memory.mind.index(memory.files, who: Clients.storage)
        }

        // Peter's schedule and model settings, as he kept them.
        for (file, store, key) in [("schedule.json", "schedule", "schedule"), ("model.json", "settings", "model")] {
            let url = peter.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { continue }
            report.found = true
            let records = storage.records(storage.spec(.peter, store)!)
            let label = "PETER/\(store.uppercased())/\(key)"
            if (try? records.get(key)) != nil {
                report.skipped.append("\(label): there already")
            } else {
                try records.put(key, value, expect: 0, by: Clients.storage, now: now)
                report.copied.append(label)
            }
        }

        try? write(report, to: storage, at: now)
        return report
    }

    /// The mind has nothing but MEMORY's own files in it (as it comes).
    static func isEmpty(_ g: MindGraph, files: Set<String>) -> Bool {
        g.edges.isEmpty && g.nodes.values.allSatisfy { $0.id.isRoot && files.contains($0.id.name) && $0.notes.isEmpty }
    }

    /// A note brought in: as it is when it isn't here (or when what's here is `replacingIf`);
    /// skipped when it's the same; beside it, as "NAME (from Tool Mac Tool Run)", when it isn't.
    static func bring(_ text: String, as name: String, into lib: FileLibrary, replacingIf: (String?) -> Bool, label: String, _ report: inout Report) throws {
        let here = lib.find(name).flatMap { try? lib.read($0.name).text }
        if here == text {
            report.skipped.append("\(label)/\(name): the same already")
        } else if here == nil || replacingIf(here) {
            try lib.write(name, text)
            report.copied.append("\(label)/\(name)")
        } else {
            let beside = "\(name) (from Tool Mac Tool Run)"
            if let there = lib.find(beside).flatMap({ try? lib.read($0.name).text }), there == text {
                report.skipped.append("\(label)/\(beside): there already")
            } else {
                try lib.write(beside, text)
                report.copied.append("\(label)/\(beside) (\(name) here is different, so it's kept as it is)")
            }
        }
    }

    static func write(_ report: Report, to storage: Storage, at now: Date) throws {
        var j = report.json
        j["at"] = JSON.date(now)
        try FileManager.default.createDirectory(at: storage.system, withIntermediateDirectories: true)
        try JSON.data(j).write(to: storage.system.appendingPathComponent("imported.json"), options: .atomic)
    }

    /// Whether it has been done before (.storage/imported.json is there).
    public static func done(in storage: Storage) -> Bool {
        FileManager.default.fileExists(atPath: storage.system.appendingPathComponent("imported.json").path)
    }
}
