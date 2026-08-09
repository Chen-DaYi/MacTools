import AppKit
import Combine
import MacToolsPluginKit

struct SystemStatusMenuBarMetricBlock: Equatable {
    let kind: SystemStatusMetricKind
    let label: String
    let value: String
}

enum SystemStatusMenuBarMetricsFormatter {
    static func blocks(
        snapshot: SystemStatusSnapshot,
        kinds: [SystemStatusMetricKind]
    ) -> [SystemStatusMenuBarMetricBlock] {
        kinds.compactMap { block(for: $0, snapshot: snapshot) }
    }

    static func text(
        snapshot: SystemStatusSnapshot,
        kinds: [SystemStatusMetricKind]
    ) -> String {
        blocks(snapshot: snapshot, kinds: kinds)
            .map { "\($0.label) \($0.value)" }
            .joined(separator: " | ")
    }

    static func tooltip(
        snapshot: SystemStatusSnapshot,
        kinds: [SystemStatusMetricKind]
    ) -> String {
        let details = blocks(snapshot: snapshot, kinds: kinds)
            .map { "\($0.label) \($0.value)" }
        guard !details.isEmpty else {
            return "System Status"
        }

        return (["System Status"] + details).joined(separator: "\n")
    }

    private static func block(
        for kind: SystemStatusMetricKind,
        snapshot: SystemStatusSnapshot
    ) -> SystemStatusMenuBarMetricBlock? {
        switch kind {
        case .cpu:
            return SystemStatusMenuBarMetricBlock(
                kind: kind,
                label: "CPU",
                value: percentAndTemperature(
                    percent: snapshot.cpu.usage,
                    temperatureCelsius: snapshot.cpu.temperatureCelsius
                )
            )
        case .gpu:
            return SystemStatusMenuBarMetricBlock(
                kind: kind,
                label: "GPU",
                value: snapshot.gpu.isAvailable
                    ? percentAndTemperature(
                        percent: snapshot.gpu.usage,
                        temperatureCelsius: snapshot.gpu.temperatureCelsius
                    )
                    : "—"
            )
        case .memory:
            return SystemStatusMenuBarMetricBlock(
                kind: kind,
                label: "RAM",
                value: compactPercent(snapshot.memory.usage)
            )
        case .disk:
            return SystemStatusMenuBarMetricBlock(
                kind: kind,
                label: "DSK",
                value: compactPercent(snapshot.disk.usage)
            )
        case .battery:
            return SystemStatusMenuBarMetricBlock(
                kind: kind,
                label: "BAT",
                value: snapshot.battery.isAvailable
                    ? percentAndTemperature(
                        percent: snapshot.battery.level,
                        temperatureCelsius: snapshot.battery.temperatureCelsius
                    )
                    : "—"
            )
        case .network:
            return SystemStatusMenuBarMetricBlock(
                kind: kind,
                label: "NET",
                value: "↓\(compactSpeed(snapshot.network.downloadBytesPerSecond)) ↑\(compactSpeed(snapshot.network.uploadBytesPerSecond))"
            )
        case .topProcesses:
            return nil
        }
    }

    private static func percentAndTemperature(
        percent: Double?,
        temperatureCelsius: Double?
    ) -> String {
        let percentText = compactPercent(percent)
        guard let temperatureText = compactTemperature(temperatureCelsius) else {
            return percentText
        }

        return "\(percentText) \(temperatureText)"
    }

    private static func compactPercent(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return "—"
        }

        return "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    private static func compactTemperature(_ celsius: Double?) -> String? {
        guard let celsius, celsius.isFinite else {
            return nil
        }

        return "\(Int(celsius.rounded()))°"
    }

    private static func compactSpeed(_ bytesPerSecond: UInt64?) -> String {
        guard let bytesPerSecond else {
            return "—"
        }

        let units = ["B", "K", "M", "G", "T", "P"]
        var value = Double(bytesPerSecond)
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(Int(value.rounded()))B"
        }

        if value < 10 {
            let rounded = (value * 10).rounded() / 10
            if rounded >= 10 || rounded.rounded() == rounded {
                return "\(Int(rounded.rounded()))\(units[unitIndex])"
            }
            return String(format: "%.1f%@", rounded, units[unitIndex])
        }

        return "\(Int(value.rounded()))\(units[unitIndex])"
    }
}

final class SystemStatusMenuBarMetricsView: NSView {
    private enum Layout {
        static let topInset: CGFloat = 1
        static let bottomInset: CGFloat = 1
        static let horizontalInset: CGFloat = 5
        static let interMetricSpacing: CGFloat = 7
        static let minimumMetricWidth: CGFloat = 24
    }

