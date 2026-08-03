import Foundation
import OSLog

enum AppDeepLink: Equatable {
    enum SettingsDestination: Equatable {
        case root
        case general
        case about
        case pluginMarketplace
        case pluginConfiguration(String)
    }

    enum PanelDestination: Equatable {
        case dashboard
        case feature
    }

    case settings(SettingsDestination)
    case panel(PanelDestination)
    case search

    var presentationRequest: AppPresentationRequest {
        switch self {
        case .settings(.root):
            return .settings(.settings)
        case .settings(.general):
            return .settings(.general)
        case .settings(.about):
            return .settings(.about)
        case .settings(.pluginMarketplace):
            return .settings(.pluginMarketplace)
        case let .settings(.pluginConfiguration(pluginID)):
            return .settings(.pluginConfiguration(pluginID))
        case .panel(.dashboard):
            return .showDashboard
        case .panel(.feature):
            return .showFeaturePanel
        case .search:
            return .showUnifiedSearch
        }
    }
}

enum AppURLRoutingError: Error, Equatable {
    case malformedURL
    case oversizedInput
    case unsupportedScheme
    case unsupportedHost
    case unsupportedRoute
    case unsupportedURLComponents
    case duplicatedParameter(String)
    case malformedPluginID
    case unavailablePlugin(String)
    case pendingQueueFull

    var diagnosticCode: String {
        switch self {
        case .malformedURL:
            return "malformed-url"
        case .oversizedInput:
            return "oversized-input"
        case .unsupportedScheme:
            return "unsupported-scheme"
        case .unsupportedHost:
            return "unsupported-host"
        case .unsupportedRoute:
            return "unsupported-route"
        case .unsupportedURLComponents:
            return "unsupported-url-components"
        case .duplicatedParameter:
            return "duplicated-parameter"
        case .malformedPluginID:
            return "malformed-plugin-id"
        case .unavailablePlugin:
            return "unavailable-plugin"
        case .pendingQueueFull:
            return "pending-queue-full"
        }
    }
}

enum AppURLHandlingResult: Equatable {
    case delegatedToRightClick
    case queued(AppDeepLink)
    case handled(AppDeepLink)
    case rejected(AppURLRoutingError)
}

enum AppDeepLinkParser {
    static let maximumURLByteCount = 4 * 1_024

    static func parse(
        _ url: URL,
        acceptedSchemes: Set<String>
    ) -> Result<AppDeepLink, AppURLRoutingError> {
        guard url.absoluteString.utf8.count <= maximumURLByteCount else {
            return .failure(.oversizedInput)
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else {
            return .failure(.malformedURL)
        }

        let normalizedSchemes = Set(acceptedSchemes.map { $0.lowercased() })
        guard normalizedSchemes.contains(scheme) else {
            return .failure(.unsupportedScheme)
        }

        guard components.host?.lowercased() == "app" else {
            return .failure(.unsupportedHost)
        }

        guard hasExactAppAuthority(url, scheme: scheme) else {
            return .failure(.unsupportedURLComponents)
        }

        guard components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil else {
            return .failure(.unsupportedURLComponents)
        }

        guard components.percentEncodedQuery == nil || components.queryItems != nil else {
            return .failure(.malformedURL)
        }

        var queryNames: Set<String> = []
        for item in components.queryItems ?? [] {
            guard !item.name.isEmpty else {
                return .failure(.unsupportedURLComponents)
            }
            guard queryNames.insert(item.name).inserted else {
                return .failure(.duplicatedParameter(item.name))
            }
        }

        guard components.path.hasPrefix("/"), !components.path.contains("//") else {
            return .failure(.unsupportedRoute)
        }

        var path = components.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }

        let pathComponents = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        switch pathComponents {
        case ["settings"]:
            return .success(.settings(.root))
        case ["settings", "general"]:
            return .success(.settings(.general))
        case ["settings", "about"]:
            return .success(.settings(.about))
        case ["settings", "plugins", "marketplace"]:
            return .success(.settings(.pluginMarketplace))
        case let components where components.count == 3
            && components[0] == "settings"
            && components[1] == "plugins":
            let pluginID = components[2]
            guard PluginPackageManifestLoader.isValidPluginID(pluginID) else {
                return .failure(.malformedPluginID)
            }
            return .success(.settings(.pluginConfiguration(pluginID)))
        case ["panels", "dashboard"]:
            return .success(.panel(.dashboard))
        case ["panels", "feature"]:
            return .success(.panel(.feature))
        case ["search"]:
            return .success(.search)
        default:
            return .failure(.unsupportedRoute)
        }
    }

