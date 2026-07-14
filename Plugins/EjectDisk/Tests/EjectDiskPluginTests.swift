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

    func testRefreshDoesNotDiscoverVolumesWhilePanelIsHidden() async {
        let probe = VolumeDiscoveryProbe(volumes: [makeVolume("Disk4")])
        let plugin = EjectDiskPlugin(discoverVolumes: { try await probe.discover() })

        plugin.refresh()
        plugin.panelSurfaceDidBecomeVisible(.component)
        await Task.yield()

        let requestCount = await probe.requestCountValue()
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(plugin.primaryPanelState.isEnabled)
    }

    func testOpeningPrimaryPanelDiscoversMountedEjectableVolumes() async {
        let probe = VolumeDiscoveryProbe(volumes: [
            makeVolume("Disk4"),
            makeVolume("Disk5")
        ])
        let plugin = EjectDiskPlugin(discoverVolumes: { try await probe.discover() })

        plugin.panelSurfaceDidBecomeVisible(.primary)

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "正在检测...")
        await waitUntil { plugin.primaryPanelState.subtitle == "2 个可推出的磁盘" }
        let requestCount = await probe.requestCountValue()
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
    }

    func testDiscoveryFailureIsReportedInsteadOfSilentlyLookingEmpty() async {
        let plugin = EjectDiskPlugin(discoverVolumes: { throw VolumeDiscoveryProbeError.failed })

        plugin.panelSurfaceDidBecomeVisible(.primary)

        await waitUntil { plugin.primaryPanelState.errorMessage != nil }
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "无可推出的磁盘")
        XCTAssertFalse(plugin.primaryPanelState.isEnabled)
    }

    func testSuccessfulEjectRemovesVolumesFromSnapshot() async {
        let volumes = [
            makeVolume("Disk4"),
            makeVolume("Disk5")
        ]
        let discoveryProbe = VolumeDiscoveryProbe(volumes: volumes)
        let ejectProbe = VolumeEjectProbe()
        let plugin = EjectDiskPlugin(
            discoverVolumes: { try await discoveryProbe.discover() },
            ejectVolume: { try await ejectProbe.eject($0) }
        )
        plugin.panelSurfaceDidBecomeVisible(.primary)
        await waitUntil { plugin.primaryPanelState.isEnabled }

        plugin.handleAction(.invokeAction(controlID: "execute"))

        await waitUntil { !plugin.primaryPanelState.isEnabled && plugin.primaryPanelState.subtitle == "无可推出的磁盘" }
        let ejectedIdentifiers = await ejectProbe.ejectedIdentifiers()
        XCTAssertEqual(ejectedIdentifiers, ["/Volumes/Disk4", "/Volumes/Disk5"])
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testPartialEjectFailureKeepsOnlyFailedVolume() async {
        let volumes = [
            makeVolume("Disk4"),
            makeVolume("Disk5")
        ]
        let discoveryProbe = VolumeDiscoveryProbe(volumes: volumes)
        let ejectProbe = VolumeEjectProbe(failingIdentifiers: ["/Volumes/Disk5"])
        let plugin = EjectDiskPlugin(
            discoverVolumes: { try await discoveryProbe.discover() },
            ejectVolume: { try await ejectProbe.eject($0) }
        )
        plugin.panelSurfaceDidBecomeVisible(.primary)
        await waitUntil { plugin.primaryPanelState.isEnabled }

        plugin.handleAction(.invokeAction(controlID: "execute"))

        await waitUntil { plugin.primaryPanelState.subtitle == "1 个可推出的磁盘" }
        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
        let ejectedIdentifiers = await ejectProbe.ejectedIdentifiers()
        XCTAssertEqual(ejectedIdentifiers, ["/Volumes/Disk4", "/Volumes/Disk5"])
    }

    func testEjectEligibilityIncludesDiskImagesAndRemovableMedia() {
        XCTAssertTrue(EjectDiskService.shouldOfferEject(
            mountPath: "/Volumes/Vorssaint",
            isInternal: nil,
            isRemovable: true,
            isEjectable: true,
            isLocal: true,
            isUnmountable: true
        ))
    }

    func testEjectEligibilityIncludesFixedExternalAndNetworkVolumes() {
        XCTAssertTrue(EjectDiskService.shouldOfferEject(
            mountPath: "/Volumes/ExternalSSD",
            isInternal: false,
            isRemovable: false,
            isEjectable: false,
            isLocal: true,
            isUnmountable: true
        ))
        XCTAssertTrue(EjectDiskService.shouldOfferEject(
            mountPath: "/Volumes/Shared",
            isInternal: nil,
            isRemovable: false,
            isEjectable: false,
            isLocal: false,
            isUnmountable: true
        ))
    }

    func testEjectEligibilityRejectsStartupAndUnknownVolumes() {
        XCTAssertFalse(EjectDiskService.shouldOfferEject(
            mountPath: "/",
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            isLocal: true,
            isUnmountable: true
        ))
        XCTAssertFalse(EjectDiskService.shouldOfferEject(
            mountPath: "/Volumes/Unknown",
            isInternal: nil,
            isRemovable: nil,
            isEjectable: nil,
            isLocal: nil,
            isUnmountable: false
        ))
        XCTAssertFalse(EjectDiskService.shouldOfferEject(
            mountPath: "/System/Volumes/Hidden",
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            isLocal: true,
            isUnmountable: true,
            isBrowsable: false
        ))
    }

    func testVolumesOnSameDeviceAreEjectedOnce() {
        let volumes = [
            makeVolume("ExternalData", deviceIdentifier: "disk8"),
            makeVolume("ExternalBackup", deviceIdentifier: "disk8"),
            makeVolume("DiskImage", deviceIdentifier: "disk9")
        ]

        let targets = EjectDiskService.deduplicate(volumes)

        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(targets[0].deviceIdentifier, "disk8")
        XCTAssertEqual(targets[0].mountURLs.count, 2)
        XCTAssertEqual(targets[1].deviceIdentifier, "disk9")
    }

    private func makeVolume(
        _ name: String,
        deviceIdentifier: String? = nil
    ) -> EjectableVolume {
        EjectableVolume(
            mountURL: URL(fileURLWithPath: "/Volumes/\(name)", isDirectory: true),
            name: name,
            deviceIdentifier: deviceIdentifier
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<40 {
            if condition() {
                return
            }
            await Task.yield()
        }

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

private actor VolumeDiscoveryProbe {
    private var requestCount = 0
    private let volumes: [EjectableVolume]

    init(volumes: [EjectableVolume]) {
        self.volumes = volumes
    }

    func discover() throws -> [EjectableVolume] {
        requestCount += 1
        return volumes
    }

    func requestCountValue() -> Int {
        requestCount
    }
}

private actor VolumeEjectProbe {
    private var identifiers: [String] = []
    private let failingIdentifiers: Set<String>

    init(failingIdentifiers: Set<String> = []) {
        self.failingIdentifiers = failingIdentifiers
    }

    func eject(_ volume: EjectableVolume) throws {
        identifiers.append(volume.id)
        if failingIdentifiers.contains(volume.id) {
            throw VolumeEjectProbeError.failed
        }
    }

    func ejectedIdentifiers() -> [String] {
        identifiers
    }
}

private enum VolumeEjectProbeError: Error {
    case failed
}

private enum VolumeDiscoveryProbeError: Error {
    case failed
}
