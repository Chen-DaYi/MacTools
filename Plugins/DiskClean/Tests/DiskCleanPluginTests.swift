import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DiskCleanPlugin

@MainActor
final class DiskCleanPluginTests: XCTestCase {
    func testMetadataIdentifiesDiskCleanPlugin() {
        let plugin = DiskCleanPlugin(controller: FakeDiskCleanPluginController())

        XCTAssertEqual(plugin.metadata.id, "disk-clean")
        XCTAssertEqual(plugin.metadata.title, "磁盘清理")
    }

    func testExpandedPanelExposesOnlyScanCleanAndOpenDetailsActions() throws {
        let plugin = DiskCleanPlugin(controller: FakeDiskCleanPluginController())

        plugin.handleAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(plugin.primaryPanelState.detail?.primaryControls)

        XCTAssertEqual(
            controls.map(\.id),
            [
                DiskCleanPlugin.ControlID.scan,
                DiskCleanPlugin.ControlID.clean,
                DiskCleanPlugin.ControlID.openDetails
            ]
        )
        XCTAssertEqual(controls.map(\.actionTitle), ["扫描", "移到废纸篓", "打开详情"])
        XCTAssertFalse(controls.contains { $0.id.hasPrefix("disk-clean-choice.") })
        XCTAssertFalse(controls.contains { $0.id == "disk-clean-test-mode" })
    }

    // MARK: - P2 分段接线（设计 §10）

    /// 扫描根一变就得把新范围推给开发产物分段。这条线断了，用户会拿着旧结果去清理
    /// 刚刚移除的文件夹——Controller 只有拿到新范围才会标记"请重新扫描"。
    func testAddingPurgeRootUpdatesDeveloperArtifactScope() {
        let purgeRoots = DiskCleanPurgeRootsModel(
            store: DiskCleanPurgeRootsStore(
                persistence: EphemeralPurgeRootsPersistence(),
                resolvePhysicalPath: { $0 }
            )
        )
        let developerArtifacts = DiskCleanController(
            engine: ControlledDiskCleanScanEngine(),
            initialSnapshot: DiskCleanControllerSnapshot(
                phase: .idle,
                scope: .developerArtifacts(roots: []),
                scanResult: nil,
                executionResult: nil,
                isResultStale: false,
                errorMessage: nil
            ),
            removalModeStore: InMemoryDiskCleanRemovalModeStore(mode: .trash)
        )
        _ = DiskCleanPlugin(
            controller: FakeDiskCleanPluginController(),
            developerArtifactsController: developerArtifacts,
            purgeRoots: purgeRoots
        )

        purgeRoots.add("/code")

        XCTAssertEqual(developerArtifacts.snapshot.scope, .developerArtifacts(roots: ["/code"]))
        XCTAssertTrue(developerArtifacts.snapshot.canScan)
    }

    /// 菜单栏只反映规则分段：P2 的候选流入不该把宿主菜单重建一遍。
    func testMenuBarPanelIgnoresSectionControllers() {
        let controller = FakeDiskCleanPluginController()
        let installers = DiskCleanController(
            engine: ControlledDiskCleanScanEngine(),
            removalModeStore: InMemoryDiskCleanRemovalModeStore(mode: .trash)
        )
        let plugin = DiskCleanPlugin(controller: controller, installersController: installers)
        var stateChanges = 0
        plugin.onStateChange = { stateChanges += 1 }

        installers.setScope(.installers)

        XCTAssertEqual(stateChanges, 0)
    }

    func testInvokingScanForwardsToController() {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)

        plugin.handleAction(.invokeAction(controlID: DiskCleanPlugin.ControlID.scan))

