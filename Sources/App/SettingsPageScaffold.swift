import SwiftUI
import MacToolsPluginKit

enum SettingsPageWidthPolicy {
    case standard
    case general

    var maximumContentWidth: CGFloat {
        switch self {
        case .standard:
            // Complex plugin workspaces and tables can use the wider column.
            960
        case .general:
            // Ordinary preferences benefit from a denser macOS-style column.
            720
        }
    }
}

enum SettingsPageLayout {
    static let horizontalInset: CGFloat = 20
    static let verticalInset: CGFloat = 24
    static let headerContentSpacing: CGFloat = 20

    /// A grouped Form adds 10pt of native card chrome on each side of an
    /// explicitly sized direct row. The host owns this adjustment so plugins
    /// only describe sections and the visible card follows the outer guide.
    static let groupedSectionHorizontalChrome: CGFloat = 20

    static func readableContentWidth(
        for viewportWidth: CGFloat,
        policy: SettingsPageWidthPolicy = .standard
    ) -> CGFloat {
        min(
            max(viewportWidth - horizontalInset * 2, 0),
            policy.maximumContentWidth
        )
    }

    static func groupedSectionLayoutWidth(
        for viewportWidth: CGFloat,
        policy: SettingsPageWidthPolicy = .standard
    ) -> CGFloat {
        max(
            readableContentWidth(
                for: viewportWidth,
                policy: policy
            ) - groupedSectionHorizontalChrome,
            0
        )
    }
}

struct SettingsPageHeaderConfiguration {
    let title: String
    let description: String
    let systemImage: String
    let iconTint: Color
    let descriptionColor: Color

    init(
        title: String,
        description: String,
        systemImage: String,
        iconTint: Color,
        descriptionColor: Color = .secondary
    ) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.iconTint = iconTint
        self.descriptionColor = descriptionColor
    }
}

/// The page shell for readable settings workspaces. It owns the semantic
/// window background, shared content guide, and page header; scrolling remains
/// the responsibility of the supplied content container.
struct SettingsPageScaffold<HeaderAccessory: View, Content: View>: View {
    let header: SettingsPageHeaderConfiguration
    private let widthPolicy: SettingsPageWidthPolicy
    private let headerAccessory: HeaderAccessory
    private let content: Content

    init(
        header: SettingsPageHeaderConfiguration,
        widthPolicy: SettingsPageWidthPolicy = .standard,
        @ViewBuilder headerAccessory: () -> HeaderAccessory,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.widthPolicy = widthPolicy
        self.headerAccessory = headerAccessory()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: SettingsPageLayout.headerContentSpacing) {
            SettingsPageHeaderContent(
                configuration: header,
                accessory: headerAccessory
            )

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(
            maxWidth: widthPolicy.maximumContentWidth,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .padding(.horizontal, SettingsPageLayout.horizontalInset)
        .padding(.vertical, SettingsPageLayout.verticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SettingsStyle.contentBackground, ignoresSafeAreaEdges: .all)
    }
}

/// The page shell for native grouped forms. The header stays outside Form so
/// every plugin page shares the same title-to-content spacing, while Form
/// continues to own native cards, section spacing, keyboard focus,
/// accessibility, and content scrolling.
struct SettingsGroupedFormPageScaffold<HeaderAccessory: View, Content: View>: View {
    let header: SettingsPageHeaderConfiguration
    private let widthPolicy: SettingsPageWidthPolicy
    private let headerAccessory: HeaderAccessory
    private let content: (SettingsGroupedFormWidths) -> Content

