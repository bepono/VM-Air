// vmctl — a small Virtualization.framework front end.
//
//   vmctl linux-create <bundle> [--disk GB] [--cpus N] [--mem GB]
//   vmctl linux-run    <bundle> [--iso FILE] [--kernel FILE --initrd FILE --cmdline STR]
//                               [--share DIR] [--headless] [--serial stdio|none|FILE]
//   vmctl mac-latest
//   vmctl mac-install  <bundle> --ipsw FILE [--disk GB] [--cpus N] [--mem GB]
//   vmctl mac-run      <bundle> [--share DIR] [--recovery] [--headless]
//
// A bundle is a directory holding config.json, disk.img and the per-machine
// identity files. Build with ./build.sh (needs the virtualization entitlement).

import AppKit
import Foundation
import Virtualization
import vmnet

setvbuf(stdout, nil, _IONBF, 0)

func log(_ s: String) {
    FileHandle.standardError.write(("[vmctl] " + s + "\r\n").data(using: .utf8)!)
}

func die(_ s: String) -> Never {
    restoreTerminal()
    log("error: " + s)
    exit(1)
}

func usage() -> Never {
    print("""
    usage:
      vmctl linux-create <bundle> [--disk GB] [--cpus N] [--mem GB]
      vmctl linux-run    <bundle> [--iso FILE] [--kernel FILE --initrd FILE --cmdline STR]
                                  [--share DIR] [--headless] [--serial stdio|none|FILE]
      vmctl mac-latest
      vmctl mac-install  <bundle> --ipsw FILE [--disk GB] [--cpus N] [--mem GB]
      vmctl mac-run      <bundle> [--share DIR] [--recovery] [--headless]
    """)
    exit(2)
}

// MARK: - Arguments

var argv = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }

// Opened from the Dock or Finder (no command): this is VM Manager's helper, and
// keeping a running VM in the Dock pins the helper rather than the app. Open
// VM Manager instead of printing usage and quitting with nothing on screen.
func openManagerIfHelper() {
    let helper = Foundation.Bundle.main.bundleURL
    guard helper.pathExtension == "app" else { return }
    let manager = helper.deletingLastPathComponent()  // Helpers
        .deletingLastPathComponent()  // Contents
        .deletingLastPathComponent()  // VM Manager.app
    guard manager.pathExtension == "app" else { return }
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: manager, configuration: .init()) { _, error in
        if let error { log("couldn't open \(manager.path): \(error.localizedDescription)") }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 10)
    exit(0)
}

guard let command = argv.first else { openManagerIfHelper(); usage() }
argv.removeFirst()

var positional: [String] = []
var opt: [String: String] = [:]
let flagNames: Set<String> = ["--headless", "--recovery"]
var argIndex = 0
while argIndex < argv.count {
    let a = argv[argIndex]
    if a.hasPrefix("--") {
        if flagNames.contains(a) {
            opt[a] = "1"
        } else {
            guard argIndex + 1 < argv.count else { die("missing value for \(a)") }
            opt[a] = argv[argIndex + 1]
            argIndex += 1
        }
    } else {
        positional.append(a)
    }
    argIndex += 1
}

func intOpt(_ name: String, _ fallback: Int) -> Int {
    guard let v = opt[name] else { return fallback }
    guard let n = Int(v), n > 0 else { die("\(name) wants a positive integer") }
    return n
}

func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

// MARK: - Bundle

struct VMConfig: Codable {
    var kind: String  // "linux" or "mac"
    var cpus: Int
    var memoryGB: Int
    var macAddress: String
    var width: Int
    var height: Int
    var shares: [SharedFolder]? = nil
    /// Direct kernel boot instead of EFI: paths relative to the bundle, plus the
    /// kernel command line. The guest hands over new kernels through the bundle's
    /// boot-incoming/ folder (shared as "vmboot"); see promoteIncomingBoot.
    var kernel: String? = nil
    var initrd: String? = nil
    var cmdline: String? = nil
    /// "nat" (default): the shared NAT network all VMs use, with IPv6.
    /// "internet-only": the VM's own network on `subnet` (a /24 inside
    /// 192.168.240.0/20) with IPv4 NAT only, no IPv6 forwarding and no router
    /// advertisements, apart from other VMs. The Mac's network guard (pf, see
    /// scripts/netguard) blocks that range from the local network and the Mac.
    var network: String? = nil
    var subnet: String? = nil
}

