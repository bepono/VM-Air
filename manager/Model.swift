import AppKit
import Foundation

/// A host folder shared with a guest.
struct SharedFolder: Identifiable, Hashable {
    let id = UUID()
    var path: String
    var readOnly: Bool

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var exists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

struct DisplaySize: Hashable {
    var width: Int
    var height: Int
    var label: String { "\(width) × \(height)" }

    static let presets = [
        DisplaySize(width: 1280, height: 800),
        DisplaySize(width: 1440, height: 900),
        DisplaySize(width: 1680, height: 1050),
        DisplaySize(width: 1920, height: 1200),
        DisplaySize(width: 2560, height: 1600),
    ]
}

enum Host {
    static let cpus = ProcessInfo.processInfo.activeProcessorCount
    static let memoryGB = Int(ProcessInfo.processInfo.physicalMemory >> 30)
}

/// One VM bundle on disk: a folder holding config.json, disk.img and its identity files.
/// Settings are written back to config.json as soon as they change; vmctl reads them
/// at the next start.
@MainActor
final class VMItem: ObservableObject, Identifiable {
    let url: URL
    nonisolated var id: String { url.path }
    var name: String { url.lastPathComponent }

    @Published private(set) var kind = "linux"
    @Published var cpus = 2 { didSet { save() } }
    @Published var memoryGB = 2 { didSet { save() } }
    @Published var display = DisplaySize(width: 1280, height: 800) { didSet { save() } }
    @Published var shares: [SharedFolder] = [] { didSet { save() } }
    /// "nat" or "internet-only" (see vmctl). `subnet` is assigned by Library.
    @Published var network = "nat" { didSet { save() } }
    @Published var subnet: String? { didSet { save() } }

    @Published private(set) var pid: pid_t?
    @Published private(set) var stopRequested = false
    @Published var failure: String?
    @Published var saveError: String?

    /// What the running VM was started with, to tell the user which edits are pending.
    @Published private(set) var runningWith: (cpus: Int, memoryGB: Int)?

    private var raw: [String: Any] = [:]
    private var loading = false
    private var process: Process?

    var isMac: Bool { kind == "mac" }
    var isRunning: Bool { pid != nil }
    var configURL: URL { url.appendingPathComponent("config.json") }
    var diskURL: URL { url.appendingPathComponent("disk.img") }
    var logURL: URL { url.appendingPathComponent("runner.log") }
    var lockURL: URL { url.appendingPathComponent(".lock") }

    init?(url: URL) {
        self.url = url
        guard load() else { return nil }
    }

    @discardableResult
    func load() -> Bool {
        guard let data = try? Data(contentsOf: configURL),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kind = obj["kind"] as? String
        else { return false }
        loading = true
        defer { loading = false }
        raw = obj
        self.kind = kind
        cpus = obj["cpus"] as? Int ?? 2
        memoryGB = obj["memoryGB"] as? Int ?? 2
        display = DisplaySize(width: obj["width"] as? Int ?? 1280, height: obj["height"] as? Int ?? 800)
        network = obj["network"] as? String ?? "nat"
        subnet = obj["subnet"] as? String
        shares = (obj["shares"] as? [[String: Any]] ?? []).compactMap { d in
            guard let path = d["path"] as? String else { return nil }
            return SharedFolder(path: path, readOnly: d["readOnly"] as? Bool ?? false)
        }
        return true
    }

