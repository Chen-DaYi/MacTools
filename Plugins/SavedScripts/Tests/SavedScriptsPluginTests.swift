import MacToolsPluginKit
import XCTest
@testable import SavedScriptsPlugin

@MainActor
final class SavedScriptsPluginTests: XCTestCase {
    func testEverySavedScriptBecomesAStableCanonicalAction() throws {
        let storage = SavedScriptsTestStorage()
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(pluginID: "saved-scripts", storage: storage),
            runner: SavedScriptRunnerStub()
        )
        let script = try plugin.store.save(SavedScript(
            name: "Daily Report",
            kind: .zsh,
            source: "echo report",
            confirmOutsideManager: true,
            allowExternalInvocation: false
        )).get()

        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertEqual(definition.key.providerID, "saved-scripts")
        XCTAssertEqual(definition.key.actionID, script.actionID)
        XCTAssertEqual(definition.title, "Daily Report")
        XCTAssertEqual(definition.risk, .confirmationRequired)
        XCTAssertNotNil(definition.confirmation)
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
        XCTAssertTrue(definition.capabilities.contains(.cancellable))
    }

    func testExternalInvocationIsAlwaysConfirmedWhenExplicitlyEnabled() throws {
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: SavedScriptRunnerStub()
        )
        _ = try plugin.store.save(SavedScript(
            name: "External",
            kind: .appleScript,
            source: "return 1",
            confirmOutsideManager: false,
            allowExternalInvocation: true
        )).get()

        XCTAssertEqual(plugin.actionDefinitions.first?.risk, .safe)
        XCTAssertEqual(plugin.actionDefinitions.first?.externalInvocationPolicy, .confirmAlways)
        XCTAssertNotNil(plugin.actionDefinitions.first?.confirmation)
    }

    func testActionExecutesScriptAndCapturesOutputForStandaloneLibrary() async throws {
        let runner = SavedScriptRunnerStub(result: SavedScriptProcessResult(
            exitCode: 0,
            standardOutput: "done\n",
            standardError: "",
            outputWasTruncated: false
        ))
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: runner
        )
        let script = try plugin.store.save(SavedScript(
            name: "Run Me",
            kind: .bash,
            source: "echo done"
        )).get()
        let reference = ActionReference(
            key: ActionKey(providerID: "saved-scripts", actionID: script.actionID)
        )

        let handle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .workflow,
            mode: .background
        ))
        let result = await handle.result()
        let receivedScriptIDs = await runner.receivedScriptIDs()

        XCTAssertEqual(result, .succeeded(message: "done"))
        XCTAssertEqual(receivedScriptIDs, [script.id])
        XCTAssertEqual(plugin.executionStore.record(for: script.id)?.status, .succeeded)
        XCTAssertEqual(plugin.executionStore.record(for: script.id)?.standardOutput, "done\n")
    }

    func testPrimaryPanelSupportsDirectRunAndManagerWithoutOtherActionSurfaces() throws {
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: SavedScriptRunnerStub()
        )
        let script = try plugin.store.save(SavedScript(
            name: "Panel Script",
            kind: .sh,
            source: "echo panel"
        )).get()
        plugin.handleAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(plugin.primaryPanelState.detail?.primaryControls)

        XCTAssertEqual(controls.first?.id, script.actionID)
        XCTAssertEqual(controls.first?.actionTitle, "Panel Script")
        XCTAssertEqual(controls.last?.id, "open-manager")
    }

    func testPrimaryPanelShowsAnExecutionIndicatorWhileAScriptRuns() throws {
        var now = Date(timeIntervalSince1970: 100)
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: SavedScriptRunnerStub(),
            indicatorNow: { now }
        )
        let script = try plugin.store.save(SavedScript(
            name: "Long Task",
            kind: .zsh,
            source: "sleep 1"
        )).get()

        XCTAssertNil(plugin.primaryPanelIndicator)
        _ = plugin.executionStore.begin(script)

        XCTAssertEqual(plugin.primaryPanelIndicator?.systemImage, "progress.indicator")
        XCTAssertFalse(plugin.primaryPanelIndicator?.text.isEmpty ?? true)

        let runID = try XCTUnwrap(plugin.executionStore.record(for: script.id)?.id)
        plugin.executionStore.finish(
            scriptID: script.id,
            runID: runID,
            status: .succeeded,
            now: now
        )
        XCTAssertEqual(plugin.primaryPanelIndicator?.systemImage, "checkmark.circle.fill")

        now.addTimeInterval(7.9)
        XCTAssertEqual(plugin.primaryPanelIndicator?.systemImage, "checkmark.circle.fill")

        now.addTimeInterval(0.1)
        XCTAssertNil(plugin.primaryPanelIndicator)
    }

    func testPortablePreferencesFollowPerScriptOptIn() throws {
        let plugin = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: SavedScriptRunnerStub()
        )
        _ = try plugin.store.save(SavedScript(
            name: "Backup",
            kind: .zsh,
            source: "echo backup",
            includeSourceInBackup: true
        )).get()

        let data = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        let restored = SavedScriptsPlugin(
            context: PluginRuntimeContext(
                pluginID: "saved-scripts",
                storage: SavedScriptsTestStorage()
            ),
            runner: SavedScriptRunnerStub()
        )
        restored.restorePortablePreferences(from: data)

        XCTAssertEqual(restored.store.scripts.map(\.name), ["Backup"])
    }
}

private actor SavedScriptRunnerStub: SavedScriptRunning {
    private let result: SavedScriptProcessResult
    private var scriptIDs: [UUID] = []

    init(result: SavedScriptProcessResult = SavedScriptProcessResult(
        exitCode: 0,
        standardOutput: "",
        standardError: "",
        outputWasTruncated: false
    )) {
        self.result = result
    }

    func run(_ script: SavedScript) async throws -> SavedScriptProcessResult {
        scriptIDs.append(script.id)
        return result
    }

    func receivedScriptIDs() -> [UUID] {
        scriptIDs
    }
}
