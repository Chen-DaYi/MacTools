import AppKit
import ApplicationServices

enum AutoInputIndicatorAlignment: CaseIterable {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft
}

struct AutoInputIndicatorFormatter {
    static func shortLabel(for inputSourceName: String) -> String {
        let trimmed = inputSourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map(String.init) ?? "?"
    }
}

struct AutoInputIndicatorAnchorResolver {
    static func anchor(caretFrame: NSRect?, mouseLocation: NSPoint) -> NSRect {
        if let caretFrame, caretFrame.isFinite, !caretFrame.isEmpty {
            return caretFrame
        }
        return NSRect(x: mouseLocation.x, y: mouseLocation.y, width: 1, height: 1)
    }
}

struct AutoInputIndicatorGeometry {
    static func origin(
        anchor: NSRect,
        panelSize: NSSize,
        visibleFrame: NSRect,
        preferredAlignment: AutoInputIndicatorAlignment = .bottomRight,
        spacing: CGFloat = 6
    ) -> NSPoint {
        for alignment in alignments(startingWith: preferredAlignment) {
            let candidate = origin(
                anchor: anchor,
                panelSize: panelSize,
                alignment: alignment,
                spacing: spacing
            )
            if visibleFrame.contains(NSRect(origin: candidate, size: panelSize)) {
                return candidate
            }
        }

        let preferred = origin(
            anchor: anchor,
            panelSize: panelSize,
            alignment: preferredAlignment,
            spacing: spacing
        )
        return NSPoint(
            x: min(max(preferred.x, visibleFrame.minX), visibleFrame.maxX - panelSize.width),
            y: min(max(preferred.y, visibleFrame.minY), visibleFrame.maxY - panelSize.height)
        )
    }

    private static func alignments(
        startingWith preferred: AutoInputIndicatorAlignment
    ) -> [AutoInputIndicatorAlignment] {
        switch preferred {
        case .bottomRight:
            return [.bottomRight, .bottomLeft, .topRight, .topLeft]
        case .bottomLeft:
            return [.bottomLeft, .bottomRight, .topLeft, .topRight]
        case .topRight:
            return [.topRight, .topLeft, .bottomRight, .bottomLeft]
        case .topLeft:
            return [.topLeft, .topRight, .bottomLeft, .bottomRight]
        }
    }

    private static func origin(
        anchor: NSRect,
        panelSize: NSSize,
        alignment: AutoInputIndicatorAlignment,
        spacing: CGFloat
    ) -> NSPoint {
        switch alignment {
        case .bottomRight:
            return NSPoint(x: anchor.maxX + spacing, y: anchor.minY - panelSize.height - spacing)
        case .bottomLeft:
            return NSPoint(x: anchor.minX - panelSize.width - spacing, y: anchor.minY - panelSize.height - spacing)
        case .topRight:
            return NSPoint(x: anchor.maxX + spacing, y: anchor.maxY + spacing)
        case .topLeft:
            return NSPoint(x: anchor.minX - panelSize.width - spacing, y: anchor.maxY + spacing)
        }
    }
}

private extension NSRect {
    var isFinite: Bool {
        [minX, minY, width, height].allSatisfy(\.isFinite)
    }
}

@MainActor
protocol AutoInputCaretLocating: AnyObject {
    func caretFrame() -> NSRect?
}

@MainActor
final class AccessibilityAutoInputCaretLocator: AutoInputCaretLocating {
    func caretFrame() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWideElement = AXUIElementCreateSystemWide()
        guard let focusedElement = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: systemWideElement
        ),
            let selectedRange = valueAttribute(
                kAXSelectedTextRangeAttribute,
                from: focusedElement
            )
        else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focusedElement,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selectedRange,
            &boundsValue
        ) == .success,
            let boundsValue,
            CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }

        var accessibilityBounds = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &accessibilityBounds),
              accessibilityBounds.isFinite,
              !accessibilityBounds.isEmpty,
              let primaryScreen = NSScreen.screens.first
        else { return nil }

        return NSRect(
            x: accessibilityBounds.minX,
            y: primaryScreen.frame.maxY - accessibilityBounds.maxY,
            width: max(accessibilityBounds.width, 1),
            height: max(accessibilityBounds.height, 1)
        )
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func valueAttribute(_ attribute: String, from element: AXUIElement) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }
}

@MainActor
final class AutoInputHUDController: AutoInputHUDPresenting {
    private static let panelSize = NSSize(width: 32, height: 32)

    private let caretLocator: AutoInputCaretLocating
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWorkItem: DispatchWorkItem?

    init(caretLocator: AutoInputCaretLocating = AccessibilityAutoInputCaretLocator()) {
        self.caretLocator = caretLocator
    }

    func show(inputSourceName: String) {
        let panel = panel ?? makePanel()
        self.panel = panel
        label?.stringValue = AutoInputIndicatorFormatter.shortLabel(for: inputSourceName)
        position(panel)

        hideWorkItem?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.fadeOut()
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: workItem)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let backgroundView = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor(calibratedWhite: 0.20, alpha: 0.70).cgColor
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.cornerCurve = .continuous
        backgroundView.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: backgroundView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor)
        ])

        panel.contentView = backgroundView
        self.label = label
        return panel
    }

    private func position(_ panel: NSPanel) {
        let anchor = AutoInputIndicatorAnchorResolver.anchor(
            caretFrame: caretLocator.caretFrame(),
            mouseLocation: NSEvent.mouseLocation
        )
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(anchor) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }

        panel.setFrameOrigin(AutoInputIndicatorGeometry.origin(
            anchor: anchor,
            panelSize: panel.frame.size,
            visibleFrame: visibleFrame
        ))
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            Task { @MainActor in
                panel?.orderOut(nil)
                panel?.alphaValue = 1
            }
        }
    }
}