struct SharedFolder: Codable {
    var path: String
    var readOnly: Bool?
}

struct Bundle {
    let url: URL
    var config: URL { url.appendingPathComponent("config.json") }
    var disk: URL { url.appendingPathComponent("disk.img") }
    var machineID: URL { url.appendingPathComponent("machine-id.bin") }
    var nvram: URL { url.appendingPathComponent("nvram.bin") }
    var aux: URL { url.appendingPathComponent("aux.img") }
    var hardwareModel: URL { url.appendingPathComponent("hardware-model.bin") }
    var consoleLog: URL { url.appendingPathComponent("console.log") }

    func load() -> VMConfig {
        guard let data = try? Data(contentsOf: config),
            let cfg = try? JSONDecoder().decode(VMConfig.self, from: data)
        else { die("\(url.path) is not a VM bundle (no readable config.json)") }
        return cfg
    }

    func loadIfPresent() -> VMConfig? {
        guard let data = try? Data(contentsOf: config) else { return nil }
        return try? JSONDecoder().decode(VMConfig.self, from: data)
    }

    func save(_ cfg: VMConfig) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try enc.encode(cfg).write(to: config) } catch { die("cannot write config: \(error)") }
    }
}

func bundleArg() -> Bundle {
    guard let p = positional.first else { usage() }
    return Bundle(url: fileURL(p))
}

func createSparseFile(_ url: URL, gigabytes: Int) {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        die("cannot create \(url.path)")
    }
    do {
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(gigabytes) << 30)
        try h.close()
    } catch { die("cannot size \(url.path): \(error)") }
}

func newBundleDirectory(_ b: Bundle) {
    if FileManager.default.fileExists(atPath: b.config.path) {
        die("\(b.url.path) already holds a VM; remove it first if you want to start over")
    }
    do {
        try FileManager.default.createDirectory(at: b.url, withIntermediateDirectories: true)
    } catch { die("cannot create \(b.url.path): \(error)") }
}

/// Hold an exclusive lock on <bundle>/.lock for the life of the process, so the
/// same disk is never booted twice. The lock file holds our PID, which is how
/// VM Manager finds and stops a running VM.
var lockFD: Int32 = -1

func lockBundle(_ b: Bundle) {
    let path = b.url.appendingPathComponent(".lock").path
    lockFD = open(path, O_RDWR | O_CREAT, 0o644)
    guard lockFD >= 0 else { die("cannot open \(path): \(String(cString: strerror(errno)))") }
    // Retry briefly: VM Manager takes a momentary shared lock when it polls.
    var tries = 0
    while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        tries += 1
        if tries >= 20 { die("\(b.url.lastPathComponent) is already running") }
        usleep(50_000)
    }
    let pid = "\(getpid())\n"
    ftruncate(lockFD, 0)
    _ = pid.withCString { write(lockFD, $0, strlen($0)) }
}

// MARK: - Shared device configuration

func diskDevice(_ url: URL, readOnly: Bool) -> VZStorageDeviceConfiguration {
    do {
        let att = try VZDiskImageStorageDeviceAttachment(
            url: url, readOnly: readOnly, cachingMode: .cached, synchronizationMode: .fsync)
        return VZVirtioBlockDeviceConfiguration(attachment: att)
    } catch { die("cannot attach \(url.path): \(error.localizedDescription)") }
}

/// Subnets for "internet-only" VMs: 192.168.241.0/24 … 192.168.254.0/24.
let guardedSubnets = (241...254).map { "192.168.\($0).0" }