    func save() {
        guard !loading else { return }
        raw["cpus"] = cpus
        raw["memoryGB"] = memoryGB
        raw["width"] = display.width
        raw["height"] = display.height
        raw["shares"] = shares.map { ["path": $0.path, "readOnly": $0.readOnly] as [String: Any] }
        raw["network"] = network
        raw["subnet"] = subnet
        do {
            let data = try JSONSerialization.data(
                withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: configURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = "Could not save settings: \(error.localizedDescription)"
        }
    }

    // MARK: Disk

    var diskSizeGB: Double {
        let size = (try? diskURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Double(size) / Double(1 << 30)
    }

    var diskUsedGB: Double {
        let v = try? diskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Double(v?.totalFileAllocatedSize ?? 0) / Double(1 << 30)
    }

    // MARK: Running

    /// The PID holding the bundle's run lock, if any. vmctl holds an exclusive
    /// flock on .lock while the VM runs and writes its PID into the file.
    nonisolated static func lockHolder(_ lockURL: URL) -> pid_t? {
        let fd = open(lockURL.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        var buf = [UInt8](repeating: 0, count: 32)
        let n = read(fd, &buf, buf.count)
        guard n > 0, let s = String(bytes: buf[0..<n], encoding: .utf8),
            let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return pid
    }

    func refreshStatus() {
        if process != nil { return }  // our own child; its termination handler keeps state
        let holder = Self.lockHolder(lockURL)
        if holder != pid {
            pid = holder
            if holder == nil {
                stopRequested = false
                runningWith = nil
            } else if runningWith == nil {
                runningWith = (cpus, memoryGB)
            }
        }
    }

    func start(runner: URL, recovery: Bool = false) {
        guard !isRunning else { return }
        failure = nil
        let p = Process()
        p.executableURL = runner
        p.arguments = [isMac ? "mac-run" : "linux-run", url.path] + (recovery ? ["--recovery"] : [])
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        do {
            let log = try FileHandle(forWritingTo: logURL)
            p.standardOutput = log
            p.standardError = log
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { [weak self] proc in
                let status = proc.terminationStatus
                Task { @MainActor in self?.processEnded(status: status) }
            }
            try p.run()
            try? log.close()
        } catch {
            failure = "Could not start the VM runner: \(error.localizedDescription)"
            return
        }
        process = p
        pid = p.processIdentifier
        stopRequested = false
        runningWith = (cpus, memoryGB)
    }

    private func processEnded(status: Int32) {
        process = nil
        pid = nil
        stopRequested = false
        runningWith = nil
        if status != 0 {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let lines = log.split(whereSeparator: \.isNewline).suffix(8).joined(separator: "\n")
            failure = lines.isEmpty ? "The VM stopped unexpectedly (status \(status))." : lines
        }
    }

    /// First call presses the guest's power button; a second call cuts the power.
    func stop() {
        guard let pid else { return }
        kill(pid, SIGTERM)
        stopRequested = true
    }

    func bringToFront() {
        guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateAllWindows])
    }

    func addShares(_ urls: [URL]) {
        var list = shares
        for u in urls where !list.contains(where: { $0.path == u.path }) {
            list.append(SharedFolder(path: u.path, readOnly: false))
        }
        shares = list
    }
}

@MainActor
final class Library: ObservableObject {
    static let folderKey = "VMFolder"

    @Published private(set) var folder: URL
    @Published private(set) var vms: [VMItem] = []
    private var timer: Timer?

    /// The vmctl helper embedded in this app (Contents/Helpers/VM Runner.app).
    let runnerURL: URL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/VM Runner.app/Contents/MacOS/vmctl")

    init() {
        let fallback = Bundle.main.object(forInfoDictionaryKey: "VMFolderDefault") as? String
            ?? (NSHomeDirectory() + "/VMs")
        folder = URL(fileURLWithPath: UserDefaults.standard.string(forKey: Self.folderKey) ?? fallback)
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var folderAvailable: Bool { FileManager.default.fileExists(atPath: folder.path) }

    func choose(folder url: URL) {
        folder = url
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        reload()
    }

    /// Rescan the folder, keeping existing items (and their running processes).
    func reload() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var byPath = Dictionary(uniqueKeysWithValues: vms.map { ($0.url.path, $0) })
        var next: [VMItem] = []
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { continue }
            if let existing = byPath.removeValue(forKey: dir.path) {
                next.append(existing)
            } else if let item = VMItem(url: dir) {
                next.append(item)
            }
        }
        // Keep a VM that is still running even if its folder vanished from the listing.
        next += byPath.values.filter(\.isRunning)
        vms = next
        refresh()
    }

    func refresh() {
        for vm in vms { vm.refreshStatus() }
        objectWillChange.send()
    }

    /// Switch a VM between the shared NAT network and its own internet-only network,
    /// giving it the first free subnet in 192.168.241–254 (the range the guard covers).
    func setNetwork(_ vm: VMItem, internetOnly: Bool) {
        if internetOnly, vm.subnet == nil {
            let used = Set(vms.compactMap(\.subnet))
            vm.subnet = (241...254).map { "192.168.\($0).0" }.first { !used.contains($0) }
        }
        vm.network = internetOnly ? "internet-only" : "nat"
    }

    /// Whether the Mac-side network guard (scripts/netguard) is installed.
    var guardInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/local.vm-netguard.plist")
    }

    var guardInstallCommand: String {
        "sudo \"\(folder.deletingLastPathComponent().path)/scripts/netguard/install.sh\""
    }

    var running: [VMItem] { vms.filter(\.isRunning) }
    var runningCPUs: Int { running.reduce(0) { $0 + ($1.runningWith?.cpus ?? $1.cpus) } }
    var runningMemoryGB: Int { running.reduce(0) { $0 + ($1.runningWith?.memoryGB ?? $1.memoryGB) } }
}
