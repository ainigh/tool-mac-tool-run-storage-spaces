import Foundation

// The spaces, and the stores in each: what's kept, for whom, and where on disk.
//
//   STORAGE-SPACES/              (~/Desktop/STORAGE-SPACES, or STORAGE_HOME)
//     USER/      the person's:   LIBRARY (notes), MEMORY (a file per kind of thing), MIND (the log)
//     SUPER/     Super Face's:   PROMPT (its standing instructions), MEMORY (what it has learned)
//     PETER/     Peter's:        SCHEDULE, STATUS, FOLLOWING, SETTINGS (records)
//     PENDING/   waiting:        REQUESTS (for access), WRITES (held until approved)
//     OTHER/     any other app's own folder of notes, made the first time it writes
//     .storage/  the app's own:  who may do what, the clients' keys, its Trash
//     README.md  this, for whoever opens the folder

/// A space: whose things these are.
public enum SpaceID: String, CaseIterable, Sendable, Codable {
    case user, `super`, peter, pending, other

    public var folderName: String { rawValue.uppercased() }

    public var title: String {
        switch self {
        case .user: "You"
        case .super: "Super Face"
        case .peter: "Peter"
        case .pending: "Pending"
        case .other: "Other apps"
        }
    }

    /// What it's for, in a line.
    public var purpose: String {
        switch self {
        case .user: "Yours: your library of notes, MEMORY (what's remembered, a file for each kind of thing) and the mind (how it all links)."
        case .super: "Super Face's: its prompt (the standing instructions it reads before every request) and its memory (what it has learned about getting things done for you)."
        case .peter: "Peter's: what he needs to work. His schedule, how things stand, the runs he's following, his settings."
        case .pending: "What's waiting: requests for access, and changes held until Peter or you approve them."
        case .other: "Any other app's own folder of notes, made the first time it writes there."
        }
    }

    /// The client whose space it is (nil: the person's, or nobody's).
    public var owner: String? {
        switch self {
        case .super: Clients.superFace
        case .peter: Clients.peter
        case .user, .pending, .other: nil
        }
    }

    /// The space a word means: user, super, peter, pending, other (and a few other ways of saying them).
    public init?(word: String) {
        switch word.lowercased().trimmingCharacters(in: .whitespaces) {
        case "user", "you", "me", "person": self = .user
        case "super", "super-face", "superface", "super face": self = .super
        case "peter", "agent", "tool-mac-agent": self = .peter
        case "pending": self = .pending
        case "other", "others": self = .other
        default: return nil
        }
    }
}

/// What a store keeps, and so what can be done with it.
public enum StoreKind: String, Sendable, Codable {
    /// Markdown files by name, with a Trash (the library's operations).
    case notes
    /// MEMORY: notes, each a node of the mind, with remember and recall.
    case memory
    /// The mind: the append-only log in the text mind-map notation.
    case mind
    /// JSON values by key, each with a version (so two writers can't overwrite each other unseen).
    case records
}

/// A store: where it is in its space, what it keeps, and what it's for.
public struct StoreSpec: Sendable, Equatable {
    public var space: SpaceID
    /// Its id in its space (library, memory, mind, prompt, schedule…; an app's name in OTHER).
    public var name: String
    public var kind: StoreKind
    /// Its folder in its space (LIBRARY, MEMORY…).
    public var folderName: String
    public var purpose: String

    /// "user/library".
    public var path: String { "\(space.rawValue)/\(name)" }

    /// Its notes' words and rules (for a notes or memory store).
    public var shelf: Shelf {
        switch kind {
        case .memory: .memory
        case .notes where space == .user && name == "library": .library
        default: Shelf(folderName: folderName, noun: "note", place: "\(space.folderName)/\(folderName)")
        }
    }

