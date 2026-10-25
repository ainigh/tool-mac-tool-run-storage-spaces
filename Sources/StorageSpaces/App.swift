import AppKit
import ServiceManagement
import StorageCore
import SwiftUI

/// Storage Spaces in the menu bar: its icon (filled while something waits for you), a menu with
/// how things stand, its window (the spaces, what's waiting, who may do what, settings), updates,
/// Factory Reset and Quit. Its HTTP API runs while the app does, on 127.0.0.1:8771.
@main
struct StorageSpacesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The icon and its menu are AppKit's (`AppDelegate`). This scene is never shown; it's
        // here because an app needs one.
        MenuBarExtra("Storage Spaces", systemImage: "square.stack.3d.up", isInserted: .constant(false)) {
            EmptyView()
        }
    }
}

/// A store, as the window shows it.
struct StoreRow: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let kind: String
    let purpose: String
    let folder: String
    /// "12 notes", "40 nodes".
    let count: String
}

/// A space, as the window shows it.
struct SpaceRow: Identifiable, Equatable {
    var id: String { space }
    let space: String
    let title: String
    let purpose: String
    let folder: String
    let stores: [StoreRow]
}

/// Something waiting for a yes or a no: a request for access, or a change held.
struct Waiting: Identifiable, Equatable {
    enum Kind { case access, write }
    var id: String { "\(kind == .access ? "request" : "write")-\(number)" }
    let kind: Kind
    let number: Int
    let client: String
    /// "read USER/MEMORY", "write shopping in USER/LIBRARY".
    let what: String
    let why: String?
    let asked: String
}

struct GrantRow: Identifiable, Equatable {
    let id: Int
    let line: String
    let why: String?
}

struct ClientRow: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let hasKey: Bool
    let grants: Int
}

/// What the app holds: the storage and its API, the server, and what the window shows.
@MainActor
final class StorageModel: ObservableObject {
    static let shared = StorageModel()

    let api: StorageAPI
    let server: APIServer
    let updater = Updater()
    let storage: Storage

    @Published private(set) var serverState: APIServer.State = .stopped
    @Published private(set) var spaces: [SpaceRow] = []
    @Published private(set) var waiting: [Waiting] = []
    @Published private(set) var grants: [GrantRow] = []
    @Published private(set) var clients: [ClientRow] = []
    @Published private(set) var importAvailable = false
    /// What the last import, reset or decision said (or what went wrong).
    @Published var message: String?
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled

    private var refreshTimer: Timer?
    /// The requests and held changes a notification was posted for (each is told about once).
    private var told: Set<String> = []
    /// Called when what's waiting changes (the menu bar icon).
    var onWaiting: ((Int) -> Void)?

    nonisolated static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The docs it ships with (Contents/Resources/docs; the repository's, under `swift run`).
    nonisolated static var docs: [URL] {
        var out: [URL] = []
        if let r = Bundle.main.resourceURL { out.append(r.appendingPathComponent("docs", isDirectory: true)) }
        let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        out += [here, here.appendingPathComponent("docs", isDirectory: true)]
        return out
    }

    private init() {
        let storage = Storage()
        self.storage = storage
        api = StorageAPI(storage: storage, version: Self.version, docs: Self.docs)
        server = APIServer(api: api)
        server.onState = { [weak self] state in MainActor.assumeIsolated { self?.serverState = state } }
        // Start at login from the first launch; the menu has the switch to turn it off.
        let key = "didSetUpOpenAtLogin"
        if !UserDefaults.standard.bool(forKey: key), Bundle.main.bundleURL.pathExtension == "app" {
            UserDefaults.standard.set(true, forKey: key)
            setOpenAtLogin(true)
        }
    }

    func start() {
        let api = self.api
        Task {
            do {
                try await api.start()
            } catch {
                message = "Couldn't make \(storage.root.path): \(error.localizedDescription)"
            }
            await api.setOnChange {
                Task { @MainActor in StorageModel.shared.refreshSoon() }
            }
            // Once, what Tool Mac Tool Run and Peter kept comes in (not after a factory reset).
            let reset = UserDefaults.standard.bool(forKey: "didFactoryReset")
            if !reset, !ToolMacImport.done(in: storage), ToolMacImport.available() {
                let r = await api.asPerson("POST", "/api/import")
                let summary = r.json["summary"] as? String ?? "Brought in what Tool Mac Tool Run kept."
                message = summary
                Notifier.post(title: "Storage Spaces is ready", body: summary + " Tool Mac Tool Run's own are left as they were.")
            }
            await refresh()
            await api.watch()
            server.start(port: StorageAPI.port, network: false)
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in await StorageModel.shared.refresh() }
        }
        updater.start()
    }

