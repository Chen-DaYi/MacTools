import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

@MainActor
protocol InputSourceHUDPresenting: AnyObject {
    func show(sourceName: String, near focusedFrame: CGRect)
    func dismiss()
}

struct InputSourceHUDPresentationGate {
    private let duplicateInterval: TimeInterval
    private var lastSourceName: String?
    private var lastFocusedFrame: CGRect?
    private var lastPresentationTime: TimeInterval?

    init(duplicateInterval: TimeInterval) {
        self.duplicateInterval = duplicateInterval
    }

    mutating func shouldPresent(
        sourceName: String,
        focusedFrame: CGRect,
        at presentationTime: TimeInterval
    ) -> Bool {
        if sourceName == lastSourceName,
           focusedFrame == lastFocusedFrame,
           let lastPresentationTime,
           presentationTime - lastPresentationTime < duplicateInterval {
            return false
        }
        lastSourceName = sourceName
        lastFocusedFrame = focusedFrame
        lastPresentationTime = presentationTime
        return true
    }

    mutating func reset() {
        lastSourceName = nil
        lastFocusedFrame = nil
        lastPresentationTime = nil
    }
}

@MainActor
final class InputSourceHUDController: InputSourceHUDPresenting {
    static let panelIdentifier = NSUserInterfaceItemIdentifier("mactools.auto-input.hud")

    private let dismissDelay: Duration
    private let now: () -> TimeInterval
    private let visibleFrames: () -> [CGRect]

    private var panel: InputSourceHUDPanel?
    private var dismissTask: Task<Void, Never>?
    private var presentationGate: InputSourceHUDPresentationGate

    init(
        dismissDelay: Duration = .milliseconds(1200),
        duplicateInterval: TimeInterval = 0.2,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        visibleFrames: @escaping () -> [CGRect] = { NSScreen.screens.map(\.visibleFrame) }
    ) {
        self.dismissDelay = dismissDelay
        self.now = now
        self.visibleFrames = visibleFrames
        self.presentationGate = InputSourceHUDPresentationGate(
            duplicateInterval: duplicateInterval
        )
    }

    func show(sourceName: String, near focusedFrame: CGRect) {
        let normalizedName = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, !focusedFrame.isEmpty else {
            dismiss()
            return
        }

        let integralFocusedFrame = focusedFrame.integral
        guard presentationGate.shouldPresent(
            sourceName: normalizedName,
            focusedFrame: integralFocusedFrame,
            at: now()
        ) else {
            return
        }

        let panel = panel ?? Self.makePanel()
        self.panel = panel
        let panelSize = Self.panelSize(for: normalizedName)
        let frame = Self.panelFrame(
            focusedFrame: focusedFrame,
            panelSize: panelSize,
            visibleFrames: visibleFrames()
        )
        panel.setFrame(frame, display: true)
        panel.setAccessibilityLabel(normalizedName)
        panel.contentView = NSHostingView(rootView: InputSourceHUDView(sourceName: normalizedName))

        PluginPresentationSafety.prepareForWindowOrdering(panel)
        panel.orderFrontRegardless()

        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self, dismissDelay] in
            try? await Task.sleep(for: dismissDelay)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        presentationGate.reset()
    }

    static func makePanel() -> InputSourceHUDPanel {
        let panel = InputSourceHUDPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = Self.panelIdentifier
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        return panel
    }

    static func panelSize(for sourceName: String) -> CGSize {
        let font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let textWidth = (sourceName as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: min(max(textWidth + 72, 132), 280), height: 52)
    }

    static func panelFrame(
        focusedFrame: CGRect,
        panelSize: CGSize,
        visibleFrames: [CGRect]
    ) -> CGRect {
        guard let visibleFrame = matchingVisibleFrame(
            for: focusedFrame,
            visibleFrames: visibleFrames
        ) else {
            return CGRect(origin: focusedFrame.origin, size: panelSize)
        }

        let margin: CGFloat = 10
        let gap: CGFloat = 8
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - panelSize.width - margin
        let preferredX = focusedFrame.midX - panelSize.width / 2
        let x = maxX >= minX
            ? min(max(preferredX, minX), maxX)
            : visibleFrame.midX - panelSize.width / 2

        let belowY = focusedFrame.minY - panelSize.height - gap
        let aboveY = focusedFrame.maxY + gap
        let minY = visibleFrame.minY + margin
        let maxY = visibleFrame.maxY - panelSize.height - margin
        let preferredY: CGFloat
        if belowY >= minY {
            preferredY = belowY
        } else if aboveY <= maxY {
            preferredY = aboveY
        } else {
            preferredY = min(max(belowY, minY), maxY)
        }
        let y = maxY >= minY
            ? min(max(preferredY, minY), maxY)
            : visibleFrame.midY - panelSize.height / 2

        return CGRect(origin: CGPoint(x: x, y: y), size: panelSize).integral
    }

    private static func matchingVisibleFrame(
        for focusedFrame: CGRect,
        visibleFrames: [CGRect]
    ) -> CGRect? {
        guard !visibleFrames.isEmpty else { return nil }
        if let containing = visibleFrames.first(where: { $0.contains(focusedFrame.center) }) {
            return containing
        }

        let intersecting = visibleFrames.max { lhs, rhs in
            lhs.intersection(focusedFrame).area < rhs.intersection(focusedFrame).area
        }
        if let intersecting, intersecting.intersects(focusedFrame) {
            return intersecting
        }

        return visibleFrames.min { lhs, rhs in
            lhs.center.squaredDistance(to: focusedFrame.center)
                < rhs.center.squaredDistance(to: focusedFrame.center)
        }
    }
}

@MainActor
final class InputSourceHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct InputSourceHUDView: View {
    let sourceName: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "keyboard")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tint)
            Text(sourceName)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        }
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    var area: CGFloat {
        isNull || isInfinite ? 0 : max(width, 0) * max(height, 0)
    }
}

private extension CGPoint {
    func squaredDistance(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}
