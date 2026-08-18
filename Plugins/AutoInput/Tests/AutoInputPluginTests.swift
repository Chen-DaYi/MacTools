import AppKit
import ApplicationServices
import XCTest
import MacToolsPluginKit
@testable import AutoInputPlugin

@MainActor
final class AutoInputStoreTests: XCTestCase {
    func testDefaultsAndPersistence() {
        let storage = AutoInputMemoryStorage()
        let store = AutoInputStore(storage: storage)
        XCTAssertTrue(store.isAutoSwitchEnabled)
        XCTAssertFalse(store.isInputHUDEnabled)
        XCTAssertFalse(store.isInteractiveHUDEnabled)
        XCTAssertEqual(store.inputHUDSize, .standard)
        XCTAssertEqual(store.inputHUDPosition, .automatic)
        XCTAssertTrue(store.remembersLastInputSource)

        store.setAutoSwitchEnabled(false)
        store.setInputHUDEnabled(true)
        store.setInteractiveHUDEnabled(true)
        store.setInputHUDSize(.large)
        store.setInputHUDPosition(.above)
        store.setRemembersLastInputSource(false)
        store.upsertRule(makeRule(bundleID: "com.example.editor", sourceID: "zh"))
        store.remember(inputSourceID: "en", for: "com.example.terminal")

        let reloaded = AutoInputStore(storage: storage)
        XCTAssertFalse(reloaded.isAutoSwitchEnabled)
        XCTAssertTrue(reloaded.isInputHUDEnabled)
        XCTAssertTrue(reloaded.isInteractiveHUDEnabled)
        XCTAssertEqual(reloaded.inputHUDSize, .large)
        XCTAssertEqual(reloaded.inputHUDPosition, .above)
        XCTAssertFalse(reloaded.remembersLastInputSource)
        XCTAssertEqual(reloaded.rule(for: "com.example.editor")?.inputSourceID, "zh")
        XCTAssertEqual(reloaded.rememberedInputSourceID(for: "com.example.terminal"), "en")
    }

    func testMigratesLegacyEnabledPreferenceOnce() {
        let storage = AutoInputMemoryStorage()
        storage.setRawValue(false, forKey: "isEnabled")

        let store = AutoInputStore(storage: storage)

        XCTAssertFalse(store.isAutoSwitchEnabled)
        XCTAssertEqual(storage.rawValue(forKey: "isAutoSwitchEnabled") as? Bool, false)
        XCTAssertNil(storage.rawValue(forKey: "isEnabled"))
    }

    func testExistingAutoSwitchPreferenceWinsOverLegacyValue() {
        let storage = AutoInputMemoryStorage()
        storage.setRawValue(false, forKey: "isEnabled")
        storage.setRawValue(true, forKey: "isAutoSwitchEnabled")

        let store = AutoInputStore(storage: storage)

        XCTAssertTrue(store.isAutoSwitchEnabled)
        XCTAssertEqual(storage.rawValue(forKey: "isEnabled") as? Bool, false)
    }

    func testUpsertKeepsOneRulePerBundleIdentifier() {
        let store = AutoInputStore(storage: AutoInputMemoryStorage())
        store.upsertRule(makeRule(bundleID: "com.example.app", sourceID: "en"))
        store.upsertRule(makeRule(bundleID: "com.example.app", sourceID: "zh"))

        XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(store.rules[0].inputSourceID, "zh")
    }

    func testRejectedWritesDoNotPublishBooleanOrRuleCandidates() {
        let storage = AutoInputMemoryStorage()
        storage.blockedSetKeys = [
            "isAutoSwitchEnabled",
            "isInputHUDEnabled",
            "isInteractiveHUDEnabled",
            "inputHUDSize",
            "inputHUDPosition",
            "rules",
        ]
        let store = AutoInputStore(storage: storage)

        XCTAssertEqual(store.setAutoSwitchEnabled(false), .rejected(rollbackSucceeded: true))
        XCTAssertEqual(store.setInputHUDEnabled(true), .rejected(rollbackSucceeded: true))
        XCTAssertEqual(store.setInteractiveHUDEnabled(true), .rejected(rollbackSucceeded: true))
        XCTAssertEqual(store.setInputHUDSize(.large), .rejected(rollbackSucceeded: true))
        XCTAssertEqual(store.setInputHUDPosition(.above), .rejected(rollbackSucceeded: true))
        XCTAssertTrue(store.isAutoSwitchEnabled)
        XCTAssertFalse(store.isInputHUDEnabled)
        XCTAssertFalse(store.isInteractiveHUDEnabled)
        XCTAssertEqual(store.inputHUDSize, .standard)
        XCTAssertEqual(store.inputHUDPosition, .automatic)
        XCTAssertEqual(
            store.upsertRule(makeRule(bundleID: "com.example.app", sourceID: "en")),
            .rejected(rollbackSucceeded: true)
        )
        XCTAssertTrue(store.rules.isEmpty)

        let reloaded = AutoInputStore(storage: storage)
        XCTAssertTrue(reloaded.isAutoSwitchEnabled)
        XCTAssertFalse(reloaded.isInputHUDEnabled)
        XCTAssertFalse(reloaded.isInteractiveHUDEnabled)
        XCTAssertEqual(reloaded.inputHUDSize, .standard)
        XCTAssertEqual(reloaded.inputHUDPosition, .automatic)
        XCTAssertTrue(reloaded.rules.isEmpty)
    }

    func testRejectedRuleWritePreservesWrongTypedRawValue() {
        let storage = AutoInputMemoryStorage()
        storage.setRawValue("sentinel", forKey: "rules")
        storage.blockedSetKeys = ["rules"]
        let store = AutoInputStore(storage: storage)

        XCTAssertEqual(
            store.upsertRule(makeRule(bundleID: "com.example.app", sourceID: "en")),
            .rejected(rollbackSucceeded: true)
        )
        XCTAssertEqual(storage.rawValue(forKey: "rules") as? String, "sentinel")
        XCTAssertTrue(store.rules.isEmpty)
    }

    func testInvalidHUDPreferencesFallBackToDefaults() {
        let storage = AutoInputMemoryStorage()
        storage.setRawValue("enormous", forKey: "inputHUDSize")
        storage.setRawValue("center", forKey: "inputHUDPosition")

        let store = AutoInputStore(storage: storage)

        XCTAssertEqual(store.inputHUDSize, .standard)
        XCTAssertEqual(store.inputHUDPosition, .automatic)
    }
}