/// Give an internet-only VM a subnet of its own if it has none yet: the first one
/// no other VM in the same folder uses. Saved back to config.json.
func ensureSubnet(_ b: Bundle, _ cfg: inout VMConfig) {
    guard cfg.network == "internet-only", cfg.subnet == nil else { return }
    let folder = b.url.deletingLastPathComponent()
    let used = Set(
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { Bundle(url: $0).loadIfPresent()?.subnet })
    guard let free = guardedSubnets.first(where: { !used.contains($0) }) else {
        die("no free subnet left for an internet-only VM")
    }
    cfg.subnet = free
    b.save(cfg)
}

var vmnetNetworks: [Any] = []  // keep the VM's network alive for the life of the process

func networkAttachment(_ cfg: VMConfig) -> VZNetworkDeviceAttachment {
    guard cfg.network == "internet-only" else { return VZNATNetworkDeviceAttachment() }
    guard #available(macOS 26, *) else { die("the internet-only network needs macOS 26 or later") }
    guard let subnet = cfg.subnet, guardedSubnets.contains(subnet) else {
        die("internet-only network needs a subnet between 192.168.241.0 and 192.168.254.0")
    }
    var status = vmnet_return_t.VMNET_SUCCESS
    guard let nc = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
        die("cannot configure the VM's network (vmnet error \(status.rawValue))")
    }
    vmnet_network_configuration_disable_nat66(nc)
    vmnet_network_configuration_disable_router_advertisement(nc)
    // vmnet takes the Mac's own address on the network (x.x.x.1), not the network address.
    let gateway = subnet.split(separator: ".").prefix(3).joined(separator: ".") + ".1"
    var addr = in_addr()
    var mask = in_addr()
    inet_pton(AF_INET, gateway, &addr)
    inet_pton(AF_INET, "255.255.255.0", &mask)
    let r = vmnet_network_configuration_set_ipv4_subnet(nc, &addr, &mask)
    guard r == .VMNET_SUCCESS else { die("cannot use subnet \(subnet) (vmnet error \(r.rawValue))") }
    guard let network = vmnet_network_create(nc, &status) else {
        die("cannot create the VM's network (vmnet error \(status.rawValue))")
    }
    vmnetNetworks.append(network)
    let guardOn = FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/local.vm-netguard.plist")
    log("network: internet only, \(subnet)/24, no IPv6"
        + (guardOn ? "" : " (network guard not installed: the local network is still reachable over IPv4)"))
    return VZVmnetNetworkDeviceAttachment(network: network)
}

func natDevice(_ cfg: VMConfig) -> VZVirtioNetworkDeviceConfiguration {
    let net = VZVirtioNetworkDeviceConfiguration()
    net.attachment = networkAttachment(cfg)
    if let mac = VZMACAddress(string: cfg.macAddress) { net.macAddress = mac }
    return net
}

