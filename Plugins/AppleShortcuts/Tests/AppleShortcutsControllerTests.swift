import MacToolsPluginKit
import XCTest
@testable import AppleShortcutsPlugin

@MainActor
final class AppleShortcutsControllerTests: XCTestCase {
    func testRefreshMergesMembershipAndReportsPartialFailure() async throws {
        let firstFolder = AppleShortcutFolder(id: UUID(), name: "First")
        let failedFolder = AppleShortcutFolder(id: UUID(), name: "Failed")
        let item = AppleShortcutItem(id: UUID(), name: "Morning")
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [item],
            folders: [firstFolder, failedFolder],
            memberships: [
                firstFolder.id: .success([item]),
                failedFolder.id: .failure(.failed),
            ]
        )
        let controller = makeController(runner: runner)

        await controller.performRefresh()

        XCTAssertEqual(controller.snapshot.discovery.shortcuts.first?.folderIDs, [firstFolder.id])
        XCTAssertEqual(controller.snapshot.discovery.failedFolderIDs, [failedFolder.id])
        XCTAssertNotNil(controller.snapshot.errorMessage)
        XCTAssertNotNil(controller.snapshot.lastSuccessfulRefresh)
    }

    func testFailedFolderMembershipPreservesSyncedMembers() async throws {
        let folder = AppleShortcutFolder(id: UUID(), name: "Synced")
        let item = AppleShortcutItem(id: UUID(), name: "Keep", folderIDs: [folder.id])
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())
        try store.setFolderSynced(true, folder: folder, members: [item]).get()
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [item],
            folders: [folder],
            memberships: [folder.id: .failure(.failed)]
        )
        let controller = makeController(store: store, runner: runner)

        await controller.performRefresh()

        XCTAssertTrue(store.isEnabled(item.id))
        XCTAssertEqual(store.state.syncedFolders[folder.id]?.memberIDs, [item.id])
        XCTAssertEqual(controller.snapshot.discovery.folderMemberships[folder.id], [item.id])
        XCTAssertEqual(controller.snapshot.discovery.shortcuts.first?.folderIDs, [folder.id])
    }

    func testFailedUnsyncedFolderMembershipPreservesPreviousDiscovery() async {
        let folder = AppleShortcutFolder(id: UUID(), name: "Ordinary")
        let item = AppleShortcutItem(id: UUID(), name: "Keep", folderIDs: [folder.id])
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [item],
            folders: [folder],
            memberships: [folder.id: .success([item])]
        )
        let controller = makeController(runner: runner)
        await controller.performRefresh()
        await runner.setMemberships([folder.id: .failure(.failed)])

        await controller.performRefresh()

        XCTAssertFalse(controller.store.isFolderSynced(folder.id))
        XCTAssertEqual(controller.snapshot.discovery.folderMemberships[folder.id], [item.id])
        XCTAssertEqual(controller.snapshot.discovery.shortcuts.first?.folderIDs, [folder.id])
        XCTAssertEqual(controller.snapshot.discovery.failedFolderIDs, [folder.id])
        XCTAssertNotNil(controller.snapshot.errorMessage)
    }

    func testConcurrentRefreshRequestsCoalesce() async throws {
        let runner = AppleShortcutsRunnerStub(delay: .milliseconds(100))
        let controller = makeController(runner: runner)

        controller.refresh(force: true)
        controller.refresh(force: true)
        try await Task.sleep(for: .milliseconds(350))

        let callCount = await runner.observedListCallCount()
        XCTAssertEqual(callCount, 1)
    }

    func testRefreshIfNeededRespectsFreshnessWindowBoundary() async throws {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let runner = AppleShortcutsRunnerStub()
        let controller = makeController(runner: runner, now: { currentDate })
        await controller.performRefresh()

        currentDate.addTimeInterval(AppleShortcutsController.freshnessInterval - 1)
        controller.refreshIfNeeded()
        for _ in 0 ..< 20 { await Task.yield() }
        var callCount = await runner.observedListCallCount()
        XCTAssertEqual(callCount, 1)

        currentDate.addTimeInterval(1)
        controller.refreshIfNeeded()
        for _ in 0 ..< 100 {
            if await runner.observedListCallCount() == 2 { break }
            await Task.yield()
        }
        callCount = await runner.observedListCallCount()
        XCTAssertEqual(callCount, 2)
    }

    func testSyncedFoldersRefreshPeriodicallyOnlyWhileActive() async throws {
        let folder = AppleShortcutFolder(id: UUID(), name: "Synced")
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())
        try store.setFolderSynced(true, folder: folder, members: []).get()
        let runner = AppleShortcutsRunnerStub(folders: [folder])
        let controller = makeController(
            store: store,
            runner: runner,
            automaticRefreshInterval: .milliseconds(20)
        )

        controller.activate()
        for _ in 0 ..< 100 {
            if await runner.observedListCallCount() >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let periodicCallCount = await runner.observedListCallCount()
        XCTAssertGreaterThanOrEqual(periodicCallCount, 2)

        controller.deactivate()
        let callCountAfterDeactivation = await runner.observedListCallCount()
        try await Task.sleep(for: .milliseconds(60))
        let finalCallCount = await runner.observedListCallCount()
        XCTAssertEqual(finalCallCount, callCountAfterDeactivation)
    }

    func testMembershipQueriesRespectConcurrencyLimit() async throws {
        let folders = (0 ..< 9).map {
            AppleShortcutFolder(id: UUID(), name: "Folder \($0)")
        }
        let runner = AppleShortcutsRunnerStub(
            folders: folders,
            membershipDelay: .milliseconds(40)
        )
        let controller = makeController(runner: runner)

        await controller.performRefresh()

        let observedMaximum = await runner.observedMaximumConcurrentMembershipCallCount()
        XCTAssertEqual(
            observedMaximum,
            AppleShortcutsController.maximumConcurrentMembershipQueries
        )
        XCTAssertEqual(controller.snapshot.discovery.folderMemberships.count, folders.count)
    }

    func testCancellingRefreshDoesNotStartQueuedMembershipQueries() async throws {
        let folders = (0 ..< 12).map {
            AppleShortcutFolder(id: UUID(), name: "Folder \($0)")
        }
        let runner = AppleShortcutsRunnerStub(
            folders: folders,
            membershipDelay: .seconds(5)
        )
        let controller = makeController(runner: runner)
        controller.refresh(force: true)
        for _ in 0 ..< 200 {
            let callCount = (await runner.observedMembershipCallIDs()).count
            if callCount == AppleShortcutsController.maximumConcurrentMembershipQueries { break }
            await Task.yield()
        }

        controller.deactivate()
        try await Task.sleep(for: .milliseconds(100))

        let callIDs = await runner.observedMembershipCallIDs()
        XCTAssertEqual(
            callIDs.count,
            AppleShortcutsController.maximumConcurrentMembershipQueries
        )
    }

    func testAppliedRefreshNotifiesHostExactlyOnce() async throws {
        let folder = AppleShortcutFolder(id: UUID(), name: "Observed")
        let item = AppleShortcutItem(id: UUID(), name: "Item")
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [item],
            folders: [folder],
            memberships: [folder.id: .success([item])]
        )
        let controller = makeController(runner: runner)
        var notificationCount = 0
        controller.onStateChange = { notificationCount += 1 }

        await controller.performRefresh()

        XCTAssertEqual(notificationCount, 1)
    }

    func testTotalRefreshFailurePreservesLastSuccessfulSnapshot() async throws {
        let item = AppleShortcutItem(id: UUID(), name: "Preserved")
        let runner = AppleShortcutsRunnerStub(shortcuts: [item])
        let controller = makeController(runner: runner)
        await controller.performRefresh()
        await runner.setListFails(true)

        await controller.performRefresh()

        XCTAssertEqual(controller.snapshot.discovery.shortcuts, [item])
        XCTAssertNotNil(controller.snapshot.errorMessage)
    }

    func testRunLimitAndDuplicatePrevention() async throws {
        let runner = AppleShortcutsRunnerStub(delay: .seconds(5))
        let controller = makeController(runner: runner)
        let ids = (0 ..< 5).map { _ in UUID() }
        let runs = try ids.prefix(4).map {
            try controller.startExecution(shortcutID: $0, name: "Run").get()
        }

        XCTAssertEqual(runs.count, 4)
        XCTAssertThrowsError(
            try controller.startExecution(shortcutID: ids[0], name: "Duplicate").get()
        ) { error in
            XCTAssertEqual(error as? AppleShortcutsExecutionStartError, .alreadyRunning)
        }
        let fifthResult = controller.startExecution(shortcutID: ids[4], name: "Fifth")
        XCTAssertThrowsError(try fifthResult.get()) { error in
            guard let startError = error as? AppleShortcutsExecutionStartError else {
                return XCTFail("Expected a typed execution admission error")
            }
            XCTAssertEqual(startError, .concurrencyLimit)
            controller.presentExecutionStartError(startError)
        }
        XCTAssertEqual(controller.snapshot.errorMessage, "同时最多运行 4 个快捷指令。")

        controller.deactivate()
        for (index, run) in runs.enumerated() {
            let result = await controller.waitForExecution(run, shortcutID: ids[index])
            XCTAssertEqual(result, .cancelled)
        }
    }

    func testCancelledTaskCannotRegisterExecution() async {
        let shortcutID = UUID()
        let runner = AppleShortcutsRunnerStub()
        let controller = makeController(runner: runner)
        let registrationTask = Task { @MainActor in
            controller.startExecution(shortcutID: shortcutID, name: "Cancelled")
        }
        registrationTask.cancel()

        let registrationResult = await registrationTask.value
        let runIDs = await runner.observedRunIDs()

        XCTAssertThrowsError(try registrationResult.get()) { error in
            XCTAssertEqual(error as? AppleShortcutsExecutionStartError, .cancelled)
        }
        XCTAssertFalse(controller.isRunning(shortcutID))
        XCTAssertTrue(runIDs.isEmpty)
    }

    func testDeactivationPreventsLateRefreshFromOverwritingReactivatedState() async throws {
        let old = AppleShortcutItem(id: UUID(), name: "Old")
        let new = AppleShortcutItem(id: UUID(), name: "New")
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [old],
            delay: .milliseconds(120),
            ignoresCancellation: true
        )
        let controller = makeController(runner: runner)
        controller.refresh(force: true)
        try await Task.sleep(for: .milliseconds(20))

        controller.deactivate()
        await runner.setShortcuts([new])
        controller.activate()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(controller.snapshot.discovery.shortcuts, [new])
    }

    func testDeactivationClearsRefreshingStateWhenFreshSnapshotSkipsReactivationRefresh() async throws {
        let item = AppleShortcutItem(id: UUID(), name: "Fresh")
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [item],
            delay: .milliseconds(120),
            ignoresCancellation: true
        )
        let controller = makeController(runner: runner)
        await controller.performRefresh()
        controller.refresh(force: true)
        for _ in 0 ..< 100 where !controller.snapshot.isRefreshing {
            await Task.yield()
        }
        XCTAssertTrue(controller.snapshot.isRefreshing)

        controller.deactivate()
        controller.activate()

        XCTAssertFalse(controller.snapshot.isRefreshing)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(controller.snapshot.isRefreshing)
        XCTAssertEqual(controller.snapshot.discovery.shortcuts, [item])
    }

    func testDeactivationClearsExecutionAndRejectsLateRunCompletion() async throws {
        let shortcutID = UUID()
        let runner = AppleShortcutsRunnerStub(
            delay: .milliseconds(100),
            ignoresCancellation: true
        )
        let controller = makeController(runner: runner)
        let run = try controller.startExecution(shortcutID: shortcutID, name: "Late").get()
        for _ in 0 ..< 100 {
            if !(await runner.observedRunIDs()).isEmpty { break }
            await Task.yield()
        }
        XCTAssertNotNil(controller.executionStore.record(for: shortcutID))

        controller.deactivate()
        controller.activate()
        let result = await controller.waitForExecution(run, shortcutID: shortcutID)

        XCTAssertEqual(result, .cancelled)
        XCTAssertNil(controller.executionStore.record(for: shortcutID))
        XCTAssertNil(controller.snapshot.errorMessage)
        XCTAssertNil(controller.snapshot.operationMessage)
    }

    func testDeactivationCancelsViewAndRejectsLatePresentation() async throws {
        let shortcutID = UUID()
        let item = AppleShortcutItem(id: shortcutID, name: "Late View")
        let runner = AppleShortcutsRunnerStub(
            shortcuts: [item],
            delay: .milliseconds(100),
            ignoresCancellation: true
        )
        let controller = makeController(runner: runner)
        await controller.performRefresh()
        controller.presentStoreError(.invalidData)
        controller.openInShortcuts(shortcutID)
        for _ in 0 ..< 100 {
            if !(await runner.observedViewNames()).isEmpty { break }
            await Task.yield()
        }

        controller.deactivate()
        XCTAssertNil(controller.snapshot.errorMessage)
        XCTAssertNil(controller.snapshot.operationMessage)
        controller.activate()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertNil(controller.snapshot.errorMessage)
        XCTAssertNil(controller.snapshot.operationMessage)
        let viewNames = await runner.observedViewNames()
        XCTAssertEqual(viewNames, [item.name])
    }

    func testOpenUsesUniqueCurrentNameAndRejectsDuplicateNames() async throws {
        let first = AppleShortcutItem(id: UUID(), name: "Duplicate")
        let second = AppleShortcutItem(id: UUID(), name: "duplicate")
        let runner = AppleShortcutsRunnerStub(shortcuts: [first, second])
        let controller = makeController(runner: runner)
        await controller.performRefresh()

        controller.openInShortcuts(first.id)
        for _ in 0 ..< 20 { await Task.yield() }
        var viewNames = await runner.observedViewNames()
        XCTAssertTrue(viewNames.isEmpty)
        XCTAssertNotNil(controller.snapshot.errorMessage)

        await runner.setShortcuts([first])
        await controller.performRefresh()
        controller.openInShortcuts(first.id)
        for _ in 0 ..< 100 {
            if !(await runner.observedViewNames()).isEmpty { break }
            await Task.yield()
        }

        viewNames = await runner.observedViewNames()
        XCTAssertEqual(viewNames, [first.name])
        XCTAssertNil(controller.snapshot.errorMessage)
    }

    private func makeController(
        store: AppleShortcutsStore? = nil,
        runner: AppleShortcutsRunnerStub,
        now: @escaping () -> Date = { .now },
        automaticRefreshInterval: Duration = .seconds(60)
    ) -> AppleShortcutsController {
        AppleShortcutsController(
            store: store ?? AppleShortcutsStore(storage: AppleShortcutsTestStorage()),
            runner: runner,
            localization: PluginLocalization(bundle: .main),
            now: now,
            automaticRefreshInterval: automaticRefreshInterval
        )
    }
}