@MainActor
final class AutoInputControllerTests: XCTestCase {
    func testFixedRuleTakesPriorityOverRememberedSource() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "zh"))
        fixture.store.remember(inputSourceID: "en", for: fixture.app.bundleIdentifier)

        fixture.controller.start()

        XCTAssertEqual(fixture.sources.selectedIDs, ["zh"])
        XCTAssertEqual(fixture.controller.target(for: fixture.app.bundleIdentifier)?.reason, .fixedRule)
    }

    func testRememberedSourceIsRestoredWithoutFixedRule() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.remember(inputSourceID: "zh", for: fixture.app.bundleIdentifier)

        fixture.controller.start()

        XCTAssertEqual(fixture.sources.selectedIDs, ["zh"])
        XCTAssertEqual(fixture.controller.target(for: fixture.app.bundleIdentifier)?.reason, .remembered)
    }

    func testUnavailableFixedRuleFallsBackToRememberedSource() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "missing"))
        fixture.store.remember(inputSourceID: "zh", for: fixture.app.bundleIdentifier)

        fixture.controller.start()

        XCTAssertEqual(fixture.sources.selectedIDs, ["zh"])
    }

    func testDisabledPluginDoesNotSwitchOrRemember() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "zh"))
        fixture.store.setAutoSwitchEnabled(false)

        fixture.controller.start()
        fixture.sources.currentSourceID = "zh"
        fixture.sources.emitChange()

        XCTAssertTrue(fixture.sources.selectedIDs.isEmpty)
        XCTAssertNil(fixture.store.rememberedInputSourceID(for: fixture.app.bundleIdentifier))
    }

    func testSourceChangeRemembersCurrentInputSourceForFrontmostApp() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.controller.start()

        fixture.sources.currentSourceID = "zh"
        fixture.sources.emitChange()

        XCTAssertEqual(fixture.store.rememberedInputSourceID(for: fixture.app.bundleIdentifier), "zh")
    }

    func testActivationRemembersOutgoingAppsCurrentSource() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.controller.start()
        let nextApp = AutoInputApplication(
            bundleIdentifier: "com.example.chat",
            displayName: "Chat",
            bundleURL: nil
        )

        fixture.sources.currentSourceID = "zh"
        fixture.applications.activate(nextApp)

        XCTAssertEqual(fixture.store.rememberedInputSourceID(for: fixture.app.bundleIdentifier), "zh")
    }

    func testSelectionFailurePublishesError() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.sources.selectionError = AutoInputSourceError.selectionFailed(-1)
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "zh"))

        fixture.controller.start()

        XCTAssertEqual(fixture.controller.errorMessage, "无法切换输入法")
    }

    func testStopRemovesObservers() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.controller.start()
        fixture.controller.stop()

        XCTAssertEqual(fixture.sources.stopCount, 1)
        XCTAssertEqual(fixture.applications.stopCount, 1)
        XCTAssertEqual(fixture.focusObserver.stopCount, 0)
        XCTAssertGreaterThanOrEqual(fixture.hud.dismissCount, 1)
    }

    func testHUDStartsOnlyWhenEnabledAndAccessibilityIsGranted() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)

        fixture.controller.start()
        XCTAssertEqual(fixture.focusObserver.startCount, 0)

        fixture.store.setInputHUDEnabled(true)
        fixture.controller.configurationDidChange()

        XCTAssertEqual(fixture.focusObserver.startCount, 1)
        fixture.focusObserver.focus(AutoInputEditableFocus(frame: CGRect(x: 100, y: 200, width: 300, height: 24)))
        XCTAssertEqual(fixture.hud.presentations.last?.sourceName, "ABC")
        XCTAssertEqual(
            fixture.hud.presentations.last?.configuration,
            AutoInputHUDConfiguration(size: .standard, position: .automatic)
        )
    }

    func testHUDUsesConfiguredPresentationAndDisplayNameResolver() {
        let fixture = makeFixture(
            currentSourceID: "en",
            accessibilityGranted: true,
            hudLabelResolver: FakeInputSourceHUDLabelResolver(
                label: InputSourceHUDLabel(title: "English", modeIndicator: "A")
            )
        )
        fixture.store.setInputHUDEnabled(true)
        fixture.store.setInputHUDSize(.compact)
        fixture.store.setInputHUDPosition(.below)

        fixture.controller.start()
        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 200, width: 300, height: 24)
        ))

        XCTAssertEqual(fixture.hud.presentations.last?.sourceName, "English")
        XCTAssertEqual(fixture.hud.presentations.last?.modeIndicator, "A")
        XCTAssertEqual(
            fixture.hud.presentations.last?.configuration,
            AutoInputHUDConfiguration(size: .compact, position: .below)
        )
    }

    func testHUDRefreshesWhenSourceChangesForSameFocusedField() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()
        fixture.focusObserver.focus(AutoInputEditableFocus(frame: CGRect(x: 100, y: 200, width: 300, height: 24)))

        fixture.sources.currentSourceID = "zh"
        fixture.sources.emitChange()

        XCTAssertEqual(fixture.hud.presentations.map(\.sourceName), ["ABC", "中文"])
    }

    func testInteractiveHUDCyclesThroughSourcesAndKeepsPresenting() throws {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setInputHUDEnabled(true)
        fixture.store.setInteractiveHUDEnabled(true)
        fixture.controller.start()
        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 200, width: 300, height: 24)
        ))

        XCTAssertTrue(try XCTUnwrap(fixture.hud.presentations.last).configuration.isInteractive)

        fixture.hud.activateLastPresentation()

        XCTAssertEqual(fixture.sources.selectedIDs, ["zh"])
        XCTAssertEqual(fixture.sources.currentSourceID, "zh")
        XCTAssertEqual(fixture.hud.presentations.map(\.sourceName), ["ABC", "中文"])

        fixture.hud.activateLastPresentation()

        XCTAssertEqual(fixture.sources.selectedIDs, ["zh", "en"])
        XCTAssertEqual(fixture.sources.currentSourceID, "en")
        XCTAssertEqual(fixture.hud.presentations.map(\.sourceName), ["ABC", "中文", "ABC"])
    }

    func testSameApplicationAutomaticSelectionPresentsHUDOnce() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()
        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 200, width: 300, height: 24),
            applicationProcessIdentifier: fixture.app.processIdentifier
        ))

        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "zh"))
        fixture.controller.configurationDidChange()
        fixture.sources.emitChange()

        XCTAssertEqual(fixture.sources.selectedIDs, ["zh"])
        XCTAssertEqual(fixture.hud.presentations.map(\.sourceName), ["ABC", "中文"])
    }

    func testConfigurationChangeAttemptsAutomaticSelectionOnce() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.controller.start()
        fixture.sources.selectionError = AutoInputSourceError.selectionFailed(-1)
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "zh"))

        fixture.controller.configurationDidChange()

        XCTAssertEqual(fixture.sources.selectionAttemptIDs, ["zh"])
        XCTAssertEqual(fixture.controller.errorMessage, "无法切换输入法")
    }

    func testHUDPresentsOnceForEachMeaningfulFocusInsideSameApplication() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setAutoSwitchEnabled(false)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()

        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 200, width: 300, height: 24)
        ))
        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 400, width: 300, height: 24)
        ))

        XCTAssertEqual(fixture.hud.presentations.map(\.sourceName), ["ABC", "ABC"])
    }

    func testHUDPresentsForMacToolsOwnedEditableFocus() {
        let application = AutoInputApplication(
            bundleIdentifier: "cc.ggbond.mactools",
            displayName: "MacTools",
            bundleURL: nil,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        let fixture = makeFixture(
            currentSourceID: "en",
            accessibilityGranted: true,
            application: application
        )
        fixture.store.setAutoSwitchEnabled(false)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()

        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 200, width: 300, height: 24),
            applicationProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        ))

        XCTAssertEqual(fixture.hud.presentations.map(\.sourceName), ["ABC"])
    }

    func testDuplicateNotificationsForSameEditableFocusPresentHUDOnce() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setAutoSwitchEnabled(false)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()
        let focus = AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 200, width: 300, height: 24),
            applicationProcessIdentifier: fixture.app.processIdentifier
        )

        fixture.focusObserver.focus(focus)
        fixture.focusObserver.focus(focus)

        XCTAssertEqual(fixture.hud.presentations.map(\.sourceName), ["ABC"])
    }

    func testDifferentEditableElementsAtSameFrameEachPresentHUD() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setAutoSwitchEnabled(false)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()
        let frame = CGRect(x: 100, y: 200, width: 300, height: 24)

        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: frame,
            applicationProcessIdentifier: fixture.app.processIdentifier
        ))
        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: frame,
            applicationProcessIdentifier: fixture.app.processIdentifier
        ))

        XCTAssertEqual(fixture.hud.presentations.map(\.sourceName), ["ABC", "ABC"])
    }

    func testChromeTabSwitchToGoogleDocsLikeEditorFocusPresentsHUD() {
        let chrome = AutoInputApplication(
            bundleIdentifier: "com.google.Chrome",
            displayName: "Google Chrome",
            bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
            processIdentifier: 404
        )
        let fixture = makeFixture(
            currentSourceID: "en",
            accessibilityGranted: true,
            application: chrome
        )
        fixture.store.setAutoSwitchEnabled(false)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()
        let sharedFrame = CGRect(x: 160, y: 120, width: 960, height: 720)

        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: sharedFrame,
            applicationProcessIdentifier: chrome.processIdentifier
        ))
        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: sharedFrame,
            applicationProcessIdentifier: chrome.processIdentifier
        ))

        XCTAssertEqual(fixture.hud.presentations.map(\.sourceName), ["ABC", "ABC"])
    }

    func testHUDPresentsAtFirstEditableFocusAfterChangingApplications() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setAutoSwitchEnabled(false)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()
        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 200, width: 300, height: 24),
            applicationProcessIdentifier: fixture.app.processIdentifier
        ))

        fixture.applications.activate(AutoInputApplication(
            bundleIdentifier: "com.example.chat",
            displayName: "Chat",
            bundleURL: nil,
            processIdentifier: 202
        ))
        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 400, width: 300, height: 24),
            applicationProcessIdentifier: 202
        ))

        XCTAssertEqual(fixture.hud.presentations.map(\.sourceName), ["ABC", "ABC"])
    }

    func testHUDFocusDeliveredBeforeMatchingApplicationActivationIsPreserved() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setAutoSwitchEnabled(false)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()
        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 200, width: 300, height: 24),
            applicationProcessIdentifier: 101
        ))

        let nextApplication = AutoInputApplication(
            bundleIdentifier: "com.example.chat",
            displayName: "Chat",
            bundleURL: nil,
            processIdentifier: 202
        )
        let nextFocus = AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 400, width: 300, height: 24),
            applicationProcessIdentifier: 202
        )
        fixture.focusObserver.focus(nextFocus)
        fixture.applications.activate(nextApplication)

        XCTAssertEqual(fixture.hud.presentations.map(\.frame), [
            CGRect(x: 100, y: 200, width: 300, height: 24),
            nextFocus.frame,
        ])
    }

    func testHUDDoesNotPresentStaleFocusAgainAfterChangingApplications() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setAutoSwitchEnabled(false)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()
        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 200, width: 300, height: 24),
            applicationProcessIdentifier: 101
        ))

        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 400, width: 300, height: 24),
            applicationProcessIdentifier: 101
        ))
        fixture.applications.activate(AutoInputApplication(
            bundleIdentifier: "com.example.chat",
            displayName: "Chat",
            bundleURL: nil,
            processIdentifier: 202
        ))

        XCTAssertEqual(fixture.hud.presentations.map(\.frame), [
            CGRect(x: 100, y: 200, width: 300, height: 24),
            CGRect(x: 100, y: 400, width: 300, height: 24),
        ])
    }

    func testReturningToApplicationWithFocusedEditableElementPresentsHUD() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setAutoSwitchEnabled(false)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()
        let editorFocus = AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 200, width: 300, height: 24),
            applicationProcessIdentifier: fixture.app.processIdentifier
        )
        fixture.focusObserver.focus(editorFocus)

        fixture.applications.activate(AutoInputApplication(
            bundleIdentifier: "com.example.chat",
            displayName: "Chat",
            bundleURL: nil,
            processIdentifier: 202
        ))
        fixture.focusObserver.setCurrentFocusWithoutNotification(editorFocus)
        fixture.applications.activate(fixture.app)

        XCTAssertEqual(fixture.hud.presentations.map(\.sourceName), ["ABC", "ABC"])
    }

    func testSourceChangeRefreshesCaretFrameBeforePresentingHUD() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setAutoSwitchEnabled(false)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()
        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 200, width: 300, height: 24),
            applicationProcessIdentifier: 101
        ))

        let refreshedFocus = AutoInputEditableFocus(
            frame: CGRect(x: 360, y: 480, width: 1, height: 18),
            applicationProcessIdentifier: 101
        )
        fixture.focusObserver.setCurrentFocusWithoutNotification(refreshedFocus)
        fixture.sources.currentSourceID = "zh"
        fixture.sources.emitChange()

        XCTAssertEqual(fixture.focusObserver.refreshCount, 1)
        XCTAssertEqual(fixture.hud.presentations.map(\.frame), [
            CGRect(x: 100, y: 200, width: 300, height: 24),
            refreshedFocus.frame,
        ])
    }

    func testReverseFocusActivationOrderingPresentsOnlyAutomaticallySelectedSource() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setInputHUDEnabled(true)
        let nextApplication = AutoInputApplication(
            bundleIdentifier: "com.example.chat",
            displayName: "Chat",
            bundleURL: nil,
            processIdentifier: 202
        )
        fixture.store.upsertRule(makeRule(
            bundleID: nextApplication.bundleIdentifier,
            sourceID: "zh"
        ))
        fixture.controller.start()
        fixture.focusObserver.focus(AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 200, width: 300, height: 24),
            applicationProcessIdentifier: 101
        ))

        let nextFocus = AutoInputEditableFocus(
            frame: CGRect(x: 100, y: 400, width: 300, height: 24),
            applicationProcessIdentifier: 202
        )
        fixture.focusObserver.focus(nextFocus)
        fixture.applications.activate(nextApplication)

        XCTAssertEqual(fixture.sources.selectedIDs, ["zh"])
        XCTAssertEqual(fixture.hud.presentations.map(\.sourceName), ["ABC", "中文"])
        XCTAssertEqual(fixture.hud.presentations.map(\.frame), [
            CGRect(x: 100, y: 200, width: 300, height: 24),
            nextFocus.frame,
        ])

        fixture.focusObserver.setCurrentFocusWithoutNotification(AutoInputEditableFocus(
            frame: CGRect(x: 240, y: 520, width: 1, height: 18),
            applicationProcessIdentifier: 202
        ))
        fixture.sources.emitChange()

        XCTAssertEqual(fixture.hud.presentations.map(\.sourceName), ["ABC", "中文"])
    }

    func testSettingsVisibilityRefreshesSources() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.setAutoSwitchEnabled(false)
        fixture.controller.start()
        XCTAssertEqual(fixture.sources.stopCount, 0)

        fixture.sources.sources = [
            AutoInputSource(id: "en", name: "ABC"),
            AutoInputSource(id: "zh", name: "中文"),
            AutoInputSource(id: "jp", name: "日本語"),
        ]
        fixture.controller.settingsVisibilityDidChange(true)

        XCTAssertEqual(fixture.sources.refreshCount, 2)
        XCTAssertEqual(fixture.controller.sources.map(\.id), ["en", "zh", "jp"])
    }

    func testHUDPermissionDenialDoesNotDisableAutomaticSwitching() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: false)
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "zh"))
        fixture.store.setInputHUDEnabled(true)

        fixture.controller.start()

        XCTAssertEqual(fixture.sources.selectedIDs, ["zh"])
        XCTAssertEqual(fixture.focusObserver.startCount, 0)
        XCTAssertFalse(fixture.controller.isAccessibilityGranted)
    }

    func testEnablingHUDRequestsPermissionAndDisablingItStopsOnlyHUDServices() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: false)
        fixture.controller.start()
        fixture.store.setInputHUDEnabled(true)
        fixture.accessibility.requestResult = true

        fixture.controller.configurationDidChange(promptForAccessibility: true)

        XCTAssertEqual(fixture.accessibility.requestCount, 1)
        XCTAssertEqual(fixture.focusObserver.startCount, 1)
        XCTAssertEqual(fixture.sources.stopCount, 0)
        XCTAssertEqual(fixture.applications.stopCount, 0)

        fixture.store.setInputHUDEnabled(false)
        fixture.controller.configurationDidChange()

        XCTAssertEqual(fixture.focusObserver.stopCount, 1)
        XCTAssertEqual(fixture.sources.stopCount, 0)
        XCTAssertEqual(fixture.applications.stopCount, 0)
    }

    func testAccessibilityRevocationStopsHUDAndPreservesAutomaticSwitching() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()
        fixture.focusObserver.focus(AutoInputEditableFocus(frame: CGRect(x: 100, y: 200, width: 300, height: 24)))

        fixture.accessibility.isTrusted = false
        fixture.focusObserver.invalidateAccessibility()

        XCTAssertFalse(fixture.controller.isAccessibilityGranted)
        XCTAssertEqual(fixture.focusObserver.stopCount, 1)
        XCTAssertGreaterThanOrEqual(fixture.hud.dismissCount, 1)
        XCTAssertEqual(fixture.applications.stopCount, 0)
    }

    func testAccessibilityRevocationStopsHUDServicesButKeepsPermissionRecoveryMonitor() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setAutoSwitchEnabled(false)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()

        fixture.accessibility.isTrusted = false
        fixture.focusObserver.invalidateAccessibility()

        XCTAssertFalse(fixture.controller.isAccessibilityGranted)
        XCTAssertEqual(fixture.sources.stopCount, 0)
        XCTAssertEqual(fixture.focusObserver.stopCount, 1)
        XCTAssertEqual(fixture.applications.stopCount, 0)
    }

    func testApplicationActivationRechecksHUDPermissionWithoutPrompting() async {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: false)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()
        XCTAssertEqual(fixture.focusObserver.startCount, 0)

        fixture.accessibility.isTrusted = true
        fixture.applicationNotificationCenter.post(
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        await Task.yield()

        XCTAssertTrue(fixture.controller.isAccessibilityGranted)
        XCTAssertEqual(fixture.accessibility.requestCount, 0)
        XCTAssertEqual(fixture.focusObserver.startCount, 1)
    }

    func testExternalApplicationActivationRecoversNewlyGrantedHUDPermission() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: false)
        fixture.store.setAutoSwitchEnabled(false)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()

        XCTAssertEqual(fixture.applications.startCount, 1)
        XCTAssertEqual(fixture.sources.startCount, 1)
        XCTAssertEqual(fixture.focusObserver.startCount, 0)

        fixture.accessibility.isTrusted = true
        fixture.applications.activate(AutoInputApplication(
            bundleIdentifier: "com.example.chat",
            displayName: "Chat",
            bundleURL: nil,
            processIdentifier: 202
        ))

        XCTAssertTrue(fixture.controller.isAccessibilityGranted)
        XCTAssertEqual(fixture.accessibility.requestCount, 0)
        XCTAssertEqual(fixture.sources.startCount, 1)
        XCTAssertEqual(fixture.focusObserver.startCount, 1)
    }

    func testHUDRunsIndependentlyWhenAutomaticSwitchingIsOff() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setAutoSwitchEnabled(false)
        fixture.store.setInputHUDEnabled(true)

        fixture.controller.start()
        fixture.focusObserver.focus(AutoInputEditableFocus(frame: CGRect(x: 100, y: 200, width: 300, height: 24)))

        XCTAssertEqual(fixture.sources.startCount, 1)
        XCTAssertEqual(fixture.applications.startCount, 1)
        XCTAssertEqual(fixture.focusObserver.startCount, 1)
        XCTAssertEqual(fixture.hud.presentations.last?.sourceName, "ABC")
    }

    func testDisablingBothFeaturesKeepsOnlyCanonicalActionSourceMonitoring() {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()

        fixture.store.setAutoSwitchEnabled(false)
        fixture.store.setInputHUDEnabled(false)
        fixture.controller.configurationDidChange()

        XCTAssertEqual(fixture.sources.stopCount, 0)
        XCTAssertEqual(fixture.applications.stopCount, 1)
        XCTAssertEqual(fixture.focusObserver.stopCount, 1)
    }

    func testNoninteractiveLifecycleSuspendsPermissionRecoveryObservation() async {
        let fixture = makeFixture(currentSourceID: "en", accessibilityGranted: true)
        fixture.store.setInputHUDEnabled(true)
        fixture.controller.start()

        fixture.controller.setInteractive(false)
        fixture.accessibility.isTrusted = false
        fixture.applicationNotificationCenter.post(
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        await Task.yield()

        XCTAssertTrue(fixture.controller.isAccessibilityGranted)

        fixture.controller.setInteractive(true)
        fixture.applicationNotificationCenter.post(
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        await Task.yield()

        XCTAssertFalse(fixture.controller.isAccessibilityGranted)
        XCTAssertEqual(fixture.focusObserver.startCount, 2)
        XCTAssertEqual(fixture.focusObserver.stopCount, 2)
    }

    private func makeFixture(
        currentSourceID: String,
        accessibilityGranted: Bool = false,
        application: AutoInputApplication? = nil,
        hudLabelResolver: InputSourceHUDLabelResolving = StandardInputSourceHUDLabelResolver()
    ) -> AutoInputFixture {
        let storage = AutoInputMemoryStorage()
        let store = AutoInputStore(storage: storage)
        let sources = FakeAutoInputSourceController(
            sources: [
                AutoInputSource(id: "en", name: "ABC"),
                AutoInputSource(id: "zh", name: "中文")
            ],
            currentSourceID: currentSourceID
        )
        let app = application ?? AutoInputApplication(
            bundleIdentifier: "com.example.editor",
            displayName: "Editor",
            bundleURL: URL(fileURLWithPath: "/Applications/Editor.app"),
            processIdentifier: 101
        )
        let applications = FakeAutoInputApplicationMonitor(frontmostApplication: app)
        let focusObserver = FakeAutoInputFocusObserver()
        let hud = FakeInputSourceHUDPresenter()
        let accessibility = FakeAutoInputAccessibilityCheck(isTrusted: accessibilityGranted)
        let applicationNotificationCenter = NotificationCenter()
        let controller = AutoInputController(
            store: store,
            sourceController: sources,
            applicationMonitor: applications,
            focusObserver: focusObserver,
            hudPresenter: hud,
            hudLabelResolver: hudLabelResolver,
            accessibilityCheck: accessibility,
            applicationNotificationCenter: applicationNotificationCenter
        )
        return AutoInputFixture(
            store: store,
            sources: sources,
            applications: applications,
            focusObserver: focusObserver,
            hud: hud,
            accessibility: accessibility,
            applicationNotificationCenter: applicationNotificationCenter,
            controller: controller,
            app: app
        )
    }
}

@MainActor
final class AutoInputApplicationMonitorTests: XCTestCase {
    func testWorkspaceActivationHopsSafelyToMainActor() async {
        let notificationCenter = NotificationCenter()
        let monitor = WorkspaceAutoInputApplicationMonitor(
            notificationCenter: notificationCenter
        )
        let activated = expectation(description: "application activation delivered")
        monitor.onApplicationActivated = { application in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(application.bundleIdentifier, NSRunningApplication.current.bundleIdentifier)
            XCTAssertEqual(application.processIdentifier, NSRunningApplication.current.processIdentifier)
            activated.fulfill()
        }
        monitor.start()
        defer { monitor.stop() }

        notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [
                NSWorkspace.applicationUserInfoKey: NSRunningApplication.current,
            ]
        )

        await fulfillment(of: [activated], timeout: 1)
    }
}

