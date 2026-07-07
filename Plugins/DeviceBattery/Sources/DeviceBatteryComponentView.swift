import AppKit
import SwiftUI
import MacToolsPluginKit

struct DeviceBatteryComponentView: View {
    @ObservedObject var viewModel: DeviceBatteryViewModel
    @ObservedObject var store: DeviceBatteryStore
    let localization: PluginLocalization
    let openSettings: () -> Void

    var body: some View {
        Group {
            if visibleItems.isEmpty {
                emptyState
            } else {
                switch store.layoutMode {
                case .grid:
                    DeviceBatteryListCard(
                        items: Array(visibleItems.prefix(DeviceBatteryLayout.maximumListItems)),
                        totalCount: visibleItems.count,
                        localization: localization
                    )
                case .list:
                    DeviceBatteryGaugeGrid(
                        items: Array(visibleItems.prefix(DeviceBatteryLayout.maximumGaugeItems)),
                        totalCount: visibleItems.count,
                        localization: localization
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var visibleItems: [DeviceBatteryItem] {
        viewModel.snapshot.visibleItems
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: viewModel.snapshot.accessState.isError ? "exclamationmark.triangle" : "battery.0percent")
                .font(.system(size: 24, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(viewModel.snapshot.accessState.isError ? Color(nsColor: .systemOrange) : Color.secondary)

            Text(emptyTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(emptySubtitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.snapshot.accessState == .permissionDenied {
                Button(action: openSettings) {
                    Label(
                        localization.string("empty.openSettings", defaultValue: "打开系统设置"),
                        systemImage: "gearshape"
                    )
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DeviceBatteryCardBackground(cornerRadius: DeviceBatteryLayout.cornerRadius))
    }

    private var emptyTitle: String {
        switch viewModel.snapshot.accessState {
        case .permissionDenied:
            return localization.string("empty.title.permissionDenied", defaultValue: "需要输入监控权限")
        case .scanning:
            return localization.string("empty.title.scanning", defaultValue: "正在读取电量")
        case .failed:
            return localization.string("empty.title.failed", defaultValue: "读取失败")
        case .idle, .ready, .noDevices:
            return localization.string("empty.title.noDevices", defaultValue: "暂无设备电量")
        }
    }

    private var emptySubtitle: String {
        switch viewModel.snapshot.accessState {
        case .permissionDenied:
            return localization.string("empty.subtitle.permissionDenied", defaultValue: "授权后可读取厂商 HID 鼠标")
        case .failed(let message):
            return message
        case .scanning:
            return localization.string("empty.subtitle.scanning", defaultValue: "正在查询系统电源与蓝牙设备")
        case .idle, .ready, .noDevices:
            return localization.string("empty.subtitle.noDevices", defaultValue: "连接蓝牙设备或厂商 HID 鼠标")
        }
    }
}

enum DeviceBatteryComponentLayout {
    static let width = 4
    static let cornerRadius: CGFloat = PluginComponentPanelLayoutMetrics.cardCornerRadius
    static let horizontalPadding: CGFloat = 12
    static let rowHeight: CGFloat = 34
    static let overflowHeight: CGFloat = 20
    static let rowIconWidth: CGFloat = 26
    static let percentWidth: CGFloat = 38
    static let batteryWidth: CGFloat = 23
    static let cardVerticalPadding: CGFloat = 6
    static let gaugeHorizontalPadding: CGFloat = 12
    static let gaugeVerticalPadding: CGFloat = 10
    static let maximumListItems = 6
    static let maximumGaugeItems = 8
    static let ringSpan: CGFloat = 0.78
    static let ringRotation: Double = 129.6
    static let ringTrackLineWidthScale: CGFloat = 1.15
    static let poweredRingLineWidthScale: CGFloat = 1.38

    static func contentHeight(mode: DeviceBatteryLayoutMode, visibleItemCount: Int) -> CGFloat {
        guard visibleItemCount > 0 else {
            return 116
        }

        switch mode {
        case .grid:
            return listCardHeight(totalCount: visibleItemCount)
        case .list:
            return gaugeCardHeight(totalCount: visibleItemCount)
        }
    }

    static func spanHeight(
        mode: DeviceBatteryLayoutMode,
        visibleItemCount: Int,
        metrics: PluginComponentPanelLayoutMetrics = .default
    ) -> Int {
        metrics.heightSpan(
            fittingContentHeight: contentHeight(
                mode: mode,
                visibleItemCount: visibleItemCount
            )
        )
    }

    static func listCardHeight(totalCount: Int) -> CGFloat {
        let displayCount = min(max(totalCount, 1), maximumListItems)
        return cardVerticalPadding * 2
            + CGFloat(displayCount) * rowHeight
            + CGFloat(max(displayCount - 1, 0))
            + overflowHeightIfNeeded(totalCount: totalCount, displayedCount: displayCount)
    }

    static func gaugeCardHeight(totalCount: Int) -> CGFloat {
        let displayCount = min(max(totalCount, 1), maximumGaugeItems)
        let tileSize = gaugeTileSize(for: displayCount)
        let rows = gaugeRowCount(totalCount: totalCount)
        let rowSpacing = gaugeRowSpacing(for: displayCount)
        return gaugeVerticalPadding * 2
            + CGFloat(rows) * (tileSize + gaugePercentHeight)
            + CGFloat(max(rows - 1, 0)) * rowSpacing
    }

    static func gaugeColumnCount(for itemCount: Int) -> Int {
        switch itemCount {
        case 0...1:
            return 1
        case 2:
            return 2
        case 3:
            return 3
        default:
            return 4
        }
    }

    static func gaugeRowCount(totalCount: Int) -> Int {
        let displayCount = min(max(totalCount, 1), maximumGaugeItems)
        let cellCount = displayCount + (totalCount > displayCount ? 1 : 0)
        let columns = gaugeColumnCount(for: displayCount)
        return Int(ceil(Double(cellCount) / Double(columns)))
    }

    static func gaugeTileSize(for itemCount: Int) -> CGFloat {
        switch itemCount {
        case 0...2:
            return 66
        case 3...4:
            return 58
        default:
            return 50
        }
    }

    static func gaugeLineWidth(for tileSize: CGFloat) -> CGFloat {
        max(4, tileSize * 0.078)
    }

    static let gaugePercentHeight: CGFloat = 20

    static func gaugeRowSpacing(for itemCount: Int) -> CGFloat {
        itemCount > 4 ? 8 : 6
    }

    static func overflowHeightIfNeeded(totalCount: Int, displayedCount: Int) -> CGFloat {
        totalCount > displayedCount ? overflowHeight + 1 : 0
    }
}

private typealias DeviceBatteryLayout = DeviceBatteryComponentLayout

private struct DeviceBatteryListCard: View {
    let items: [DeviceBatteryItem]
    let totalCount: Int
    let localization: PluginLocalization

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                DeviceBatteryNativeRow(
                    item: item,
                    rowHeight: DeviceBatteryLayout.rowHeight,
                    showsDetail: false,
                    localization: localization
                )

                if index < items.count - 1 {
                    DeviceBatteryDivider()
                }
            }

            if totalCount > items.count {
                DeviceBatteryDivider()
                DeviceBatteryOverflowRow(count: totalCount - items.count, localization: localization)
            }
        }
        .padding(.vertical, DeviceBatteryLayout.cardVerticalPadding)
        .frame(maxWidth: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DeviceBatteryCardBackground(cornerRadius: DeviceBatteryLayout.cornerRadius))
    }
}

private struct DeviceBatteryGaugeGrid: View {
    let items: [DeviceBatteryItem]
    let totalCount: Int
    let localization: PluginLocalization

    var body: some View {
        Group {
            LazyVGrid(columns: columns, spacing: rowSpacing) {
                ForEach(items) { item in
                    DeviceBatteryGaugeTile(
                        item: item,
                        tileSize: tileSize,
                        lineWidth: DeviceBatteryLayout.gaugeLineWidth(for: tileSize),
                        localization: localization
                    )
                    .frame(maxWidth: .infinity)
                }

                if totalCount > items.count {
                    Text("+\(totalCount - items.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: tileSize, height: tileSize + DeviceBatteryLayout.gaugePercentHeight)
                }
            }
            .padding(.horizontal, DeviceBatteryLayout.gaugeHorizontalPadding)
            .padding(.vertical, DeviceBatteryLayout.gaugeVerticalPadding)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DeviceBatteryCardBackground(cornerRadius: DeviceBatteryLayout.cornerRadius))
    }

    private var tileSize: CGFloat {
        DeviceBatteryLayout.gaugeTileSize(for: items.count)
    }

    private var rowSpacing: CGFloat {
        DeviceBatteryLayout.gaugeRowSpacing(for: items.count)
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: tileSize), spacing: items.count > 4 ? 6 : 8),
            count: DeviceBatteryLayout.gaugeColumnCount(for: items.count)
        )
    }
}

private struct DeviceBatteryGaugeTile: View {
    let item: DeviceBatteryItem
    let tileSize: CGFloat
    let lineWidth: CGFloat
    let localization: PluginLocalization

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                DeviceBatteryRing(
                    item: item,
                    size: tileSize,
                    lineWidth: lineWidth,
                    localization: localization
                )

                Image(systemName: deviceSymbolName(for: item))
                    .font(.system(size: tileSize * 0.32, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconTint)
                    .frame(width: tileSize * 0.54, height: tileSize * 0.48)
            }
            .frame(width: tileSize, height: tileSize)
            .overlay {
                if chargingSymbolName(for: item) != nil {
                    let badgeSize = max(14, tileSize * 0.24)
                    DeviceBatteryChargingBadge(
                        systemName: "bolt.fill",
                        color: batteryTint(for: item),
                        size: badgeSize
                    )
                    .position(x: tileSize / 2, y: chargingBadgeCenterY)
                }
            }

            Text(DeviceBatteryFormatter.percent(item.clampedLevel))
                .font(.system(size: max(10, tileSize * 0.18), weight: .regular, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: tileSize, height: tileSize + DeviceBatteryLayout.gaugePercentHeight)
        .compositingGroup()
        .help(helpText(for: item, localization: localization))
    }

    private var iconTint: Color {
        chargingSymbolName(for: item) == nil
            ? Color.primary.opacity(0.58)
            : batteryTint(for: item).opacity(0.84)
    }

    private var chargingBadgeCenterY: CGFloat {
        ringPathInset
    }

    private var ringPathInset: CGFloat {
        lineWidth * DeviceBatteryLayout.poweredRingLineWidthScale / 2
    }
}

private struct DeviceBatteryChargingBadge: View {
    let systemName: String
    let color: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)

            Image(systemName: systemName)
                .font(.system(size: max(7.2, size * 0.54), weight: .black))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct DeviceBatteryRing: View {
    let item: DeviceBatteryItem
    let size: CGFloat
    let lineWidth: CGFloat
    var localization: PluginLocalization = PluginLocalization(bundle: .main)

    var body: some View {
        ZStack {
            Circle()
                .inset(by: ringPathInset)
                .trim(from: 0, to: DeviceBatteryLayout.ringSpan)
                .stroke(
                    Color.primary.opacity(0.12),
                    style: StrokeStyle(
                        lineWidth: lineWidth * DeviceBatteryLayout.ringTrackLineWidthScale,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

            if showsPoweredOverlay {
                Circle()
                    .inset(by: ringPathInset)
                    .trim(from: 0, to: DeviceBatteryLayout.ringSpan)
                    .stroke(
                        batteryTint(for: item).opacity(0.12),
                        style: StrokeStyle(
                            lineWidth: lineWidth * DeviceBatteryLayout.poweredRingLineWidthScale,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )

                if progressSpan > 0.002, progress < 0.995 {
                    Circle()
                        .inset(by: ringPathInset)
                        .trim(from: max(progressSpan - 0.002, 0), to: max(progressSpan - 0.0004, 0))
                        .stroke(
                            batteryTint(for: item),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                        )
                        .shadow(color: batteryTint(for: item).opacity(0.32), radius: lineWidth * 0.7)
                        .clipShape(
                            Circle()
                                .inset(by: ringPathInset)
                                .trim(from: 0, to: DeviceBatteryLayout.ringSpan)
                                .stroke(style: StrokeStyle(lineWidth: lineWidth * 1.4, lineCap: .round, lineJoin: .round))
                        )
                }
            }

            Circle()
                .inset(by: ringPathInset)
                .trim(from: 0, to: progressSpan)
                .stroke(
                    batteryTint(for: item),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
        }
        .rotationEffect(.degrees(DeviceBatteryLayout.ringRotation))
        .frame(width: size, height: size)
        .accessibilityLabel(
            localization.format(
                "accessibility.ring",
                defaultValue: "%@，%@",
                item.name,
                DeviceBatteryFormatter.percent(item.clampedLevel)
            )
        )
    }

    private var progress: CGFloat {
        CGFloat(item.clampedLevel ?? 0) / 100
    }

    private var progressSpan: CGFloat {
        DeviceBatteryLayout.ringSpan * progress
    }

    private var showsPoweredOverlay: Bool {
        chargingSymbolName(for: item) != nil
    }

    private var ringPathInset: CGFloat {
        lineWidth * DeviceBatteryLayout.poweredRingLineWidthScale / 2
    }
}

private struct DeviceBatteryDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, DeviceBatteryLayout.horizontalPadding + DeviceBatteryLayout.rowIconWidth + 10)
            .padding(.trailing, DeviceBatteryLayout.horizontalPadding)
    }
}

private struct DeviceBatteryOverflowRow: View {
    let count: Int
    let localization: PluginLocalization

    var body: some View {
        Text(localization.format("overflow.moreDevices", defaultValue: "还有 %d 台设备", count))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .frame(height: DeviceBatteryLayout.overflowHeight)
    }
}

private struct DeviceBatteryNativeRow: View {
    let item: DeviceBatteryItem
    let rowHeight: CGFloat
    var showsDetail = false
    var compact = false
    var prominent = false
    var localization: PluginLocalization = PluginLocalization(bundle: .main)

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            Image(systemName: deviceSymbolName(for: item))
                .font(.system(size: iconSize, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.primary.opacity(iconOpacity))
                .frame(width: DeviceBatteryLayout.rowIconWidth, height: rowHeight)

            VStack(alignment: .leading, spacing: showsDetail ? 2 : 0) {
                Text(item.name)
                    .font(titleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.72)

                if showsDetail {
                    Text(deviceDetailText(for: item, localization: localization))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Text(DeviceBatteryFormatter.percent(item.clampedLevel))
                .font(percentFont)
                .foregroundStyle(item.clampedLevel ?? 100 <= 10 ? Color(nsColor: .systemRed) : .primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: DeviceBatteryLayout.percentWidth, alignment: .trailing)

            DeviceBatterySystemBattery(item: item)
                .frame(width: DeviceBatteryLayout.batteryWidth, height: 14)
        }
        .padding(.horizontal, DeviceBatteryLayout.horizontalPadding)
        .frame(height: rowHeight)
        .help(helpText(for: item, localization: localization))
    }

    private var titleFont: Font {
        if prominent {
            return .body.weight(.semibold)
        }
        return compact ? .caption.weight(.medium) : .subheadline.weight(.medium)
    }

    private var percentFont: Font {
        if prominent {
            return .subheadline
        }
        return compact
            ? .caption2
            : .caption
    }

    private var iconSize: CGFloat {
        if prominent {
            return 21
        }
        return compact ? 15 : 17
    }

    private var iconOpacity: Double {
        prominent ? 0.64 : 0.56
    }
}

private struct DeviceBatterySystemBattery: View {
    let item: DeviceBatteryItem

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.9, style: .continuous)
                    .stroke(Color.primary.opacity(0.30), lineWidth: 0.85)
                    .frame(width: 18, height: 8.2)

                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .fill(batteryTint(for: item))
                    .frame(width: fillWidth, height: 4.8)
                    .padding(.leading, 1.9)
                    .opacity(item.clampedLevel == nil ? 0.18 : 0.82)

                if chargingSymbolName(for: item) != nil {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 5.1, weight: .black))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 8.2)
                }
            }

            RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                .fill(Color.primary.opacity(0.30))
                .frame(width: 1.3, height: 3.6)
        }
        .accessibilityLabel(DeviceBatteryFormatter.percent(item.clampedLevel))
    }

    private var fillWidth: CGFloat {
        guard let level = item.clampedLevel else {
            return 3
        }

        return max(2.8, 14.2 * CGFloat(level) / 100)
    }
}

