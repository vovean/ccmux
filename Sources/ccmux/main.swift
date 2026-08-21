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
        if window == nil || window?.isVisible != true { showWindow() }
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
