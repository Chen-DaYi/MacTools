import Foundation
import OSLog
import MacToolsPluginKit

enum AppDeepLink: Equatable {
    enum SettingsDestination: Equatable {
        case root
        case general
        case about
        case actionsAndShortcuts
        case automation
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
        case .settings(.actionsAndShortcuts):
            return .settings(.feature(.actionsAndShortcuts))
        case .settings(.automation):
            return .settings(.feature(.automation))
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

enum AppURLRoute: Equatable {
    case navigation(AppDeepLink)
    case run(ActionRunLinkRequest)
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
    case malformedActionID
    case invalidPresetID
    case unexpectedActionParameters
    case unavailablePlugin(String)
    case pendingQueueFull
    case actionAlreadyRunning
    case recursiveActionInvocation

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
        case .malformedActionID:
            return "malformed-action-id"
        case .invalidPresetID:
            return "invalid-preset-id"
        case .unexpectedActionParameters:
            return "unexpected-action-parameters"
        case .unavailablePlugin:
            return "unavailable-plugin"
        case .pendingQueueFull:
            return "pending-queue-full"
        case .actionAlreadyRunning:
            return "action-already-running"
        case .recursiveActionInvocation:
            return "recursive-action-invocation"
        }
    }
}

enum AppURLHandlingResult: Equatable {
    case delegatedToRightClick
    case queued(AppDeepLink)
    case handled(AppDeepLink)
    case queuedAction(ActionRunLinkRequest)
    case rejected(AppURLRoutingError)
}

struct AppURLActionHandlingDisposition {
    let completion: Task<Void, Never>?

    static let completed = AppURLActionHandlingDisposition(completion: nil)

    static func continuing(
        until completion: Task<Void, Never>
    ) -> AppURLActionHandlingDisposition {
        AppURLActionHandlingDisposition(completion: completion)
    }
}

enum AppDeepLinkParser {
    static let maximumURLByteCount = 4 * 1_024

    static func parse(
        _ url: URL,
        acceptedSchemes: Set<String>
    ) -> Result<AppDeepLink, AppURLRoutingError> {
        switch parseRoute(url, acceptedSchemes: acceptedSchemes) {
        case let .success(.navigation(deepLink)):
            return .success(deepLink)
        case .success(.run):
            return .failure(.unsupportedRoute)
        case let .failure(error):
            return .failure(error)
        }
    }

    static func parseRoute(
        _ url: URL,
        acceptedSchemes: Set<String>
    ) -> Result<AppURLRoute, AppURLRoutingError> {
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

        guard let pathComponents = decodedPathComponents(from: components.percentEncodedPath) else {
            return .failure(.unsupportedRoute)
        }

        switch pathComponents {
        case ["settings"]:
            return .success(.navigation(.settings(.root)))
        case ["settings", "general"]:
            return .success(.navigation(.settings(.general)))
        case ["settings", "about"]:
            return .success(.navigation(.settings(.about)))
        case ["settings", "features", "actions-and-shortcuts"]:
            return .success(.navigation(.settings(.actionsAndShortcuts)))
        case ["settings", "features", "automation"]:
            return .success(.navigation(.settings(.automation)))
        case ["settings", "plugins", "marketplace"]:
            return .success(.navigation(.settings(.pluginMarketplace)))
        case let components where components.count == 3
            && components[0] == "settings"
            && components[1] == "plugins":
            let pluginID = components[2]
            guard PluginPackageManifestLoader.isValidPluginID(pluginID) else {
                return .failure(.malformedPluginID)
            }
            return .success(.navigation(.settings(.pluginConfiguration(pluginID))))
        case ["panels", "dashboard"]:
            return .success(.navigation(.panel(.dashboard)))
        case ["panels", "feature"]:
            return .success(.navigation(.panel(.feature)))
        case ["search"]:
            return .success(.navigation(.search))
        case let path where path.count == 3 && path[0] == "actions":
            guard components.percentEncodedQuery == nil else {
                return .failure(.unexpectedActionParameters)
            }
            let providerID = path[1]
            let actionID = path[2]
            guard PluginPackageManifestLoader.isValidPluginID(providerID),
                  isValidActionIdentifier(actionID) else {
                return .failure(.malformedActionID)
            }
            return .success(
                .run(.direct(ActionKey(providerID: providerID, actionID: actionID)))
            )
        case let path where path.count == 2 && path[0] == "presets":
            guard components.percentEncodedQuery == nil else {
                return .failure(.unexpectedActionParameters)
            }
            let presetID = path[1]
            guard let id = UUID(uuidString: presetID) else {
                return .failure(.invalidPresetID)
            }
            return .success(.run(.preset(id)))
        default:
            return .failure(.unsupportedRoute)
        }
    }