        XCTAssertEqual(controller.scanCallCount, 1)
    }

    /// 面板不再自己算"要清理什么"：它只把命令转给 Controller，选中集是 Controller 的权威状态。
    func testInvokingCleanForwardsToControllerWithoutComposingItsOwnSelection() {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        controller.snapshot = makeScannedSnapshot(
            candidates: [
                makePluginTestCandidate(
                    id: "allowed",
                    path: "/Users/tester/Library/Caches/App",
                    sizeResult: .testComplete(bytes: 10)
                )
            ],
            selection: makeSelection(selected: ["allowed"], bytes: 10)
        )

        plugin.handleAction(.invokeAction(controlID: DiskCleanPlugin.ControlID.clean))

        XCTAssertEqual(controller.cleanCallCount, 1)
    }

    /// 按钮文案要说清"会删几项、大约多少"，并按删除方式直说会发生什么（设计 §8.2、§8.4）。
    func testCleanActionTitleReportsSelectionAndRemovalMode() throws {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        let candidates = [
            makePluginTestCandidate(
                id: "a",
                path: "/Users/tester/Library/Caches/App",
                sizeResult: .testComplete(bytes: 5_368_709_120)
            )
        ]

        controller.snapshot = makeScannedSnapshot(
            candidates: candidates,
            selection: makeSelection(selected: ["a"], bytes: 5_368_709_120)
        )
        plugin.handleAction(.setDisclosureExpanded(true))
        let trashTitle = try XCTUnwrap(try cleanControl(of: plugin).actionTitle)
        XCTAssertTrue(trashTitle.hasPrefix("移到废纸篓 · 1 项 · 约"), "实际：\(trashTitle)")
        XCTAssertTrue(trashTitle.contains("GB"), "实际：\(trashTitle)")

        controller.snapshot = makeScannedSnapshot(
            candidates: candidates,
            removalMode: .permanent,
            selection: makeSelection(selected: ["a"], bytes: 5_368_709_120)
        )
        let permanentTitle = try XCTUnwrap(try cleanControl(of: plugin).actionTitle)
        XCTAssertTrue(permanentTitle.hasPrefix("清理 · 1 项 · 约"), "实际：\(permanentTitle)")
    }

    func testCleanIsDisabledWhenNothingIsSelected() throws {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        controller.snapshot = makeScannedSnapshot(
            candidates: [
                makePluginTestCandidate(
                    id: "a",
                    path: "/Users/tester/Library/Caches/App",
                    sizeResult: .testComplete(bytes: 10)
                )
            ],
            selection: makeSelection(selected: [], selectable: ["a"], bytes: 0)
        )

        plugin.handleAction(.setDisclosureExpanded(true))

        XCTAssertEqual(try cleanControl(of: plugin).isEnabled, false)
        XCTAssertEqual(try cleanControl(of: plugin).actionTitle, "移到废纸篓")
    }

    /// "打开详情"必须真的把设置窗口切过去；M4 之前它是个空操作。
    func testOpenDetailsRequestsConfigurationPresentation() {
        let plugin = DiskCleanPlugin(controller: FakeDiskCleanPluginController())
        var presentationRequests = 0
        plugin.requestConfigurationPresentation = { presentationRequests += 1 }

        plugin.handleAction(.invokeAction(controlID: DiskCleanPlugin.ControlID.openDetails))

        XCTAssertEqual(presentationRequests, 1)
    }

    /// "（受限）"后缀一律由 limitations 派生，不依赖恰好扫出了某种被保护候选（设计 §4.5、§8.2）。
    func testPanelSubtitleAppendsLimitedSuffixWhenScanReportsLimitations() {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        let candidates = [
            makePluginTestCandidate(
                id: "allowed",
                path: "/Users/tester/Library/Caches/App",
                sizeResult: .testComplete(bytes: 1_024)
            )
        ]

        controller.snapshot = makeScannedSnapshot(candidates: candidates)
        let plain = plugin.primaryPanelState.subtitle

        controller.snapshot = makeScannedSnapshot(
            candidates: candidates,
            limitations: [.fdaRestricted(skippedTargetIDs: ["cache.system"])]
        )
        let limited = plugin.primaryPanelState.subtitle

        XCTAssertFalse(plain.hasSuffix("（受限）"))
        XCTAssertEqual(limited, plain + "（受限）")
    }

    func testPanelDisablesCleanWhenResultExpired() {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        controller.snapshot = makeScannedSnapshot(
            candidates: [
                makePluginTestCandidate(
                    id: "allowed",
                    path: "/Users/tester/Library/Caches/App",
                    sizeResult: .testComplete(bytes: 10)
                )
            ],
            isResultExpired: true
        )

        plugin.handleAction(.setDisclosureExpanded(true))
        let controls = plugin.primaryPanelState.detail?.primaryControls ?? []

        XCTAssertEqual(controls.first { $0.id == DiskCleanPlugin.ControlID.clean }?.isEnabled, false)
    }

    /// 永久删除的确认期：面板换成"确认 / 取消"一对，"清理"必须消失——
    /// 同一个按钮不该在两种语义之间摇摆。
    func testConfirmingPhaseReplacesCleanActionWithConfirmAndCancel() throws {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        controller.snapshot = makeConfirmingSnapshot(itemCount: 3, totalEstimatedBytes: 5_368_709_120)

        plugin.handleAction(.setDisclosureExpanded(true))
        let controls = try XCTUnwrap(plugin.primaryPanelState.detail?.primaryControls)

        XCTAssertEqual(
            controls.map(\.id),
            [
                DiskCleanPlugin.ControlID.scan,
                DiskCleanPlugin.ControlID.confirmClean,
                DiskCleanPlugin.ControlID.cancelClean,
                DiskCleanPlugin.ControlID.openDetails
            ]
        )
        let confirm = try XCTUnwrap(controls.first { $0.id == DiskCleanPlugin.ControlID.confirmClean })
        let confirmTitle = try XCTUnwrap(confirm.actionTitle)
        XCTAssertTrue(confirmTitle.hasPrefix("确认永久清理 3 项 · 约"), "实际：\(confirmTitle)")
        XCTAssertTrue(confirmTitle.contains("GB"), "冻结的字节数要出现在确认文案里")
    }

    func testConfirmAndCancelActionsForwardToController() {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        controller.snapshot = makeConfirmingSnapshot(itemCount: 1, totalEstimatedBytes: 1_024)

        plugin.handleAction(.invokeAction(controlID: DiskCleanPlugin.ControlID.confirmClean))
        plugin.handleAction(.invokeAction(controlID: DiskCleanPlugin.ControlID.cancelClean))

        XCTAssertEqual(controller.confirmCallCount, 1)
        XCTAssertEqual(controller.cancelPendingCallCount, 1)
    }

    /// 废纸篓完成文案不得写"已释放"：对象还在废纸篓里，空间尚未回收（设计 §7.7）。
    func testTrashCompletionSubtitleDoesNotClaimSpaceWasReclaimed() {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        controller.snapshot = DiskCleanControllerSnapshot(
            phase: .completed,
            scope: .rules(choices: Set(DiskCleanChoice.allCases)),
            scanResult: nil,
            executionResult: DiskCleanExecutionResult(
                itemResults: [
                    DiskCleanExecutionItemResult(
                        candidateID: "a",
                        path: "/cache/a",
                        outcome: .trashed(reclaimedBytes: 1_024, stagedName: ".mactools-staged-a")
                    )
                ],
                mode: .trash
            ),
            isResultStale: false,
            errorMessage: nil
        )

        let subtitle = plugin.primaryPanelState.subtitle
        XCTAssertTrue(subtitle.hasPrefix("已移到废纸篓约"), "实际：\(subtitle)")
        XCTAssertFalse(subtitle.contains("已释放"), "废纸篓里的对象尚未真正释放空间")
        XCTAssertTrue(subtitle.contains("KB"), "实际：\(subtitle)")
    }

    /// 启动 reconciliation 必须在 activate 时触发，否则孤儿暂存对象没有第二条被发现的路径。
    func testActivateTriggersStagingReconciliation() async {
        let reconciler = SpyDiskCleanStagingReconciler()
        let storage = URL(fileURLWithPath: "/tmp/diskclean-plugin-activate-test")
        let plugin = DiskCleanPlugin(
            controller: FakeDiskCleanPluginController(),
            storageDirectory: storage,
            reconciler: reconciler
        )

        plugin.activate(context: PluginRuntimeContext(pluginID: "disk-clean"))

        await waitUntil("reconciliation 已触发") { !reconciler.reconciledDirectories.isEmpty }
        XCTAssertEqual(reconciler.reconciledDirectories, [storage])
    }

    private func makeConfirmingSnapshot(
        itemCount: Int,
        totalEstimatedBytes: Int64
    ) -> DiskCleanControllerSnapshot {
        DiskCleanControllerSnapshot(
            phase: .confirming,
            scope: .rules(choices: Set(DiskCleanChoice.allCases)),
            scanResult: nil,
            executionResult: nil,
            isResultStale: false,
            errorMessage: nil,
            removalMode: .permanent,
            pendingPlan: DiskCleanPendingPlanSummary(
                itemCount: itemCount,
                totalEstimatedBytes: totalEstimatedBytes,
                mode: .permanent
            )
        )
    }

    private func cleanControl(of plugin: DiskCleanPlugin) throws -> PluginPanelControl {
        let controls = plugin.primaryPanelState.detail?.primaryControls ?? []
        return try XCTUnwrap(controls.first { $0.id == DiskCleanPlugin.ControlID.clean })
    }

    /// 默认让全部可清理候选处于选中态，这样"清理"按钮的可用性由被测条件决定，而不是被空选中集掩盖。
    private func makeScannedSnapshot(
        candidates: [DiskCleanCandidate],
        limitations: [DiskCleanScanLimitation] = [],
        isResultExpired: Bool = false,
        removalMode: DiskCleanRemovalMode = .trash,
        selection: DiskCleanSelectionProjection? = nil
    ) -> DiskCleanControllerSnapshot {
        let cleanable = candidates.filter(\.isCleanable)
        let resolvedSelection = selection ?? makeSelection(
            selected: Set(cleanable.map(\.id)),
            bytes: cleanable.reduce(0) { $0 + $1.estimatedBytes }
        )
        return DiskCleanControllerSnapshot(
            phase: .scanned,
            scope: .rules(choices: Set(DiskCleanChoice.allCases)),
            scanResult: DiskCleanScanResult(
                scope: .rules(choices: Set(DiskCleanChoice.allCases)),
                candidates: candidates,
                scannedAt: Date(timeIntervalSince1970: 0),
                limitations: limitations
            ),
            executionResult: nil,
            isResultStale: false,
            isResultExpired: isResultExpired,
            errorMessage: nil,
            removalMode: removalMode,
            selection: resolvedSelection
        )
    }

    private func makeSelection(
        selected: Set<DiskCleanCandidate.ID>,
        selectable: Set<DiskCleanCandidate.ID>? = nil,
        bytes: Int64
    ) -> DiskCleanSelectionProjection {
        DiskCleanSelectionProjection(
            selectedIDs: selected,
            selectableIDs: selectable ?? selected,
            selectedEstimatedBytes: bytes,
            categoryStates: [.appCaches: selected.isEmpty ? .noneSelected : .allSelected]
        )
    }

    private func makePluginTestCandidate(
        id: String,
        path: String,
        safety: DiskCleanSafetyStatus = .allowed,
        sizeResult: DiskCleanSizeResult?
    ) -> DiskCleanCandidate {
        DiskCleanCandidate(
            id: id,
            targetID: "cache.rule",
            legacyRuleID: "cache.rule",
            category: .appCaches,
            path: path,
            risk: .low,
            safety: safety,
            sizeResult: sizeResult
        )
    }

    func testOpenDetailsActionUsesMenuBarStableActionID() throws {
        let plugin = DiskCleanPlugin(controller: FakeDiskCleanPluginController())

        plugin.handleAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(plugin.primaryPanelState.detail?.primaryControls)
        let openDetails = try XCTUnwrap(
            controls.first { $0.id == DiskCleanPlugin.ControlID.openDetails }
        )

        XCTAssertEqual(DiskCleanPlugin.ControlID.openDetails, MenuBarContent.diskCleanOpenDetailsActionID)
        switch openDetails.actionBehavior {
        case .dismissBeforeHandling:
            break
        case .keepPresented:
            XCTFail("Open details action should dismiss the menu before opening the window")
        }
    }

    func testPluginHostIncludesDiskCleanWhenProvided() {
        let host = makePluginHostForTests(plugins: [DiskCleanPlugin(controller: FakeDiskCleanPluginController())])

        XCTAssertTrue(host.featureManagementItems.contains { $0.id == "disk-clean" })
    }

    func testPluginHostExposesDiskCleanConfigurationWhenProvided() {
        let host = makePluginHostForTests(plugins: [DiskCleanPlugin(controller: DiskCleanController())])

        XCTAssertTrue(host.pluginConfigurationItems.contains { $0.id == "disk-clean" })
    }

    func testPresentPluginConfigurationRequestsDiskCleanSettings() {
        let host = makePluginHostForTests(plugins: [DiskCleanPlugin(controller: DiskCleanController())])
        var requests: [AppPresentationRequest] = []
        host.appPresentationHandler = { requests.append($0) }

        host.presentPluginConfiguration(pluginID: "disk-clean")

        XCTAssertEqual(requests, [.settings(.pluginConfiguration("disk-clean"))])
    }
}

