import AppKit
import SwiftUI

// View state lives in small ObservableObjects: in the macOS 27 SDK `@State` is a
// macro whose plugin ships only with Xcode, and this builds with the Command Line Tools.
final class SidebarState: ObservableObject {
    @Published var selection: String?
}

final class DetailState: ObservableObject {
    @Published var confirmOvercommit = false
    @Published var startInRecovery = false
}

struct ContentView: View {
    @EnvironmentObject var library: Library
    @StateObject private var state = SidebarState()

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selection) {
                Section("Virtual Machines") {
                    ForEach(library.vms) { vm in
                        VMRow(vm: vm).tag(vm.id)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { HostUsage().padding(10) }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            if let vm = library.vms.first(where: { $0.id == state.selection }) {
                VMDetail(vm: vm).id(vm.id)
            } else if !library.folderAvailable || library.vms.isEmpty {
                EmptyLibrary()
            } else {
                Text("Select a virtual machine").foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if state.selection == nil {
                let wanted = UserDefaults.standard.string(forKey: "select")
                state.selection = library.vms.first(where: { $0.name == wanted })?.id ?? library.vms.first?.id
            }
        }
        .onChange(of: library.vms.map(\.id)) { _, ids in
            if state.selection == nil || !ids.contains(state.selection!) { state.selection = ids.first }
        }
    }
}

struct VMRow: View {
    @ObservedObject var vm: VMItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: vm.isMac ? "apple.logo" : "terminal.fill")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 22)
                .foregroundStyle(vm.isMac ? Color.primary : Color.teal)
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.name).font(.body.weight(.medium))
                Text("\(vm.isMac ? "macOS" : "Linux") · \(vm.cpus) CPU · \(vm.memoryGB) GB")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(vm.isRunning ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)
                .help(vm.isRunning ? "Running" : "Stopped")
        }
        .padding(.vertical, 3)
    }
}

/// Footer showing how much of the host is promised to running VMs.
struct HostUsage: View {
    @EnvironmentObject var library: Library

    var body: some View {
        let mem = library.runningMemoryGB
        VStack(alignment: .leading, spacing: 6) {
            Text("Running: \(library.running.count) of \(library.vms.count)")
                .font(.caption.weight(.semibold))
            Gauge(value: Double(min(mem, Host.memoryGB)), in: 0...Double(Host.memoryGB)) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(mem > Host.memoryGB - 2 ? .orange : .accentColor)
            Text("\(mem) of \(Host.memoryGB) GB memory · \(library.runningCPUs) of \(Host.cpus) CPUs")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyLibrary: View {
    @EnvironmentObject var library: Library

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text(library.folderAvailable ? "No virtual machines here" : "VM folder not found")
                .font(.title3.weight(.semibold))
            Text(library.folder.path).font(.callout.monospaced()).foregroundStyle(.secondary)
            Button("Choose VM Folder…") { chooseVMFolder(library) }
        }
        .padding()
    }
}

@MainActor
func chooseVMFolder(_ library: Library) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Use Folder"
    panel.message = "Choose the folder that holds your VM bundles (each with a config.json)."
    panel.directoryURL = library.folder
    if panel.runModal() == .OK, let url = panel.url { library.choose(folder: url) }
}

struct VMDetail: View {
    @EnvironmentObject var library: Library
    @ObservedObject var vm: VMItem
    @StateObject private var state = DetailState()

