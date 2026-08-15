import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

@MainActor
protocol InputSourceHUDPresenting: AnyObject {
    func show(
        label: InputSourceHUDLabel,
        near focusedFrame: CGRect,
        configuration: AutoInputHUDConfiguration
    )
    func dismiss()
}

protocol InputSourceHUDLabelResolving: Sendable {
    func displayLabel(for source: AutoInputSource) -> InputSourceHUDLabel
}

struct StandardInputSourceHUDLabelResolver: InputSourceHUDLabelResolving {
    func displayLabel(for source: AutoInputSource) -> InputSourceHUDLabel {
        InputSourceHUDLabel(
            title: source.name,
            modeIndicator: nil
        )
    }
}

struct InputSourceHUDLabel: Equatable, Sendable {
    let title: String
    let modeIndicator: String?
}

struct InputSourceHUDPresentationGate {
    private let duplicateInterval: TimeInterval
    private var lastLabel: InputSourceHUDLabel?
    private var lastFocusedFrame: CGRect?
    private var lastConfiguration: AutoInputHUDConfiguration?
    private var lastPresentationTime: TimeInterval?

    init(duplicateInterval: TimeInterval) {
        self.duplicateInterval = duplicateInterval
    }

    mutating func shouldPresent(
        label: InputSourceHUDLabel,
        focusedFrame: CGRect,
        configuration: AutoInputHUDConfiguration,
        at presentationTime: TimeInterval
    ) -> Bool {
        if label == lastLabel,
           focusedFrame == lastFocusedFrame,
           configuration == lastConfiguration,
           let lastPresentationTime,
           presentationTime - lastPresentationTime < duplicateInterval {
            return false
        }
        lastLabel = label
        lastFocusedFrame = focusedFrame
        lastConfiguration = configuration
        lastPresentationTime = presentationTime
        return true
    }