@MainActor
final class AutoInputFocusObserverTests: XCTestCase {
    func testEditableRolesAreLimitedToTextInputs() {
        XCTAssertTrue(AccessibilityAutoInputFocusObserver.isEditableRole(kAXTextFieldRole as String))
        XCTAssertTrue(AccessibilityAutoInputFocusObserver.isEditableRole(kAXTextAreaRole as String))
        XCTAssertTrue(AccessibilityAutoInputFocusObserver.isEditableRole(kAXComboBoxRole as String))
        XCTAssertFalse(AccessibilityAutoInputFocusObserver.isEditableRole(kAXButtonRole as String))
    }

    func testFocusedTerminalTextAreaDoesNotRequireSettableValue() {
        XCTAssertTrue(AccessibilityAutoInputFocusObserver.acceptsFocusedInput(
            role: kAXTextAreaRole as String,
            valueIsSettable: false,
            applicationBundleIdentifier: "com.apple.Terminal"
        ))
        XCTAssertTrue(AccessibilityAutoInputFocusObserver.acceptsFocusedInput(
            role: kAXTextAreaRole as String,
            valueIsSettable: false,
            applicationBundleIdentifier: "com.mitchellh.ghostty"
        ))
        XCTAssertFalse(AccessibilityAutoInputFocusObserver.acceptsFocusedInput(
            role: kAXTextAreaRole as String,
            valueIsSettable: false,
            applicationBundleIdentifier: "com.example.viewer"
        ))
        XCTAssertFalse(AccessibilityAutoInputFocusObserver.acceptsFocusedInput(
            role: kAXTextFieldRole as String,
            valueIsSettable: false,
            applicationBundleIdentifier: "com.apple.Terminal"
        ))
        XCTAssertTrue(AccessibilityAutoInputFocusObserver.acceptsFocusedInput(
            role: kAXTextFieldRole as String,
            valueIsSettable: true,
            applicationBundleIdentifier: "com.example.editor"
        ))
        XCTAssertFalse(AccessibilityAutoInputFocusObserver.acceptsFocusedInput(
            role: kAXTextAreaRole as String,
            valueIsSettable: nil,
            applicationBundleIdentifier: "com.apple.Terminal"
        ))
        XCTAssertFalse(AccessibilityAutoInputFocusObserver.acceptsFocusedInput(
            role: kAXTextFieldRole as String,
            valueIsSettable: nil,
            applicationBundleIdentifier: "com.example.editor"
        ))
        XCTAssertFalse(AccessibilityAutoInputFocusObserver.acceptsFocusedInput(
            role: kAXComboBoxRole as String,
            valueIsSettable: nil,
            applicationBundleIdentifier: "com.example.editor"
        ))
    }