    /// The stores each space comes with (OTHER's are made as apps write to them).
    public static let builtIn: [StoreSpec] = [
        StoreSpec(space: .user, name: "library", kind: .notes, folderName: "LIBRARY", purpose: "Your notes, each a Markdown file known by its name."),
        StoreSpec(space: .user, name: "memory", kind: .memory, folderName: "MEMORY",
                  purpose: "What's remembered: a file for each kind of thing (PEOPLE, ORGANIZATIONS, EVENT-DATES, BIRTHDAYS…), each a node of the mind."),
        StoreSpec(space: .user, name: "mind", kind: .mind, folderName: "MIND", purpose: "How what's known links up: names and the links between them, in the text mind-map notation, append only."),
        StoreSpec(space: .super, name: "prompt", kind: .notes, folderName: "PROMPT", purpose: "What Super Face reads before every request: your standing instructions, and any other part of its prompt you keep here."),
        StoreSpec(space: .super, name: "memory", kind: .notes, folderName: "MEMORY", purpose: "What Super Face has learned about getting things done for you: its playbook, a line each."),
        StoreSpec(space: .peter, name: "schedule", kind: .records, folderName: "SCHEDULE", purpose: "What's set for later: reminders, and requests to do later or again and again."),
        StoreSpec(space: .peter, name: "status", kind: .records, folderName: "STATUS", purpose: "How things stand: what Peter is doing, what he last did, what went wrong."),
        StoreSpec(space: .peter, name: "following", kind: .records, folderName: "FOLLOWING", purpose: "The runs Peter is following, so he can tell whoever asked once they're over (even after a restart)."),
        StoreSpec(space: .peter, name: "settings", kind: .records, folderName: "SETTINGS", purpose: "Peter's settings: where Tool Mac Tool Run is, his model, the sound."),
        StoreSpec(space: .pending, name: "requests", kind: .records, folderName: "REQUESTS", purpose: "Apps asking to read or write a space they can't: waiting for Peter or you."),
        StoreSpec(space: .pending, name: "writes", kind: .records, folderName: "WRITES", purpose: "Changes an app asked for without the access to make them, held until Peter or you approve them."),
    ]

    /// An app's own store in OTHER (`other/super-voice`), as notes.
    public static func other(_ slug: String) -> StoreSpec {
        StoreSpec(space: .other, name: slug, kind: .notes, folderName: slug, purpose: "An app's own notes.")
    }
}

/// Where everything is, and each store as the thing that reads and writes it.
public struct Storage: Sendable {
    public let root: URL

    public static let folderName = "STORAGE-SPACES"

