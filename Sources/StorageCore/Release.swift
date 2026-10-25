import Foundation

// What the app's updater needs from GitHub, worked out here (Foundation only) so it's tested on
// any machine. The updater itself (downloading, swapping the app, opening it again) is the app's
// Updater.swift. Taken from ainigh/MyTouchScreen, whose updater does the same.

/// A version like "0.1.42" (a leading "v" is fine). Compared number by number: 0.1.42 > 0.1.9.
public struct ToolVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parsed = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parsed.isEmpty, !parsed.contains(where: { $0 == nil }) else { return nil }
        parts = parsed.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: ToolVersion, b: ToolVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: ToolVersion, b: ToolVersion) -> Bool { !(a < b) && !(b < a) }
}

/// The parts of a GitHub release the updater uses (GET /repos/{owner}/{repo}/releases/latest).
public struct GitHubRelease: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let tag: String
    /// The commit the release was built from (the workflow passes the full sha).
    public let target: String?
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case target = "target_commitish"
        case assets
    }

    public init(tag: String, target: String?, assets: [Asset]) {
        self.tag = tag
        self.target = target
        self.assets = assets
    }

    public static func decode(_ data: Data) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    public var version: ToolVersion? { ToolVersion(tag) }

    public func asset(named name: String) -> Asset? { assets.first { $0.name == name } }
}

/// The newest commit on a branch (GET /repos/{owner}/{repo}/commits/{branch}).
public struct GitHubCommit: Decodable, Equatable, Sendable {
    public let sha: String
    public let message: String

    private struct Details: Decodable { let message: String }
    private enum CodingKeys: String, CodingKey { case sha, commit }

    public init(sha: String, message: String) {
        self.sha = sha
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sha = try c.decode(String.self, forKey: .sha)
        message = try c.decode(Details.self, forKey: .commit).message
    }

    public static func decode(_ data: Data) throws -> GitHubCommit {
        try JSONDecoder().decode(GitHubCommit.self, from: data)
    }

    public var short: String { String(sha.prefix(7)) }
    /// The first line of the message.
    public var title: String { message.components(separatedBy: "\n").first ?? message }
}

/// What an update check concluded.
public enum UpdatePlan: Equatable, Sendable {
    case upToDate
    /// GitHub built this commit: download the release.
    case prebuilt(GitHubCommit, GitHubRelease)
    /// No release for this commit (the build is still running, or Actions is off): build it here.
    case buildHere(GitHubCommit)

    /// Compares the branch's newest commit with the one this copy was built from. A copy with no
    /// recorded commit updates to whatever the branch has.
    public static func decide(head: GitHubCommit, installedCommit: String?, latestRelease: GitHubRelease?,
                              assetName: String) -> UpdatePlan {
        if let mine = installedCommit, !mine.isEmpty, mine != "unknown",
           head.sha.hasPrefix(mine) || mine.hasPrefix(head.sha) {
            return .upToDate
        }
        if let release = latestRelease, release.target == head.sha, release.asset(named: assetName) != nil {
            return .prebuilt(head, release)
        }
        return .buildHere(head)
    }

    /// The commit it updates to (none when up to date).
    public var commit: GitHubCommit? {
        switch self {
        case .upToDate: nil
        case let .prebuilt(c, _), let .buildHere(c): c
        }
    }

    /// What the menu offers, in a line.
    public var title: String {
        switch self {
        case .upToDate: "Up to date"
        case let .prebuilt(c, r): "Update to \(r.tag): \(c.title)"
        case let .buildHere(c): "Update (built on this Mac): \(c.title)"
        }
    }
}

/// Reads `swift --version` ("… Swift version 5.10 (swift-5.10-RELEASE) …").
public enum SwiftToolchain {
    /// The package's swift-tools-version.
    public static let required = ToolVersion("5.9")!

    public static func version(in output: String) -> ToolVersion? {
        guard let range = output.range(of: #"Swift version (\d+(\.\d+)*)"#, options: .regularExpression) else { return nil }
        return ToolVersion(output[range].replacingOccurrences(of: "Swift version ", with: ""))
    }

    public static func isNewEnough(_ output: String) -> Bool {
        guard let v = version(in: output) else { return false }
        return !(v < required)
    }
}
