import Foundation

public enum ActionGridPresentationLimits {
    public static let maximumEntriesPerGrid = 9
    public static let maximumFolderDepth = 3
}

public struct ActionSurfaceCatalogItem: Identifiable, Hashable, Sendable {
    public let reference: ActionReference
    public let title: String
    public let subtitle: String?
    public let ownerTitle: String
    public let systemImage: String
    public let availability: ActionAvailability
    public let isSafe: Bool
    public let canOpenOwner: Bool

    public init(
        reference: ActionReference,
        title: String,
        subtitle: String?,
        ownerTitle: String,
        systemImage: String,
        availability: ActionAvailability,
        isSafe: Bool,
        canOpenOwner: Bool = false
    ) {
        self.reference = reference
        self.title = title
        self.subtitle = subtitle
        self.ownerTitle = ownerTitle
        self.systemImage = systemImage
        self.availability = availability
        self.isSafe = isSafe
        self.canOpenOwner = canOpenOwner
    }

    public var id: ActionReference { reference }
}

public struct ActionGridPresentationEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let reference: ActionReference
    public let customTitle: String?
    public let folderSystemImage: String?
    public let children: [ActionGridPresentationEntry]?
    public let slotIndex: Int?

    public init(
        id: String,
        reference: ActionReference,
        customTitle: String? = nil,
        slotIndex: Int? = nil
    ) {
        self.id = id
        self.reference = reference
        self.customTitle = customTitle
        self.folderSystemImage = nil
        self.children = nil
        self.slotIndex = slotIndex
    }

    public init(
        id: String,
        folderTitle: String,
        systemImage: String = "folder.fill",
        children: [ActionGridPresentationEntry],
        slotIndex: Int? = nil
    ) {
        self.id = id
        self.reference = ActionReference(
            key: ActionKey(providerID: "action-grid.folder", actionID: id)
        )
        self.customTitle = folderTitle
        self.folderSystemImage = systemImage
        self.children = children
        self.slotIndex = slotIndex
    }

    public var isFolder: Bool { children != nil }

    public var actionReferences: [ActionReference] {
        if let children {
            return children.flatMap(\.actionReferences)
        }
        return [reference]
    }
}

@MainActor
public struct ActionGridHostContext {
    private let catalogHandler: () -> [ActionSurfaceCatalogItem]
    private let itemHandler: (ActionReference) -> ActionSurfaceCatalogItem?
    private let migrationHandler: (ActionReference) -> ActionReference?
    private let openOwnerHandler: (ActionReference) -> Bool
    private let exportHandler: (ActionReference) -> Bool
    private let restoreHandler: (ActionReference) -> Bool
    private let presentationAvailabilityHandler: () -> Bool
    private let presentationHandler: ([ActionGridPresentationEntry], ActionExecutionSource) -> Bool

    public init(
        catalog: @escaping () -> [ActionSurfaceCatalogItem],
        item: @escaping (ActionReference) -> ActionSurfaceCatalogItem?,
        migrate: @escaping (ActionReference) -> ActionReference?,
        openOwner: @escaping (ActionReference) -> Bool = { _ in false },
        canExport: @escaping (ActionReference) -> Bool = { _ in true },
        canRestore: @escaping (ActionReference) -> Bool = { _ in true },
        canPresent: @escaping () -> Bool,
        present: @escaping ([ActionGridPresentationEntry], ActionExecutionSource) -> Bool
    ) {
        self.catalogHandler = catalog
        self.itemHandler = item
        self.migrationHandler = migrate
        self.openOwnerHandler = openOwner
        self.exportHandler = canExport
        self.restoreHandler = canRestore
        self.presentationAvailabilityHandler = canPresent
        self.presentationHandler = present
    }

    public var catalog: [ActionSurfaceCatalogItem] { catalogHandler() }
    public var canPresent: Bool { presentationAvailabilityHandler() }

    public func item(for reference: ActionReference) -> ActionSurfaceCatalogItem? {
        itemHandler(reference)
    }