private struct DeviceBatteryCardBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.045))
    }
}

private func batteryTint(for item: DeviceBatteryItem?) -> Color {
    guard let item else {
        return Color(nsColor: .systemGreen)
    }

    if item.chargeState == .charging || item.chargeState == .charged {
        return Color(nsColor: .systemGreen)
    }

    guard let level = item.clampedLevel else {
        return Color(nsColor: .systemBlue)
    }

    if level <= 20 {
        return Color(nsColor: .systemRed)
    }
    if level <= 35 {
        return Color(nsColor: .systemOrange)
    }
    return Color(nsColor: .systemGreen)
}

private func chargingSymbolName(for item: DeviceBatteryItem) -> String? {
    switch item.chargeState {
    case .charging, .charged:
        return "bolt.fill"
    case .plugged:
        return "powerplug.fill"
    case .unknown, .normal, .invalid:
        return nil
    }
}

private func batterySymbolName(for item: DeviceBatteryItem) -> String {
    if item.chargeState == .charging || item.chargeState == .charged || item.chargeState == .plugged {
        return "battery.100percent.bolt"
    }

    guard let level = item.clampedLevel else {
        return "battery.0percent"
    }

    switch level {
    case 76...100:
        return "battery.100percent"
    case 51...75:
        return "battery.75percent"
    case 26...50:
        return "battery.50percent"
    case 11...25:
        return "battery.25percent"
    default:
        return "battery.0percent"
    }
}