    /// How things stand: the spaces, what's waiting, the grants, the clients.
    func refresh() async {
        let s = await api.asPerson("GET", "/api/spaces")
        spaces = (s.json["spaces"] as? [[String: Any]] ?? []).map { sp in
            SpaceRow(space: sp["space"] as? String ?? "", title: sp["title"] as? String ?? "", purpose: sp["purpose"] as? String ?? "",
                     folder: sp["folder"] as? String ?? "",
                     stores: (sp["stores"] as? [[String: Any]] ?? []).map { st in
                         let kind = st["kind"] as? String ?? ""
                         let count: String
                         switch kind {
                         case "mind": count = "\(st["nodes"] as? Int ?? 0) nodes, \(st["edges"] as? Int ?? 0) links"
                         case "records": count = Self.count(st["records"] as? Int ?? 0, "record")
                         default: count = Self.count(st["notes"] as? Int ?? 0, kind == "memory" ? "file" : "note")
                         }
                         return StoreRow(path: st["path"] as? String ?? "", name: st["store"] as? String ?? "", kind: kind,
                                         purpose: st["purpose"] as? String ?? "", folder: st["folder"] as? String ?? "", count: count)
                     })
        }
        let p = await api.asPerson("GET", "/api/pending")
        var list: [Waiting] = []
        for r in p.json["requests"] as? [[String: Any]] ?? [] {
            let place = (r["space"] as? String ?? "").uppercased() + ((r["store"] as? String).map { "/" + $0.uppercased() } ?? "")
            list.append(Waiting(kind: .access, number: r["id"] as? Int ?? 0, client: r["client"] as? String ?? "?",
                                what: "\(r["access"] as? String ?? "read") \(place)", why: r["why"] as? String, asked: r["asked"] as? String ?? ""))
        }
        for w in p.json["writes"] as? [[String: Any]] ?? [] where w["state"] as? String == "waiting" {
            list.append(Waiting(kind: .write, number: w["id"] as? Int ?? 0, client: w["client"] as? String ?? "?",
                                what: w["what"] as? String ?? "a change", why: w["why"] as? String, asked: w["asked"] as? String ?? ""))
        }
        if list != waiting {
            waiting = list
            onWaiting?(list.count)
            tell(list)
        }
        let a = await api.asPerson("GET", "/api/access")
        grants = (a.json["all_grants"] as? [[String: Any]] ?? []).map { GrantRow(id: $0["id"] as? Int ?? 0, line: $0["line"] as? String ?? "", why: $0["why"] as? String) }
        let c = await api.asPerson("GET", "/api/clients")
        clients = (c.json["clients"] as? [[String: Any]] ?? []).map { ClientRow(name: $0["client"] as? String ?? "", hasKey: $0["has_key"] as? Bool ?? false, grants: $0["grants"] as? Int ?? 0) }
        let i = await api.asPerson("GET", "/api/import")
        importAvailable = i.json["available"] as? Bool ?? false
    }

