import Foundation
import MacToolsPluginKit
import XCTest
@testable import CloudflareR2Plugin

@MainActor
final class CloudflareR2PluginTests: XCTestCase {
    func testMetadataPanelShortcutActionAndSettingsContracts() {
        let h = makeHarness()
        XCTAssertEqual(h.plugin.metadata.id, "cloudflare-r2"); XCTAssertEqual(h.plugin.metadata.order, 75)
        XCTAssertEqual(h.plugin.metadata.title, "Cloudflare R2 上传")
        XCTAssertEqual(h.plugin.primaryPanelDescriptor.controlStyle, .button); XCTAssertEqual(h.plugin.primaryPanelDescriptor.buttonTitle, "选择")
        XCTAssertEqual(h.plugin.shortcutDefinitions.first?.actionID, CloudflareR2Plugin.ShortcutID.upload)
        XCTAssertEqual(h.plugin.actionDefinitions.first?.key.actionID, CloudflareR2Plugin.ActionID.upload)
        XCTAssertNotNil(h.plugin.settingsPage); XCTAssertTrue(h.plugin.primaryPanelState.isEnabled)
        XCTAssertEqual(h.plugin.primaryPanelState.subtitle, "上传文件并复制链接")
    }

    func testExecuteAndShortcutOpenPickerButUnknownActionDoesNot() {
        var count = 0
        let h = makeHarness(filePicker: { count += 1; return nil })
        h.plugin.handleAction(.invokeAction(controlID: "other")); XCTAssertEqual(count, 0)
        h.plugin.handleAction(.invokeAction(controlID: "execute")); XCTAssertEqual(count, 1)
        h.plugin.handleShortcutAction(id: CloudflareR2Plugin.ShortcutID.upload); XCTAssertEqual(count, 2)
    }

    func testMenuUploadDoesNotImplicitlySavePartialConfigurationOrSecret() async {
        let h = makeHarness(fileURL: URL(fileURLWithPath: "/tmp/file.txt"))
        h.store.secretAccessKey = "half-written"
        h.store.accountID = "edited-but-unsaved"
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil { if case .succeeded = h.plugin.status { true } else { false } }
        XCTAssertEqual(h.secrets.saveCount, 0)
        XCTAssertEqual(try? h.secrets.loadSecret(), "stored-secret")
        XCTAssertEqual(h.store.secretAccessKey, "half-written")
    }

    func testMissingConfigurationRequestsSettingsWithoutPicker() {
        var pickerCount = 0; let h = makeHarness(configured: false, filePicker: { pickerCount += 1; return nil })
        var settingsCount = 0; h.plugin.requestSettingsPresentation = { settingsCount += 1 }
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        XCTAssertEqual(pickerCount, 0); XCTAssertEqual(settingsCount, 1)
        XCTAssertEqual(h.plugin.status, .failed("请先在设置中完成 R2 配置。"))
    }

    func testProgressUpdatesSubtitleAndCopyButtonCopiesPublicURL() async {
        let result = R2UploadResult(objectKey: "file.txt", url: URL(string: "https://files.example.com/file.txt"))
        let uploader = R2UploaderMock(outcome: .success(result), progressValues: [0.42])
        let h = makeHarness(fileURL: URL(fileURLWithPath: "/tmp/file.txt"), uploader: uploader)
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil { h.plugin.status == .succeeded(result) }
        XCTAssertEqual(h.clipboard.values, ["https://files.example.com/file.txt"])
        XCTAssertEqual(h.notifier.notifications, [.init(fileName: "file.txt", result: result)])
        XCTAssertEqual(h.plugin.primaryPanelState.subtitle, "上传完成：file.txt")
    }