    func testGoogleDocsLikeSettableTextAreaIsAccepted() {
        XCTAssertTrue(AccessibilityAutoInputFocusObserver.acceptsFocusedInput(
            role: kAXTextAreaRole as String,
            valueIsSettable: true,
            applicationBundleIdentifier: "com.google.Chrome"
        ))
    }

    func testStoppedObservationLifecycleRejectsQueuedGeneration() {
        var lifecycle = AutoInputObservationLifecycle()
        let firstGeneration = lifecycle.start()
        XCTAssertTrue(lifecycle.accepts(firstGeneration))

        lifecycle.stop()
        XCTAssertFalse(lifecycle.accepts(firstGeneration))

        let nextGeneration = lifecycle.start()
        XCTAssertFalse(lifecycle.accepts(firstGeneration))
        XCTAssertTrue(lifecycle.accepts(nextGeneration))
    }

    func testAccessibilityCoordinatesConvertToAppKitCoordinates() {
        let converted = AccessibilityAutoInputFocusObserver.appKitFrame(
            fromAccessibilityFrame: CGRect(x: 120, y: 80, width: 300, height: 24),
            primaryScreenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )

        XCTAssertEqual(converted, CGRect(x: 120, y: 976, width: 300, height: 24))
    }

    func testSelectedTextBoundsArePreferredForHUDPlacement() {
        let elementFrame = CGRect(x: 100, y: 200, width: 500, height: 240)
        let caretFrame = CGRect(x: 180, y: 250, width: 0, height: 18)

        XCTAssertEqual(
            AccessibilityAutoInputFocusObserver.preferredAccessibilityFrame(
                elementFrame: elementFrame,
                selectionFrame: caretFrame
            ),
            CGRect(x: 180, y: 250, width: 1, height: 18)
        )
    }

