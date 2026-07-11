import XCTest
@testable import MacTools
@testable import EjectDiskPlugin

@MainActor
final class EjectDiskPluginTests: XCTestCase {
    func testMetadataIdentifiesEjectDiskPlugin() {
        let plugin = EjectDiskPlugin()

        XCTAssertEqual(plugin.metadata.id, "eject-disk")
        XCTAssertEqual(plugin.metadata.title, "推出磁盘")
    }

    func testControlStyleIsButton() {
        let plugin = EjectDiskPlugin()

        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .button)
        XCTAssertEqual(plugin.primaryPanelDescriptor.buttonTitle, "推出")
    }

    func testInitialStateHasEjectedOffAndIsDisabled() {
        let plugin = EjectDiskPlugin()

        let state = plugin.primaryPanelState
        XCTAssertFalse(state.isOn)
        XCTAssertFalse(state.isEnabled)
    }

    func testPermissionRequirementsIsEmpty() {
        let plugin = EjectDiskPlugin()

        XCTAssertTrue(plugin.permissionRequirements.isEmpty)
    }

    func testPluginHostIncludesEjectDiskWhenProvided() {
        let host = makePluginHostForTests(plugins: [EjectDiskPlugin()])

        XCTAssertTrue(host.featureManagementItems.contains { $0.id == "eject-disk" })
    }

    func testPluginDescriptionMatches() {
        let plugin = EjectDiskPlugin()

        XCTAssertEqual(plugin.metadata.defaultDescription, "推出所有可移动磁盘")
    }

    func testSubtitleShowsNoEjectableDiskWhenCountIsZero() {
        let plugin = EjectDiskPlugin()

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "无可推出的磁盘")
    }

    func testEjectableVolumeRequiresExplicitExternalLocalVolumeProperties() {
        XCTAssertTrue(EjectDiskPlugin.isEjectableVolume(
            isEjectable: true,
            isInternal: false,
            isLocal: true
        ))
    }

    func testEjectableVolumeRejectsInternalSystemVolume() {
        XCTAssertFalse(EjectDiskPlugin.isEjectableVolume(
            isEjectable: true,
            isInternal: true,
            isLocal: true
        ))
    }

    func testEjectableVolumeRejectsNetworkVolume() {
        XCTAssertFalse(EjectDiskPlugin.isEjectableVolume(
            isEjectable: true,
            isInternal: false,
            isLocal: false
        ))
    }

    func testEjectableVolumeRejectsUnknownProperties() {
        XCTAssertFalse(EjectDiskPlugin.isEjectableVolume(
            isEjectable: true,
            isInternal: nil,
            isLocal: true
        ))
        XCTAssertFalse(EjectDiskPlugin.isEjectableVolume(
            isEjectable: nil,
            isInternal: false,
            isLocal: true
        ))
    }
}
