import StorageCore
import SwiftUI

/// The window: every space and what's in it, what's waiting for a yes or a no, who may do
/// what, and the settings (Open at Login, bringing in Tool Mac Tool Run's things, resets, updates).
struct SpacesView: View {
    @EnvironmentObject var model: StorageModel
    @ObservedObject private var tabs = WindowTab.shared

    var body: some View {
        VStack(spacing: 0) {
            StatusLine()
            Picker("", selection: $tabs.tab) {
                Text("Spaces").tag(0)
                Text(model.waiting.isEmpty ? "Waiting" : "Waiting (\(model.waiting.count))").tag(1)
                Text("Access").tag(2)
                Text("Settings").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            if let message = model.message {
                HStack(alignment: .top) {
                    Text(message).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            Divider()
            switch tabs.tab {
            case 0: SpacesList()
            case 1: WaitingList()
            case 2: AccessList()
            default: SettingsView()
            }
        }
        .frame(minWidth: 480, minHeight: 480)
        .task { await model.refresh() }
    }
}

/// Whether the API is up, in a line.
struct StatusLine: View {
    @EnvironmentObject var model: StorageModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.serverState {
            case let .running(port):
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Serving the apps on 127.0.0.1:\(port)").font(.caption)
            case let .failed(why):
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text(why).font(.caption)
            default:
                Circle().fill(Color.orange).frame(width: 8, height: 8)
                Text("Starting…").font(.caption)
            }
            Spacer()
            Button("Show in Finder") { model.openFolder() }.controlSize(.small)
        }
        .padding(12)
    }
}

/// Every space, a section each, with its stores.
struct SpacesList: View {
    @EnvironmentObject var model: StorageModel

    var body: some View {
        List {
            ForEach(model.spaces) { space in
                Section {
                    if space.stores.isEmpty {
                        Text(space.space == "other" ? "No other app has written here yet." : "Nothing here.").foregroundStyle(.secondary)
                    }
                    ForEach(space.stores) { store in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: Self.icon(store.kind)).frame(width: 18).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(store.name.uppercased()).font(.body.weight(.medium))
                                    Text(store.count).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(store.purpose).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button { model.reveal(store.folder) } label: { Image(systemName: "folder") }
                                .buttonStyle(.borderless)
                                .help("Show \(store.name.uppercased()) in the Finder")
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(space.space.uppercased()) · \(space.title)").font(.headline)
                        Text(space.purpose).font(.caption).foregroundStyle(.secondary).textCase(nil)
                    }
                }
            }
        }
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "memory": "brain.head.profile"
        case "mind": "point.3.connected.trianglepath.dotted"
        case "records": "list.bullet.rectangle"
        default: "doc.text"
        }
    }
}

/// What's waiting for a yes or a no: apps asking for access, and changes held.
struct WaitingList: View {
    @EnvironmentObject var model: StorageModel

    var body: some View {
        if model.waiting.isEmpty {
            VStack {
                Spacer()
                Text("Nothing is waiting. When an app asks to read or change a space that isn't its own, it shows here (and Peter may answer it for you).")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            }
        } else {
            List(model.waiting) { w in
                VStack(alignment: .leading, spacing: 6) {
                    Text(w.kind == .access ? "\(w.client) asks to \(w.what)" : "\(w.client) wants to \(w.what)").font(.body.weight(.medium))
                    if let why = w.why { Text("“\(why)”").font(.callout).foregroundStyle(.secondary) }
                    Text("Asked \(w.asked)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if w.kind == .access {
                            Button("Allow for an Hour") { model.decide(w, yes: true, hours: 1) }
                            Button("Allow") { model.decide(w, yes: true) }
                        } else {
                            Button("Do It") { model.decide(w, yes: true) }
                        }
                        Button("Say No", role: .destructive) { model.decide(w, yes: false) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// Who may do what beyond their own space, and the apps that have claimed their names.
struct AccessList: View {
    @EnvironmentObject var model: StorageModel

    var body: some View {
        List {
            Section {
                Text("Peter may read and write every space: he's the one who lets other apps in. Every other app has its own space (Super Face: SUPER; any other: its folder in OTHER), and asks for the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Allowed") {
                if model.grants.isEmpty { Text("No app has been let in beyond its own space.").foregroundStyle(.secondary) }
                ForEach(model.grants) { g in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.line)
                            if let why = g.why { Text(why).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Take Back") { model.revoke(g) }.controlSize(.small)
                    }
                }
            }
            Section("Apps") {
                if model.clients.isEmpty { Text("No app has used Storage Spaces yet.").foregroundStyle(.secondary) }
                ForEach(model.clients) { c in
                    HStack {
                        Text(c.name)
                        if c.hasKey { Image(systemName: "key.fill").foregroundStyle(.secondary).help("It has claimed its name with a key") }
                        Spacer()
                        if c.hasKey {
                            Button("Forget Its Key") { model.forgetKey(c) }
                                .controlSize(.small)
                                .help("So it can register again (if it lost its key)")
                        }
                    }
                }
            }
        }
    }
}

/// Open at Login, bringing in Tool Mac Tool Run's things, resets, updates.
struct SettingsView: View {
    @EnvironmentObject var model: StorageModel
    @EnvironmentObject var updater: Updater

    var body: some View {
        Form {
            Section("Where it's kept") {
                Text(FactoryReset.short(model.storage.root, FileManager.default.homeDirectoryForCurrentUser)).textSelection(.enabled)
                Button("Show in Finder") { model.openFolder() }
            }
            Section("Tool Mac Tool Run") {
                Text("Copies its library, MEMORY and mind (and Peter's schedule) in. Its own are left as they were; what's here already is kept, and a note that differs comes in beside it.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Bring In Tool Mac Tool Run's Things") { model.importNow() }.disabled(!model.importAvailable)
            }
            Section("Reset") {
                ForEach(model.spaces.filter { $0.space != "pending" }) { space in
                    Button("Reset \(space.title)'s Space…") { model.reset(space) }
                }
                Button("Factory Reset…", role: .destructive) { model.factoryReset() }
            }
            Section("Storage Spaces") {
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                Text(updater.versionLine).foregroundStyle(.secondary)
                switch updater.state {
                case let .available(plan): Button("Update: \(plan.title)") { updater.install() }
                case let .installing(step): Text(step)
                case .checking: Text("Checking for updates…")
                case let .failed(why):
                    Text(why).foregroundStyle(.red)
                    Button("Check for updates") { updater.check(userInitiated: true) }
                case .upToDate:
                    Text("Up to date").foregroundStyle(.secondary)
                    Button("Check for updates") { updater.check(userInitiated: true) }
                case .idle: Button("Check for updates") { updater.check(userInitiated: true) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