    func testInvalidSelectedTextBoundsFallBackToElementFrame() {
        let elementFrame = CGRect(x: 100, y: 200, width: 500, height: 240)

        XCTAssertEqual(
            AccessibilityAutoInputFocusObserver.preferredAccessibilityFrame(
                elementFrame: elementFrame,
                selectionFrame: CGRect(x: CGFloat.infinity, y: 250, width: 1, height: 18)
            ),
            elementFrame
        )
    }

    func testGoogleDocsPlacementFallsBackToVisibleEditorFrameWithoutCaretBounds() {
        let editorFrame = CGRect(x: 160, y: 120, width: 960, height: 720)

        XCTAssertEqual(
            AccessibilityAutoInputFocusObserver.preferredAccessibilityFrame(
                elementFrame: editorFrame,
                selectionFrame: nil
            ),
            editorFrame
        )
    }
}

@MainActor
final class InputSourceHUDControllerTests: XCTestCase {
    func testInputSourcesKeepTheirLocalizedNameWithoutGuessingPrivateModes() {
        let resolver = StandardInputSourceHUDLabelResolver()

        XCTAssertEqual(
            resolver.displayLabel(for: AutoInputSource(
                id: "com.bytedance.inputmethod.doubaoime.pinyin",
                name: "豆包输入法"
            )),
            InputSourceHUDLabel(title: "豆包输入法", modeIndicator: nil)
        )
        XCTAssertEqual(
            resolver.displayLabel(for: AutoInputSource(id: "com.apple.keylayout.ABC", name: "ABC")),
            InputSourceHUDLabel(title: "ABC", modeIndicator: nil)
        )
    }

    func testPresentationGateDebouncesOnlyIdenticalEvents() {
        var gate = InputSourceHUDPresentationGate(duplicateInterval: 0.2)
        let frame = CGRect(x: 100, y: 200, width: 300, height: 24)
        let configuration = AutoInputHUDConfiguration(size: .standard, position: .automatic)
        let abc = InputSourceHUDLabel(title: "ABC", modeIndicator: nil)
        let customChinese = InputSourceHUDLabel(title: "Custom", modeIndicator: "中")
        let customEnglish = InputSourceHUDLabel(title: "Custom", modeIndicator: "A")
        let firstPresentationID = AutoInputHUDPresentationID()

        XCTAssertTrue(gate.shouldPresent(
            label: abc,
            focusedFrame: frame,
            configuration: configuration,
            presentationID: firstPresentationID,
            at: 1
        ))
        XCTAssertFalse(gate.shouldPresent(
            label: abc,
            focusedFrame: frame,
            configuration: configuration,
            presentationID: firstPresentationID,
            at: 1.1
        ))
        XCTAssertTrue(gate.shouldPresent(
            label: abc,
            focusedFrame: frame,
            configuration: configuration,
            presentationID: AutoInputHUDPresentationID(),
            at: 1.105
        ))
        XCTAssertTrue(gate.shouldPresent(
            label: customChinese,
            focusedFrame: frame,
            configuration: configuration,
            presentationID: AutoInputHUDPresentationID(),
            at: 1.11
        ))
        XCTAssertTrue(gate.shouldPresent(
            label: customEnglish,
            focusedFrame: frame.offsetBy(dx: 10, dy: 0),
            configuration: configuration,
            presentationID: AutoInputHUDPresentationID(),
            at: 1.12
        ))

        gate.reset()
        XCTAssertTrue(gate.shouldPresent(
            label: abc,
            focusedFrame: frame,
            configuration: configuration,
            presentationID: firstPresentationID,
            at: 1.13
        ))
    }

    func testHUDAppearsBelowFocusedFieldWhenSpaceAllows() {
        let frame = InputSourceHUDController.panelFrame(
            focusedFrame: CGRect(x: 300, y: 500, width: 200, height: 24),
            panelSize: CGSize(width: 160, height: 52),
            visibleFrames: [CGRect(x: 0, y: 0, width: 1000, height: 800)]
        )

        XCTAssertEqual(frame, CGRect(x: 320, y: 440, width: 160, height: 52))
    }

