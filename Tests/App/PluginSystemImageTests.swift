import AppKit
import MacToolsPluginKit
import XCTest

@MainActor
final class PluginSystemImageTests: XCTestCase {
    func testInvalidDynamicSymbolFallsBackToAVisibleSymbol() {
        let resolved = PluginSystemImage.resolvedName("mactools.definitely-not-a-symbol")

        XCTAssertEqual(resolved, PluginSystemImage.fallbackName)
        XCTAssertNotNil(NSImage(systemSymbolName: resolved, accessibilityDescription: nil))
    }

    func testStaticSystemImageArgumentsAreAvailableOnTheDeploymentOS() throws {
        let argumentPattern = #"(?:systemImage|actionIconSystemName|iconName):\s*\"([A-Za-z0-9._-]+)\""#
        let regex = try NSRegularExpression(pattern: argumentPattern)
        var invalid: [String] = []

        for url in sourceFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: source) else { continue }
                let name = String(source[nameRange])
                if !PluginSystemImage.isAvailable(name) {
                    let line = source[..<nameRange.lowerBound].split(separator: "\n").count
                    invalid.append("\(url.path):\(line) \(name)")
                }
            }
        }

        XCTAssertEqual(invalid, [], "Unavailable SF Symbols: \(invalid)")
    }

    private func sourceFiles() -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return ["Sources", "Plugins"].flatMap { directory in
            let base = root.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return [URL]()
            }
            return enumerator.compactMap { element in
                guard let url = element as? URL,
                      url.pathExtension == "swift",
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    return nil
                }
                return url
            }
        }
    }
}
