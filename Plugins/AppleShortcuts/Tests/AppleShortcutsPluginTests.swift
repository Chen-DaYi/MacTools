import Foundation
import MacToolsPluginKit
import XCTest
@testable import AppleShortcutsPlugin

@MainActor
final class AppleShortcutsPluginTests: XCTestCase {
    func testPublishesOnlyEnabledStableCanonicalActionsAcrossRename() async throws {
        let id = UUID()
        let runner = AppleShortcutsRunnerStub(shortcuts: [AppleShortcutItem(id: id, name: "Old")])
        let plugin = makePlugin(runner: runner)
        await plugin.controller.performRefresh()
        let item = try XCTUnwrap(plugin.item(id: id))
        try plugin.store.setShortcutEnabled(true, item: item).get()

        let original = try XCTUnwrap(plugin.actionDefinitions.first)
        await runner.setShortcuts([AppleShortcutItem(id: id, name: "New")])
        await plugin.controller.performRefresh()
        let renamed = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertEqual(original.key.actionID, "run.\(id.uuidString.lowercased())")
        XCTAssertEqual(original.key, renamed.key)
        XCTAssertEqual(renamed.title, "New")
        XCTAssertEqual(renamed.risk, .confirmationRequired)
        XCTAssertEqual(renamed.externalInvocationPolicy, .unavailable)
    }

    func testConfirmationAndRunLinkPoliciesAreIndependentAndExternalAlwaysConfirms() async throws {
        let id = UUID()
        let runner = AppleShortcutsRunnerStub(shortcuts: [AppleShortcutItem(id: id, name: "Secure")])
        let plugin = makePlugin(runner: runner)
        await plugin.controller.performRefresh()
        try plugin.store.setShortcutEnabled(true, item: try XCTUnwrap(plugin.item(id: id))).get()

        var definition = try XCTUnwrap(plugin.actionDefinitions.first)
        XCTAssertEqual(definition.risk, .confirmationRequired)
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)

        try plugin.store.setAllowsRunLink(true, for: id).get()

        definition = try XCTUnwrap(plugin.actionDefinitions.first)
        XCTAssertEqual(definition.risk, .confirmationRequired)
        XCTAssertEqual(definition.externalInvocationPolicy, .confirmAlways)
        XCTAssertNotNil(definition.confirmation)

