import AppKit
import SwiftUI

@MainActor
final class ScreenshotOverlaySession: ScreenshotOverlaySelecting {
    private var windows: [any ScreenshotOverlayWindowManaging] = []
    private var closingWindows: [any ScreenshotOverlayWindowManaging] = []
    private var continuation: CheckedContinuation<ScreenshotOverlaySelectionResult, Never>?
    private let hasAvailableScreens: () -> Bool
    private let activateApplication: () -> Void
    private let overlayWindowPresenter: (@escaping (ScreenshotOverlaySelectionResult) -> Void) -> [any ScreenshotOverlayWindowManaging]

    init(
        hasAvailableScreens: @escaping () -> Bool = { !NSScreen.screens.isEmpty },
        activateApplication: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) },
        overlayWindowPresenter: (
            (@escaping (ScreenshotOverlaySelectionResult) -> Void) -> [any ScreenshotOverlayWindowManaging]
        )? = nil
    ) {
        self.hasAvailableScreens = hasAvailableScreens
        self.activateApplication = activateApplication
        self.overlayWindowPresenter = overlayWindowPresenter ?? { completion in
            Self.makeOverlayWindows(on: NSScreen.screens, completion: completion)
        }
    }

    func selectRegion() async -> ScreenshotOverlaySelectionResult {
        guard continuation == nil else {
            return .failure(.cancelled)
        }

        guard hasAvailableScreens() else {
            return .failure(.noScreen)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled {
                    self.complete(.failure(.cancelled))
                    return
                }
                self.showOverlayWindows()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.complete(.failure(.cancelled))
            }
        }
    }

    private func showOverlayWindows() {
        activateApplication()
        windows = overlayWindowPresenter { [weak self] result in
            self?.complete(result)
        }

        guard !windows.isEmpty else {
            complete(.failure(.noScreen))
            return
        }

        windows.forEach { $0.showOverlayWindow() }
        windows.first?.makeOverlayKeyWindow()
    }

    private static func makeOverlayWindows(
        on screens: [NSScreen],
        completion: @escaping (ScreenshotOverlaySelectionResult) -> Void
    ) -> [any ScreenshotOverlayWindowManaging] {
        screens.map { screen in
            let window = ScreenshotOverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.animationBehavior = .none
            window.backgroundColor = .clear
            window.isOpaque = false
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .ignoresCycle,
                .stationary,
            ]
            window.onCancel = {
                completion(.failure(.cancelled))
            }
            window.contentView = NSHostingView(
                rootView: ScreenshotOverlayView(
                    screen: screen,
                    onComplete: completion
                )
            )
            return window
        }
    }

    private func complete(_ result: ScreenshotOverlaySelectionResult) {
        guard let continuation else { return }

        self.continuation = nil
        let currentWindows = windows
        windows = []
        closingWindows.append(contentsOf: currentWindows)
        currentWindows.forEach { window in
            window.dismissOverlayWindow()
        }
        continuation.resume(returning: result)

        DispatchQueue.main.async { [weak self] in
            self?.closingWindows.removeAll()
        }
    }
}

@MainActor
protocol ScreenshotOverlayWindowManaging: AnyObject {
    func showOverlayWindow()
    func makeOverlayKeyWindow()
    func dismissOverlayWindow()
}

private final class ScreenshotOverlayWindow: NSWindow, ScreenshotOverlayWindowManaging {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        super.keyDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    func showOverlayWindow() {
        orderFrontRegardless()
    }

    func makeOverlayKeyWindow() {
        makeKeyAndOrderFront(nil)
    }

    func dismissOverlayWindow() {
        onCancel = nil
        contentView = nil
        orderOut(nil)
    }
}

private struct ScreenshotOverlayView: View {
    let screen: NSScreen
    let onComplete: (ScreenshotOverlaySelectionResult) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            if let selectionRect {
                Rectangle()
                    .fill(Color.clear)
                    .background(.clear)
                    .overlay(
                        Rectangle()
                            .stroke(Color.white, lineWidth: 1.5)
                    )
                    .background(Color.white.opacity(0.12))
                    .frame(width: selectionRect.width, height: selectionRect.height)
                    .offset(x: selectionRect.minX, y: selectionRect.minY)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = value.startLocation
                    }
                    dragCurrent = value.location
                }
                .onEnded { value in
                    let rect = normalizedRect(from: dragStart ?? value.startLocation, to: value.location)
                    dragStart = nil
                    dragCurrent = nil

                    guard rect.width >= 10, rect.height >= 10 else {
                        onComplete(.failure(.regionTooSmall))
                        return
                    }

                    onComplete(.success(ScreenshotOverlaySelection(screen: screen, selectedRect: rect)))
                }
        )
        .onAppear {
            NSCursor.crosshair.push()
        }
        .onDisappear {
            NSCursor.pop()
        }
    }

    private var selectionRect: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return normalizedRect(from: dragStart, to: dragCurrent)
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(start.x - end.x),
            height: abs(start.y - end.y)
        )
    }
}
