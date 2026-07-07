import Foundation
import XCTest
@testable import TranslatorPlugin

@MainActor
final class SelectedTextCapturePipelineTests: XCTestCase {
    func testFirstSuccessfulStrategyWins() async {
        let pipeline = SelectedTextCapturePipeline(strategies: [
            StubSelectedTextCapture(
                strategyID: .accessibility,
                result: SelectedTextCaptureResult(
                    text: nil,
                    strategyID: .accessibility,
                    isEditable: false,
                    sourceApplicationBundleID: "com.example.first",
                    failureReason: "失败"
                )
            ),
            StubSelectedTextCapture(
                strategyID: .browserAppleScript,
                result: SelectedTextCaptureResult(
                    text: "selected text",
                    strategyID: .browserAppleScript,
                    isEditable: true,
                    sourceApplicationBundleID: "com.example.second",
                    failureReason: "忽略"
                )
            ),
            StubSelectedTextCapture(
                strategyID: .simulatedCopy,
                result: SelectedTextCaptureResult(
                    text: "later text",
                    strategyID: .simulatedCopy,
                    isEditable: false,
                    sourceApplicationBundleID: "com.example.third",
                    failureReason: nil
                )
            ),
        ])

        let result = await pipeline.capture(context: SelectedTextCaptureContext())

        XCTAssertEqual(result.text, "selected text")
        XCTAssertEqual(result.strategyID, .browserAppleScript)
        XCTAssertTrue(result.isEditable)
        XCTAssertEqual(result.sourceApplicationBundleID, "com.example.second")
        XCTAssertNil(result.failureReason)
    }

    func testBlankTextFallsThroughAfterTrimming() async {
        let pipeline = SelectedTextCapturePipeline(strategies: [
            StubSelectedTextCapture(
                strategyID: .accessibility,
                result: SelectedTextCaptureResult(
                    text: " \n\t ",
                    strategyID: .accessibility,
                    isEditable: true,
                    sourceApplicationBundleID: "com.example.blank",
                    failureReason: nil
                )
            ),
            StubSelectedTextCapture(
                strategyID: .browserAppleScript,
                result: SelectedTextCaptureResult(
                    text: "browser text",
                    strategyID: .browserAppleScript,
                    isEditable: false,
                    sourceApplicationBundleID: "com.apple.Safari",
                    failureReason: nil
                )
            ),
        ])

        let result = await pipeline.capture(context: SelectedTextCaptureContext())

        XCTAssertEqual(result.text, "browser text")
        XCTAssertEqual(result.strategyID, .browserAppleScript)
        XCTAssertEqual(result.sourceApplicationBundleID, "com.apple.Safari")
    }

    func testBrowserContextPrefersAppleScriptOverAccessibilityText() async {
        let pipeline = SelectedTextCapturePipeline(strategies: [
            StubSelectedTextCapture(
                strategyID: .accessibility,
                result: SelectedTextCaptureResult(
                    text: "accessibility text",
                    strategyID: .accessibility,
                    isEditable: true,
                    sourceApplicationBundleID: "com.apple.Safari",
                    failureReason: nil
                )
            ),
            StubSelectedTextCapture(
                strategyID: .browserAppleScript,
                result: SelectedTextCaptureResult(
                    text: "browser selection",
                    strategyID: .browserAppleScript,
                    isEditable: false,
                    sourceApplicationBundleID: "com.apple.Safari",
                    failureReason: nil
                )
            ),
        ])

        let result = await pipeline.capture(context: SelectedTextCaptureContext(frontmostApplicationBundleID: "com.apple.Safari"))

        XCTAssertEqual(result.text, "browser selection")
        XCTAssertEqual(result.strategyID, .browserAppleScript)
    }