    private static func isValidActionIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "."
                || scalar == "_"
                || scalar == "-"
        }
    }

    private static func decodedPathComponents(from percentEncodedPath: String) -> [String]? {
        guard percentEncodedPath.hasPrefix("/"), !percentEncodedPath.contains("//") else {
            return nil
        }

        var normalizedPath = percentEncodedPath
        if normalizedPath.count > 1, normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }

        var components: [String] = []
        for encodedComponent in normalizedPath.split(
            separator: "/",
            omittingEmptySubsequences: true
        ) {
            guard let component = String(encodedComponent).removingPercentEncoding,
                  !component.isEmpty,
                  component != ".",
                  component != "..",
                  !component.contains("/"),
                  !component.contains("\\"),
                  !component.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                return nil
            }
            components.append(component)
        }
        return components
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
    @TaskLocal private static var currentActionAncestry: Set<ActionRunLinkRequest> = []

    private struct PendingRoute {
        let route: AppURLRoute
        let actionAncestry: Set<ActionRunLinkRequest>
    }

    private struct ActiveActionLease {
        let request: ActionRunLinkRequest
    }

    private let acceptedURLSchemes: Set<String>
    private let maximumPendingRoutes: Int
    private let rightClickHandler: (URL) -> Void
    private let logger: Logger

    private var pendingRoutes: [PendingRoute] = []
    private var presentationHandler: ((AppPresentationRequest) -> Void)?
    private var isPluginConfigurationAvailable: ((String) -> Bool)?
    private var actionHandler: (
        (ActionRunLinkRequest) async -> AppURLActionHandlingDisposition
    )?
    private var activeActionLeases: [UUID: ActiveActionLease] = [:]
    private var dispatchingActionRequest: ActionRunLinkRequest?
    private var dispatchingActionAncestry: Set<ActionRunLinkRequest> = []
    private var drainTask: Task<Void, Never>?
    private var isDraining = false

    init(
        acceptedURLSchemes: Set<String> = RightClickURLRouter.bundleURLSchemes(),
        maximumPendingDeepLinks: Int = 32,
        rightClickHandler: @escaping (URL) -> Void = { RightClickURLRouter.shared.handle($0) },
        logger: Logger = AppLog.appURLRouter
    ) {
        precondition(maximumPendingDeepLinks > 0)
        self.acceptedURLSchemes = Set(acceptedURLSchemes.map { $0.lowercased() })
        self.maximumPendingRoutes = maximumPendingDeepLinks
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

        switch AppDeepLinkParser.parseRoute(url, acceptedSchemes: acceptedURLSchemes) {
        case let .failure(error):
            return reject(error, url: url)
        case let .success(route):
            guard presentationHandler != nil else {
                guard enqueue(route) else {
                    return reject(.pendingQueueFull, url: url)
                }
                return queuedResult(for: route)
            }

            switch route {
            case let .navigation(deepLink) where pendingRoutes.isEmpty && !isDraining:
                return deliver(deepLink)
            case let .run(request):
                if isRecursiveActionRequest(request) {
                    return reject(.recursiveActionInvocation, url: url)
                }
                if isActionAlreadyRunning(request) {
                    return reject(.actionAlreadyRunning, url: url)
                }
                guard enqueue(route) else {
                    return reject(.pendingQueueFull, url: url)
                }
                startDrainIfNeeded()
                return queuedResult(for: route)
            default:
                guard enqueue(route) else {
                    return reject(.pendingQueueFull, url: url)
                }
                startDrainIfNeeded()
                return queuedResult(for: route)
            }
        }
    }

    @discardableResult
    func activate(
        presentationHandler: @escaping (AppPresentationRequest) -> Void,
        isPluginConfigurationAvailable: @escaping (String) -> Bool,
        actionHandler: @escaping (
            ActionRunLinkRequest
        ) async -> AppURLActionHandlingDisposition = { _ in .completed }
    ) -> [AppURLHandlingResult] {
        guard self.presentationHandler == nil else {
            return []
        }

        self.presentationHandler = presentationHandler
        self.isPluginConfigurationAvailable = isPluginConfigurationAvailable
        self.actionHandler = actionHandler

        var synchronousResults: [AppURLHandlingResult] = []
        while let first = pendingRoutes.first {
            guard case let .navigation(deepLink) = first.route else {
                break
            }
            pendingRoutes.removeFirst()
            synchronousResults.append(deliver(deepLink))
        }
        startDrainIfNeeded()
        return synchronousResults
    }

    func waitUntilIdle() async {
        while isDraining || !pendingRoutes.isEmpty {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func enqueue(_ route: AppURLRoute) -> Bool {
        guard pendingRoutes.count < maximumPendingRoutes else {
            return false
        }
        var actionAncestry = Self.currentActionAncestry
        actionAncestry.formUnion(dispatchingActionAncestry)
        pendingRoutes.append(PendingRoute(
            route: route,
            actionAncestry: actionAncestry
        ))
        return true
    }

    private func queuedResult(for route: AppURLRoute) -> AppURLHandlingResult {
        switch route {
        case let .navigation(deepLink):
            .queued(deepLink)
        case let .run(request):
            .queuedAction(request)
        }
    }

    private func startDrainIfNeeded() {
        guard presentationHandler != nil,
              actionHandler != nil,
              !isDraining,
              !pendingRoutes.isEmpty else {
            return
        }

        isDraining = true
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !pendingRoutes.isEmpty {
                let pendingRoute = pendingRoutes.removeFirst()
                let route = pendingRoute.route
                switch route {
                case let .navigation(deepLink):
                    _ = deliver(deepLink)
                case let .run(request):
                    let ancestry = pendingRoute.actionAncestry.union([request])
                    let leaseID = UUID()
                    activeActionLeases[leaseID] = ActiveActionLease(
                        request: request
                    )
                    dispatchingActionRequest = request
                    dispatchingActionAncestry = ancestry
                    let disposition = await Self.$currentActionAncestry.withValue(ancestry) {
                        await actionHandler?(request) ?? .completed
                    }
                    dispatchingActionRequest = nil
                    dispatchingActionAncestry = []
                    if let completion = disposition.completion {
                        Task { @MainActor [weak self] in
                            await completion.value
                            self?.activeActionLeases[leaseID] = nil
                        }
                    } else {
                        activeActionLeases[leaseID] = nil
                    }
                }
            }
            isDraining = false
            drainTask = nil
        }
    }

    private func isRecursiveActionRequest(_ request: ActionRunLinkRequest) -> Bool {
        Self.currentActionAncestry.contains(request)
            || (
                dispatchingActionRequest != request
                    && dispatchingActionAncestry.contains(request)
            )
    }

    private func isActionAlreadyRunning(_ request: ActionRunLinkRequest) -> Bool {
        activeActionLeases.values.contains { $0.request == request }
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