    func testProgressUpdatesAreClampedAndDeduplicatedByPercentage() async {
        let uploader = R2UploaderMock(
            outcome: .success(R2UploadResult(objectKey: "file.txt", url: nil)),
            progressValues: [0.421, 0.429, 0.42],
            suspended: true
        )
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/file.txt"),
            uploader: uploader
        )
        var stateChangeCount = 0
        h.plugin.onStateChange = { stateChangeCount += 1 }
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil {
            h.plugin.primaryPanelState.subtitle == "正在上传 file.txt… 42%"
        }
        XCTAssertEqual(stateChangeCount, 2)
        h.plugin.cancelUpload()
    }

    func testProgressRelayClampsAndOnlyReportsIncreasingWholePercentages() {
        let recorder = ProgressRecorderMock()
        let relay = R2ProgressRelay { recorder.append($0) }
        [-0.5, 0, 0.421, 0.429, 0.41, 1.5, 1].forEach(relay.report)
        XCTAssertEqual(recorder.values, [0.42, 1])
    }

    func testPrivateSuccessShowsConfirmationWithoutCopying() async {
        let result = R2UploadResult(objectKey: "private/file.txt", url: nil)
        let h = makeHarness(fileURL: URL(fileURLWithPath: "/tmp/file.txt"), uploader: R2UploaderMock(outcome: .success(result)))
        h.plugin.handleAction(.invokeAction(controlID: "execute")); await waitUntil { h.plugin.status == .succeeded(result) }
        XCTAssertTrue(h.clipboard.values.isEmpty); XCTAssertEqual(h.notifier.notifications, [.init(fileName: "file.txt", result: result)])
        XCTAssertEqual(h.plugin.primaryPanelState.subtitle, "上传完成：private/file.txt")
    }

    func testDismissingPublicSuccessWithoutCopyLeavesClipboardUntouched() async {
        let result = R2UploadResult(objectKey: "file.txt", url: URL(string: "https://files.example.com/file.txt"))
        let h = makeHarness(fileURL: URL(fileURLWithPath: "/tmp/file.txt"), uploader: R2UploaderMock(outcome: .success(result)), copyLinkOnNotification: false)
        h.plugin.handleAction(.invokeAction(controlID: "execute")); await waitUntil { h.plugin.status == .succeeded(result) }
        XCTAssertTrue(h.clipboard.values.isEmpty)
    }

    func testFailureUpdatesPanelWithoutSuccessSideEffects() async {
        let h = makeHarness(fileURL: URL(fileURLWithPath: "/tmp/file.txt"), uploader: R2UploaderMock(outcome: .failure(.httpStatus(403))))
        h.plugin.handleAction(.invokeAction(controlID: "execute")); await waitUntil { if case .failed = h.plugin.status { true } else { false } }
        XCTAssertEqual(h.plugin.status, .failed("上传失败（HTTP 403）。")); XCTAssertTrue(h.clipboard.values.isEmpty); XCTAssertTrue(h.notifier.notifications.isEmpty)
    }

    func testCancelReturnsToIdleAndLateCancelledErrorCannotOverwriteState() async {
        let uploader = R2UploaderMock(outcome: .failureURLCancelled, suspended: true)
        let h = makeHarness(fileURL: URL(fileURLWithPath: "/tmp/file.txt"), uploader: uploader)
        h.plugin.handleAction(.invokeAction(controlID: "execute")); await waitUntil { h.plugin.status.isUploading }
        h.plugin.cancelUpload(); XCTAssertEqual(h.plugin.status, .idle)
        await uploader.resume(); for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(h.plugin.status, .idle)
    }

    func testActionAvailabilityAndInvocation() async throws {
        var pickerCount = 0
        let h = makeHarness(filePicker: {
            pickerCount += 1
            return URL(fileURLWithPath: "/tmp/action.txt")
        })
        let definition = try XCTUnwrap(h.plugin.actionDefinitions.first)
        let reference = ActionReference(key: definition.key)
        XCTAssertTrue(h.plugin.actionAvailability(for: reference).isAvailable)
        let invocation = ActionInvocation(reference: reference, source: .test, mode: .foreground)
        let handle = try h.plugin.beginAction(invocation)
        XCTAssertEqual(pickerCount, 0)
        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(pickerCount, 1)
    }

    func testSettingsCancellationStopsActionUploadTask() async throws {
        let uploader = R2UploaderMock(
            outcome: .success(R2UploadResult(objectKey: "action.txt", url: nil)),
            suspended: true
        )
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/action.txt"),
            uploader: uploader
        )
        let definition = try XCTUnwrap(h.plugin.actionDefinitions.first)
        let invocation = ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .test,
            mode: .foreground
        )
        let handle = try h.plugin.beginAction(invocation)
        let resultTask = Task { await handle.result() }
        await waitUntil { h.plugin.status.isUploading }
        h.plugin.cancelUpload()
        let actionResult = await resultTask.value
        XCTAssertEqual(actionResult, .cancelled)
        let wasCancelled = await uploader.wasCancelled
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(h.plugin.status, .idle)
    }

    func testDeactivationStopsActionUploadTask() async throws {
        let uploader = R2UploaderMock(
            outcome: .success(R2UploadResult(objectKey: "action.txt", url: nil)),
            suspended: true
        )
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/action.txt"),
            uploader: uploader
        )
        let definition = try XCTUnwrap(h.plugin.actionDefinitions.first)
        let handle = try h.plugin.beginAction(ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .test,
            mode: .foreground
        ))
        let resultTask = Task { await handle.result() }
        await waitUntil { h.plugin.status.isUploading }
        h.plugin.deactivate(reason: .uninstalling)
        let actionResult = await resultTask.value
        let wasCancelled = await uploader.wasCancelled
        XCTAssertEqual(actionResult, .cancelled)
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(h.plugin.status, .idle)
    }

    func testTerminalStatusReturnsToIdle() async {
        let result = R2UploadResult(objectKey: "file.txt", url: nil)
        let h = makeHarness(
            fileURL: URL(fileURLWithPath: "/tmp/file.txt"),
            uploader: R2UploaderMock(outcome: .success(result)),
            terminalStatusDuration: .milliseconds(1)
        )
        h.plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil { h.plugin.status == .idle }
        XCTAssertEqual(h.plugin.primaryPanelState.subtitle, "上传文件并复制链接")
    }

    func testStatusDerivedValues() {
        XCTAssertEqual(R2UploadStatus.uploading("file", progress: 0.42).subtitle, "正在上传 file… 42%")
        XCTAssertTrue(R2UploadStatus.uploading("file", progress: 0).isUploading)
        XCTAssertEqual(R2UploadStatus.failed("reason").errorMessage, "reason")
    }

    private func makeHarness(configured: Bool = true, fileURL: URL? = nil, uploader: R2UploaderMock = R2UploaderMock(outcome: .success(R2UploadResult(objectKey: "file.txt", url: nil))), filePicker: (@MainActor @Sendable () -> URL?)? = nil, copyLinkOnNotification: Bool = true, terminalStatusDuration: Duration? = nil) -> Harness {
        let storage = R2MemoryStorage(values: configured ? ["account-id": "account", "bucket": "bucket", "access-key-id": "access"] : [:])
        let secrets = R2SecretStoreMock(secret: configured ? "stored-secret" : nil)
        let store = R2ConfigurationStore(storage: storage, secrets: secrets)
        let clipboard = R2ClipboardMock(); let notifier = R2CompletionNotifierMock(copyLink: copyLinkOnNotification); let picker: @MainActor @Sendable () -> URL? = filePicker ?? { fileURL }
        let plugin = CloudflareR2Plugin(context: PluginRuntimeContext(pluginID: "cloudflare-r2", storage: storage), uploader: uploader, configurationStore: store, filePicker: picker, clipboard: clipboard, completionNotifier: notifier, terminalStatusDuration: terminalStatusDuration)
        return Harness(plugin: plugin, store: store, secrets: secrets, clipboard: clipboard, notifier: notifier)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async { for _ in 0..<200 { if predicate() { return }; await Task.yield() }; XCTFail("Condition did not become true") }
}