    var body: some View {
        Form {
            Section {
                header
            }
            if let failure = vm.failure {
                Section {
                    Label {
                        Text(failure).font(.callout.monospaced()).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Button("Dismiss") { vm.failure = nil }
                } header: {
                    Text("Last start failed")
                }
            }
            resources
            networkSection
            sharedFolders
            storage
        }
        .formStyle(.grouped)
        .navigationTitle(vm.name)
        .alert("Not enough memory for everything", isPresented: $state.confirmOvercommit) {
            Button("Start Anyway") { vm.start(runner: library.runnerURL, recovery: state.startInRecovery) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Running VMs already use \(library.runningMemoryGB) GB. Starting \(vm.name) with "
                    + "\(vm.memoryGB) GB would give VMs \(library.runningMemoryGB + vm.memoryGB) GB of this "
                    + "Mac's \(Host.memoryGB) GB, and everything will slow down.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: vm.isMac ? "apple.logo" : "terminal.fill")
                .font(.system(size: 26, weight: .medium))
                .frame(width: 48, height: 48)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.name).font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(vm.isRunning ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(statusText).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            controls
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        if vm.isRunning { return vm.stopRequested ? "Shutting down…" : "Running" }
        return vm.isMac ? "macOS · Stopped" : "Linux · Stopped"
    }

    @ViewBuilder
    private var controls: some View {
        if vm.isRunning {
            Button("Show") { vm.bringToFront() }
            if vm.stopRequested {
                Button("Force Stop", role: .destructive) { vm.stop() }
                    .help("Cut the power without waiting for the guest")
            } else {
                Button("Shut Down") { vm.stop() }
                    .help("Press the guest's power button")
            }
        } else {
            if vm.isMac {
                Menu {
                    Button("Start in macOS Recovery") { start(recovery: true) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                } primaryAction: {
                    start(recovery: false)
                }
                .menuStyle(.borderedButton)
                .fixedSize()
            } else {
                Button { start(recovery: false) } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func start(recovery: Bool) {
        state.startInRecovery = recovery
        if library.runningMemoryGB + vm.memoryGB > Host.memoryGB {
            state.confirmOvercommit = true
        } else {
            vm.start(runner: library.runnerURL, recovery: recovery)
        }
    }

    private var resources: some View {
        Section {
            LabeledContent("Processors") {
                HStack {
                    Slider(
                        value: Binding(get: { Double(vm.cpus) }, set: { vm.cpus = Int($0.rounded()) }),
                        in: 1...Double(Host.cpus), step: 1)
                    Text("\(vm.cpus)").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            LabeledContent("Memory") {
                HStack {
                    Slider(
                        value: Binding(get: { Double(vm.memoryGB) }, set: { vm.memoryGB = Int($0.rounded()) }),
                        in: 1...Double(Host.memoryGB), step: 1)
                    Text("\(vm.memoryGB) GB").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Picker("Display", selection: $vm.display) {
                ForEach(displayChoices, id: \.self) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Resources")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if vm.memoryGB > Host.memoryGB - 2 {
                    Label(
                        "Leaves less than 2 GB for this Mac (\(Host.memoryGB) GB total).",
                        systemImage: "exclamationmark.triangle"
                    ).foregroundStyle(.orange)
                }
                if vm.isMac && vm.memoryGB < 4 {
                    Label("macOS guests are very slow with less than 4 GB.", systemImage: "tortoise")
                        .foregroundStyle(.orange)
                }
                if let was = vm.runningWith, was != (vm.cpus, vm.memoryGB) {
                    Text("Running with \(was.cpus) CPUs and \(was.memoryGB) GB; changes apply at the next start.")
                        .foregroundStyle(.secondary)
                } else if vm.isRunning {
                    Text("Changes apply the next time it starts.").foregroundStyle(.secondary)
                }
                if let err = vm.saveError { Text(err).foregroundStyle(.red) }
            }
            .font(.caption)
        }
    }

    private var networkSection: some View {
        Section {
            Picker("Network", selection: Binding(
                get: { vm.network == "internet-only" },
                set: { library.setNetwork(vm, internetOnly: $0) }
            )) {
                Text("Internet and local network").tag(false)
                Text("Internet only").tag(true)
            }
            if vm.network == "internet-only" {
                LabeledContent("Subnet") {
                    Text(vm.subnet.map { "\($0)/24" } ?? "assigned at start").monospacedDigit()
                }
            }
        } header: {
            Text("Network")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if vm.network == "internet-only" {
                    Text("The VM gets a network of its own: internet over IPv4, no IPv6, and no "
                        + "connection to other VMs.")
                    if library.guardInstalled {
                        Label("Network guard is on: this VM can't reach your local network or services on this Mac.",
                              systemImage: "checkmark.shield")
                            .foregroundStyle(.green)
                    } else {
                        Label("The network guard isn't installed, so this VM can still reach devices on your "
                              + "local network over IPv4. Install it once (needs your admin password):",
                              systemImage: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                        Text(library.guardInstallCommand)
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                } else {
                    Text("Shares the Mac's network: the VM can reach the internet, other VMs, devices on your "
                        + "local network, and services on this Mac.")
                }
                if vm.isRunning { Text("Changes apply the next time it starts.") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var displayChoices: [DisplaySize] {
        DisplaySize.presets.contains(vm.display) ? DisplaySize.presets : DisplaySize.presets + [vm.display]
    }

    private var sharedFolders: some View {
        Section {
            if vm.shares.isEmpty {
                Text("No folders shared with this VM.").foregroundStyle(.secondary)
            }
            ForEach($vm.shares) { $share in
                HStack(spacing: 10) {
                    Image(systemName: share.exists ? "folder.fill" : "folder.badge.questionmark")
                        .foregroundStyle(share.exists ? Color.accentColor : Color.orange)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(share.name)
                        Text(share.exists ? share.path : "\(share.path) — not found, will be skipped")
                            .font(.caption).foregroundStyle(share.exists ? Color.secondary : Color.orange)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Toggle("Read-only", isOn: $share.readOnly).toggleStyle(.checkbox)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([share.url])
                    } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).help("Show in Finder")
                        .disabled(!share.exists)
                    Button {
                        vm.shares.removeAll { $0.id == share.id }
                    } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Stop sharing")
                }
            }
        } header: {
            HStack {
                Text("Shared Folders")
                Spacer()
                Button {
                    addFolders()
                } label: { Label("Add Folder…", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
        } footer: {
            Text(shareHint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var shareHint: String {
        let guest = vm.isMac
            ? "In the guest, look for “My Shared Files” in the Finder sidebar (/Volumes/My Shared Files)."
            : "In the guest, the share is mounted from the tag “shared” (the Linux VMs built here mount it at ~/shared)."
        return guest + " One folder appears as the share itself; with several, each is a subfolder named "
            + "after it. Changes apply the next time the VM starts."
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Share"
        panel.message = "Choose folders to share with \(vm.name)."
        if panel.runModal() == .OK { vm.addShares(panel.urls) }
    }

    private var storage: some View {
        Section("Storage") {
            LabeledContent("Disk") {
                Text(String(format: "%.0f GB  ·  %.1f GB used on this Mac", vm.diskSizeGB, vm.diskUsedGB))
                    .monospacedDigit()
            }
            LabeledContent("Location") {
                HStack {
                    Text(vm.url.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([vm.url])
                    } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).help("Show in Finder")
                }
            }
        }
    }
}