    private static func hasExactAppAuthority(_ url: URL, scheme: String) -> Bool {
        let absoluteString = url.absoluteString
        guard let delimiter = absoluteString.range(of: "://") else {
            return false
        }

        let rawScheme = String(absoluteString[..<delimiter.lowerBound])
        guard rawScheme.caseInsensitiveCompare(scheme) == .orderedSame else {
            return false
        }

        let authorityStart = delimiter.upperBound
        let authorityEnd = absoluteString[authorityStart...].firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? absoluteString.endIndex
        let authority = String(absoluteString[authorityStart..<authorityEnd])
        return authority.caseInsensitiveCompare("app") == .orderedSame
    }
}

@MainActor
final class AppURLRouter {
    private let acceptedURLSchemes: Set<String>
    private let maximumPendingDeepLinks: Int
    private let rightClickHandler: (URL) -> Void
    private let logger: Logger

    private var pendingDeepLinks: [AppDeepLink] = []
    private var presentationHandler: ((AppPresentationRequest) -> Void)?
    private var isPluginConfigurationAvailable: ((String) -> Bool)?

    init(
        acceptedURLSchemes: Set<String> = RightClickURLRouter.bundleURLSchemes(),
        maximumPendingDeepLinks: Int = 32,
        rightClickHandler: @escaping (URL) -> Void = { RightClickURLRouter.shared.handle($0) },
        logger: Logger = AppLog.appURLRouter
    ) {
        precondition(maximumPendingDeepLinks > 0)
        self.acceptedURLSchemes = Set(acceptedURLSchemes.map { $0.lowercased() })
        self.maximumPendingDeepLinks = maximumPendingDeepLinks
        self.rightClickHandler = rightClickHandler
        self.logger = logger
    }

    @discardableResult
    func handle(_ urls: [URL]) -> [AppURLHandlingResult] {
        urls.map(handle)
    }

    @discardableResult
    func handle(_ url: URL) -> AppURLHandlingResult {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else {
            return reject(.malformedURL, url: url)
        }

        guard acceptedURLSchemes.contains(scheme) else {
            return reject(.unsupportedScheme, url: url)
        }

        if components.host?.lowercased() == "right-click" {
            rightClickHandler(url)
            return .delegatedToRightClick
        }

        switch AppDeepLinkParser.parse(url, acceptedSchemes: acceptedURLSchemes) {
        case let .failure(error):
            return reject(error, url: url)
        case let .success(deepLink):
            guard presentationHandler != nil else {
                guard pendingDeepLinks.count < maximumPendingDeepLinks else {
                    return reject(.pendingQueueFull, url: url)
                }
                pendingDeepLinks.append(deepLink)
                return .queued(deepLink)
            }
            return deliver(deepLink)
        }
    }

    @discardableResult
    func activate(
        presentationHandler: @escaping (AppPresentationRequest) -> Void,
        isPluginConfigurationAvailable: @escaping (String) -> Bool
    ) -> [AppURLHandlingResult] {
        guard self.presentationHandler == nil else {
            return []
        }

        self.presentationHandler = presentationHandler
        self.isPluginConfigurationAvailable = isPluginConfigurationAvailable

        let queuedDeepLinks = pendingDeepLinks
        pendingDeepLinks.removeAll(keepingCapacity: false)
        return queuedDeepLinks.map(deliver)
    }

    private func deliver(_ deepLink: AppDeepLink) -> AppURLHandlingResult {
        if case let .settings(.pluginConfiguration(pluginID)) = deepLink,
           isPluginConfigurationAvailable?(pluginID) != true {
            return reject(.unavailablePlugin(pluginID), deepLink: deepLink)
        }

        guard let presentationHandler else {
            return reject(.malformedURL, deepLink: deepLink)
        }

        presentationHandler(deepLink.presentationRequest)
        return .handled(deepLink)
    }

    private func reject(
        _ error: AppURLRoutingError,
        url _: URL
    ) -> AppURLHandlingResult {
        logger.error(
            "Rejected URL route: \(error.diagnosticCode, privacy: .public)"
        )
        return .rejected(error)
    }

    private func reject(
        _ error: AppURLRoutingError,
        deepLink _: AppDeepLink
    ) -> AppURLHandlingResult {
        logger.error(
            "Rejected parsed URL route: \(error.diagnosticCode, privacy: .public)"
        )
        return .rejected(error)
    }
}
