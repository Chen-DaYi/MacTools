import XCTest
@testable import MacTools
@testable import EmptyTrashPlugin

@MainActor
final class EmptyTrashPluginTests: XCTestCase {
    func testMetadataIdentifiesEmptyTrashPlugin() {
        let plugin = EmptyTrashPlugin()

        XCTAssertEqual(plugin.metadata.id, "empty-trash")
        XCTAssertEqual(plugin.metadata.title, "清空废纸篓")
    }

    func testControlStyleIsButton() {
        let plugin = EmptyTrashPlugin()

        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .button)
        XCTAssertEqual(plugin.primaryPanelDescriptor.buttonTitle, "清空")
    }

    func testInitialStateIsOffAndDisabled() {
        let plugin = EmptyTrashPlugin()

        let state = plugin.primaryPanelState
        XCTAssertFalse(state.isOn)
        XCTAssertFalse(state.isEnabled)
    }

    func testInitialSubtitleShowsEmpty() {
        let plugin = EmptyTrashPlugin()

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "废纸篓为空")
    }

    func testPermissionRequirementsIsEmpty() {
        let plugin = EmptyTrashPlugin()

        XCTAssertTrue(plugin.permissionRequirements.isEmpty)
    }

    func testPluginHostIncludesEmptyTrashWhenProvided() {
        let host = makePluginHostForTests(plugins: [EmptyTrashPlugin()])

        XCTAssertTrue(host.featureManagementItems.contains { $0.id == "empty-trash" })
    }

    func testPluginDescriptionMatches() {
        let plugin = EmptyTrashPlugin()

        XCTAssertEqual(plugin.metadata.defaultDescription, "清空废纸篓中的所有项目")
    }

    func testMenuActionBehaviorIsKeepPresented() {
        let plugin = EmptyTrashPlugin()

        XCTAssertEqual(plugin.primaryPanelDescriptor.menuActionBehavior, .keepPresented)
    }

    func testRefreshDoesNotCountItemsWhilePrimaryPanelIsHidden() async {
        let counter = TrashCountProbe(itemCount: 3)
        let plugin = EmptyTrashPlugin(
            countItems: { await counter.countItems() },
            countRefreshDelay: .zero
        )

        plugin.refresh()
        await Task.yield()

        let requestCount = await counter.requestCountValue()
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(plugin.primaryPanelState.isEnabled)
    }

    func testPrimaryPanelVisibilityRefreshesTrashCount() async {
        let counter = TrashCountProbe(itemCount: 3)
        let plugin = EmptyTrashPlugin(
            countItems: { await counter.countItems() },
            countRefreshDelay: .zero
        )

        plugin.panelSurfaceDidBecomeVisible(.primary)

        await waitForRequestCount(1, counter: counter)
        let requestCount = await counter.requestCountValue()
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "3 个项目")
    }

    func testVisibleCountRefreshesAreDebounced() async {
        let counter = TrashCountProbe(itemCount: 2)
        let plugin = EmptyTrashPlugin(
            countItems: { await counter.countItems() },
            countRefreshDelay: .zero
        )

        plugin.panelSurfaceDidBecomeVisible(.primary)
        plugin.refresh()
        plugin.refresh()

        await waitForRequestCount(1, counter: counter)
        for _ in 0..<5 {
            await Task.yield()
        }

        let requestCount = await counter.requestCountValue()
        XCTAssertEqual(requestCount, 1)
    }

    private func waitForRequestCount(
        _ expectedRequestCount: Int,
        counter: TrashCountProbe,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 {
            if await counter.requestCountValue() == expectedRequestCount {
                return
            }

            await Task.yield()
        }

        try? await Task.sleep(for: .milliseconds(50))
        if await counter.requestCountValue() == expectedRequestCount {
            return
        }

        let requestCount = await counter.requestCountValue()
        XCTAssertEqual(requestCount, expectedRequestCount, file: file, line: line)
    }
}

private actor TrashCountProbe {
    private(set) var requestCount = 0
    private let itemCount: Int

    init(itemCount: Int) {
        self.itemCount = itemCount
    }

    func countItems() async -> Int {
        requestCount += 1
        return itemCount
    }

    func requestCountValue() -> Int {
        requestCount
    }
}