        try plugin.store.setRequiresConfirmation(false, for: id).get()
        definition = try XCTUnwrap(plugin.actionDefinitions.first)
        XCTAssertEqual(definition.risk, .safe)
        XCTAssertEqual(definition.externalInvocationPolicy, .confirmAlways)
        XCTAssertNotNil(definition.confirmation)
    }

    func testPolicyChangesRequestImmediateSafetyRegistryRebuild() async throws {
        let id = UUID()
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [AppleShortcutItem(id: id, name: "Safety")]
        )
        let plugin = makePlugin(runner: runner)
        await plugin.controller.performRefresh()
        try plugin.store.setShortcutEnabled(
            true,
            item: try XCTUnwrap(plugin.item(id: id))
        ).get()
        var safetyChangeCount = 0
        plugin.onActionSafetyStateChange = { safetyChangeCount += 1 }

        try plugin.store.setRequiresConfirmation(false, for: id).get()
        try plugin.store.setAllowsRunLink(true, for: id).get()

        XCTAssertEqual(safetyChangeCount, 2)
    }

    func testMissingEnabledShortcutRemainsPublishedButUnavailable() async throws {
        let id = UUID()
        let runner = AppleShortcutsRunnerStub(shortcuts: [AppleShortcutItem(id: id, name: "Keep")])
        let plugin = makePlugin(runner: runner)
        await plugin.controller.performRefresh()
        try plugin.store.setShortcutEnabled(true, item: try XCTUnwrap(plugin.item(id: id))).get()
        await runner.setShortcuts([])
        await plugin.controller.performRefresh()

        let definition = try XCTUnwrap(plugin.actionDefinitions.first)
        let availability = plugin.actionAvailability(for: ActionReference(key: definition.key))

        XCTAssertEqual(definition.title, "Keep")
        XCTAssertFalse(availability.isAvailable)
    }

    func testActionExecutesByIdentifierAndCapturesOutput() async throws {
        let id = UUID()
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [AppleShortcutItem(id: id, name: "Run")],
            runResult: .success(AppleShortcutsCommandResult(
                exitCode: 0,
                standardOutput: "done\n",
                standardError: "",
                outputWasTruncated: false
            ))
        )
        let plugin = makePlugin(runner: runner)
        await plugin.controller.performRefresh()
        try plugin.store.setShortcutEnabled(true, item: try XCTUnwrap(plugin.item(id: id))).get()
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let handle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .workflow,
            mode: .background
        ))

        let result = await handle.result()
        let runIDs = await runner.observedRunIDs()
        XCTAssertEqual(result, .succeeded(message: "done"))
        XCTAssertEqual(runIDs, [id])
        XCTAssertEqual(plugin.controller.executionStore.record(for: id)?.standardOutput, "done\n")
    }

    func testNonzeroActionPreservesCapturedDiagnosticsAndTruncation() async throws {
        let item = AppleShortcutItem(id: UUID(), name: "Fail")
        let commandResult = AppleShortcutsCommandResult(
            exitCode: 9,
            standardOutput: "partial output",
            standardError: "failure detail",
            outputWasTruncated: true
        )
        let runner = NonzeroAppleShortcutsRunnerStub(item: item, result: commandResult)
        let plugin = AppleShortcutsPlugin(
            context: PluginRuntimeContext(
                pluginID: "apple-shortcuts",
                storage: AppleShortcutsTestStorage()
            ),
            runner: runner
        )
        await plugin.controller.performRefresh()
        try plugin.store.setShortcutEnabled(true, item: item).get()
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let handle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        ))
        let result = await handle.result()
        let record = try XCTUnwrap(plugin.controller.executionStore.record(for: item.id))

        XCTAssertEqual(result, .failed(message: "failure detail"))
        XCTAssertEqual(record.exitCode, 9)
        XCTAssertEqual(record.standardOutput, "partial output")
        XCTAssertEqual(record.standardError, "failure detail")
        XCTAssertTrue(record.outputWasTruncated)
    }

    func testPortablePreferencesAndBackupDispositionRequirePluginSettings() async throws {
        let id = UUID()
        let runner = AppleShortcutsRunnerStub(shortcuts: [AppleShortcutItem(id: id, name: "Backup")])
        let plugin = makePlugin(runner: runner)
        await plugin.controller.performRefresh()
        try plugin.store.setShortcutEnabled(true, item: try XCTUnwrap(plugin.item(id: id))).get()
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)
        let backup = try XCTUnwrap(plugin.makePortablePreferencesBackup())

        XCTAssertEqual(plugin.backupDisposition(for: reference), .requiresPluginPreferences)
        XCTAssertEqual(plugin.actionReferences(inPortablePreferences: backup), [reference])

        let restored = makePlugin(runner: AppleShortcutsRunnerStub())
        XCTAssertTrue(restored.restorePortablePreferencesReportingResult(from: backup))
        XCTAssertEqual(restored.actionDefinitions.first?.key, reference.key)
    }

    func testProviderRejectsNoncanonicalUppercaseActionIdentity() async throws {
        let id = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [AppleShortcutItem(id: id, name: "Canonical")]
        )
        let plugin = makePlugin(runner: runner)
        await plugin.controller.performRefresh()
        try plugin.store.setShortcutEnabled(
            true,
            item: try XCTUnwrap(plugin.item(id: id))
        ).get()
        let reference = ActionReference(key: ActionKey(
            providerID: plugin.metadata.id,
            actionID: "run.\(id.uuidString)"
        ))

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
        XCTAssertEqual(plugin.backupDisposition(for: reference), .excluded)
    }

    func testActionCancellationWinsWhenRunnerReturnsAfterIgnoringCancellation() async throws {
        let id = UUID()
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [AppleShortcutItem(id: id, name: "Cancel")],
            delay: .milliseconds(100),
            ignoresCancellation: true
        )
        let plugin = makePlugin(runner: runner)
        await plugin.controller.performRefresh()
        try plugin.store.setShortcutEnabled(true, item: try XCTUnwrap(plugin.item(id: id))).get()
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)
        let handle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        ))
        let resultTask = Task { @MainActor in await handle.result() }
        var didStart = false
        for _ in 0 ..< 100 {
            didStart = await runner.observedRunIDs().contains(id)
            if didStart { break }
            await Task.yield()
        }
        XCTAssertTrue(didStart)

        handle.cancel()
        let result = await resultTask.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(plugin.controller.executionStore.record(for: id)?.status, .cancelled)
    }

    func testCancellationBeforeActionRegistrationNeverStartsShortcut() async throws {
        let item = AppleShortcutItem(id: UUID(), name: "Cancel Before Registration")
        let runner = AppleShortcutsRunnerStub(shortcuts: [item])
        let gate = AppleShortcutsActionRegistrationGate()
        let plugin = AppleShortcutsPlugin(
            context: PluginRuntimeContext(
                pluginID: "apple-shortcuts",
                storage: AppleShortcutsTestStorage()
            ),
            runner: runner,
            beforeActionRegistration: { await gate.wait() }
        )
        await plugin.controller.performRefresh()
        try plugin.store.setShortcutEnabled(true, item: item).get()
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)
        let handle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        ))
        let resultTask = Task { @MainActor in await handle.result() }
        for _ in 0 ..< 100 where !gate.isWaiting { await Task.yield() }
        XCTAssertTrue(gate.isWaiting)

        handle.cancel()
        gate.resume()
        let result = await resultTask.value
        let runIDs = await runner.observedRunIDs()

        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(runIDs.isEmpty)
        XCTAssertFalse(plugin.controller.isRunning(item.id))
    }

    func testHostRefreshEntryPointRespectsFreshnessWindow() async {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let runner = AppleShortcutsRunnerStub()
        let plugin = AppleShortcutsPlugin(
            context: PluginRuntimeContext(
                pluginID: "apple-shortcuts",
                storage: AppleShortcutsTestStorage()
            ),
            runner: runner,
            now: { currentDate }
        )
        await plugin.controller.performRefresh()

        currentDate.addTimeInterval(AppleShortcutsController.freshnessInterval - 1)
        plugin.refresh()
        for _ in 0 ..< 20 { await Task.yield() }
        var callCount = await runner.observedListCallCount()
        XCTAssertEqual(callCount, 1)

        currentDate.addTimeInterval(1)
        plugin.refresh()
        for _ in 0 ..< 100 {
            if await runner.observedListCallCount() == 2 { break }
            await Task.yield()
        }
        callCount = await runner.observedListCallCount()
        XCTAssertEqual(callCount, 2)
    }

    func testMetadataAndSettingsOnlyCapabilitiesMatchManifest() throws {
        struct Manifest: Decodable {
            struct Capabilities: Decodable {
                let primaryPanel: Bool
                let componentPanel: Bool
                let settings: String
            }

            let id: String
            let capabilities: Capabilities
        }

        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugin.json")
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let plugin = makePlugin(runner: AppleShortcutsRunnerStub())

        XCTAssertEqual(plugin.metadata.id, manifest.id)
        XCTAssertEqual(plugin.primaryPanel != nil, manifest.capabilities.primaryPanel)
        XCTAssertEqual(plugin.componentPanel != nil, manifest.capabilities.componentPanel)
        XCTAssertEqual(manifest.capabilities.settings, "workspace")
        XCTAssertEqual(plugin.settingsPage?.body.layout, .workspace)
        XCTAssertTrue(plugin.actionDefinitions.isEmpty)
        XCTAssertTrue(plugin.actionCatalogEntries.isEmpty)
        XCTAssertTrue(plugin.store.trackedRecords.isEmpty)
        XCTAssertEqual(plugin.controller.snapshot.discovery, .empty)
    }

    func testRuntimeLocalizationCatalogCoversEnglishAndChineseFormatStrings() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        XCTAssertEqual(strings.count, 87)

        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any], "Invalid entry for \(key)")
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                "Missing localizations for \(key)"
            )
            for language in ["en", "zh-Hans", "zh-Hant"] {
                let localization = try XCTUnwrap(
                    localizations[language] as? [String: Any],
                    "Missing \(language) localization for \(key)"
                )
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                XCTAssertEqual(unit["state"] as? String, "translated")
                XCTAssertFalse((unit["value"] as? String ?? "").isEmpty)
            }
        }

        let formatSpecifiers = [
            "settings.run.confirm.title": ["%@"],
            "source.folders.format": ["%@"],
            "folder.sync.enable.review": ["%lld"],
            "folder.sync.disable.review": ["%lld"],
            "settings.counts.format": ["%1$lld", "%2$lld"],
        ]
        for (key, specifiers) in formatSpecifiers {
            let entry = try XCTUnwrap(strings[key] as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for language in ["en", "zh-Hans", "zh-Hant"] {
                let localization = try XCTUnwrap(localizations[language] as? [String: Any])
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                let value = unit["value"] as? String ?? ""
                for specifier in specifiers {
                    XCTAssertTrue(value.contains(specifier))
                }
            }
        }

        let countEntry = try XCTUnwrap(strings["settings.counts.format"] as? [String: Any])
        let countLocalizations = try XCTUnwrap(
            countEntry["localizations"] as? [String: Any]
        )
        for language in ["en", "zh-Hans", "zh-Hant"] {
            let localization = try XCTUnwrap(
                countLocalizations[language] as? [String: Any]
            )
            let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
            let format = try XCTUnwrap(unit["value"] as? String)
            XCTAssertEqual(
                String(
                    format: format,
                    locale: Locale(identifier: language),
                    Int64(12),
                    Int64(3)
                ),
                "12 / 3"
            )
        }
    }

    private func makePlugin(runner: AppleShortcutsRunnerStub) -> AppleShortcutsPlugin {
        AppleShortcutsPlugin(
            context: PluginRuntimeContext(
                pluginID: "apple-shortcuts",
                storage: AppleShortcutsTestStorage()
            ),
            runner: runner
        )
    }
}

@MainActor
private final class AppleShortcutsActionRegistrationGate {
    private(set) var isWaiting = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isWaiting = true
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
