// swift-tools-version:5.9
import PackageDescription

// StorageCore is the storage itself (the spaces and their stores: notes, MEMORY, the mind,
// records; who may read and write what; what waits for approval; the HTTP API): Foundation only,
// so it's tested on any machine (swift test). The menu bar app is only on the Mac.
var targets: [Target] = [
    .target(name: "StorageCore"),
    .testTarget(name: "StorageCoreTests", dependencies: ["StorageCore"]),
]
#if os(macOS)
targets.append(.executableTarget(name: "StorageSpaces", dependencies: ["StorageCore"]))
#endif

let package = Package(name: "StorageSpaces", platforms: [.macOS(.v14)], targets: targets)