@MainActor
private final class FakeDiskCleanPluginController: DiskCleanControlling {
    var onStateChange: (() -> Void)?
    var snapshot = DiskCleanControllerSnapshot.initial
    private(set) var scanCallCount = 0
    private(set) var canceledOperationCount = 0
    private(set) var selectedChoiceChanges: [(choice: DiskCleanChoice, isSelected: Bool)] = []
    private(set) var cleanCallCount = 0
    private(set) var confirmCallCount = 0
    private(set) var cancelPendingCallCount = 0
    private(set) var removalModeChanges: [DiskCleanRemovalMode] = []
    private(set) var candidateSelectionChanges: [(id: DiskCleanCandidate.ID, isSelected: Bool)] = []
    private(set) var categorySelectionChanges: [(category: DiskCleanCategoryID, isSelected: Bool)] = []

    private(set) var scopeChanges: [DiskCleanScanScope] = []

    func setScope(_ scope: DiskCleanScanScope) {
        scopeChanges.append(scope)
        snapshot = DiskCleanControllerSnapshot(
            phase: snapshot.phase,
            scope: scope,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: snapshot.isResultStale,
            isResultExpired: snapshot.isResultExpired,
            errorMessage: snapshot.errorMessage
        )
        onStateChange?()
    }

    func setChoice(_ choice: DiskCleanChoice, isSelected: Bool) {
        selectedChoiceChanges.append((choice: choice, isSelected: isSelected))
        var nextChoices = snapshot.selectedChoices
        if isSelected {
            nextChoices.insert(choice)
        } else {
            nextChoices.remove(choice)
        }
        setScope(.rules(choices: nextChoices))
    }

    func scan() {
        scanCallCount += 1
        onStateChange?()
    }

    func clean() {
        cleanCallCount += 1
        onStateChange?()
    }

    func setCandidateSelected(_ candidateID: DiskCleanCandidate.ID, isSelected: Bool) {
        candidateSelectionChanges.append((id: candidateID, isSelected: isSelected))
        onStateChange?()
    }

    func setCategorySelection(_ category: DiskCleanCategoryID, isSelected: Bool) {
        categorySelectionChanges.append((category: category, isSelected: isSelected))
        onStateChange?()
    }

    func confirmPendingClean() {
        confirmCallCount += 1
        onStateChange?()
    }

    func cancelPendingClean() {
        cancelPendingCallCount += 1
        onStateChange?()
    }

    func setRemovalMode(_ mode: DiskCleanRemovalMode) {
        removalModeChanges.append(mode)
        onStateChange?()
    }

    func cancelCurrentOperation() {
        canceledOperationCount += 1
        onStateChange?()
    }
}