    init(
        header: SettingsPageHeaderConfiguration,
        widthPolicy: SettingsPageWidthPolicy = .standard,
        @ViewBuilder headerAccessory: () -> HeaderAccessory,
        @ViewBuilder content: @escaping (SettingsGroupedFormWidths) -> Content
    ) {
        self.header = header
        self.widthPolicy = widthPolicy
        self.headerAccessory = headerAccessory()
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let widths = SettingsGroupedFormWidths(
                viewportWidth: geometry.size.width,
                widthPolicy: widthPolicy
            )

            VStack(spacing: 0) {
                SettingsPageHeaderContent(
                    configuration: header,
                    accessory: headerAccessory
                )
                .frame(width: widths.readableContent)
                .padding(.top, SettingsPageLayout.verticalInset)
                .padding(.bottom, SettingsPageLayout.headerContentSpacing)

                Form {
                    content(widths)
                }
                .settingsGroupedFormStyle()
                .contentMargins(.top, 0, for: .scrollContent)
                .contentMargins(
                    .bottom,
                    SettingsPageLayout.verticalInset,
                    for: .scrollContent
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(SettingsStyle.contentBackground, ignoresSafeAreaEdges: .all)
    }
}

struct SettingsGroupedFormWidths {
    let readableContent: CGFloat
    let sectionLayout: CGFloat

    init(
        viewportWidth: CGFloat,
        widthPolicy: SettingsPageWidthPolicy
    ) {
        readableContent = SettingsPageLayout.readableContentWidth(
            for: viewportWidth,
            policy: widthPolicy
        )
        sectionLayout = SettingsPageLayout.groupedSectionLayoutWidth(
            for: viewportWidth,
            policy: widthPolicy
        )
    }
}

struct SettingsGroupedFormLayout<Content: View>: View {
    private let widthPolicy: SettingsPageWidthPolicy
    private let content: (SettingsGroupedFormWidths) -> Content

    init(
        widthPolicy: SettingsPageWidthPolicy = .standard,
        @ViewBuilder content: @escaping (SettingsGroupedFormWidths) -> Content
    ) {
        self.widthPolicy = widthPolicy
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let widths = SettingsGroupedFormWidths(
                viewportWidth: geometry.size.width,
                widthPolicy: widthPolicy
            )

            Form {
                content(widths)
            }
            .settingsGroupedFormStyle()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsStyle.contentBackground, ignoresSafeAreaEdges: .all)
    }
}

extension View {
    func settingsGroupedFormRowWidth(_ width: CGFloat) -> some View {
        frame(width: width)
    }
}

extension SettingsGroupedFormPageScaffold where HeaderAccessory == EmptyView {
    init(
        header: SettingsPageHeaderConfiguration,
        widthPolicy: SettingsPageWidthPolicy = .standard,
        @ViewBuilder content: @escaping (SettingsGroupedFormWidths) -> Content
    ) {
        self.init(
            header: header,
            widthPolicy: widthPolicy,
            headerAccessory: { EmptyView() },
            content: content
        )
    }
}

extension SettingsPageScaffold where HeaderAccessory == EmptyView {
    init(
        header: SettingsPageHeaderConfiguration,
        widthPolicy: SettingsPageWidthPolicy = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            header: header,
            widthPolicy: widthPolicy,
            headerAccessory: { EmptyView() },
            content: content
        )
    }
}

struct SettingsPageHeader: View {
    let configuration: SettingsPageHeaderConfiguration

    init(configuration: SettingsPageHeaderConfiguration) {
        self.configuration = configuration
    }

    init(
        title: String,
        description: String,
        systemImage: String,
        iconTint: Color
    ) {
        configuration = SettingsPageHeaderConfiguration(
            title: title,
            description: description,
            systemImage: systemImage,
            iconTint: iconTint
        )
    }

    var body: some View {
        SettingsPageHeaderCore(configuration: configuration)
    }
}

/// A single header treatment for every grouped Form section owned by the host.
/// The explicit outer width keeps first and later headers aligned while direct
/// rows independently report the narrower width needed by native card chrome.
struct SettingsGroupedFormSectionHeader<Accessory: View>: View {
    let title: String?
    let systemImage: String?
    let layoutWidth: CGFloat
    private let accessory: Accessory

    init(
        title: String?,
        systemImage: String? = nil,
        layoutWidth: CGFloat,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.systemImage = systemImage
        self.layoutWidth = layoutWidth
        self.accessory = accessory()
    }

    var body: some View {
        HStack(
            alignment: .center,
            spacing: PluginSettingsTheme.Spacing.controlCluster
        ) {
            if let title {
                sectionLabel(title)
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.controlCluster)
            accessory
        }
        .frame(width: layoutWidth, alignment: .leading)
        .textCase(nil)
    }

    @ViewBuilder
    private func sectionLabel(_ title: String) -> some View {
        if let systemImage {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .frame(width: PluginSettingsTheme.Size.rowIcon)
            }
        } else {
            Text(title)
        }
    }
}

extension SettingsGroupedFormSectionHeader where Accessory == EmptyView {
    init(
        title: String?,
        systemImage: String? = nil,
        layoutWidth: CGFloat
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            layoutWidth: layoutWidth,
            accessory: { EmptyView() }
        )
    }
}

private struct SettingsPageHeaderContent<Accessory: View>: View {
    let configuration: SettingsPageHeaderConfiguration
    let accessory: Accessory

    var body: some View {
        HStack(
            alignment: .center,
            spacing: PluginSettingsTheme.Spacing.rowContentControl
        ) {
            SettingsPageHeaderCore(configuration: configuration)
            Spacer(minLength: PluginSettingsTheme.Spacing.controlCluster)
            accessory
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsPageHeaderCore: View {
    let configuration: SettingsPageHeaderConfiguration

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.iconTint.opacity(0.14))

                Image(systemName: configuration.systemImage)
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(configuration.iconTint)
            }
            .frame(width: PluginSettingsTheme.Size.pageIcon, height: PluginSettingsTheme.Size.pageIcon)

            VStack(alignment: .leading, spacing: 4) {
                Text(configuration.title)
                    .font(PluginSettingsTheme.Typography.pageTitle)
                    .foregroundStyle(.primary)

                Text(configuration.description)
                    .font(PluginSettingsTheme.Typography.pageDescription)
                    .foregroundStyle(configuration.descriptionColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
extension Form {
    /// Makes the grouped form share the scaffold's semantic window background
    /// while preserving native section cards and row styling.
    func settingsGroupedFormStyle() -> some View {
        self
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
    }
}