    public func migrate(_ reference: ActionReference) -> ActionReference? {
        migrationHandler(reference)
    }

    @discardableResult
    public func openOwner(for reference: ActionReference) -> Bool {
        openOwnerHandler(reference)
    }

    public func canExport(_ reference: ActionReference) -> Bool {
        exportHandler(reference)
    }

    public func canRestore(_ reference: ActionReference) -> Bool {
        restoreHandler(reference)
    }

    @discardableResult
    public func present(
        entries: [ActionGridPresentationEntry],
        source: ActionExecutionSource
    ) -> Bool {
        presentationHandler(entries, source)
    }
}

@MainActor
public protocol ActionGridHostContextConsuming: AnyObject {
    var actionGridHostContext: ActionGridHostContext? { get set }
    func actionSurfaceCatalogDidChange()
}

public extension ActionGridHostContextConsuming {
    func actionSurfaceCatalogDidChange() {}
}

/// Host bridge for gesture plugins that invoke the same canonical actions used
/// by shortcuts, workflows, Run Links, and Action Grid. Script-like targets
/// should be published as actions instead of adding gesture-specific execution
/// paths, so permission, confirmation, migration, and availability stay shared.
@MainActor
public struct TrackpadActionHostContext {
    private let catalogHandler: () -> [ActionSurfaceCatalogItem]
    private let itemHandler: (ActionReference) -> ActionSurfaceCatalogItem?
    private let migrationHandler: (ActionReference) -> ActionReference?
    private let exportHandler: (ActionReference) -> Bool
    private let restoreHandler: (ActionReference) -> Bool
    private let executionHandler: (ActionReference) -> Void

    public init(
        catalog: @escaping () -> [ActionSurfaceCatalogItem],
        item: @escaping (ActionReference) -> ActionSurfaceCatalogItem?,
        migrate: @escaping (ActionReference) -> ActionReference?,
        canExport: @escaping (ActionReference) -> Bool = { _ in true },
        canRestore: @escaping (ActionReference) -> Bool = { _ in true },
        execute: @escaping (ActionReference) -> Void
    ) {
        self.catalogHandler = catalog
        self.itemHandler = item
        self.migrationHandler = migrate
        self.exportHandler = canExport
        self.restoreHandler = canRestore
        self.executionHandler = execute
    }

    public var catalog: [ActionSurfaceCatalogItem] { catalogHandler() }

    public func item(for reference: ActionReference) -> ActionSurfaceCatalogItem? {
        itemHandler(reference)
    }

    public func migrate(_ reference: ActionReference) -> ActionReference? {
        migrationHandler(reference)
    }

    public func canExport(_ reference: ActionReference) -> Bool {
        exportHandler(reference)
    }

    public func canRestore(_ reference: ActionReference) -> Bool {
        restoreHandler(reference)
    }

    public func execute(_ reference: ActionReference) {
        executionHandler(reference)
    }
}

@MainActor
public protocol TrackpadActionHostContextConsuming: AnyObject {
    var trackpadActionHostContext: TrackpadActionHostContext? { get set }
    func trackpadActionCatalogDidChange()
}

public extension TrackpadActionHostContextConsuming {
    func trackpadActionCatalogDidChange() {}
}

public struct ActionSurfaceAssignmentSummary: Identifiable, Hashable, Sendable {
    public let surfaceID: String
    public let surfaceTitle: String
    public let systemImage: String
    public let detail: String

    public init(
        surfaceID: String,
        surfaceTitle: String,
        systemImage: String,
        detail: String
    ) {
        self.surfaceID = surfaceID
        self.surfaceTitle = surfaceTitle
        self.systemImage = systemImage
        self.detail = detail
    }

    public var id: String { surfaceID }
}

@MainActor
public protocol ActionSurfaceAssignmentSummarizing: AnyObject {
    func actionSurfaceAssignmentSummary(
        for reference: ActionReference
    ) -> ActionSurfaceAssignmentSummary?
}
