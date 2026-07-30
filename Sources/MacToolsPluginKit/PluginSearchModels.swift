import SwiftUI

public struct PluginSettingsSearchEntry: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let description: String
    public let keywords: [String]
    public let systemImage: String

    public init(
        id: String,
        title: String,
        description: String,
        keywords: [String] = [],
        systemImage: String = "slider.horizontal.3"
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.keywords = keywords
        self.systemImage = systemImage
    }
}

@MainActor
public protocol PluginSettingsSearchProviding: AnyObject {
    var settingsSearchEntries: [PluginSettingsSearchEntry] { get }
}

public struct PluginCommandDefinition: Identifiable, Hashable {
    public struct Confirmation: Hashable {
        public let title: String
        public let message: String
        public let confirmButtonTitle: String

        public init(title: String, message: String, confirmButtonTitle: String) {
            self.title = title
            self.message = message
            self.confirmButtonTitle = confirmButtonTitle
        }
    }

    public let id: String
    public let title: String
    public let description: String
    public let keywords: [String]
    public let systemImage: String
    public let confirmation: Confirmation?

    public init(
        id: String,
        title: String,
        description: String,
        keywords: [String] = [],
        systemImage: String,
        confirmation: Confirmation? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.keywords = keywords
        self.systemImage = systemImage
        self.confirmation = confirmation
    }
}

@MainActor
public protocol PluginCommandProviding: AnyObject {
    var commandDefinitions: [PluginCommandDefinition] { get }

    func handleCommand(id: String)
}

public struct PluginSettingsSearchTarget: Hashable, Sendable {
    public let pluginID: String
    public let entryID: String

    public init(pluginID: String, entryID: String) {
        self.pluginID = pluginID
        self.entryID = entryID
    }

    public var scrollID: String {
        "plugin-search-anchor.\(pluginID).\(entryID)"
    }
}

private struct PluginSettingsSearchTargetEnvironmentKey: EnvironmentKey {
    static let defaultValue: PluginSettingsSearchTarget? = nil
}

public extension EnvironmentValues {
    var pluginSettingsSearchTarget: PluginSettingsSearchTarget? {
        get { self[PluginSettingsSearchTargetEnvironmentKey.self] }
        set { self[PluginSettingsSearchTargetEnvironmentKey.self] = newValue }
    }
}

private struct PluginSettingsSearchAnchorModifier: ViewModifier {
    @Environment(\.pluginSettingsSearchTarget) private var activeTarget
    @AccessibilityFocusState private var isAccessibilityFocused: Bool

    let target: PluginSettingsSearchTarget

    func body(content: Content) -> some View {
        content
            .id(target.scrollID)
            .accessibilityFocused($isAccessibilityFocused)
            .overlay {
                if activeTarget == target {
                    RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onAppear {
                focusIfNeeded(activeTarget)
            }
            .onChange(of: activeTarget) { _, newValue in
                focusIfNeeded(newValue)
            }
    }

    private func focusIfNeeded(_ activeTarget: PluginSettingsSearchTarget?) {
        guard activeTarget == target else {
            return
        }

        isAccessibilityFocused = true
    }
}

public extension View {
    func pluginSettingsSearchAnchor(pluginID: String, entryID: String) -> some View {
        modifier(
            PluginSettingsSearchAnchorModifier(
                target: PluginSettingsSearchTarget(pluginID: pluginID, entryID: entryID)
            )
        )
    }
}