/// Host folders shared with the guest under one virtio-fs tag. --share DIR on
/// the command line replaces the list in config.json. One folder is shared as
/// the root of the mount; several appear as subfolders named after each folder.
/// Folders that are missing (an unplugged drive, say) are skipped with a warning.
func shareDevice(tag: String, cfg: VMConfig) -> VZVirtioFileSystemDeviceConfiguration? {
    let wanted: [SharedFolder] =
        opt["--share"].map { [SharedFolder(path: $0, readOnly: false)] } ?? cfg.shares ?? []
    var dirs: [(name: String, dir: VZSharedDirectory)] = []
    var used = Set<String>()
    for folder in wanted {
        let url = fileURL(folder.path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue
        else {
            log("warning: shared folder \(url.path) is not available; skipping it")
            continue
        }
        let base = url.lastPathComponent.isEmpty ? "share" : url.lastPathComponent
        var name = base
        var n = 2
        while used.contains(name) { name = "\(base)-\(n)"; n += 1 }
        used.insert(name)
        dirs.append((name, VZSharedDirectory(url: url, readOnly: folder.readOnly ?? false)))
    }
    guard !dirs.isEmpty else { return nil }
    let fs = VZVirtioFileSystemDeviceConfiguration(tag: tag)
    if dirs.count == 1 {
        fs.share = VZSingleDirectoryShare(directory: dirs[0].dir)
    } else {
        fs.share = VZMultipleDirectoryShare(
            directories: Dictionary(uniqueKeysWithValues: dirs.map { ($0.name, $0.dir) }))
    }
    for d in dirs { log("sharing \(d.dir.url.path)\(d.dir.isReadOnly ? " (read-only)" : "")") }
    return fs
}

func soundDevice() -> VZVirtioSoundDeviceConfiguration {
    let sound = VZVirtioSoundDeviceConfiguration()
    let out = VZVirtioSoundDeviceOutputStreamConfiguration()
    out.sink = VZHostAudioOutputStreamSink()
    sound.streams = [out]
    return sound
}

// MARK: - Terminal handling for the serial console

var savedTermios: termios?

func makeTerminalRaw() {
    guard isatty(STDIN_FILENO) != 0 else { return }
    var t = termios()
    guard tcgetattr(STDIN_FILENO, &t) == 0 else { return }
    savedTermios = t
    cfmakeraw(&t)
    tcsetattr(STDIN_FILENO, TCSANOW, &t)
}

func restoreTerminal() {
    if var t = savedTermios {
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
        savedTermios = nil
    }
}

func serialPort(mode: String, bundle: Bundle) -> VZSerialPortConfiguration? {
    let port = VZVirtioConsoleDeviceSerialPortConfiguration()
    switch mode {
    case "none":
        return nil
    case "stdio":
        makeTerminalRaw()
        port.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: FileHandle.standardInput,
            fileHandleForWriting: FileHandle.standardOutput)
    default:
        let url = mode == "log" ? bundle.consoleLog : fileURL(mode)
        do { port.attachment = try VZFileSerialPortAttachment(url: url, append: false) } catch {
            die("cannot open serial log \(url.path): \(error.localizedDescription)")
        }
    }
    return port
}

// MARK: - Linux

/// True for a regular file that is not a symbolic link.
func isPlainFile(_ url: URL) -> Bool {
    var st = stat()
    return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
}

/// Read a file the guest wrote, refusing symbolic links (which would make the
/// host read some other file on the Mac) and anything but a regular file.
func readGuestFile(_ url: URL, maxBytes: Int) -> Data? {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
        st.st_size > 0, st.st_size <= maxBytes
    else { return nil }
    return try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd()
}

