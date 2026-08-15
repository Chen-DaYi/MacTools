import Carbon.HIToolbox
import Foundation

enum AutoInputSourceError: LocalizedError, Equatable {
    case sourceUnavailable
    case selectionFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            return "输入法不可用"
        case .selectionFailed:
            return "无法切换输入法"
        }
    }
}

@MainActor
protocol AutoInputSourceControlling: AnyObject {
    var onSourcesChanged: (() -> Void)? { get set }
    var sources: [AutoInputSource] { get }
    var currentSourceID: String? { get }

    func start()
    func stop()
    func refresh()
    func selectSource(id: String) throws
}

@MainActor
final class CarbonAutoInputSourceCatalog: AutoInputSourceControlling {
    var onSourcesChanged: (() -> Void)?
    private(set) var sources: [AutoInputSource] = []

    private var sourceReferences: [String: TISInputSource] = [:]
    private var observers: [NSObjectProtocol] = []

    var currentSourceID: String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return stringProperty(source, key: kTISPropertyInputSourceID)
    }

    init() {
        refresh()
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        let names = [
            Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refresh()
                    self?.onSourcesChanged?()
                }
            }
        }
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    func refresh() {
        let rawList = TISCreateInputSourceList(nil, false).takeRetainedValue()
        guard let list = rawList as? [TISInputSource] else {
            sourceReferences = [:]
            sources = []
            return
        }
        var nextReferences: [String: TISInputSource] = [:]
        var nextSources: [AutoInputSource] = []

        for source in list {
            guard boolProperty(source, key: kTISPropertyInputSourceIsEnabled) == true,
                  boolProperty(source, key: kTISPropertyInputSourceIsSelectCapable) == true,
                  stringProperty(source, key: kTISPropertyInputSourceCategory) == kTISCategoryKeyboardInputSource as String,
                  let id = stringProperty(source, key: kTISPropertyInputSourceID)
            else { continue }

            let name = stringProperty(source, key: kTISPropertyLocalizedName) ?? id
            nextReferences[id] = source
            nextSources.append(AutoInputSource(
                id: id,
                name: name
            ))
        }

        sourceReferences = nextReferences
        sources = nextSources.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func selectSource(id: String) throws {
        if sourceReferences[id] == nil {
            refresh()
        }
        guard let source = sourceReferences[id] else {
            throw AutoInputSourceError.sourceUnavailable
        }

        let status = TISSelectInputSource(source)
        guard status == noErr else {
            throw AutoInputSourceError.selectionFailed(status)
        }
    }

    private func stringProperty(_ source: TISInputSource, key: CFString) -> String? {
        property(source, key: key) as? String
    }

    private func boolProperty(_ source: TISInputSource, key: CFString) -> Bool? {
        property(source, key: key) as? Bool
    }

    private func property(_ source: TISInputSource, key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
}