private struct Harness { let plugin: CloudflareR2Plugin; let store: R2ConfigurationStore; let secrets: R2SecretStoreMock; let clipboard: R2ClipboardMock; let notifier: R2CompletionNotifierMock }

private actor R2UploaderMock: R2Uploading {
    enum Outcome: Sendable { case success(R2UploadResult), failure(R2UploadError), failureURLCancelled }
    let outcome: Outcome; let progressValues: [Double]; private var continuation: CheckedContinuation<Void, Never>?; private var suspended: Bool
    private(set) var wasCancelled = false
    init(outcome: Outcome, progressValues: [Double] = [], suspended: Bool = false) { self.outcome = outcome; self.progressValues = progressValues; self.suspended = suspended }
    func resume() { suspended = false; continuation?.resume(); continuation = nil }
    func upload(fileURL: URL, configuration: R2Configuration, secretAccessKey: String, progress: @escaping @Sendable (Double) -> Void) async throws -> R2UploadResult {
        progressValues.forEach(progress)
        if suspended {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation = $0 }
            } onCancel: {
                Task { await self.recordCancellationAndResume() }
            }
        }
        try Task.checkCancellation()
        switch outcome { case let .success(result): return result; case let .failure(error): throw error; case .failureURLCancelled: throw URLError(.cancelled) }
    }
    private func recordCancellationAndResume() {
        wasCancelled = true
        suspended = false
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class R2ClipboardMock: R2ClipboardWriting { private(set) var values: [String] = []; func copy(_ value: String) { values.append(value) } }

@MainActor
private final class R2CompletionNotifierMock: R2UploadCompletionNotifying {
    struct Notification: Equatable { let fileName: String; let result: R2UploadResult }
    let copyLink: Bool
    private(set) var notifications: [Notification] = []
    init(copyLink: Bool) { self.copyLink = copyLink }
    func notify(fileName: String, result: R2UploadResult) -> Bool { notifications.append(Notification(fileName: fileName, result: result)); return copyLink }
}

private final class ProgressRecorderMock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Double] = []
    var values: [Double] { lock.withLock { storedValues } }
    func append(_ value: Double) { lock.withLock { storedValues.append(value) } }
}