/// A direct-boot guest installs kernel updates by writing vmlinuz, initrd.img and
/// version into boot-incoming/ (its /mnt/vmboot). Before booting them the host
/// checks they are plain files of sane size that really are an arm64 kernel and
/// an initramfs, then copies them over boot/. Anything else is thrown away.
func promoteIncomingBoot(_ b: Bundle) {
    let fm = FileManager.default
    let inbox = b.url.appendingPathComponent("boot-incoming")
    let names = ["vmlinuz", "initrd.img", "version"]
    let present = names.filter { (try? fm.attributesOfItem(atPath: inbox.appendingPathComponent($0).path)) != nil }
    guard !present.isEmpty else { return }
    // removeItem deletes a symbolic link itself, never its target.
    defer { for n in present { try? fm.removeItem(at: inbox.appendingPathComponent(n)) } }

    guard let kernel = readGuestFile(inbox.appendingPathComponent("vmlinuz"), maxBytes: 256 << 20),
        let initrd = readGuestFile(inbox.appendingPathComponent("initrd.img"), maxBytes: 512 << 20)
    else {
        log("warning: ignoring boot files from the guest (missing, too large, or not plain files)")
        return
    }
    // arm64 Image header: "ARM\x64" at offset 56.
    guard kernel.count > 64, kernel[56..<60] == Data([0x41, 0x52, 0x4D, 0x64]) else {
        log("warning: ignoring boot files from the guest (vmlinuz is not an arm64 kernel Image)")
        return
    }
    let initrdMagics: [[UInt8]] = [
        [0x1F, 0x8B], [0x28, 0xB5, 0x2F, 0xFD], [0xFD, 0x37, 0x7A, 0x58, 0x5A], [0x02, 0x21, 0x4C, 0x18],
        [0x5D, 0x00, 0x00], [0x89, 0x4C, 0x5A, 0x4F], Array("070701".utf8), Array("070702".utf8),
    ]
    guard initrdMagics.contains(where: { initrd.starts(with: $0) }) else {
        log("warning: ignoring boot files from the guest (initrd.img is not an initramfs)")
        return
    }
    let raw = readGuestFile(inbox.appendingPathComponent("version"), maxBytes: 128)
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    let version = String(raw.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-~".contains($0)) })

    let boot = b.url.appendingPathComponent("boot")
    do {
        try fm.createDirectory(at: boot, withIntermediateDirectories: true)
        try kernel.write(to: boot.appendingPathComponent("vmlinuz"), options: .atomic)
        try initrd.write(to: boot.appendingPathComponent("initrd.img"), options: .atomic)
        try Data((version.isEmpty ? "unknown" : version).utf8 + [0x0A])
            .write(to: boot.appendingPathComponent("version"), options: .atomic)
    } catch {
        die("cannot install the new kernel: \(error.localizedDescription)")
    }
    log("installed kernel \(version.isEmpty ? "(no version)" : version) handed over by the guest")
}

func linuxConfiguration(_ b: Bundle, _ cfg: VMConfig, headless: Bool) -> VZVirtualMachineConfiguration {
    let c = VZVirtualMachineConfiguration()
    c.cpuCount = cfg.cpus
    c.memorySize = UInt64(cfg.memoryGB) << 30

    let platform = VZGenericPlatformConfiguration()
    guard let idData = try? Data(contentsOf: b.machineID),
        let id = VZGenericMachineIdentifier(dataRepresentation: idData)
    else { die("bad machine identifier in \(b.url.path)") }
    platform.machineIdentifier = id
    c.platform = platform

    if let kernel = opt["--kernel"] {
        let loader = VZLinuxBootLoader(kernelURL: fileURL(kernel))
        if let initrd = opt["--initrd"] { loader.initialRamdiskURL = fileURL(initrd) }
        loader.commandLine = opt["--cmdline"] ?? "console=hvc0"
        c.bootLoader = loader
    } else if let kernel = cfg.kernel {
        promoteIncomingBoot(b)
        let kernelURL = b.url.appendingPathComponent(kernel)
        guard isPlainFile(kernelURL) else { die("kernel \(kernelURL.path) is missing or not a plain file") }
        if let initrd = cfg.initrd, !isPlainFile(b.url.appendingPathComponent(initrd)) {
            die("initrd \(initrd) is missing or not a plain file")
        }
        let loader = VZLinuxBootLoader(kernelURL: kernelURL)
        if let initrd = cfg.initrd { loader.initialRamdiskURL = b.url.appendingPathComponent(initrd) }
        loader.commandLine = cfg.cmdline ?? "console=hvc0"
        c.bootLoader = loader
    } else {
        let loader = VZEFIBootLoader()
        do {
            loader.variableStore =
                FileManager.default.fileExists(atPath: b.nvram.path)
                ? VZEFIVariableStore(url: b.nvram)
                : try VZEFIVariableStore(creatingVariableStoreAt: b.nvram)
        } catch { die("cannot set up EFI variable store: \(error.localizedDescription)") }
        c.bootLoader = loader
    }

    // Install media goes first: the firmware then prefers it, and Alpine's
    // setup-disk only identifies its boot media correctly on the first disk.
    var storage: [VZStorageDeviceConfiguration] = []
    if let iso = opt["--iso"] { storage.append(diskDevice(fileURL(iso), readOnly: true)) }
    storage.append(diskDevice(b.disk, readOnly: false))
    c.storageDevices = storage

    c.networkDevices = [natDevice(cfg)]
    c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    var fsDevices: [VZDirectorySharingDeviceConfiguration] = []
    if let share = shareDevice(tag: "shared", cfg: cfg) { fsDevices.append(share) }
    if cfg.kernel != nil, opt["--kernel"] == nil {
        // The guest only ever sees the inbox, never the files the host boots.
        let inbox = b.url.appendingPathComponent("boot-incoming")
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: "vmboot")
        fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: inbox, readOnly: false))
        fsDevices.append(fs)
    }
    // One-way control channel: the Mac drops jobs into <bundle>/control/inbox; the
    // guest can read them but never write here (results come back through the
    // normal shared folder). See scripts/vm-prompt and scripts/kiosk/vm-agent.
    let control = b.url.appendingPathComponent("control")
    try? FileManager.default.createDirectory(
        at: control.appendingPathComponent("inbox"), withIntermediateDirectories: true)
    let controlFS = VZVirtioFileSystemDeviceConfiguration(tag: "control")
    controlFS.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: control, readOnly: true))
    fsDevices.append(controlFS)
    c.directorySharingDevices = fsDevices

    let gpu = VZVirtioGraphicsDeviceConfiguration()
    gpu.scanouts = [
        VZVirtioGraphicsScanoutConfiguration(widthInPixels: cfg.width, heightInPixels: cfg.height)
    ]
    c.graphicsDevices = [gpu]
    c.keyboards = [VZUSBKeyboardConfiguration()]
    c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    c.audioDevices = [soundDevice()]

    // Clipboard sharing with the host, picked up by spice-vdagent in the guest.
    let spice = VZVirtioConsoleDeviceConfiguration()
    let spicePort = VZVirtioConsolePortConfiguration()
    spicePort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
    spicePort.attachment = VZSpiceAgentPortAttachment()
    spice.ports[0] = spicePort
    c.consoleDevices = [spice]

    let serialMode = opt["--serial"] ?? (headless ? "stdio" : "log")
    if let port = serialPort(mode: serialMode, bundle: b) { c.serialPorts = [port] }
    return c
}