    func testBrowserContextFallsBackToAccessibilityWhenAppleScriptFails() async {
        let pipeline = SelectedTextCapturePipeline(strategies: [
            StubSelectedTextCapture(
                strategyID: .accessibility,
                result: SelectedTextCaptureResult(
                    text: "accessibility fallback",
                    strategyID: .accessibility,
                    isEditable: true,
                    sourceApplicationBundleID: "com.apple.Safari",
                    failureReason: nil
                )
            ),
            StubSelectedTextCapture(
                strategyID: .browserAppleScript,
                result: SelectedTextCaptureResult(
                    text: nil,
                    strategyID: .browserAppleScript,
                    isEditable: false,
                    sourceApplicationBundleID: "com.apple.Safari",
                    failureReason: "自动化取词失败"
                )
            ),
        ])

        let result = await pipeline.capture(context: SelectedTextCaptureContext(frontmostApplicationBundleID: "com.apple.Safari"))

        XCTAssertEqual(result.text, "accessibility fallback")
        XCTAssertEqual(result.strategyID, .accessibility)
    }

    func testAllFailuresReturnsMissingSelection() async {
        let pipeline = SelectedTextCapturePipeline(strategies: [
            StubSelectedTextCapture(
                strategyID: .accessibility,
                result: SelectedTextCaptureResult(
                    text: nil,
                    strategyID: .accessibility,
                    isEditable: false,
                    sourceApplicationBundleID: nil,
                    failureReason: "失败"
                )
            ),
            StubSelectedTextCapture(
                strategyID: .simulatedCopy,
                result: SelectedTextCaptureResult(
                    text: nil,
                    strategyID: .simulatedCopy,
                    isEditable: false,
                    sourceApplicationBundleID: nil,
                    failureReason: "复制失败"
                )
            ),
        ])

        let result = await pipeline.capture(context: SelectedTextCaptureContext())

        XCTAssertEqual(result, .missing)
        XCTAssertEqual(result.failureReason, "未找到选中文本")
    }

    func testPermissionRequiredFailureIsPreservedWhenNoStrategySucceeds() async {
        let pipeline = SelectedTextCapturePipeline(strategies: [
            StubSelectedTextCapture(
                strategyID: .accessibility,
                result: SelectedTextCaptureResult(
                    text: nil,
                    strategyID: .accessibility,
                    isEditable: false,
                    sourceApplicationBundleID: "com.example.secure",
                    failureReason: "需要辅助功能授权"
                )
            ),
            StubSelectedTextCapture(
                strategyID: .simulatedCopy,
                result: SelectedTextCaptureResult(
                    text: nil,
                    strategyID: .simulatedCopy,
                    isEditable: false,
                    sourceApplicationBundleID: nil,
                    failureReason: "复制失败"
                )
            ),
        ])

        let result = await pipeline.capture(context: SelectedTextCaptureContext())

        XCTAssertNil(result.text)
        XCTAssertEqual(result.strategyID, .accessibility)
        XCTAssertFalse(result.isEditable)
        XCTAssertEqual(result.sourceApplicationBundleID, "com.example.secure")
        XCTAssertEqual(result.failureReason, "需要辅助功能授权")
    }

    func testReturnedTextIsTrimmed() async {
        let pipeline = SelectedTextCapturePipeline(strategies: [
            StubSelectedTextCapture(
                strategyID: .simulatedCopy,
                result: SelectedTextCaptureResult(
                    text: "\n  trimmed text \t",
                    strategyID: .simulatedCopy,
                    isEditable: false,
                    sourceApplicationBundleID: "com.example.app",
                    failureReason: nil
                )
            ),
        ])

        let result = await pipeline.capture(context: SelectedTextCaptureContext())

        XCTAssertEqual(result.text, "trimmed text")
        XCTAssertEqual(result.strategyID, .simulatedCopy)
        XCTAssertEqual(result.sourceApplicationBundleID, "com.example.app")
        XCTAssertNil(result.failureReason)
    }
}

private struct StubSelectedTextCapture: SelectedTextCapturing {
    let strategyID: SelectedTextCaptureStrategyID
    let result: SelectedTextCaptureResult

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        result
    }
}
