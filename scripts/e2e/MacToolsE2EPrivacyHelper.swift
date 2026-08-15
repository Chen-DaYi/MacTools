import AppKit
import Darwin

@MainActor
private func terminateRunningCopies(of executableURL: URL) -> Int {
    let targetURL = executableURL.standardizedFileURL
    let currentProcessID = ProcessInfo.processInfo.processIdentifier
    let applications = NSWorkspace.shared.runningApplications.filter { application in
        application.processIdentifier != currentProcessID
            && application.executableURL?.standardizedFileURL == targetURL
            && !application.isTerminated
    }

    applications.forEach { _ = $0.terminate() }
    let gracefulDeadline = Date().addingTimeInterval(5)
    while applications.contains(where: { !$0.isTerminated }), Date() < gracefulDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    let survivors = applications.filter { !$0.isTerminated }
    survivors.forEach { _ = $0.forceTerminate() }
    let forcedDeadline = Date().addingTimeInterval(2)
    while survivors.contains(where: { !$0.isTerminated }), Date() < forcedDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    let remaining = survivors.filter { !$0.isTerminated }.count
    print("matched=\(applications.count) forced=\(survivors.count) remaining=\(remaining)")
    return remaining
}

@MainActor
@discardableResult
private func restoreApplicationVisibility(from stateURL: URL) -> Int {
    guard let payload = try? String(contentsOf: stateURL, encoding: .utf8) else {
        return 0
    }
    let processIdentifiers = Set(payload.split(whereSeparator: \.isWhitespace).compactMap {
        pid_t($0)
    })
    var restored = 0
    for processIdentifier in processIdentifiers {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated,
              application.isHidden else {
            continue
        }
        _ = application.unhide()
        restored += 1
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    return restored
}

@MainActor
private final class PrivacyHelperDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var backdropWindows: [NSWindow] = []
    private var hiddenApplications: [pid_t: NSRunningApplication] = [:]
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var window: NSWindow?
    private let isolatesRecording = ProcessInfo.processInfo.arguments.contains("--recording-privacy")
    private let protectedBundleIdentifier: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--protected-bundle-id"),
              arguments.indices.contains(index + 1),
              !arguments[index + 1].isEmpty else {
            return nil
        }
        return arguments[index + 1]
    }()
    private let visibilityStateURL: URL? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--visibility-state"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundle = Bundle.main
        let title = bundle.object(forInfoDictionaryKey: "MacToolsE2ETitle") as? String
            ?? "MacTools E2E Helper"
        let accentName = bundle.object(forInfoDictionaryKey: "MacToolsE2EAccent") as? String
            ?? "blue"
        let accent: NSColor = accentName == "orange" ? .systemOrange : .systemBlue

        backdropWindows = NSScreen.screens.map(makeBackdropWindow(for:))
        backdropWindows.forEach { $0.orderFront(nil) }

        if isolatesRecording {
            guard protectedBundleIdentifier != nil else {
                fputs("error: --protected-bundle-id is required for recording privacy\n", stderr)
                NSApp.terminate(nil)
                return
            }
            installTerminationSignalHandlers()
            NSWorkspace.shared.runningApplications.forEach(hideIfUnrelated)
            let notifications = NSWorkspace.shared.notificationCenter
            notifications.addObserver(
                self,
                selector: #selector(workspaceApplicationChanged(_:)),
                name: NSWorkspace.didLaunchApplicationNotification,
                object: nil
            )
            notifications.addObserver(
                self,
                selector: #selector(workspaceApplicationChanged(_:)),
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil
            )
        }

        let content = NSVisualEffectView()
        content.material = .sidebar
        content.blendingMode = .behindWindow
        content.state = .active

        let symbol = NSImageView(image: NSImage(
            systemSymbolName: "checkmark.shield.fill",
            accessibilityDescription: "Privacy-safe test window"
        ) ?? NSImage())
        symbol.contentTintColor = accent
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 52, weight: .semibold)
        symbol.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 24, weight: .bold)
        heading.alignment = .center
        heading.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(labelWithString: "Deterministic automation target\nNo user files, account data, or clipboard content")
        detail.font = .systemFont(ofSize: 15)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 2
        detail.translatesAutoresizingMaskIntoConstraints = false

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        progress.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [symbol, heading, detail, progress])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -36),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeBackdropWindow(for screen: NSScreen) -> NSWindow {
        let label = NSTextField(
            labelWithString: "MacTools E2E Privacy Backdrop\nNo background application content is recorded"
        )
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.72)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(
            calibratedRed: 0.055,
            green: 0.065,
            blue: 0.09,
            alpha: 1
        ).cgColor
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        let backdrop = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        backdrop.contentView = view
        backdrop.isOpaque = true
        backdrop.backgroundColor = .black
        backdrop.ignoresMouseEvents = true
        backdrop.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return backdrop
    }

    @objc
    private func workspaceApplicationChanged(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else {
            return
        }
        hideIfUnrelated(application)
    }

    private func hideIfUnrelated(_ application: NSRunningApplication) {
        let identifier = application.bundleIdentifier ?? ""
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              identifier != protectedBundleIdentifier,
              !identifier.hasPrefix("com.jennymedia.mactools.e2e-helper."),
              application.activationPolicy == .regular,
              !application.isHidden,
              !application.isTerminated else {
            return
        }
        hiddenApplications[application.processIdentifier] = application
        persistHiddenApplicationState()
        _ = application.hide()
    }

    private func persistHiddenApplicationState() {
        guard let visibilityStateURL else { return }
        let payload = hiddenApplications.keys.sorted().map(String.init).joined(separator: "\n") + "\n"
        try? payload.write(to: visibilityStateURL, atomically: true, encoding: .utf8)
    }

    private func installTerminationSignalHandlers() {
        for signalValue in [SIGTERM, SIGINT] {
            signal(signalValue, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalValue, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let visibilityStateURL {
            restoreApplicationVisibility(from: visibilityStateURL)
        }
        hiddenApplications.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            NSApp.terminate(nil)
        }
    }
}

@main
private struct PrivacyHelperMain {
    @MainActor
    static func main() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--terminate-running-copies"),
           arguments.indices.contains(index + 1) {
            let executableURL = URL(fileURLWithPath: arguments[index + 1])
            if terminateRunningCopies(of: executableURL) != 0 {
                Darwin.exit(1)
            }
            return
        }
        if let index = arguments.firstIndex(of: "--restore-visibility"),
           arguments.indices.contains(index + 1) {
            let stateURL = URL(fileURLWithPath: arguments[index + 1])
            let restored = restoreApplicationVisibility(from: stateURL)
            try? "".write(to: stateURL, atomically: true, encoding: .utf8)
            print("restoredVisibility=\(restored)")
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = PrivacyHelperDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