// MARK: - macOS

func macPlatform(_ b: Bundle) -> VZMacPlatformConfiguration {
    let platform = VZMacPlatformConfiguration()
    guard let hwData = try? Data(contentsOf: b.hardwareModel),
        let hw = VZMacHardwareModel(dataRepresentation: hwData)
    else { die("bad hardware model in \(b.url.path)") }
    guard hw.isSupported else { die("this host cannot run the hardware model stored in the bundle") }
    guard let idData = try? Data(contentsOf: b.machineID),
        let id = VZMacMachineIdentifier(dataRepresentation: idData)
    else { die("bad machine identifier in \(b.url.path)") }
    platform.hardwareModel = hw
    platform.machineIdentifier = id
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: b.aux)
    return platform
}

func macConfiguration(_ b: Bundle, _ cfg: VMConfig) -> VZVirtualMachineConfiguration {
    let c = VZVirtualMachineConfiguration()
    c.cpuCount = cfg.cpus
    c.memorySize = UInt64(cfg.memoryGB) << 30
    c.platform = macPlatform(b)
    c.bootLoader = VZMacOSBootLoader()

    let gpu = VZMacGraphicsDeviceConfiguration()
    gpu.displays = [
        VZMacGraphicsDisplayConfiguration(
            widthInPixels: cfg.width, heightInPixels: cfg.height, pixelsPerInch: 80)
    ]
    c.graphicsDevices = [gpu]

    c.storageDevices = [diskDevice(b.disk, readOnly: false)]
    c.networkDevices = [natDevice(cfg)]
    c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    c.keyboards = [VZMacKeyboardConfiguration()]
    c.pointingDevices = [
        VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration(),
    ]
    c.audioDevices = [soundDevice()]
    if let share = shareDevice(
        tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag, cfg: cfg)
    {
        c.directorySharingDevices = [share]
    }
    return c
}

func validated(_ c: VZVirtualMachineConfiguration) -> VZVirtualMachineConfiguration {
    do { try c.validate() } catch { die("invalid VM configuration: \(error.localizedDescription)") }
    return c
}

// MARK: - Running

