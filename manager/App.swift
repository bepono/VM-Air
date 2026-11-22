import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--snapshot FILE` renders the main window to a PNG and quits (used to check the UI).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if let view = NSApp.windows.first(where: \.isVisible)?.contentView,
                    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                {
                    // Translucent materials draw nothing offscreen; flatten them for the capture.
                    func flatten(_ v: NSView) {
                        if let fx = v as? NSVisualEffectView {
                            fx.state = .inactive
                            fx.material = .windowBackground
                        }
                        v.subviews.forEach(flatten)
                    }
                    flatten(view.superview ?? view)
                    view.layoutSubtreeIfNeeded()
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out)
                }
                NSApp.terminate(nil)
            }
        }
    }
}

@main
struct VMManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var library = Library()

    var body: some Scene {
        Window("VM Manager", id: "main") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 780, minHeight: 560)
        }
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose VM Folder…") { chooseVMFolder(library) }
                    .keyboardShortcut("o")
                Button("Show VM Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([library.folder])
                }
                Divider()
                Button("Refresh") { library.reload() }
                    .keyboardShortcut("r")
            }
        }
    }
}