    func testHUDPanelCannotBecomeKeyOrReceiveMouseEvents() {
        let panel = InputSourceHUDController.makePanel()

        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.hasShadow)
    }

    func testInteractiveHUDConfigurationStillUsesANonactivatingPanel() {
        let panel = InputSourceHUDController.makePanel()
        panel.ignoresMouseEvents = false

        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }

    func testHUDOrderingPreservesActiveKeyWindowEditing() {
        let keyWindow = NSWindow()
        let backgroundWindow = NSWindow()

        let windows = InputSourceHUDController.presentationSafetyWindows(
            applicationIsActive: true,
            keyWindow: keyWindow,
            windows: [keyWindow, backgroundWindow]
        )

        XCTAssertFalse(windows.contains { $0 === keyWindow })
        XCTAssertTrue(windows.contains { $0 === backgroundWindow })
    }

    func testHUDOrderingPreparesEveryWindowWhileAnotherAppIsActive() {
        let keyWindow = NSWindow()
        let backgroundWindow = NSWindow()

        let windows = InputSourceHUDController.presentationSafetyWindows(
            applicationIsActive: false,
            keyWindow: keyWindow,
            windows: [keyWindow, backgroundWindow]
        )

        XCTAssertEqual(windows.count, 2)
        XCTAssertTrue(windows.contains { $0 === keyWindow })
        XCTAssertTrue(windows.contains { $0 === backgroundWindow })
    }

    func testInteractiveHUDRepeatedClicksReusePanelAndHostingView() throws {
        var now: TimeInterval = 1
        let controller = InputSourceHUDController(
            dismissDelay: .seconds(60),
            duplicateInterval: 0,
            now: { now },
            visibleFrames: { [CGRect(x: 0, y: 0, width: 1200, height: 800)] }
        )
        defer { controller.dismiss() }
        let configuration = AutoInputHUDConfiguration(
            size: .standard,
            position: .automatic,
            isInteractive: true
        )
        let focusedFrame = CGRect(x: 300, y: 400, width: 200, height: 24)
        var activationCount = 0
        var activationHandler: (() -> Void)?
        activationHandler = {
            activationCount += 1
            now += 1
            controller.show(
                label: InputSourceHUDLabel(
                    title: activationCount.isMultiple(of: 2) ? "U.S." : "Pinyin",
                    modeIndicator: nil
                ),
                near: focusedFrame,
                configuration: configuration,
                presentationID: AutoInputHUDPresentationID(),
                onActivate: activationHandler
            )
        }

        controller.show(
            label: InputSourceHUDLabel(title: "U.S.", modeIndicator: nil),
            near: focusedFrame,
            configuration: configuration,
            presentationID: AutoInputHUDPresentationID(),
            onActivate: activationHandler
        )
        let panel = try XCTUnwrap(controller.presentedPanelForTests)
        let hostingViewIdentity = try XCTUnwrap(controller.hostingViewIdentityForTests)

        XCTAssertTrue(controller.sendPointerHoverForTests(true))
        XCTAssertTrue(controller.sendPointerClickForTests())
        XCTAssertTrue(controller.sendPointerClickForTests())

        XCTAssertEqual(activationCount, 2)
        XCTAssertTrue(panel === controller.presentedPanelForTests)
        XCTAssertEqual(controller.hostingViewIdentityForTests, hostingViewIdentity)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertTrue(controller.sendPointerHoverForTests(false))
    }

    func testHUDAppearsAboveFocusedFieldNearBottomEdge() {
        let frame = InputSourceHUDController.panelFrame(
            focusedFrame: CGRect(x: 300, y: 20, width: 200, height: 24),
            panelSize: CGSize(width: 160, height: 52),
            visibleFrames: [CGRect(x: 0, y: 0, width: 1000, height: 800)]
        )

        XCTAssertEqual(frame, CGRect(x: 320, y: 52, width: 160, height: 52))
    }

    func testHUDUsesAndClampsToFocusedDisplay() {
        let frame = InputSourceHUDController.panelFrame(
            focusedFrame: CGRect(x: 1970, y: 400, width: 120, height: 24),
            panelSize: CGSize(width: 240, height: 52),
            visibleFrames: [
                CGRect(x: 0, y: 0, width: 1920, height: 1080),
                CGRect(x: 1920, y: 0, width: 1280, height: 1024),
            ],
            position: .below
        )

        XCTAssertEqual(frame, CGRect(x: 1930, y: 340, width: 240, height: 52))
    }

    func testAutomaticPlacementChoosesSideWithMoreAvailableSpace() {
        let frame = InputSourceHUDController.panelFrame(
            focusedFrame: CGRect(x: 300, y: 300, width: 200, height: 24),
            panelSize: CGSize(width: 160, height: 52),
            visibleFrames: [CGRect(x: 0, y: 0, width: 1000, height: 800)],
            position: .automatic
        )

        XCTAssertEqual(frame, CGRect(x: 320, y: 332, width: 160, height: 52))
    }

    func testScreenCenteredHUDUsesTheDisplayContainingTheFocusedField() {
        let frame = InputSourceHUDController.panelFrame(
            focusedFrame: CGRect(x: 2100, y: 400, width: 120, height: 24),
            panelSize: CGSize(width: 200, height: 60),
            visibleFrames: [
                CGRect(x: 0, y: 0, width: 1920, height: 1080),
                CGRect(x: 1920, y: 0, width: 1280, height: 1024),
            ],
            position: .screenCenter
        )

        XCTAssertEqual(frame, CGRect(x: 2460, y: 482, width: 200, height: 60))
    }

    func testHUDSizesScalePredictably() {
        let compact = InputSourceHUDController.panelSize(for: "ABC", size: .compact)
        let standard = InputSourceHUDController.panelSize(for: "ABC", size: .standard)
        let large = InputSourceHUDController.panelSize(for: "ABC", size: .large)

        XCTAssertLessThan(compact.width, standard.width)
        XCTAssertLessThan(standard.width, large.width)
        XCTAssertEqual([compact.height, standard.height, large.height], [44, 52, 64])
    }

    func testCompactHUDExpandsToFitLongInputSourceNames() {
        let name = "Chinese, Simplified – Pinyin"
        let panelSize = InputSourceHUDController.panelSize(for: name, size: .compact)
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let textWidth = ceil((name as NSString).size(withAttributes: [.font: font]).width)

        XCTAssertGreaterThan(panelSize.width, 240)
        XCTAssertGreaterThanOrEqual(panelSize.width, textWidth + 26 + 7 + 26)
    }

    func testHUDWidthIsClampedToTheFocusedDisplay() {
        XCTAssertEqual(
            InputSourceHUDController.panelSize(
                for: String(repeating: "Very Long Input Source ", count: 20),
                size: .compact,
                maximumWidth: 300
            ).width,
            300
        )
    }

    func testPreferredAboveFallsBackBelowWhenNeeded() {
        let frame = InputSourceHUDController.panelFrame(
            focusedFrame: CGRect(x: 300, y: 740, width: 200, height: 24),
            panelSize: CGSize(width: 160, height: 52),
            visibleFrames: [CGRect(x: 0, y: 0, width: 1000, height: 800)],
            position: .above
        )

        XCTAssertEqual(frame, CGRect(x: 320, y: 680, width: 160, height: 52))
    }
}

@MainActor
final class AutoInputPluginPanelTests: XCTestCase {
    func testSettingsSeparateBehaviorHUDRulesAndDeclareInputSourceShortcuts() throws {
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(
                pluginID: "auto-input",
                storage: AutoInputMemoryStorage()
            ),
            sourceController: FakeAutoInputSourceController(sources: [], currentSourceID: nil),
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        )

        let settingsPage = try XCTUnwrap(plugin.settingsPage)
        guard case let .form(sections) = settingsPage.body else {
            return XCTFail("expected form settings")
        }
        XCTAssertEqual(sections.map(\.id), ["behavior", "rules", "hud"])

