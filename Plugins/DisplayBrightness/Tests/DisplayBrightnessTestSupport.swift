import CoreGraphics
import MacToolsPluginKit
@testable import MacTools
@testable import DisplayBrightnessPlugin

func makeTestDisplay(
    id: CGDirectDisplayID,
    name: String,
    isBuiltin: Bool = false,
    isMain: Bool = false,
    vendorNumber: UInt32? = nil,
    modelNumber: UInt32? = nil,
    serialNumber: UInt32? = nil
) -> DisplayInfo {
    DisplayInfo(
        id: id,
        name: name,
        isBuiltin: isBuiltin,
        isMain: isMain,
        vendorNumber: vendorNumber,
        modelNumber: modelNumber,
        serialNumber: serialNumber
    )
}

func makeBrightnessDisplay(
    id: CGDirectDisplayID,
    name: String,
    brightness: Double,
    vendorNumber: UInt32? = nil,
    modelNumber: UInt32? = nil,
    serialNumber: UInt32? = nil
) -> DisplayBrightnessDisplay {
    DisplayBrightnessDisplay(
        display: makeTestDisplay(
            id: id,
            name: name,
            vendorNumber: vendorNumber,
            modelNumber: modelNumber,
            serialNumber: serialNumber
        ),
        brightness: brightness,
        isPendingWrite: false
    )
}

@MainActor
final class MockDisplayBrightnessController: DisplayBrightnessControlling {
    struct BrightnessWrite: Equatable {
        let value: Double
        let displayID: CGDirectDisplayID
        let phase: PluginPanelAction.SliderPhase
    }

    var onStateChange: (() -> Void)?
    var snapshotValue = DisplayBrightnessSnapshot(displays: [], errorMessage: nil)
    private(set) var brightnessWrites: [BrightnessWrite] = []

    func refresh() {}

    func snapshot() -> DisplayBrightnessSnapshot {
        snapshotValue
    }

    func setBrightness(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        phase: PluginPanelAction.SliderPhase
    ) {
        brightnessWrites.append(BrightnessWrite(value: value, displayID: displayID, phase: phase))
        snapshotValue = DisplayBrightnessSnapshot(
            displays: snapshotValue.displays.map { display in
                guard display.id == displayID else { return display }
                return DisplayBrightnessDisplay(
                    display: display.display,
                    brightness: min(max(value, 0), 1),
                    isPendingWrite: phase != .ended
                )
            },
            errorMessage: snapshotValue.errorMessage
        )
    }
}

@MainActor
final class DisplayBrightnessMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }

    func set(_ value: Any?, forKey key: String) {
        guard let value else {
            removeObject(forKey: key)
            return
        }

        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }

        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}