final class Runner: NSObject, NSApplicationDelegate, NSWindowDelegate, VZVirtualMachineDelegate {
    let vm: VZVirtualMachine
    let title: String
    let size: NSSize
    let headless: Bool
    let startOptions: VZVirtualMachineStartOptions?
    /// Seconds to wait after a shutdown request before powering off; nil waits forever.
    let forceStopAfter: TimeInterval?
    var window: NSWindow?
    var signalSources: [DispatchSourceSignal] = []
    var stopping = false

    init(
        configuration: VZVirtualMachineConfiguration, title: String, size: NSSize, headless: Bool,
        startOptions: VZVirtualMachineStartOptions? = nil, forceStopAfter: TimeInterval? = 20
    ) {
        vm = VZVirtualMachine(configuration: configuration)
        self.title = title
        self.size = size
        self.headless = headless
        self.startOptions = startOptions
        self.forceStopAfter = forceStopAfter
        super.init()
        vm.delegate = self
    }

    func run() -> Never {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.shutDown() }
            src.resume()
            signalSources.append(src)
        }
        if headless {
            startVM()
            dispatchMain()
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = self
        app.run()
        exit(0)
    }

    func startVM() {
        let done: (Error?) -> Void = { error in
            if let error { die("VM failed to start: \(error.localizedDescription)") }
            log("started \(self.title)")
        }
        if let startOptions {
            vm.start(options: startOptions, completionHandler: done)
        } else {
            vm.start { result in
                if case .failure(let error) = result { done(error) } else { done(nil) }
            }
        }
    }

    /// Ask the guest to power off (the equivalent of pressing its power button).
    /// Asking a second time, or the timeout if there is one, pulls the plug.
    func shutDown() {
        if stopping || vm.state == .stopped { forceStop(); return }
        stopping = true
        if vm.canRequestStop, (try? vm.requestStop()) != nil {
            log("asked the guest to shut down")
            // A guest that is still booting may miss the first press; press again.
            for delay in [4.0, 8.0, 12.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if self.vm.state == .running, self.vm.canRequestStop { try? self.vm.requestStop() }
                }
            }
            if let forceStopAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + forceStopAfter) {
                    log("guest did not shut down in time; powering off")
                    self.forceStop()
                }
            }
        } else {
            forceStop()
        }
    }

    func forceStop() {
        guard vm.canStop else { restoreTerminal(); exit(0) }
        vm.stop { _ in restoreTerminal(); exit(0) }
    }

    // NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Shut Down and Quit", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu

        let view = VZVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true

        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = title
        w.contentView = view
        w.contentAspectRatio = size
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
        window = w
        NSApp.activate(ignoringOtherApps: true)
        startVM()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if vm.state == .stopped { return .terminateNow }
        shutDown()
        return .terminateCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if vm.state == .stopped { return true }
        shutDown()
        return false
    }

    // VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        restoreTerminal()
        log("guest powered off")
        exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        die("guest stopped with error: \(error.localizedDescription)")
    }
}

// MARK: - Commands

var keepAlive: [Any] = []

func linuxCreate() -> Never {
    let b = bundleArg()
    newBundleDirectory(b)
    createSparseFile(b.disk, gigabytes: intOpt("--disk", 16))
    do { try VZGenericMachineIdentifier().dataRepresentation.write(to: b.machineID) } catch {
        die("cannot write machine identifier: \(error)")
    }
    b.save(
        VMConfig(
            kind: "linux", cpus: intOpt("--cpus", 2), memoryGB: intOpt("--mem", 2),
            macAddress: VZMACAddress.randomLocallyAdministered().string, width: 1280, height: 800))
    log("created Linux VM bundle at \(b.url.path)")
    exit(0)
}

func linuxRun() -> Never {
    let b = bundleArg()
    var cfg = b.load()
    guard cfg.kind == "linux" else { die("\(b.url.path) is not a Linux VM") }
    lockBundle(b)
    ensureSubnet(b, &cfg)
    let headless = opt["--headless"] != nil
    let runner = Runner(
        configuration: validated(linuxConfiguration(b, cfg, headless: headless)),
        title: b.url.lastPathComponent, size: NSSize(width: cfg.width, height: cfg.height),
        headless: headless)
    runner.run()
}

