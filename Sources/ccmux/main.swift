import AppKit
import CCMuxKit
import SwiftUI

extension Notification.Name {
    static let ccmuxShowWindow = Notification.Name("io.vovean.ccmux.showWindow")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let engine = Engine()
    private var window: NSWindow?
    private var didFinishLaunching = false
    private var lastCloseAt = Date.distantPast
    private var activity: NSObjectProtocol?
    private let headless: Bool
    private var termination: DispatchSourceSignal?
    private var exiting = false
    /// How long a shutdown waits for in-flight requests. A real turn streams for far
    /// longer than this, so the deadline is a compromise: it sits just under the 20s
    /// `scripts/restart.sh` waits before it gives up and sends SIGKILL, leaving room for
    /// the exit itself. Listeners are already cancelled by then, so a longer wait also
    /// means longer refusing new connections — which a session survives by retrying,
    /// unlike a response cut off mid-body.
    private static let drainDeadline: TimeInterval = 15

    override init() {
        headless = Paths.consumeHeadlessMarker()
        super.init()
    }

    private static let windowSize = NSSize(width: 720, height: 640)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A Dock-less .accessory app can be launched a second time rather than
        // reactivated. Hand the request to the instance that already owns the proxies
        // and control socket, and get out of the way.
        if let bundleID = Bundle.main.bundleIdentifier {
            let mine = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != mine }
            if !others.isEmpty {
                DistributedNotificationCenter.default().postNotificationName(
                    .ccmuxShowWindow, object: nil, userInfo: nil, deliverImmediately: true)
                NSApp.terminate(nil)
                return
            }
        }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showWindow), name: .ccmuxShowWindow, object: nil)

        // Steady state is a windowless background process whose job is serving proxy
        // traffic and firing timers, which is exactly what App Nap throttles.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "ccmux proxies Claude Code sessions")

        buildMenu()
        installTerminationHandler()
        engine.start()

        if headless {
            // Started by the shim: stay out of the way, no window and no Dock icon.
            NSApp.setActivationPolicy(.accessory)
        } else {
            showWindow()
        }
        didFinishLaunching = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    /// SIGTERM is what `pkill` and every restart script sends, and its default
    /// disposition kills the process outright — AppKit never runs
    /// `applicationWillTerminate`, so responses are severed mid-body. Ignoring the
    /// signal first is what lets the dispatch source see it at all.
    private func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in self?.beginGracefulExit() }
        source.resume()
        termination = source
    }

    private func beginGracefulExit() {
        guard !exiting else { return }
        exiting = true
        engine.beginShutdown()
        drain(until: Date().addingTimeInterval(Self.drainDeadline))
    }

    private func drain(until deadline: Date) {
        let active = engine.activeRequests
        guard active > 0, Date() < deadline else {
            if active > 0 {
                Log.warn("exiting with \(active) request(s) still in flight")
            }
            engine.stop()
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.drain(until: deadline)
        }
    }

    // MARK: - Window

    @objc func showWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.windowSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            w.title = "ccmux"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: RootView(engine: engine))
            w.setContentSize(Self.windowSize)
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        lastCloseAt = Date()
        // Drop the Dock icon but keep running: the proxies and the control socket are
        // what every live session depends on. Deferred because changing activation
        // policy inside the close notification confuses AppKit.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard didFinishLaunching else { return }
        guard Date().timeIntervalSince(lastCloseAt) > 1.0 else { return }
        if window?.isVisible != true { showWindow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About ccmux", action: #selector(about), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Refresh Usage", action: #selector(refresh),
                        keyEquivalent: "r").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ccmux", action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit ccmux", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Without an Edit menu the standard shortcuts don't reach text fields.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func refresh() {
        engine.refreshNow()
    }

    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = "ccmux"
        alert.informativeText = """
        Runs each Claude Code session on the subscription you choose, and moves a \
        session to another account when the one it is on runs out.

        Start a session with cc-opus or cc-fable. Closing this window keeps ccmux \
        running, because live sessions depend on it.
        """
        alert.alertStyle = .informational
        alert.runModal()
    }
}

let arguments = ProcessInfo.processInfo.arguments
if CLI.isCLIInvocation(arguments) {
    CLI.main(arguments)
}

if let index = arguments.firstIndex(of: "--render-icon"), index + 1 < arguments.count {
    MainActor.assumeIsolated { IconRenderer.write(to: arguments[index + 1]) }
    exit(0)
}

// Top-level code is not actor-isolated in Swift 5 mode but does run on the main
// thread. `app.run()` never returns, so `delegate` lives for the process lifetime,
// which matters because NSApplication holds its delegate weakly.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // The real policy is decided in applicationDidFinishLaunching, once the delegate
    // knows whether this launch came from the shim.
    app.setActivationPolicy(.accessory)
    app.run()
}


/// `ccmux --render-icon <path>` rasterises the app icon, so `scripts/make-icon.sh` can
/// rebuild AppIcon.icns from the same drawing the app ships.
@MainActor
enum IconRenderer {
    static func write(to path: String) {
        let renderer = ImageRenderer(content: AppIconArt(side: 1024))
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("could not render the icon\n".utf8))
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
