#!/usr/bin/env swift

import ApplicationServices
import Foundation

private struct WindowBounds {
    let origin: CGPoint
    let size: CGSize

    var area: CGFloat {
        size.width * size.height
    }

    var screencaptureArgument: String {
        let x = Int(origin.x.rounded(.down))
        let y = Int(origin.y.rounded(.down))
        let maxX = Int((origin.x + size.width).rounded(.up))
        let maxY = Int((origin.y + size.height).rounded(.up))
        return "\(x),\(y),\(maxX - x),\(maxY - y)"
    }
}

private func attribute(
    _ name: String,
    from element: AXUIElement
) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

private func point(from value: CFTypeRef?) -> CGPoint? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgPoint else {
        return nil
    }
    var point = CGPoint.zero
    return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
}

private func size(from value: CFTypeRef?) -> CGSize? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgSize else {
        return nil
    }
    var size = CGSize.zero
    return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
}

private func standardWindowBounds(processIdentifier: pid_t) -> [WindowBounds] {
    let application = AXUIElementCreateApplication(processIdentifier)
    guard let windows = attribute(kAXWindowsAttribute, from: application) as? [AXUIElement] else {
        return []
    }

    return windows.compactMap { window in
        guard attribute(kAXSubroleAttribute, from: window) as? String == kAXStandardWindowSubrole,
              let origin = point(from: attribute(kAXPositionAttribute, from: window)),
              let size = size(from: attribute(kAXSizeAttribute, from: window)),
              size.width >= 320,
              size.height >= 240 else {
            return nil
        }
        return WindowBounds(origin: origin, size: size)
    }
}

guard CommandLine.arguments.count == 2,
      let processIdentifier = pid_t(CommandLine.arguments[1]) else {
    fputs("usage: MacToolsE2ECaptureRect.swift <process-id>\n", stderr)
    exit(2)
}

guard let bounds = standardWindowBounds(processIdentifier: processIdentifier)
    .max(by: { $0.area < $1.area }) else {
    fputs("error: no visible standard MacTools window is available for private recording\n", stderr)
    exit(1)
}

print(bounds.screencaptureArgument)