func macLatest() -> Never {
    VZMacOSRestoreImage.fetchLatestSupported { result in
        switch result {
        case .failure(let error):
            die("cannot look up the latest restore image: \(error.localizedDescription)")
        case .success(let image):
            let v = image.operatingSystemVersion
            print("version \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
            print("build \(image.buildVersion)")
            print("url \(image.url.absoluteString)")
            exit(0)
        }
    }
    dispatchMain()
}

func macInstall() -> Never {
    let b = bundleArg()
    guard let ipswPath = opt["--ipsw"] else { die("mac-install needs --ipsw FILE") }
    let ipsw = fileURL(ipswPath)
    guard FileManager.default.fileExists(atPath: ipsw.path) else { die("no such file: \(ipsw.path)") }

    VZMacOSRestoreImage.load(from: ipsw) { result in
        DispatchQueue.main.async {
            let image: VZMacOSRestoreImage
            switch result {
            case .failure(let error): die("cannot read restore image: \(error.localizedDescription)")
            case .success(let i): image = i
            }
            guard let req = image.mostFeaturefulSupportedConfiguration else {
                die("this host cannot run the macOS version in that restore image")
            }
            guard req.hardwareModel.isSupported else { die("hardware model not supported on this host") }

            newBundleDirectory(b)
            lockBundle(b)
            let cpus = max(intOpt("--cpus", 4), req.minimumSupportedCPUCount)
            let minGB = Int((req.minimumSupportedMemorySize + (1 << 30) - 1) >> 30)
            let cfg = VMConfig(
                kind: "mac", cpus: cpus, memoryGB: max(intOpt("--mem", 4), minGB),
                macAddress: VZMACAddress.randomLocallyAdministered().string, width: 1920, height: 1200)
            do {
                _ = try VZMacAuxiliaryStorage(
                    creatingStorageAt: b.aux, hardwareModel: req.hardwareModel, options: [])
                try req.hardwareModel.dataRepresentation.write(to: b.hardwareModel)
                try VZMacMachineIdentifier().dataRepresentation.write(to: b.machineID)
            } catch { die("cannot create machine identity: \(error.localizedDescription)") }
            createSparseFile(b.disk, gigabytes: intOpt("--disk", 64))
            b.save(cfg)

            let v = image.operatingSystemVersion
            log(
                "installing macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (\(image.buildVersion)) "
                    + "with \(cfg.cpus) CPUs, \(cfg.memoryGB) GB RAM")
            let vm = VZVirtualMachine(configuration: validated(macConfiguration(b, cfg)))
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
            var lastPercent = -1
            let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                let percent = Int(p.fractionCompleted * 100)
                if percent != lastPercent {
                    lastPercent = percent
                    print("install \(percent)%")
                }
            }
            keepAlive = [vm, installer, observation]
            installer.install { result in
                if case .failure(let error) = result {
                    die("installation failed: \(error.localizedDescription)")
                }
                log("macOS installed into \(b.url.path)")
                exit(0)
            }
        }
    }
    dispatchMain()
}

func macRun() -> Never {
    let b = bundleArg()
    var cfg = b.load()
    guard cfg.kind == "mac" else { die("\(b.url.path) is not a macOS VM") }
    lockBundle(b)
    ensureSubnet(b, &cfg)
    let options = VZMacOSVirtualMachineStartOptions()
    options.startUpFromMacOSRecovery = opt["--recovery"] != nil
    let runner = Runner(
        configuration: validated(macConfiguration(b, cfg)),
        title: b.url.lastPathComponent,
        size: NSSize(width: 1280, height: (1280 * cfg.height / max(cfg.width, 1))),
        headless: opt["--headless"] != nil, startOptions: options,
        // macOS answers the power button with a confirmation dialog; leave it to the user.
        forceStopAfter: nil)
    runner.run()
}

switch command {
case "linux-create": linuxCreate()
case "linux-run": linuxRun()
case "mac-latest": macLatest()
case "mac-install": macInstall()
case "mac-run": macRun()
default: usage()
}