        let configuration = plugin.actionShortcutSettingsConfiguration
        XCTAssertEqual(configuration.actionIDs, ["select-input-source"])
        XCTAssertEqual(configuration.placementAfterSectionID, "hud")
        XCTAssertFalse(configuration.title.isEmpty)
        XCTAssertFalse(configuration.description?.isEmpty ?? true)
    }

    func testCustomSettingsSectionsAreSearchableWithoutPublishingConfigurationCommands() {
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(
                pluginID: "auto-input",
                storage: AutoInputMemoryStorage()
            ),
            sourceController: FakeAutoInputSourceController(sources: [], currentSourceID: nil),
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        )

        XCTAssertEqual(
            plugin.settingsSearchEntries.map(\.id),
            [
                AutoInputSettingsSearchEntryID.behavior,
                AutoInputSettingsSearchEntryID.rules,
                AutoInputSettingsSearchEntryID.hud,
                AutoInputSettingsSearchEntryID.shortcuts,
            ]
        )
        XCTAssertEqual(
            plugin.settingsSearchEntries.map(\.systemImage),
            ["arrow.counterclockwise", "app.badge.checkmark", "text.cursor", "command"]
        )
        XCTAssertTrue(plugin.settingsSearchEntries.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(plugin.settingsSearchEntries.allSatisfy { !$0.description.isEmpty })
        XCTAssertEqual(
            plugin.actionDefinitions.map(\.key.actionID),
            ["toggle", "set-enabled", "select-input-source"]
        )
    }

    func testSettingsVisibilityRefreshesTheInputSourceCatalog() throws {
        let storage = AutoInputMemoryStorage()
        AutoInputStore(storage: storage).setAutoSwitchEnabled(false)
        let sources = FakeAutoInputSourceController(sources: [], currentSourceID: nil)
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(pluginID: "auto-input", storage: storage),
            sourceController: sources,
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        )
        let settingsPage = try XCTUnwrap(plugin.settingsPage)

        settingsPage.visibilityHandler?(false)
        XCTAssertEqual(sources.refreshCount, 0)

        settingsPage.visibilityHandler?(true)
        XCTAssertEqual(sources.refreshCount, 1)
    }

    func testPanelReflectsDefaultsRulesAndPause() {
        let storage = AutoInputMemoryStorage()
        let sourceController = FakeAutoInputSourceController(sources: [], currentSourceID: nil)
        let appMonitor = FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(pluginID: "auto-input", storage: storage),
            sourceController: sourceController,
            applicationMonitor: appMonitor
        )

        XCTAssertEqual(plugin.metadata.id, "auto-input")
        XCTAssertEqual(plugin.metadata.iconName, "keyboard")
        XCTAssertEqual(NSColor(plugin.metadata.iconTint), .systemBlue)
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "自动记忆已开启")

        AutoInputStore(storage: storage).upsertRule(makeRule(bundleID: "com.example.app", sourceID: "en"))
        let pluginWithRule = AutoInputPlugin(
            context: PluginRuntimeContext(pluginID: "auto-input", storage: storage),
            sourceController: sourceController,
            applicationMonitor: appMonitor
        )
        XCTAssertEqual(pluginWithRule.primaryPanelState.subtitle, "1 条固定规则")

        pluginWithRule.handleAction(.setSwitch(false))
        XCTAssertFalse(pluginWithRule.primaryPanelState.isOn)
        XCTAssertEqual(pluginWithRule.primaryPanelState.subtitle, "已暂停")
    }

    func testCanonicalActionCanPauseAutoInput() async throws {
        let storage = AutoInputMemoryStorage()
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(pluginID: "auto-input", storage: storage),
            sourceController: FakeAutoInputSourceController(sources: [], currentSourceID: nil),
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.last?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertFalse(plugin.primaryPanelState.isOn)
    }

    func testCanonicalMutationIsDeferredAndRejectedPersistenceReturnsFailure() async throws {
        let storage = AutoInputMemoryStorage()
        storage.blockedSetKeys = ["isAutoSwitchEnabled"]
        let sources = FakeAutoInputSourceController(sources: [], currentSourceID: nil)
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(pluginID: "auto-input", storage: storage),
            sourceController: sources,
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.last?.reference)

        let handle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        ))
        XCTAssertTrue(plugin.primaryPanelState.isOn)

        let result = await handle.result()

        guard case .failed = result else { return XCTFail("expected persistence failure") }
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
        XCTAssertTrue(sources.selectedIDs.isEmpty)
        XCTAssertTrue(AutoInputStore(storage: storage).isAutoSwitchEnabled)
    }

    func testAdaptiveActionReflectsAndTogglesCurrentState() async throws {
        let storage = AutoInputMemoryStorage()
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(pluginID: "auto-input", storage: storage),
            sourceController: FakeAutoInputSourceController(sources: [], currentSourceID: nil),
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        )

        XCTAssertEqual(
            plugin.actionDefinitions.map(\.key.actionID),
            ["toggle", "set-enabled", "select-input-source"]
        )
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .active)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .inactive)
    }

    func testAdaptiveToggleResolvesStateWhenDeferredHandleExecutes() async throws {
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(
                pluginID: "auto-input",
                storage: AutoInputMemoryStorage()
            ),
            sourceController: FakeAutoInputSourceController(sources: [], currentSourceID: nil),
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)
        let invocation = ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )
        let first = try plugin.beginAction(invocation)
        let second = try plugin.beginAction(invocation)

        let firstResult = await first.result()
        XCTAssertEqual(firstResult, .succeeded())
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        let secondResult = await second.result()
        XCTAssertEqual(secondResult, .succeeded())
        XCTAssertTrue(plugin.primaryPanelState.isOn)
    }

    func testInputSourcesPublishDistinctLocalOnlyCanonicalActions() throws {
        let sources = FakeAutoInputSourceController(
            sources: [
                AutoInputSource(id: "com.apple.keylayout.ABC", name: "ABC"),
                AutoInputSource(id: "com.apple.inputmethod.SCIM.ITABC", name: "拼音"),
            ],
            currentSourceID: "com.apple.keylayout.ABC"
        )
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(
                pluginID: "auto-input",
                storage: AutoInputMemoryStorage()
            ),
            sourceController: sources,
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        )

        let definition = try XCTUnwrap(
            plugin.actionDefinitions.first { $0.key.actionID == "select-input-source" }
        )
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
        XCTAssertEqual(definition.parameters.map(\.portability), [.localOnly])

        let entries = plugin.actionCatalogEntries.filter {
            $0.reference.key.actionID == "select-input-source"
        }
        XCTAssertEqual(entries.map(\.title), ["切换到 ABC", "切换到 拼音"])
        XCTAssertEqual(Set(entries.map(\.reference)).count, 2)
        XCTAssertEqual(entries.map(\.presentationState), [.active, .inactive])
    }

    func testCanonicalInputSourceSelectionWorksWhenAutomaticSwitchingAndHUDAreOff() async throws {
        let storage = AutoInputMemoryStorage()
        AutoInputStore(storage: storage).setAutoSwitchEnabled(false)
        let sources = FakeAutoInputSourceController(
            sources: [
                AutoInputSource(id: "en", name: "ABC"),
                AutoInputSource(id: "zh", name: "中文"),
            ],
            currentSourceID: "en"
        )
        let applications = FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(pluginID: "auto-input", storage: storage),
            sourceController: sources,
            applicationMonitor: applications
        )
        plugin.activate(context: PluginRuntimeContext(pluginID: "auto-input"))

        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first {
            $0.reference.parameters["inputSourceID"] == .string("zh")
        }?.reference)
        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(sources.selectedIDs, ["zh"])
        XCTAssertEqual(sources.startCount, 1)
        XCTAssertEqual(applications.startCount, 0)
        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["accessibility"])
        XCTAssertEqual(
            plugin.actionCatalogEntries.first { $0.reference == reference }?.presentationState,
            .active
        )
    }

    func testSelectingCurrentInputSourceSucceedsWithoutSelectingAgain() async throws {
        let sources = FakeAutoInputSourceController(
            sources: [AutoInputSource(id: "en", name: "ABC")],
            currentSourceID: "en"
        )
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(
                pluginID: "auto-input",
                storage: AutoInputMemoryStorage()
            ),
            sourceController: sources,
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first {
            $0.reference.key.actionID == "select-input-source"
        }?.reference)

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertTrue(sources.selectionAttemptIDs.isEmpty)
        XCTAssertEqual(sources.refreshCount, 0)
    }

    func testRemovedInputSourceMakesStoredActionUnavailableAndFailsClearly() async throws {
        let sources = FakeAutoInputSourceController(
            sources: [AutoInputSource(id: "en", name: "ABC")],
            currentSourceID: nil
        )
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(
                pluginID: "auto-input",
                storage: AutoInputMemoryStorage()
            ),
            sourceController: sources,
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        )
        plugin.activate(context: PluginRuntimeContext(pluginID: "auto-input"))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first {
            $0.reference.key.actionID == "select-input-source"
        }?.reference)

        sources.sources = []
        sources.emitChange()

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()
        guard case let .failed(message) = result else {
            return XCTFail("expected unavailable input source failure")
        }
        XCTAssertEqual(message, "输入法已停用或不可用。")
        XCTAssertTrue(sources.selectedIDs.isEmpty)
    }

    func testInputSourceSelectionFailureUsesSwitchFailureMessage() async throws {
        let sources = FakeAutoInputSourceController(
            sources: [AutoInputSource(id: "en", name: "ABC")],
            currentSourceID: nil
        )
        sources.selectionError = AutoInputSourceError.selectionFailed(-1)
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(
                pluginID: "auto-input",
                storage: AutoInputMemoryStorage()
            ),
            sourceController: sources,
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first {
            $0.reference.key.actionID == "select-input-source"
        }?.reference)

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        XCTAssertEqual(result, .failed(message: "无法切换输入法"))
        XCTAssertEqual(sources.selectionAttemptIDs, ["en"])
    }

    func testInputSourceChangesRefreshCanonicalActionCatalogAndActiveState() {
        let sources = FakeAutoInputSourceController(
            sources: [AutoInputSource(id: "en", name: "ABC")],
            currentSourceID: "en"
        )
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(
                pluginID: "auto-input",
                storage: AutoInputMemoryStorage()
            ),
            sourceController: sources,
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        )
        var stateChangeCount = 0
        plugin.onStateChange = { stateChangeCount += 1 }
        plugin.activate(context: PluginRuntimeContext(pluginID: "auto-input"))

        sources.sources.append(AutoInputSource(id: "zh", name: "中文"))
        sources.currentSourceID = "zh"
        sources.emitChange()

        let entries = plugin.actionCatalogEntries.filter {
            $0.reference.key.actionID == "select-input-source"
        }
        XCTAssertEqual(entries.map(\.title), ["切换到 ABC", "切换到 中文"])
        XCTAssertEqual(entries.map(\.presentationState), [.inactive, .active])
        XCTAssertEqual(stateChangeCount, 1)
    }

    func testAccessibilityPermissionRemainsVisibleWhenHUDIsOff() {
        let storage = AutoInputMemoryStorage()
        let accessibility = FakeAutoInputAccessibilityCheck(isTrusted: false)
        var plugin = AutoInputPlugin(
            context: PluginRuntimeContext(pluginID: "auto-input", storage: storage),
            sourceController: FakeAutoInputSourceController(sources: [], currentSourceID: nil),
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil),
            focusObserver: FakeAutoInputFocusObserver(),
            hudPresenter: FakeInputSourceHUDPresenter(),
            accessibilityCheck: accessibility
        )

        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["accessibility"])
        XCTAssertFalse(plugin.permissionState(for: "accessibility").isGranted)

        AutoInputStore(storage: storage).setInputHUDEnabled(true)
        plugin = AutoInputPlugin(
            context: PluginRuntimeContext(pluginID: "auto-input", storage: storage),
            sourceController: FakeAutoInputSourceController(sources: [], currentSourceID: nil),
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil),
            focusObserver: FakeAutoInputFocusObserver(),
            hudPresenter: FakeInputSourceHUDPresenter(),
            accessibilityCheck: accessibility
        )

        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["accessibility"])
        XCTAssertFalse(plugin.permissionState(for: "accessibility").isGranted)
    }
}