    mutating func reset() {
        lastLabel = nil
        lastFocusedFrame = nil
        lastConfiguration = nil
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

    func show(
        label: InputSourceHUDLabel,
        near focusedFrame: CGRect,
        configuration: AutoInputHUDConfiguration
    ) {
        let normalizedName = label.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, !focusedFrame.isEmpty else {
            dismiss()
            return
        }

        let integralFocusedFrame = focusedFrame.integral
        guard presentationGate.shouldPresent(
            label: InputSourceHUDLabel(
                title: normalizedName,
                modeIndicator: label.modeIndicator
            ),
            focusedFrame: integralFocusedFrame,
            configuration: configuration,
            at: now()
        ) else {
            return
        }

        let displayFrames = visibleFrames()
        let maximumPanelWidth = Self.matchingVisibleFrame(
            for: focusedFrame,
            visibleFrames: displayFrames
        ).map { max($0.width - (Self.displayMargin * 2), 1) }

        let panel = panel ?? Self.makePanel()
        self.panel = panel
        let metrics = Self.metrics(for: configuration.size)
        let panelSize = Self.panelSize(
            for: normalizedName,
            size: configuration.size,
            maximumWidth: maximumPanelWidth
        )
        let frame = Self.panelFrame(
            focusedFrame: focusedFrame,
            panelSize: panelSize,
            visibleFrames: displayFrames,
            position: configuration.position
        )
        panel.setFrame(frame, display: true)
        panel.setAccessibilityLabel(
            [label.modeIndicator, normalizedName].compactMap { $0 }.joined(separator: ", ")
        )
        let hostingView = NSHostingView(rootView: InputSourceHUDView(
            label: InputSourceHUDLabel(
                title: normalizedName,
                modeIndicator: label.modeIndicator
            ),
            metrics: metrics
        ))
        hostingView.wantsLayer = true
        hostingView.layer?.borderWidth = 0
        hostingView.layer?.borderColor = NSColor.clear.cgColor
        panel.contentView = hostingView

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
        panel.hasShadow = false
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

    static func panelSize(
        for sourceName: String,
        size: AutoInputHUDSize = .standard,
        maximumWidth: CGFloat? = nil
    ) -> CGSize {
        let metrics = metrics(for: size)
        let font = NSFont.systemFont(ofSize: metrics.textSize, weight: .semibold)
        let textWidth = ceil((sourceName as NSString).size(withAttributes: [.font: font]).width)
        let naturalWidth = max(
            textWidth
                + metrics.modeBadgeSize
                + metrics.spacing
                + (metrics.horizontalPadding * 2),
            metrics.minimumWidth
        )
        let resolvedWidth = maximumWidth.map { min(naturalWidth, max($0, 1)) }
            ?? naturalWidth
        return CGSize(
            width: resolvedWidth,
            height: metrics.height
        )
    }

    static func panelFrame(
        focusedFrame: CGRect,
        panelSize: CGSize,
        visibleFrames: [CGRect],
        position: AutoInputHUDPosition = .automatic
    ) -> CGRect {
        guard let visibleFrame = matchingVisibleFrame(
            for: focusedFrame,
            visibleFrames: visibleFrames
        ) else {
            return CGRect(origin: focusedFrame.origin, size: panelSize)
        }

        let gap: CGFloat = 8
        let minX = visibleFrame.minX + displayMargin
        let maxX = visibleFrame.maxX - panelSize.width - displayMargin
        let preferredX = focusedFrame.midX - panelSize.width / 2
        let x = maxX >= minX
            ? min(max(preferredX, minX), maxX)
            : visibleFrame.midX - panelSize.width / 2

        let belowY = focusedFrame.minY - panelSize.height - gap
        let aboveY = focusedFrame.maxY + gap
        let minY = visibleFrame.minY + displayMargin
        let maxY = visibleFrame.maxY - panelSize.height - displayMargin
        let belowFits = belowY >= minY
        let aboveFits = aboveY <= maxY
        let preferredY = preferredVerticalOrigin(
            position: position,
            belowY: belowY,
            aboveY: aboveY,
            belowFits: belowFits,
            aboveFits: aboveFits,
            minY: minY,
            maxY: maxY
        )
        let y = maxY >= minY
            ? min(max(preferredY, minY), maxY)
            : visibleFrame.midY - panelSize.height / 2

        return CGRect(origin: CGPoint(x: x, y: y), size: panelSize).integral
    }

    private static func preferredVerticalOrigin(
        position: AutoInputHUDPosition,
        belowY: CGFloat,
        aboveY: CGFloat,
        belowFits: Bool,
        aboveFits: Bool,
        minY: CGFloat,
        maxY: CGFloat
    ) -> CGFloat {
        switch position {
        case .automatic, .below:
            if belowFits { return belowY }
            if aboveFits { return aboveY }
        case .above:
            if aboveFits { return aboveY }
            if belowFits { return belowY }
        }
        return min(max(position == .above ? aboveY : belowY, minY), maxY)
    }

    fileprivate static func metrics(for size: AutoInputHUDSize) -> InputSourceHUDMetrics {
        switch size {
        case .compact:
            InputSourceHUDMetrics(
                textSize: 14,
                modeTextSize: 13,
                modeBadgeSize: 26,
                spacing: 7,
                horizontalPadding: 13,
                minimumWidth: 112,
                height: 44,
                cornerRadius: 11
            )
        case .standard:
            InputSourceHUDMetrics(
                textSize: 16,
                modeTextSize: 15,
                modeBadgeSize: 30,
                spacing: 9,
                horizontalPadding: 16,
                minimumWidth: 132,
                height: 52,
                cornerRadius: 13
            )
        case .large:
            InputSourceHUDMetrics(
                textSize: 19,
                modeTextSize: 18,
                modeBadgeSize: 36,
                spacing: 11,
                horizontalPadding: 20,
                minimumWidth: 156,
                height: 64,
                cornerRadius: 16
            )
        }
    }

    private static let displayMargin: CGFloat = 10

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
    let label: InputSourceHUDLabel
    let metrics: InputSourceHUDMetrics

    var body: some View {
        HStack(spacing: metrics.spacing) {
            if let modeIndicator = label.modeIndicator {
                Text(modeIndicator)
                    .font(.system(size: metrics.modeTextSize, weight: .semibold, design: .rounded))
                    .frame(width: metrics.modeBadgeSize, height: metrics.modeBadgeSize)
                    .background(
                        Color.primary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: metrics.modeBadgeSize * 0.3, style: .continuous)
                    )
            } else {
                Image(systemName: "keyboard")
                    .font(.system(size: metrics.modeTextSize, weight: .medium))
                    .frame(width: metrics.modeBadgeSize, height: metrics.modeBadgeSize)
            }
            Text(label.title)
                .font(.system(size: metrics.textSize, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            InputSourceHUDMaterial(cornerRadius: metrics.cornerRadius)
        )
    }
}

struct InputSourceHUDPreview: View {
    let title: String
    let size: AutoInputHUDSize

    var body: some View {
        let metrics = InputSourceHUDController.metrics(for: size)
        let panelSize = InputSourceHUDController.panelSize(for: title, size: size)

        InputSourceHUDView(
            label: InputSourceHUDLabel(title: title, modeIndicator: nil),
            metrics: metrics
        )
        .frame(width: panelSize.width, height: panelSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

private struct InputSourceHUDMaterial: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        configureLayer(of: view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context _: Context) {
        configureLayer(of: view)
    }

    private func configureLayer(of view: NSVisualEffectView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 0
        view.layer?.borderColor = NSColor.clear.cgColor
        view.layer?.masksToBounds = true
    }
}

private struct InputSourceHUDMetrics {
    let textSize: CGFloat
    let modeTextSize: CGFloat
    let modeBadgeSize: CGFloat
    let spacing: CGFloat
    let horizontalPadding: CGFloat
    let minimumWidth: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
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
