import Foundation

/// What kind of folder of notes a `FileLibrary` is: how its notes are spoken of, and what it
/// allows. In Tool Mac Tool Run this was an enum of its three shelves; here every notes store of
/// every space is one (the person's library, MEMORY, Super Face's prompt…), so it's a value.
public struct Shelf: Sendable, Equatable {
    /// The folder's own name (LIBRARY, MEMORY, PROMPT).
    public var folderName: String
    /// What a file on it is called ("note", "memory file").
    public var noun: String
    /// How it's named in a sentence ("the library", "MEMORY").
    public var place: String
    /// Its files can't be changed.
    public var readOnly: Bool
    /// Its names are nodes of the mind too (MEMORY), so each must be one the notation can write.
    public var mindNames: Bool

    public init(folderName: String, noun: String = "note", place: String? = nil, readOnly: Bool = false, mindNames: Bool = false) {
        self.folderName = folderName
        self.noun = noun
        self.place = place ?? folderName
        self.readOnly = readOnly
        self.mindNames = mindNames
    }

    /// The person's library: their notes.
    public static let library = Shelf(folderName: "LIBRARY", noun: "note", place: "the library")
    /// MEMORY: a file for each kind of thing remembered, each a node of the mind.
    public static let memory = Shelf(folderName: "MEMORY", noun: "memory file", place: "MEMORY", mindNames: true)
    /// Docs that are read, never written (the ones Storage Spaces ships with).
    public static let docs = Shelf(folderName: "DOCS", noun: "doc", place: "DOCS", readOnly: true)
}