private func makeRule(bundleID: String, sourceID: String) -> AutoInputRule {
    AutoInputRule(
        bundleIdentifier: bundleID,
        displayName: bundleID,
        bundleURL: nil,
        inputSourceID: sourceID
    )
}

@MainActor
private struct AutoInputFixture {
    let store: AutoInputStore
    let sources: FakeAutoInputSourceController
    let applications: FakeAutoInputApplicationMonitor
    let focusObserver: FakeAutoInputFocusObserver
    let hud: FakeInputSourceHUDPresenter
    let accessibility: FakeAutoInputAccessibilityCheck
    let applicationNotificationCenter: NotificationCenter
    let controller: AutoInputController
    let app: AutoInputApplication
}

@MainActor
private final class FakeAutoInputSourceController: AutoInputSourceControlling {
    var onSourcesChanged: (() -> Void)?
    var sources: [AutoInputSource]
    var currentSourceID: String?
    var selectedIDs: [String] = []
    var selectionAttemptIDs: [String] = []
    var startCount = 0
    var stopCount = 0
    var refreshCount = 0
    var selectionError: Error?

    init(sources: [AutoInputSource], currentSourceID: String?) {
        self.sources = sources
        self.currentSourceID = currentSourceID
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func refresh() { refreshCount += 1 }

    func selectSource(id: String) throws {
        selectionAttemptIDs.append(id)
        if let selectionError { throw selectionError }
        selectedIDs.append(id)
        currentSourceID = id
    }

    func emitChange() {
        onSourcesChanged?()
    }
}

@MainActor
private final class FakeAutoInputApplicationMonitor: AutoInputApplicationMonitoring {
    var onApplicationActivated: ((AutoInputApplication) -> Void)?
    var frontmostApplication: AutoInputApplication?
    var stopCount = 0
    var startCount = 0

    init(frontmostApplication: AutoInputApplication?) {
        self.frontmostApplication = frontmostApplication
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }

    func activate(_ application: AutoInputApplication) {
        frontmostApplication = application
        onApplicationActivated?(application)
    }
}

@MainActor
private final class FakeAutoInputFocusObserver: AutoInputFocusObserving {
    var onEditableFocusChanged: ((AutoInputEditableFocus?) -> Void)?
    var onAccessibilityInvalidated: (() -> Void)?
    var startCount = 0
    var stopCount = 0
    var refreshCount = 0
    private(set) var currentFocus: AutoInputEditableFocus?

    func start() { startCount += 1 }

    func stop() {
        stopCount += 1
        currentFocus = nil
        onEditableFocusChanged?(nil)
    }

    func refreshFocusedElement() {
        refreshCount += 1
        onEditableFocusChanged?(currentFocus)
    }

    func focus(_ focus: AutoInputEditableFocus?) {
        currentFocus = focus
        onEditableFocusChanged?(focus)
    }

    func setCurrentFocusWithoutNotification(_ focus: AutoInputEditableFocus?) {
        currentFocus = focus
    }

    func invalidateAccessibility() {
        onAccessibilityInvalidated?()
    }
}

@MainActor
private final class FakeInputSourceHUDPresenter: InputSourceHUDPresenting {
    struct Presentation: Equatable {
        let sourceName: String
        let modeIndicator: String?
        let frame: CGRect
        let configuration: AutoInputHUDConfiguration
    }

    var presentations: [Presentation] = []
    var activationHandlers: [(() -> Void)?] = []
    var dismissCount = 0

    func show(
        label: InputSourceHUDLabel,
        near focusedFrame: CGRect,
        configuration: AutoInputHUDConfiguration,
        presentationID _: AutoInputHUDPresentationID,
        onActivate: (() -> Void)?
    ) {
        presentations.append(Presentation(
            sourceName: label.title,
            modeIndicator: label.modeIndicator,
            frame: focusedFrame,
            configuration: configuration
        ))
        activationHandlers.append(onActivate)
    }

    func activateLastPresentation() {
        activationHandlers.last.flatMap { $0 }?()
    }

    func dismiss() {
        dismissCount += 1
    }
}

private struct FakeInputSourceHUDLabelResolver: InputSourceHUDLabelResolving {
    let label: InputSourceHUDLabel

    func displayLabel(for _: AutoInputSource) -> InputSourceHUDLabel {
        label
    }
}

@MainActor
private final class FakeAutoInputAccessibilityCheck: AutoInputAccessibilityChecking {
    var isTrusted: Bool
    var requestResult: Bool
    var requestCount = 0

    init(isTrusted: Bool) {
        self.isTrusted = isTrusted
        self.requestResult = isTrusted
    }

    func requestTrust(prompt: Bool) -> Bool {
        if prompt { requestCount += 1 }
        isTrusted = requestResult
        return isTrusted
    }
}

@MainActor
private final class AutoInputMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]
    var blockedSetKeys: Set<String> = []

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) {
        guard !blockedSetKeys.contains(key) else { return }
        values[key] = value
    }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }

    func setRawValue(_ value: Any, forKey key: String) {
        values[key] = value
    }

    func rawValue(forKey key: String) -> Any? {
        values[key]
    }
}
