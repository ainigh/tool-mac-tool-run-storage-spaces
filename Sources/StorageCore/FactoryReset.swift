import Foundation

/// Factory reset: Storage Spaces back as it was installed. STORAGE-SPACES (every space, the
/// access rules, the apps' keys) goes to the Trash, so it can be had back; its settings are
/// forgotten too. It's done once the app has quit, then the app opens again with every space as
/// it comes (MEMORY's files, Super Face's two notes), and doesn't bring Tool Mac Tool Run's
/// things in again by itself (the window's Import does that, when asked). Taken from Tool Mac
/// Tool Run's.
public enum FactoryReset {
    public struct Plan: Sendable, Equatable {
        /// What goes to the Trash.
        public var trash: [URL]
        /// What's kept though it's the app's, and why ("~/Documents: it holds more than the app's").
        public var kept: [String]
    }

    /// What a factory reset takes away: what's there now.
    public static func plan(root: URL = Storage.defaultRoot, support: URL? = nil,
                            user: URL = FileManager.default.homeDirectoryForCurrentUser) -> Plan {
        let fm = FileManager.default
        var trash: [URL] = []
        var kept: [String] = []
        for url in [root] + (support.map { [$0] } ?? []) {
            let u = url.standardizedFileURL
            guard fm.fileExists(atPath: u.path) else { continue }
            if mayRemove(u, user: user) { trash.append(u) } else { kept.append("\(short(u, user)): it holds more than the app's") }
        }
        return Plan(trash: trash, kept: kept)
    }

    /// Whether a folder may go to the Trash whole: not the top of the disk, the person's home or
    /// anything holding it, nor one of the folders every Mac has (Desktop, Documents, Downloads…).
    public static func mayRemove(_ folder: URL, user: URL) -> Bool {
        let f = folder.standardizedFileURL.path, home = user.standardizedFileURL.path
        if f == "/" || f.isEmpty || within(user.standardizedFileURL, folder.standardizedFileURL) { return false }
        let mine = ["Desktop", "Documents", "Downloads", "Library", "Applications", "Movies", "Music", "Pictures", "Public", "Sites", "iCloud Drive"]
        if mine.contains(where: { f == home + "/" + $0 }) { return false }
        let system = ["/Applications", "/Library", "/System", "/Users", "/Volumes", "/private", "/usr", "/bin", "/sbin", "/opt", "/etc", "/var", "/tmp"]
        if system.contains(f) || (f.hasPrefix("/Volumes/") && f.split(separator: "/").count <= 2) { return false }
        return true
    }

    /// Whether `inner` is `outer` or inside it.
    static func within(_ inner: URL, _ outer: URL) -> Bool {
        let i = inner.standardizedFileURL.path, o = outer.standardizedFileURL.path
        return i == o || i.hasPrefix(o.hasSuffix("/") ? o : o + "/")
    }

    public static func short(_ url: URL, _ user: URL) -> String {
        let p = url.standardizedFileURL.path, h = user.standardizedFileURL.path
        return p.hasPrefix(h + "/") ? "~" + p.dropFirst(h.count) : p
    }

    /// What does it, as `sh -c script factory-reset PID TRASH STAMP APP DOMAIN PATH…`: waits for
    /// the app (PID) to have quit, moves each PATH into TRASH as "NAME (reset STAMP)", forgets the
    /// settings kept under DOMAIN (none: "") but that it was reset, and opens APP again (none: "").
    public static let script = """
    pid="$1"; trash="$2"; stamp="$3"; app="$4"; domain="$5"; shift 5
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    mkdir -p "$trash"
    for p in "$@"; do
      [ -e "$p" ] || continue
      dest="$trash/$(basename "$p") (reset $stamp)"
      n=2
      while [ -e "$dest" ]; do dest="$trash/$(basename "$p") (reset $stamp $n)"; n=$((n + 1)); done
      mv "$p" "$dest"
    done
    if [ -n "$domain" ]; then
      /usr/bin/defaults delete "$domain" >/dev/null 2>&1
      /usr/bin/defaults write "$domain" didFactoryReset -bool true
    fi
    if [ -n "$app" ]; then /usr/bin/open "$app"; fi
    exit 0
    """

    /// The arguments `script` takes, after `-c script`.
    public static func arguments(pid: Int32, trash: URL, app: URL?, domain: String?, plan: Plan, at date: Date = Date()) -> [String] {
        ["factory-reset", String(pid), trash.path, Storage.stamp(date), app?.path ?? "", domain ?? ""] + plan.trash.map(\.path)
    }
}