    /// A refresh in a moment: many changes at once make one.
    func refreshSoon() {
        guard !refreshPending else { return }
        refreshPending = true
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            refreshPending = false
            await refresh()
        }
    }

    private var refreshPending = false

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// A notification for each new thing waiting (Peter may answer it first; then it's gone).
    private func tell(_ list: [Waiting]) {
        for w in list where !told.contains(w.id) {
            told.insert(w.id)
            let title = w.kind == .access ? "\(w.client) asks to \(w.what)" : "\(w.client) wants to \(w.what)"
            Notifier.post(title: title, body: (w.why.map { "\"\($0)\" " } ?? "") + "Open Storage Spaces to say yes or no (Peter may answer first).")
        }
    }

    var waitingCount: Int { waiting.count }

    // MARK: deciding

    func decide(_ w: Waiting, yes: Bool, hours: Double? = nil) {
        let api = self.api
        Task {
            let path = w.kind == .access ? "/api/access/requests/\(w.number)/\(yes ? "approve" : "deny")" : "/api/pending/\(w.number)/\(yes ? "approve" : "deny")"
            let r = await api.asPerson("POST", path, hours.map { ["hours": $0] })
            if r.status >= 400 { message = r.json["error"] as? String ?? "That didn't work." }
            await refresh()
        }
    }

    func revoke(_ g: GrantRow) {
        let api = self.api
        Task {
            _ = await api.asPerson("DELETE", "/api/access/grants/\(g.id)")
            await refresh()
        }
    }

    func forgetKey(_ c: ClientRow) {
        let api = self.api
        Task {
            _ = await api.asPerson("POST", "/api/clients/forget", ["name": c.name])
            message = "\(c.name)'s key is forgotten: it can register again."
            await refresh()
        }
    }

    // MARK: the folders

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openFolder() {
        NSWorkspace.shared.open(storage.root)
    }

    func importNow() {
        let api = self.api
        Task {
            let r = await api.asPerson("POST", "/api/import")
            message = r.json["summary"] as? String ?? (r.json["error"] as? String ?? "Done.")
            await refresh()
        }
    }

    /// A space back as it came, once you've said so: what's in it goes to the Trash.
    func reset(_ space: SpaceRow) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Reset \(space.title)'s space?"
        alert.informativeText = "Everything in \(space.space.uppercased()) (\(space.stores.map(\.name).joined(separator: ", "))) goes to the Trash (you can get it back from there), and it starts again as it came."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let api = self.api
        Task {
            let r = await api.asPerson("POST", "/api/spaces/\(space.space)/reset")
            message = r.json["message"] as? String ?? r.json["error"] as? String
            await refresh()
        }
    }

    /// Factory reset: STORAGE-SPACES goes to the Trash (`FactoryReset`) and the settings are
    /// forgotten; then the app opens again as it was installed.
    func factoryReset() {
        NSApp.activate(ignoringOtherApps: true)
        let plan = FactoryReset.plan(root: storage.root)
        let user = FileManager.default.homeDirectoryForCurrentUser
        let alert = NSAlert()
        alert.messageText = "Factory reset Storage Spaces?"
        var info = "It quits, and these go to the Trash (you can get them back from there):\n"
            + (plan.trash.isEmpty ? "• nothing (there's nothing yet)" : plan.trash.map { "• " + FactoryReset.short($0, user) }.joined(separator: "\n"))
        if !plan.kept.isEmpty { info += "\n\nKept: " + plan.kept.joined(separator: "; ") + "." }
        info += "\n\nThat's every space: your library, MEMORY and the mind, Super Face's and Peter's, and who may do what. Its settings are forgotten too. Then it opens again as it was installed, with every space as it comes."
        alert.informativeText = info
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset and Restart").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let app = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/bin/sh")
        reset.arguments = ["-c", FactoryReset.script] + FactoryReset.arguments(pid: getpid(), trash: user.appendingPathComponent(".Trash", isDirectory: true),
                                                                              app: app, domain: Bundle.main.bundleIdentifier, plan: plan)
        do {
            try reset.run()
        } catch {
            message = "Couldn't factory reset: \(error.localizedDescription)"
            return
        }
        NSApp.terminate(nil)
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var item: NSStatusItem!
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            setIcon(waiting: 0)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            let model = StorageModel.shared
            model.onWaiting = { [weak self] n in self?.setIcon(waiting: n) }
            model.start()
        }
    }

    @MainActor
    private func setIcon(waiting: Int) {
        let name = waiting > 0 ? "square.stack.3d.up.fill" : "square.stack.3d.up"
        item.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: waiting > 0 ? "Storage Spaces (\(waiting) waiting)" : "Storage Spaces")
        item.button?.toolTip = waiting > 0 ? "Storage Spaces: \(waiting) waiting for a yes or no" : "Storage Spaces"
    }

    // MARK: the menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { build(menu) }
    }

    @MainActor
    private func build(_ menu: NSMenu) {
        let model = StorageModel.shared
        Task { await model.refresh() }
        menu.removeAllItems()
        func info(_ title: String) {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        func action(_ title: String, _ selector: Selector, key: String = "") {
            let i = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            i.target = self
            menu.addItem(i)
        }
        let n = model.waitingCount
        info(n == 0 ? "Storage Spaces — ready" : "Storage Spaces — \(n) waiting for a yes or no")
        switch model.serverState {
        case let .running(port): info("Listening on 127.0.0.1:\(port)")
        case let .failed(why): info("Not listening: \(why)")
        default: info("Not listening yet")
        }
        for space in model.spaces where !space.stores.isEmpty {
            info("\(space.title): " + space.stores.map { "\($0.name) \($0.count)" }.joined(separator: " · "))
        }
        menu.addItem(.separator())
        action("Open Storage Spaces…", #selector(openWindow), key: "o")
        if n > 0 { action("Waiting (\(n))…", #selector(openWaiting)) }
        action("Show in Finder", #selector(showInFinder))
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = model.openAtLogin ? .on : .off
        menu.addItem(login)
        if model.importAvailable { action("Bring In Tool Mac Tool Run's Things", #selector(importNow)) }
        menu.addItem(.separator())
        info(model.updater.versionLine)
        switch model.updater.state {
        case let .available(plan): action("Update: \(plan.title)", #selector(installUpdate))
        case let .installing(step): info(step)
        case .checking: info("Checking for updates…")
        case let .failed(why):
            info(why)
            action("Check for Updates", #selector(checkUpdates))
        default: action("Check for Updates", #selector(checkUpdates))
        }
        menu.addItem(.separator())
        action("Factory Reset…", #selector(factoryReset))
        action("Quit Storage Spaces", #selector(quit), key: "q")
    }

    @MainActor
    private func show(tab: Int) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Storage Spaces"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SpacesView().environmentObject(StorageModel.shared).environmentObject(StorageModel.shared.updater))
            w.delegate = self
            w.center()
            window = w
        }
        WindowTab.shared.tab = tab
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func openWindow() { MainActor.assumeIsolated { show(tab: StorageModel.shared.waitingCount > 0 ? 1 : 0) } }
    @objc func openWaiting() { MainActor.assumeIsolated { show(tab: 1) } }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { window = nil }
    }

    @objc func showInFinder() { MainActor.assumeIsolated { StorageModel.shared.openFolder() } }
    @objc func toggleLogin() { MainActor.assumeIsolated { StorageModel.shared.setOpenAtLogin(!StorageModel.shared.openAtLogin) } }
    @objc func importNow() { MainActor.assumeIsolated { StorageModel.shared.importNow() } }
    @objc func checkUpdates() { MainActor.assumeIsolated { StorageModel.shared.updater.check(userInitiated: true) } }
    @objc func installUpdate() { MainActor.assumeIsolated { StorageModel.shared.updater.install() } }
    @objc func factoryReset() { MainActor.assumeIsolated { StorageModel.shared.factoryReset() } }
    @objc func quit() { NSApp.terminate(nil) }
}

/// Which tab the window shows (the menu opens it on Waiting when something is).
@MainActor
final class WindowTab: ObservableObject {
    static let shared = WindowTab()
    @Published var tab = 0
}