    var blocks: [SystemStatusMenuBarMetricBlock] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth(for: blocks), height: NSStatusBar.system.thickness)
    }

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let metricWidths = blocks.map(metricWidth)
        var x = Layout.horizontalInset

        for index in blocks.indices {
            let width = metricWidths[index]
            draw(blocks[index], in: NSRect(x: x, y: 0, width: width, height: bounds.height))
            x += width

            guard index < blocks.index(before: blocks.endIndex) else {
                continue
            }

            x += Layout.interMetricSpacing
        }
    }

    private var labelFont: NSFont {
        NSFont.systemFont(ofSize: 7, weight: .regular)
    }

    private var valueFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    }

    private func draw(_ block: SystemStatusMenuBarMetricBlock, in rect: NSRect) {
        let label = attributedText(
            block.label,
            font: labelFont,
            color: .labelColor,
            kern: 0.2
        )
        let value = attributedText(
            block.value,
            font: valueFont,
            color: .labelColor
        )

        let labelSize = label.size()
        let valueSize = value.size()
        let labelRect = NSRect(
            x: rect.minX + (rect.width - labelSize.width) / 2,
            y: Layout.topInset,
            width: labelSize.width,
            height: labelSize.height
        )
        let valueRect = NSRect(
            x: rect.minX + (rect.width - valueSize.width) / 2,
            y: max(Layout.topInset + labelSize.height - 1, rect.maxY - valueSize.height - Layout.bottomInset),
            width: valueSize.width,
            height: valueSize.height
        )

        label.draw(in: labelRect)
        value.draw(in: valueRect)
    }

    private func metricWidth(_ block: SystemStatusMenuBarMetricBlock) -> CGFloat {
        let labelWidth = attributedText(
            block.label,
            font: labelFont,
            color: .labelColor
        ).size().width
        let valueWidth = attributedText(
            block.value,
            font: valueFont,
            color: .labelColor
        ).size().width
        return ceil(max(Layout.minimumMetricWidth, labelWidth, valueWidth))
    }

    private func preferredWidth(for blocks: [SystemStatusMenuBarMetricBlock]) -> CGFloat {
        guard !blocks.isEmpty else {
            return 0
        }

        let metricsWidth = blocks.reduce(CGFloat(0)) { partialResult, block in
            partialResult + metricWidth(block)
        }
        let spacingCount = CGFloat(max(blocks.count - 1, 0))
        let spacingWidth = spacingCount * Layout.interMetricSpacing
        return ceil(metricsWidth + spacingWidth + Layout.horizontalInset * 2)
    }

    private func attributedText(
        _ string: String,
        font: NSFont,
        color: NSColor,
        kern: CGFloat = 0
    ) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .kern: kern
            ]
        )
    }
}

@MainActor
final class SystemStatusMenuBarMetricsController: NSObject {
    private static let autosaveName = "MacTools.SystemStatus.MenuBarMetrics"

    private let viewModel: SystemStatusViewModel
    private let settingsController: SystemStatusSettingsController
    var requestConfigurationPresentation: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    private var statusItem: NSStatusItem?
    private var metricsView: SystemStatusMenuBarMetricsView?
    private var isActive = false

    init(
        viewModel: SystemStatusViewModel,
        settingsController: SystemStatusSettingsController
    ) {
        self.viewModel = viewModel
        self.settingsController = settingsController
        super.init()
        observeState()
    }

    func activate() {
        isActive = true
        render(
            configuration: settingsController.configuration,
            snapshot: viewModel.snapshot
        )
    }

    func stop() {
        isActive = false
        viewModel.stopMenuBar()
        removeStatusItem()
    }

    private func observeState() {
        settingsController.$configuration
            .removeDuplicates()
            .combineLatest(viewModel.$snapshot.removeDuplicates())
            .sink { [weak self] configuration, snapshot in
                self?.render(configuration: configuration, snapshot: snapshot)
            }
            .store(in: &cancellables)
    }

    private func render(
        configuration: SystemStatusConfiguration,
        snapshot: SystemStatusSnapshot
    ) {
        guard isActive else {
            removeStatusItem()
            return
        }

        let kinds = configuration.visibleMenuBarMetricKinds
        guard !kinds.isEmpty else {
            viewModel.stopMenuBar()
            removeStatusItem()
            return
        }

        viewModel.startMenuBar(requiresSlowSampling: kinds.requiresMenuBarSlowSampling)
        let blocks = SystemStatusMenuBarMetricsFormatter.blocks(
            snapshot: snapshot,
            kinds: kinds
        )
        guard !blocks.isEmpty else {
            viewModel.stopMenuBar()
            removeStatusItem()
            return
        }

        let statusItem = ensureStatusItem()

        guard let button = statusItem.button else {
            return
        }

        let metricsView = ensureMetricsView(in: button)
        metricsView.blocks = blocks
        statusItem.length = metricsView.intrinsicContentSize.width
        metricsView.frame = button.bounds
        button.toolTip = SystemStatusMenuBarMetricsFormatter.tooltip(
            snapshot: snapshot,
            kinds: kinds
        )
    }

    private func ensureStatusItem() -> NSStatusItem {
        if let statusItem {
            return statusItem
        }

        PluginPresentationSafety.prepareForWindowOrdering()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        if let button = item.button {
            button.image = nil
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
        }

        statusItem = item
        return item
    }

    private func ensureMetricsView(in button: NSStatusBarButton) -> SystemStatusMenuBarMetricsView {
        if let metricsView {
            return metricsView
        }

        let view = SystemStatusMenuBarMetricsView()
        view.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            view.topAnchor.constraint(equalTo: button.topAnchor),
            view.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        metricsView = view
        return view
    }

    private func removeStatusItem() {
        guard let statusItem else {
            return
        }

        PluginPresentationSafety.prepareForWindowOrdering()
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        metricsView = nil
    }

    @objc
    private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        requestConfigurationPresentation?()
    }
}

private extension Array where Element == SystemStatusMetricKind {
    var requiresMenuBarSlowSampling: Bool {
        contains { kind in
            switch kind {
            case .gpu, .disk, .battery:
                return true
            case .cpu, .network, .memory, .topProcesses:
                return false
            }
        }
    }
}
