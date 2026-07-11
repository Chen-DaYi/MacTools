import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

private enum MenuBarIconSettingsMetrics {
    static let recentPreviewHeight: CGFloat = 44
    static let recentTileSize = CGSize(width: 58, height: 58)
    static let recentBadgeSize: CGFloat = 18

    static let galleryColumnWidth: CGFloat = 128
    static let galleryColumnSpacing: CGFloat = 10
    static let galleryColumnCount = 4
    static let galleryContentWidth: CGFloat = 554
    static let galleryContentHeight: CGFloat = 340
    static let galleryPopoverWidth: CGFloat = 582
    static let galleryPreviewHeight: CGFloat = 34
    static let galleryPreviewMaxWidth: CGFloat = 122
    static let galleryTileSize = CGSize(width: 128, height: 52)
    static let galleryCellSize = CGSize(width: 128, height: 82)
    static let galleryTitleWidth: CGFloat = 120
}

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
    @AppStorage(AppLanguagePreference.userDefaultsKey) private var languagePreferenceRawValue = AppLanguagePreference.system.rawValue
    @State private var sliderID = UUID()

    private let rowLabelWidth: CGFloat = 76
    private let contentMaxWidth: CGFloat = 520
    private let animationModePickerWidth: CGFloat = 240
    private let manualSpeedSliderWidth: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controlRow(AppL10n.settings("menuBarIcon.source", defaultValue: "图标来源")) {
                actionButtons
            }

            contentOnlyRow {
                Text(AppL10n.settings(
                    "menuBarIcon.sourceDescription",
                    defaultValue: "支持图片、轻量 GIF/MP4 和在线动态图标；导入时会自动扣除纯色背景。"
                ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: contentMaxWidth, alignment: .leading)
            }

            animationSpeedControls

            controlRow(AppL10n.settings("menuBarIcon.recent", defaultValue: "最近使用"), alignment: .top) {
                MenuBarIconRecentGrid(iconSettings: iconSettings, gallery: gallery)
                    .frame(maxWidth: contentMaxWidth, alignment: .leading)
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
                .frame(maxWidth: contentMaxWidth, alignment: .leading)
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

            MenuBarIconGalleryPicker(iconSettings: iconSettings, gallery: gallery)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: contentMaxWidth, alignment: .leading)
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
                .frame(maxWidth: contentMaxWidth, alignment: .leading)
                .id(languagePreferenceRawValue)
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
        .frame(maxWidth: contentMaxWidth, minHeight: PluginSettingsTheme.Size.controlHeight, alignment: .leading)
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
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(iconSettings.recentItems.prefix(6)) { item in
                            recentItemButton(for: item)
                        }
                    }
                    .frame(minHeight: MenuBarIconSettingsMetrics.recentTileSize.height, alignment: .leading)
                }
                .scrollIndicators(.never)
                .frame(maxWidth: .infinity, minHeight: MenuBarIconSettingsMetrics.recentTileSize.height, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentItemButton(for item: MenuBarIconRecentItem) -> some View {
        let previewImage = iconSettings.previewImage(for: item)

        return Button {
            Task {
                activeRecentID = item.id
                _ = await gallery.selectRecentItem(item, iconSettings: iconSettings)
                activeRecentID = nil
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                MenuBarIconThumbnail(
                    image: previewImage,
                    height: MenuBarIconSettingsMetrics.recentPreviewHeight,
                    maxWidth: nil
                )
                .frame(
                    minWidth: MenuBarIconSettingsMetrics.recentTileSize.width,
                    minHeight: MenuBarIconSettingsMetrics.recentTileSize.height
                )
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

    @ViewBuilder
    private func badge(for item: MenuBarIconRecentItem) -> some View {
        if activeRecentID == item.id {
            ProgressView()
                .controlSize(.small)
                .frame(width: MenuBarIconSettingsMetrics.recentBadgeSize, height: MenuBarIconSettingsMetrics.recentBadgeSize)
                .background(.thinMaterial, in: Circle())
        } else if iconSettings.remoteAssetSelection(forRecentItem: item) != nil,
                  !iconSettings.isRemoteAssetCached(for: item) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: MenuBarIconSettingsMetrics.recentBadgeSize, height: MenuBarIconSettingsMetrics.recentBadgeSize)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(Circle())
        } else if item.mediaKind == .animation {
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: MenuBarIconSettingsMetrics.recentBadgeSize, height: MenuBarIconSettingsMetrics.recentBadgeSize)
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
        .frame(width: MenuBarIconSettingsMetrics.galleryPopoverWidth)
    }

    @ViewBuilder
    private var content: some View {
        if gallery.status.isLoading && gallery.assets.isEmpty {
            ProgressView()
                .frame(
                    width: MenuBarIconSettingsMetrics.galleryContentWidth,
                    height: MenuBarIconSettingsMetrics.galleryContentHeight
                )
        } else if gallery.assets.isEmpty {
            ContentUnavailableView(
                AppL10n.settings("menuBarIcon.gallery.unavailable", defaultValue: "图库不可用"),
                systemImage: "wifi.exclamationmark",
                description: Text(gallery.lastErrorMessage ?? AppL10n.settings("menuBarIcon.gallery.tryLater", defaultValue: "稍后再试。"))
            )
            .frame(
                width: MenuBarIconSettingsMetrics.galleryContentWidth,
                height: MenuBarIconSettingsMetrics.galleryContentHeight
            )
        } else {
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(
                            .fixed(MenuBarIconSettingsMetrics.galleryColumnWidth),
                            spacing: MenuBarIconSettingsMetrics.galleryColumnSpacing
                        ),
                        count: MenuBarIconSettingsMetrics.galleryColumnCount
                    ),
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
            .frame(
                width: MenuBarIconSettingsMetrics.galleryContentWidth,
                height: MenuBarIconSettingsMetrics.galleryContentHeight
            )
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
                    .frame(
                        width: MenuBarIconSettingsMetrics.galleryTileSize.width,
                        height: MenuBarIconSettingsMetrics.galleryTileSize.height
                    )
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
                .frame(width: MenuBarIconSettingsMetrics.galleryTitleWidth)
        }
        .frame(
            width: MenuBarIconSettingsMetrics.galleryCellSize.width,
            height: MenuBarIconSettingsMetrics.galleryCellSize.height
        )
    }

    @ViewBuilder
    private var preview: some View {
        if let previewImage {
            MenuBarIconThumbnail(
                image: previewImage,
                height: MenuBarIconSettingsMetrics.galleryPreviewHeight,
                maxWidth: MenuBarIconSettingsMetrics.galleryPreviewMaxWidth
            )
        } else {
            MenuBarIconThumbnail(
                image: nil,
                height: MenuBarIconSettingsMetrics.galleryPreviewHeight,
                maxWidth: MenuBarIconSettingsMetrics.galleryPreviewMaxWidth
            )
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

private struct MenuBarIconThumbnail: View {
    let image: NSImage?
    let height: CGFloat
    let maxWidth: CGFloat?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(height: height)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: height, height: height)
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: height)
    }
}
