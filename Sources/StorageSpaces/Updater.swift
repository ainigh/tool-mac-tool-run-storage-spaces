import AppKit
import Foundation
import StorageCore

/// Keeps the app on the newest commit of the branch it was built from (`main`, unless it was
/// installed from another): checks at launch, every 6 hours and from the menu, and installs with a
/// click. Taken from ainigh/MyTouchScreen's updater.
///
/// Installing takes GitHub's build when the latest release was made from that exact commit;
/// otherwise it downloads the source and builds it here (Apple's command line tools), so an update
/// never waits on GitHub Actions. It reaches GitHub through `gh` (signed in, so the private
/// repository works), else directly (a public one).
///
/// The app that was there is kept beside the new one until the new one is seen running: if it
/// quits straight away, the old one goes back and opens again (as install.sh does).
@MainActor
final class Updater: ObservableObject {
    nonisolated static let repo = "ainigh/tool-mac-tool-run-storage-spaces"
    nonisolated static let assetName = "StorageSpaces.zip"
    /// What build-app.sh makes and zips (the installed copy may have been renamed).
    nonisolated static let builtAppName = "StorageSpaces.app"
    nonisolated static let processName = "StorageSpaces"

    /// The branch this copy follows (build-app.sh writes it into Info.plist).
    nonisolated static var branch: String {
        let b = Bundle.main.object(forInfoDictionaryKey: "StorageBranch") as? String ?? ""
        return b.isEmpty ? "main" : b
    }

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The commit this copy was built from (build-app.sh writes it into Info.plist).
    nonisolated static var currentCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "StorageCommit") as? String
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(UpdatePlan)
        case installing(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The commit of the last update a notification was posted for (each is told about once,
    /// even when its build here becomes a download from GitHub).
    private var toldSHA: String?
    private var timer: Timer?
    private let work = DispatchQueue(label: "StorageSpaces.updater", qos: .utility)

    var isBusy: Bool {
        switch state {
        case .checking, .installing: true
        default: false
        }
    }

    var available: UpdatePlan? {
        if case let .available(plan) = state { return plan }
        return nil
    }

    /// One line for the menu: what this copy is.
    var versionLine: String {
        let commit = Self.currentCommit.flatMap { $0 == "unknown" || $0.isEmpty ? nil : " (\($0.prefix(7)))" } ?? ""
        let branch = Self.branch == "main" ? "" : " · \(Self.branch)"
        return "Storage Spaces \(Self.currentVersion)\(commit)\(branch)"
    }

    /// Only an installed app updates itself (not `swift run`).
    nonisolated static var canUpdate: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func start() {
        guard Self.canUpdate else { return }
        check(userInitiated: false)
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(userInitiated: false) }
        }
    }

    func check(userInitiated: Bool) {
        if isBusy { return }
        let before = state
        state = .checking
        work.async {
            let outcome: State
            do {
                let plan = try Self.findUpdate()
                outcome = plan == .upToDate ? .upToDate : .available(plan)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A quiet check that fails leaves no error of its own in the menu; an update it
                    // had already found stays offered, and an install that failed stays said.
                    if case .failed = outcome, !userInitiated {
                        switch before {
                        case .available, .failed: self.state = before
                        default: self.state = .idle
                        }
                    } else {
                        self.state = outcome
                    }
                    self.tell(outcome, userInitiated: userInitiated)
                }
            }
        }
    }

    /// Nothing is silent: a new update gets a notification (a click installs it); a check asked
    /// for from the menu always says how it went.
    private func tell(_ outcome: State, userInitiated: Bool) {
        switch outcome {
        case let .available(plan) where plan.commit?.sha != toldSHA || userInitiated:
            toldSHA = plan.commit?.sha
            Notifier.post(title: "An update is ready", body: plan.title + ". Click to install it (the app restarts).", update: true)
        case .upToDate where userInitiated:
            Notifier.post(title: "Storage Spaces is up to date", body: versionLine, tone: .success)
        case let .failed(message) where userInitiated:
            Notifier.post(title: "Couldn't check for updates", body: message, tone: .warning)
        default:
            break
        }
    }

    func install() {
        guard case let .available(plan) = state else { return }
        state = .installing("Updating…")
        work.async {
            do {
                try Self.install(plan) { step in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.state = .installing(step) } }
                }
            } catch {
                Self.log("update failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.state = .failed("Update failed: \(error.localizedDescription)")
                        Notifier.post(title: "The update didn't install", body: "\(error.localizedDescription) The app you have is unchanged.", tone: .failure)
                    }
                }
            }
        }
    }

    // MARK: - What's new

    nonisolated static func findUpdate() throws -> UpdatePlan {
        let head = try GitHubCommit.decode(api("repos/\(repo)/commits/\(branch)"))
        let release = try? GitHubRelease.decode(api("repos/\(repo)/releases/latest"))
        return UpdatePlan.decide(head: head, installedCommit: currentCommit, latestRelease: release, assetName: assetName)
    }

    // MARK: - Installing

    nonisolated static func install(_ plan: UpdatePlan, step: @escaping @Sendable (String) -> Void) throws {
        let fm = FileManager.default
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { throw Problem("this copy isn't an installed app") }
        // On the app's own volume, so the swap at the end is a rename.
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? fm.removeItem(at: scratch) }

        let newApp: URL
        let commit: GitHubCommit
        switch plan {
        case .upToDate:
            return
        case let .prebuilt(head, release):
            commit = head
            step("Downloading \(release.tag)…")
            newApp = try downloadPrebuilt(release, into: scratch)
        case let .buildHere(head):
            commit = head
            newApp = try buildFromSource(head, in: scratch, step: step)
        }
        let newBundle = Bundle(url: newApp)
        guard let newID = newBundle?.bundleIdentifier, newID == Bundle.main.bundleIdentifier else {
            throw Problem("the download isn't Storage Spaces")
        }
        // Never swap in something that isn't the commit meant, or that was damaged on the way.
        guard newBundle?.object(forInfoDictionaryKey: "StorageCommit") as? String == commit.sha else {
            throw Problem("the new copy wasn't built from \(commit.short)")
        }
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        } catch {
            throw Problem("the new copy's signature doesn't check out: \(error.localizedDescription)")
        }
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        step("Restarting…")
        // The old app is parked beside it until the new one is seen running.
        let previous = app.deletingLastPathComponent().appendingPathComponent(".\(processName)-previous.app")
        let failed = app.deletingLastPathComponent().appendingPathComponent(".\(processName)-failed.app")
        try? fm.removeItem(at: previous)
        try fm.moveItem(at: app, to: previous)
        do {
            try fm.moveItem(at: newApp, to: app)
        } catch {
            try? fm.moveItem(at: previous, to: app)
            throw Problem("couldn't put the new copy in place: \(error.localizedDescription)")
        }
        log("updated to \(commit.short)")
        // Once this copy has quit: open the new one; if it isn't running a few seconds on, the old
        // one goes back and opens again. "Running" is a program whose command starts with the new
        // copy's path, matched as it is (pgrep -f would read "(1)" in a path as a pattern).
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        /usr/bin/open "$2"
        ok=0
        running() { /bin/ps -axo command= | P="$2/Contents/MacOS/$5" /usr/bin/awk 'index($0, ENVIRON["P"]) == 1 { f = 1 } END { exit !f }'; }
        for _ in 1 2 3 4 5 6; do sleep 1; if running "$@"; then ok=1; else ok=0; fi; done
        if [ "$ok" = 1 ]; then rm -rf "$3"; exit 0; fi
        rm -rf "$4"; mv "$2" "$4" && mv "$3" "$2" && /usr/bin/open "$2"
        """
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", script, "relaunch", String(getpid()), app.path, previous.path, failed.path, processName]
        do {
            try relaunch.run()
        } catch {
            // Nothing would open the new copy or check it: put the old one back as it was.
            try? fm.removeItem(at: failed)
            try? fm.moveItem(at: app, to: failed)
            try? fm.moveItem(at: previous, to: app)
            throw Problem("couldn't restart into the new copy: \(error.localizedDescription)")
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }

    nonisolated static func downloadPrebuilt(_ release: GitHubRelease, into scratch: URL) throws -> URL {
        let zip = scratch.appendingPathComponent(assetName)
        // gh first (the repository is private); one that isn't signed in falls back to a plain download.
        if let gh = ghPath(), (try? run(gh, ["release", "download", release.tag, "--repo", repo, "--pattern", assetName,
                                            "--dir", scratch.path, "--clobber"])) != nil {
            // Downloaded by gh.
        } else if let asset = release.asset(named: assetName) {
            try download(asset.browserDownloadURL, to: zip)
        } else {
            throw Problem("the release has no \(assetName)")
        }
        let unpacked = scratch.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        return unpacked.appendingPathComponent(builtAppName)
    }

    /// Downloads the commit's source and runs scripts/build-app.sh on it (for this Mac's chip only).
    nonisolated static func buildFromSource(_ commit: GitHubCommit, in scratch: URL, step: (String) -> Void) throws -> URL {
        guard (try? run("/usr/bin/xcode-select", ["-p"])) != nil else {
            throw Problem("building needs Apple's command line tools: run xcode-select --install in Terminal")
        }
        let developerDir = try checkSwift()
        step("Downloading \(commit.short)…")
        let tarball = scratch.appendingPathComponent("source.tar.gz")
        if let gh = ghPath(), (try? run(gh, ["api", "repos/\(repo)/tarball/\(commit.sha)"], to: tarball)) != nil {
            // Downloaded by gh.
        } else if let url = URL(string: "https://codeload.github.com/\(repo)/tar.gz/\(commit.sha)") {
            try download(url, to: tarball)
        }
        let src = scratch.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try run("/usr/bin/tar", ["-xzf", tarball.path, "-C", src.path, "--strip-components", "1"])

        step("Building \(commit.short) (a minute or two)…")
        log("building \(commit.short) in \(src.path)")
        var env = ["VERSION": "0.1-\(commit.short)", "COMMIT": commit.sha, "BRANCH": branch, "UNIVERSAL": "0"]
        // The Xcode that passed the check, not the older command line tools.
        if let developerDir { env["DEVELOPER_DIR"] = developerDir }
        try run("/bin/bash", [src.appendingPathComponent("scripts/build-app.sh").path], env: env, in: src, logOutput: true)
        return src.appendingPathComponent("build").appendingPathComponent(builtAppName)
    }

    /// The package needs Swift 5.9 or newer, from the command line tools or an installed Xcode.
    /// Returns the Xcode's developer folder when it's an Xcode's Swift that's new enough (nil: the
    /// command line tools are).
    nonisolated static func checkSwift() throws -> String? {
        func output(_ developerDir: String?) -> String {
            let env = developerDir.map { ["DEVELOPER_DIR": $0] } ?? [:]
            guard let data = try? run("/bin/sh", ["-c", "/usr/bin/xcrun swift --version 2>&1"], env: env) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        let here = output(nil)
        if SwiftToolchain.isNewEnough(here) { return nil }
        let folders = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where name.hasPrefix("Xcode") && name.hasSuffix(".app") {
                let dir = "\(folder)/\(name)/Contents/Developer"
                if SwiftToolchain.isNewEnough(output(dir)) { return dir }
            }
        }
        let have = SwiftToolchain.version(in: here).map { "Swift \($0)" } ?? "no Swift"
        throw Problem("This Mac has \(have); building needs Swift \(SwiftToolchain.required) or newer. "
            + "Update Apple's command line tools in Software Update, or wait for GitHub to build this version.")
    }

    /// The error, plus the end of update.log, for pasting somewhere.
    nonisolated static func report(_ problem: String) -> String {
        guard let log = try? String(contentsOf: logURL, encoding: .utf8) else { return problem }
        let tail = log.components(separatedBy: "\n").suffix(60).joined(separator: "\n")
        return problem + "\n\n--- the end of \(logURL.path) ---\n" + tail
    }

    // MARK: - GitHub

    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// GET https://api.github.com/<path>
    nonisolated static func api(_ path: String) throws -> Data {
        // gh's own error says more ("isn't signed in") than GitHub's 404 for a private repo does.
        var ghError: Error?
        if let gh = ghPath() {
            do { return try run(gh, ["api", path]) } catch { ghError = error }
        }
        guard let url = URL(string: "https://api.github.com/\(path)") else { throw Problem("bad path \(path)") }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404, let ghError { throw ghError }
        if status == 404 { throw Problem("GitHub can't see \(repo): it's private, so install gh (brew install gh) and run gh auth login") }
        if status == 403 { throw Problem("GitHub's hourly limit: try again later, or sign in with gh auth login") }
        guard status == 200 else { throw Problem("GitHub answered \(status)") }
        return data
    }

    nonisolated static func download(_ url: URL, to file: URL) throws {
        let (data, response) = try fetch(URLRequest(url: url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Problem("the download failed (GitHub answered \(status))") }
        try data.write(to: file)
    }

    /// gh from Homebrew (an app opened from the Finder doesn't get Terminal's PATH).
    nonisolated static func ghPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Helpers

    /// ~/Library/Logs/StorageSpaces/update.log: what updates did, and a build's full output.
    nonisolated static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/StorageSpaces/update.log")
    }

    nonisolated static func log(_ line: String) {
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    /// Runs a program and gives back its output (or writes it to `file`). Throws with the last
    /// line of its errors when it fails; `logOutput` copies everything it printed into update.log.
    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String], env extra: [String: String] = [:],
                                in dir: URL? = nil, to file: URL? = nil, logOutput: Bool = false) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        if let dir { process.currentDirectoryURL = dir }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["GH_PROMPT_DISABLED"] = "1"
        env.merge(extra) { $1 }
        process.environment = env
        let out = Pipe(), err = Pipe()
        var outFile: FileHandle?
        if let file {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            outFile = try FileHandle(forWritingTo: file)
            process.standardOutput = outFile
        } else {
            process.standardOutput = out
        }
        defer { try? outFile?.close() }
        process.standardError = err
        try process.run()
        // Errors are read on another thread while the output is read here, so a full pipe can't stall it.
        final class Box: @unchecked Sendable { var data = Data() }
        let errBox = Box()
        let errRead = DispatchGroup()
        errRead.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            errRead.leave()
        }
        let data = file == nil ? out.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        errRead.wait()
        let errData = errBox.data
        let name = (tool as NSString).lastPathComponent
        if logOutput {
            log("\(name) \(args.joined(separator: " "))\n\(String(decoding: data, as: UTF8.self))\(String(decoding: errData, as: UTF8.self))")
        }
        if process.terminationStatus != 0 {
            let lines = String(decoding: errData.isEmpty ? data : errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            let message = logOutput ? (lines.last(where: { $0.contains("error") }) ?? lines.last ?? "") : (lines.last ?? "")
            if name == "gh", message.contains("auth login") || message.contains("401") {
                throw Problem("gh isn't signed in: run gh auth login in Terminal")
            }
            let tail = message.isEmpty ? "\(name) failed (\(process.terminationStatus))" : message
            throw Problem(logOutput ? "\(tail) (details in \(logURL.path))" : tail)
        }
        return data
    }

    nonisolated static func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var result: Result<(Data, URLResponse), Error> = .failure(Problem("no answer")) }
        let box = Box()
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data, let response {
                box.result = .success((data, response))
            } else {
                box.result = .failure(error ?? Problem("no answer"))
            }
            done.signal()
        }.resume()
        done.wait()
        return try box.result.get()
    }
}
