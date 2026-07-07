import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

struct MenuBarIconSettingsView: View {
    @ObservedObject var iconSettings: MenuBarIconSettings
    @ObservedObject var gallery: MenuBarIconGalleryLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            MenuBarIconEditorControls(iconSettings: iconSettings, gallery: gallery)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
    }

    private var header: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                Image(systemName: "menubar.rectangle")
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(AppL10n.settings("menuBarIcon.title", defaultValue: "菜单栏图标"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(AppL10n.settings(
                    "menuBarIcon.description",
                    defaultValue: "统一设置浅色和深色菜单栏图标，导入时会自动扣除纯色背景。"
                ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                iconSettings.resetToDefault()
            } label: {
                Label(AppL10n.settings("menuBarIcon.restoreDefault", defaultValue: "恢复默认"), systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!iconSettings.hasCustomIcon)
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .help(AppL10n.settings("menuBarIcon.help", defaultValue: "设置菜单栏图标"))
    }
}

private struct MenuBarIconEditorControls: View {
    @ObservedObject var iconSettings: MenuBarIconSettings
    @ObservedObject var gallery: MenuBarIconGalleryLibrary
    @State private var sliderID = UUID()

    private let rowLabelWidth: CGFloat = 76
    private let contentWidth: CGFloat = 520
    private let animationModePickerWidth: CGFloat = 240
    private let manualSpeedSliderWidth: CGFloat = 180
    private var sourceButtonWidth: CGFloat {
        (contentWidth - 8) / 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controlRow(AppL10n.settings("menuBarIcon.source", defaultValue: "图标来源")) {
                actionButtons
            }

            Text(AppL10n.settings(
                "menuBarIcon.sourceDescription",
                defaultValue: "支持图片、轻量 GIF/MP4 和在线动态图标；导入时会自动扣除纯色背景。"
            ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .frame(width: contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .trailing)

            animationSpeedControls

            controlRow(AppL10n.settings("menuBarIcon.recent", defaultValue: "最近使用"), alignment: .top) {
                MenuBarIconRecentGrid(iconSettings: iconSettings, gallery: gallery)
                    .frame(width: contentWidth, alignment: .leading)
            }

            if let warningText = iconSettings.contrastReport(for: .light).warningText
                ?? iconSettings.contrastReport(for: .dark).warningText {
                contentOnlyRow {
                    Label(warningText, systemImage: "exclamationmark.triangle")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.orange)
                }
            }

            if let errorMessage = iconSettings.lastErrorMessage {
                contentOnlyRow {
                    Label(errorMessage, systemImage: "xmark.circle")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func controlRow<Content: View>(
        _ title: String,
        alignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(title)
                .font(PluginSettingsTheme.Typography.secondaryLabel)
                .foregroundStyle(.secondary)
                .frame(width: rowLabelWidth, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contentOnlyRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Color.clear
                .frame(width: rowLabelWidth, height: 1)

            content()
                .frame(width: contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                selectMedia()
            } label: {
                Label(AppL10n.settings("menuBarIcon.upload", defaultValue: "上传图片或动画"), systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .frame(width: sourceButtonWidth)

            MenuBarIconGalleryPicker(iconSettings: iconSettings, gallery: gallery)
            .frame(width: sourceButtonWidth)
        }
        .frame(width: contentWidth, alignment: .leading)
    }

    private var animationSpeedControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            controlRow(AppL10n.settings("menuBarIcon.playbackSpeed", defaultValue: "播放速度")) {
                Picker(AppL10n.settings("menuBarIcon.playbackSpeed", defaultValue: "播放速度"), selection: Binding(
                    get: { iconSettings.animationSpeedMode },
                    set: { iconSettings.animationSpeedMode = $0 }
                )) {
                    ForEach(MenuBarIconAnimationSpeedMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: animationModePickerWidth, alignment: .leading)
                .frame(width: contentWidth, alignment: .leading)
            }

            controlRow(AppL10n.settings("menuBarIcon.multiplier", defaultValue: "倍率")) {
                animationMultiplierControls
            }
        }
    }

    private var speedDescription: String {
        switch iconSettings.animationSpeedMode {
        case .manual:
            return AppL10n.settings("menuBarIcon.speedDescription.manual", defaultValue: "固定倍率循环播放。")
        case .adaptiveSystemLoad:
            return AppL10n.settings("menuBarIcon.speedDescription.adaptiveSystemLoad", defaultValue: "CPU、GPU、内存越高越快。")
        }
    }

    private var animationMultiplierControls: some View {
        HStack(spacing: 12) {
            Text(speedDescription)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)

            manualSpeedSlider
                .opacity(isManualAnimationSpeed ? 1 : 0)
                .disabled(!isManualAnimationSpeed)

            Text(String(format: "%.1fx", iconSettings.manualAnimationSpeedMultiplier))
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
                .opacity(isManualAnimationSpeed ? 1 : 0)

            Spacer(minLength: 0)
        }
        .frame(width: contentWidth, height: PluginSettingsTheme.Size.controlHeight, alignment: .leading)
        .onAppear {
            DispatchQueue.main.async {
                sliderID = UUID()
            }
        }
    }

    private var isManualAnimationSpeed: Bool {
        iconSettings.animationSpeedMode == .manual
    }

    private var manualSpeedSlider: some View {
        Slider(
            value: Binding(
                get: { iconSettings.manualAnimationSpeedMultiplier },
                set: { iconSettings.manualAnimationSpeedMultiplier = $0 }
            ),
            in: MenuBarIconAnimationSpeedPolicy.minimumMultiplier...MenuBarIconAnimationSpeedPolicy.maximumMultiplier
        )
        .labelsHidden()
        .frame(width: manualSpeedSliderWidth)
        .id(sliderID)
    }

    private func selectMedia() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = MenuBarIconProcessing.supportedImageContentTypes
            + MenuBarIconProcessing.supportedAnimationContentTypes
        panel.message = AppL10n.settings(
            "menuBarIcon.openPanel.message",
            defaultValue: "选择图片、GIF 或 MP4 作为 MacTools 状态栏图标"
        )

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let contentType = UTType(filenameExtension: url.pathExtension)
        if let contentType,
           MenuBarIconProcessing.supportedAnimationContentTypes.contains(where: { contentType.conforms(to: $0) }) {
            Task {
                await iconSettings.importAnimation(from: url)
            }
        } else {
            iconSettings.importIcon(from: url)
        }
    }
}

private struct MenuBarIconPreviewPair: View {
    let lightPayload: MenuBarIconImagePayload
    let darkPayload: MenuBarIconImagePayload

    var body: some View {
        HStack(spacing: 8) {
            MenuBarIconPreviewStrip(
                title: AppL10n.settings("menuBarIcon.preview.light", defaultValue: "浅色"),
                payload: lightPayload,
                backgroundColor: Color(nsColor: .windowBackgroundColor),
                foregroundColor: .black
            )
            .frame(maxWidth: .infinity)

            MenuBarIconPreviewStrip(
                title: AppL10n.settings("menuBarIcon.preview.dark", defaultValue: "深色"),
                payload: darkPayload,
                backgroundColor: Color(red: 0.12, green: 0.12, blue: 0.13),
                foregroundColor: .white
            )
            .frame(maxWidth: .infinity)
        }
    }
}

private struct MenuBarIconPreviewStrip: View {
    let title: String
    let payload: MenuBarIconImagePayload
    let backgroundColor: Color
    let foregroundColor: Color

    private var frameDuration: TimeInterval {
        switch payload.speedMode {
        case .manual:
            return max(payload.frameDuration / payload.manualSpeedMultiplier, 1.0 / 30.0)
        case .adaptiveSystemLoad:
            return max(payload.frameDuration, 1.0 / 30.0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Circle()
                    .fill(.yellow)
                    .frame(width: 8, height: 8)
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)

                Spacer()

                TimelineView(.periodic(from: .now, by: frameDuration)) { context in
                    Image(nsImage: frame(for: context.date))
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(foregroundColor)
                        .frame(width: 18, height: 18)
                }
                .frame(width: 18, height: 18)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func frame(for date: Date) -> NSImage {
        guard payload.animationFrames.count > 1 else {
            return payload.image
        }

        let frameIndex = Int(date.timeIntervalSinceReferenceDate / frameDuration) % payload.animationFrames.count
        return payload.animationFrames[frameIndex]
    }
}

private struct MenuBarIconRecentGrid: View {
    @ObservedObject var iconSettings: MenuBarIconSettings
    @ObservedObject var gallery: MenuBarIconGalleryLibrary
    @State private var activeRecentID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if iconSettings.recentItems.isEmpty {
                Text(AppL10n.settings("menuBarIcon.recent.empty", defaultValue: "上传或选择图标后会显示在这里。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    ForEach(iconSettings.recentItems.prefix(6)) { item in
                        Button {
                            Task {
                                activeRecentID = item.id
                                _ = await gallery.selectRecentItem(item, iconSettings: iconSettings)
                                activeRecentID = nil
                            }
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                Image(nsImage: iconSettings.previewImage(for: item))
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 20, height: 20)
                                    .frame(width: 42, height: 42)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                    )

                                badge(for: item)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(activeRecentID != nil)
                        .help(item.displayName)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func badge(for item: MenuBarIconRecentItem) -> some View {
        if activeRecentID == item.id {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
                .background(.thinMaterial, in: Circle())
        } else if iconSettings.remoteAssetSelection(forRecentItem: item) != nil,
                  !iconSettings.isRemoteAssetCached(for: item) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(Circle())
        } else if item.mediaKind == .animation {
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(Color.accentColor)
                .clipShape(Circle())
        }
    }
}

private struct MenuBarIconGalleryPicker: View {
    @ObservedObject var iconSettings: MenuBarIconSettings
    @ObservedObject var gallery: MenuBarIconGalleryLibrary
    @State private var selectedCategoryID: String?
    @State private var isPickerPresented = false
    @State private var activeAssetID: String?

    private var selectedCategory: String? {
        selectedCategoryID ?? gallery.categories.first?.id
    }

    private var filteredAssets: [MenuBarIconGalleryAsset] {
        guard let selectedCategory else {
            return []
        }

        return gallery.assets.filter { asset in
            asset.categoryID == selectedCategory
        }
    }

    var body: some View {
        Button {
            isPickerPresented.toggle()
        } label: {
            Label(AppL10n.settings("menuBarIcon.gallery.title", defaultValue: "在线图库"), systemImage: "sparkles")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            pickerContent
                .task {
                    await gallery.loadCatalogIfNeeded()
                    if selectedCategoryID == nil {
                        selectedCategoryID = gallery.categories.first?.id
                    }
                }
        }
    }

    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(AppL10n.settings("menuBarIcon.gallery.title", defaultValue: "在线图库"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Spacer()

                if gallery.status.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                }

                Button {
                    Task {
                        await gallery.refreshCatalog()
                        selectedCategoryID = selectedCategoryID ?? gallery.categories.first?.id
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(AppL10n.settings("menuBarIcon.gallery.refresh", defaultValue: "刷新图库"))
                .disabled(gallery.status.isLoading)

                Picker(AppL10n.settings("menuBarIcon.gallery.category", defaultValue: "分组"), selection: Binding(
                    get: { selectedCategoryID ?? gallery.categories.first?.id ?? "" },
                    set: { selectedCategoryID = $0 }
                )) {
                    ForEach(gallery.categories) { category in
                        Text(category.title).tag(category.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)
                .disabled(gallery.categories.isEmpty)
            }

            content
        }
        .padding(14)
        .frame(width: 488)
    }

    @ViewBuilder
    private var content: some View {
        if gallery.status.isLoading && gallery.assets.isEmpty {
            ProgressView()
                .frame(width: 460, height: 300)
        } else if gallery.assets.isEmpty {
            ContentUnavailableView(
                AppL10n.settings("menuBarIcon.gallery.unavailable", defaultValue: "图库不可用"),
                systemImage: "wifi.exclamationmark",
                description: Text(gallery.lastErrorMessage ?? AppL10n.settings("menuBarIcon.gallery.tryLater", defaultValue: "稍后再试。"))
            )
            .frame(width: 460, height: 300)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(70), spacing: 8), count: 6),
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(filteredAssets) { asset in
                        Button {
                            Task {
                                activeAssetID = asset.id
                                let didSelect = await gallery.selectAsset(asset, iconSettings: iconSettings)
                                activeAssetID = nil
                                if didSelect {
                                    isPickerPresented = false
                                }
                            }
                        } label: {
                            MenuBarIconGalleryAssetCell(
                                asset: asset,
                                state: gallery.state(for: asset),
                                previewImage: gallery.previewImage(for: asset),
                                isBusy: activeAssetID == asset.id,
                                isSelected: iconSettings.selectedRemoteAsset?.id == asset.id
                                    && iconSettings.selectedRemoteAsset?.version == asset.version
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(activeAssetID != nil)
                        .help(AppL10n.settingsFormat("menuBarIcon.gallery.useAssetFormat", defaultValue: "使用 %@", asset.title))
                        .task {
                            await gallery.loadPreviewIfNeeded(for: asset)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(width: 460, height: 300)
        }
    }
}

private struct MenuBarIconGalleryAssetCell: View {
    let asset: MenuBarIconGalleryAsset
    let state: MenuBarIconGalleryAssetState
    let previewImage: NSImage?
    let isBusy: Bool
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                preview
                    .frame(width: 32, height: 20)
                    .frame(width: 54, height: 34)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
                    )

                badge
            }

            Text(asset.title)
                .font(PluginSettingsTheme.Typography.statusBadge)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 64)
        }
        .frame(width: 70, height: 64)
    }

    @ViewBuilder
    private var preview: some View {
        if let previewImage {
            Image(nsImage: previewImage)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
        } else {
            Image(systemName: "photo")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var badge: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(Circle())
        } else {
            switch state {
            case .cached:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(Circle())
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.orange)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(Circle())
            case .downloading:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(Circle())
            case .available:
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(Circle())
            }
        }
    }

    private var borderColor: Color {
        isSelected ? .accentColor : Color.primary.opacity(0.1)
    }
}