    /// ~/Desktop/STORAGE-SPACES, or `STORAGE_HOME` when it's set (a test, or storage kept elsewhere).
    public static var defaultRoot: URL {
        if let path = ProcessInfo.processInfo.environment["STORAGE_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    public init(root: URL = Storage.defaultRoot) {
        self.root = root
    }

    public func folder(_ space: SpaceID) -> URL { root.appendingPathComponent(space.folderName, isDirectory: true) }
    public func folder(_ spec: StoreSpec) -> URL { folder(spec.space).appendingPathComponent(spec.folderName, isDirectory: true) }

    /// The app's own folder: access, keys, its Trash. Hidden in the Finder.
    public var system: URL { root.appendingPathComponent(".storage", isDirectory: true) }
    public var trashFolder: URL { system.appendingPathComponent("Trash", isDirectory: true) }

    // MARK: the stores

    public func spec(_ space: SpaceID, _ name: String) -> StoreSpec? {
        if space == .other {
            guard let slug = Clients.slug(name), !slug.isEmpty else { return nil }
            return .other(slug)
        }
        let n = name.lowercased()
        return StoreSpec.builtIn.first { $0.space == space && ($0.name == n || $0.folderName.lowercased() == n) }
    }

    public func stores(in space: SpaceID) -> [StoreSpec] {
        if space == .other {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder(.other).path)) ?? []
            return names.filter { !$0.hasPrefix(".") && Clients.slug($0) == $0 }.sorted().map(StoreSpec.other)
        }
        return StoreSpec.builtIn.filter { $0.space == space }
    }

    public var allStores: [StoreSpec] { SpaceID.allCases.flatMap(stores(in:)) }

    public func notes(_ spec: StoreSpec) -> FileLibrary { FileLibrary(root: folder(spec), shelf: spec.shelf) }
    public func records(_ spec: StoreSpec) -> RecordStore { RecordStore(root: folder(spec), name: spec.path) }

    public var userMemory: Memory {
        let spec = self.spec(.user, "memory")!
        return Memory(files: notes(spec), mind: mind)
    }

    public var mind: MindStore { MindStore(root: folder(spec(.user, "mind")!)) }

    // MARK: making it ready

    /// Whether the folder is there at all (before the first launch it isn't).
    public var exists: Bool { FileManager.default.fileExists(atPath: root.path) }

    /// Makes every space and store that isn't there, with what each comes with (MEMORY's files,
    /// the mind's first lines, Super Face's two notes). Safe to run again: nothing there is changed.
    public func ensure() throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: system, withIntermediateDirectories: true)
            for space in SpaceID.allCases { try fm.createDirectory(at: folder(space), withIntermediateDirectories: true) }
        } catch {
            throw LibraryError(.failed, "Couldn't make \(root.path): \(error.localizedDescription)")
        }
        for spec in StoreSpec.builtIn {
            switch spec.kind {
            case .memory: try userMemory.ensure()
            case .mind: try mind.ensure()
            case .notes: try notes(spec).ensure()
            case .records: try records(spec).ensure()
            }
        }
        for (name, text) in SuperFace.seeds {
            let spec = self.spec(.super, name.store)!
            let lib = notes(spec)
            if !lib.exists(name.note) { try lib.write(name.note, text, mode: .create) }
        }
        let readme = root.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) { try? Data(Self.readme.utf8).write(to: readme, options: .atomic) }
    }

    /// The README in the folder, for whoever opens it.
    public static var readme: String {
        var out = """
        # Storage Spaces

        Everything the apps on this Mac keep for you and for themselves, a folder each. The Storage Spaces app (its icon is in the menu bar) looks after it and serves it to the apps at http://127.0.0.1:\(StorageAPI.port). You can open, read and change any of these files yourself.


        """
        for space in SpaceID.allCases {
            out += "## \(space.folderName): \(space.title)\n\n\(space.purpose)\n\n"
            for s in StoreSpec.builtIn where s.space == space {
                out += "- **\(s.folderName)** (\(s.kind.rawValue)): \(s.purpose)\n"
            }
            if space != .other { out += "\n" }
        }
        out += """

        `.storage` (hidden) is the app's own: who may read and write what, the apps' keys, and its Trash.
        """
        return out + "\n"
    }

    // MARK: putting things away

    /// Moves something to the Trash (the Mac's; where there's none, the app's own in .storage),
    /// as "NAME (reset STAMP)". Returns where it went.
    @discardableResult
    public func trash(_ url: URL, label: String = "reset", at date: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let stamp = Self.stamp(date)
        #if os(macOS)
        var out: NSURL?
        if (try? fm.trashItem(at: url, resultingItemURL: &out)) != nil, let out = out as URL? { return out }
        #endif
        try fm.createDirectory(at: trashFolder, withIntermediateDirectories: true)
        var dest = trashFolder.appendingPathComponent("\(url.lastPathComponent) (\(label) \(stamp))")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = trashFolder.appendingPathComponent("\(url.lastPathComponent) (\(label) \(stamp) \(n))")
            n += 1
        }
        try fm.moveItem(at: url, to: dest)
        return dest
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: date)
    }

    /// A space back as it came: its stores to the Trash, then made again. The person's, Peter's or
    /// the space's owner's to do. Returns where each went.
    public func reset(_ space: SpaceID) throws -> [String] {
        var moved: [String] = []
        for spec in stores(in: space) {
            let url = folder(spec)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if spec.kind == .mind || spec.kind == .memory { MindCache.shared.drop(mind.file.path) }
            moved.append(try trash(url, label: "\(space.rawValue) reset").path)
        }
        try ensure()
        return moved
    }
}

/// What Super Face's space comes with: the two notes it used to keep in Tool Mac Tool Run's
/// library ("Super Face instructions", "Super Face playbook"), with the same first lines.
public enum SuperFace {
    public static let instructions = (store: "prompt", note: "instructions")
    public static let playbook = (store: "memory", note: "playbook")

    public static let instructionsHead = "# Super Face instructions\n\nWhat Super Face should always do or keep in mind, in your words. It reads this before every request.\n"
    public static let playbookHead = "# Super Face playbook\n\nWhat Super Face has learned about getting things done for you, a line each. It reads this before every request; change it as you like.\n"

    static var seeds: [((store: String, note: String), String)] {
        [(instructions, instructionsHead), (playbook, playbookHead)]
    }
}