private func deviceDetailText(
    for item: DeviceBatteryItem,
    localization: PluginLocalization = PluginLocalization(bundle: .main)
) -> String {
    if let detail = item.detail, !detail.isEmpty {
        return detail
    }
    if let model = item.model, !model.isEmpty, model != item.name {
        return model
    }
    return item.chargeState == .normal
        ? localization.string("deviceDetail.connected", defaultValue: "已连接")
        : item.chargeState.title(localization: localization)
}

func deviceSymbolName(for item: DeviceBatteryItem) -> String {
    let haystack = [
        item.name,
        item.model,
        item.detail,
        item.parentName,
        item.kind.title()
    ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

    switch item.kind {
    case .internalBattery:
        if containsAny(haystack, ["macbook", "mac book", "book"]) {
            return "macbook"
        }
        if containsAny(haystack, ["mac mini", "macmini", "mini"]) {
            return "macmini"
        }
        if containsAny(haystack, ["imac"]) {
            return "desktopcomputer"
        }
        return "desktopcomputer.and.macbook"
    case .rapooMouse:
        return "computermouse.fill"
    case .airPodsPart:
        let ownName = item.name.lowercased()
        if ownName.contains("case") || ownName.contains("充电盒") {
            return airPodsSymbolName(in: haystack, part: .case)
        }
        if ownName.contains("左耳") || ownName.contains("left") || ownName.contains("🄻") {
            return airPodsSymbolName(in: haystack, part: .left)
        }
        if ownName.contains("右耳") || ownName.contains("right") || ownName.contains("🅁") {
            return airPodsSymbolName(in: haystack, part: .right)
        }
        return airPodsSymbolName(in: haystack, part: .all)
    case .bluetooth, .magicAccessory, .other:
        if containsAny(haystack, ["iphone", "phone", "mobile phone", "手机"]) {
            return "iphone.gen2"
        }
        if containsAny(haystack, ["ipad", "tablet", "平板"]) {
            return "ipad"
        }
        if containsAny(haystack, ["watch", "手表"]) {
            return "applewatch"
        }
        if haystack.contains("vision") {
            return "visionpro"
        }
        if containsAny(haystack, ["macbook", "mac book", "notebook", "laptop"]) {
            return "macbook"
        }
        if containsAny(haystack, ["mac mini", "macmini"]) {
            return "macmini"
        }
        if containsAny(haystack, ["imac", "desktop computer"]) {
            return "desktopcomputer"
        }
        if containsAny(haystack, ["magic mouse", "magicmouse"]) {
            return "magicmouse.fill"
        }
        if containsAny(haystack, ["mouse", "pointing", "鼠标", "mx anywhere", "mx master", "razer"]) {
            return "computermouse.fill"
        }
        if containsAny(haystack, ["keyboard", "键盘", "hhkb", "niz"]) {
            return "keyboard.fill"
        }
        if containsAny(haystack, ["trackpad", "touchpad", "触控板"]) {
            return "rectangle.and.hand.point.up.left.fill"
        }
        if containsAny(haystack, ["airpods"]) {
            return airPodsSymbolName(in: haystack, part: .all)
        }
        if containsAny(haystack, ["beats", "headphone", "headphones", "headset", "earbud", "earbuds", "耳机"]) {
            return "headphones"
        }
        if containsAny(haystack, ["gamepad", "controller", "joystick", "手柄"]) {
            return "gamecontroller.fill"
        }
        if containsAny(haystack, ["speaker", "音箱", "扬声器"]) {
            return "hifispeaker.fill"
        }
        if containsAny(haystack, ["printer", "打印机"]) {
            return "printer.fill"
        }
        if containsAny(haystack, ["camera", "摄像头", "相机"]) {
            return "camera.fill"
        }
        return item.kind.iconName
    }
}

private func containsAny(_ text: String, _ needles: [String]) -> Bool {
    needles.contains { text.contains($0) }
}

private enum DeviceBatteryAirPodsPart {
    case all
    case left
    case right
    case `case`
}

private func airPodsSymbolName(
    in haystack: String,
    part: DeviceBatteryAirPodsPart
) -> String {
    if haystack.contains("airpods max") {
        return availableSystemSymbolName(["airpods.max", "airpodsmax"])
    }

    if isAirPodsPro(in: haystack) {
        switch part {
        case .all:
            return "airpodspro"
        case .left:
            return "airpodpro.left"
        case .right:
            return "airpodpro.right"
        case .case:
            return "airpodspro.chargingcase.wireless"
        }
    }

    if isAirPodsGeneration(4, in: haystack) {
        switch part {
        case .all:
            return availableSystemSymbolName(["airpods.gen4", "airpods"])
        case .left:
            return availableSystemSymbolName(["airpods.gen4.left", "airpod.left"])
        case .right:
            return availableSystemSymbolName(["airpods.gen4.right", "airpod.right"])
        case .case:
            return availableSystemSymbolName(["airpods.gen4.chargingcase.wireless", "airpods.chargingcase"])
        }
    }

    if isAirPodsGeneration(3, in: haystack) {
        switch part {
        case .all:
            return availableSystemSymbolName(["airpods.gen3", "airpods"])
        case .left:
            return availableSystemSymbolName(["airpod.gen3.left", "airpod.left"])
        case .right:
            return availableSystemSymbolName(["airpod.gen3.right", "airpod.right"])
        case .case:
            return availableSystemSymbolName(["airpods.gen3.chargingcase.wireless", "airpods.chargingcase"])
        }
    }

    switch part {
    case .all:
        return "airpods"
    case .left:
        return "airpod.left"
    case .right:
        return "airpod.right"
    case .case:
        return "airpods.chargingcase"
    }
}

private func isAirPodsPro(in haystack: String) -> Bool {
    haystack.contains("airpods pro") || haystack.contains("airpodspro")
}

private func isAirPodsGeneration(_ generation: Int, in haystack: String) -> Bool {
    let compact = haystack.replacingOccurrences(of: " ", with: "")
    return haystack.contains("airpods \(generation)")
        || haystack.contains("airpods gen\(generation)")
        || haystack.contains("airpods gen \(generation)")
        || haystack.contains("airpods.gen\(generation)")
        || compact.contains("airpods\(generation)")
        || compact.contains("第\(generation)代")
}

private func availableSystemSymbolName(_ candidates: [String]) -> String {
    for candidate in candidates {
        if NSImage(systemSymbolName: candidate, accessibilityDescription: nil) != nil {
            return candidate
        }
    }

    return candidates.last ?? "airpods"
}

private func helpText(
    for item: DeviceBatteryItem,
    localization: PluginLocalization = PluginLocalization(bundle: .main)
) -> String {
    var lines = [
        item.name,
        localization.format(
            "help.levelAndState",
            defaultValue: "%@ · %@",
            DeviceBatteryFormatter.percent(item.clampedLevel),
            item.chargeState.title(localization: localization)
        ),
        localization.format("help.source", defaultValue: "来源：%@", item.source)
    ]
    if let parentName = item.parentName {
        lines.append(localization.format("help.parent", defaultValue: "关联：%@", parentName))
    }
    if let lastUpdated = item.lastUpdated {
        lines.append(
            localization.format(
                "help.updated",
                defaultValue: "更新：%@",
                DeviceBatteryFormatter.time(lastUpdated, localization: localization)
            )
        )
    }
    return lines.joined(separator: "\n")
}
