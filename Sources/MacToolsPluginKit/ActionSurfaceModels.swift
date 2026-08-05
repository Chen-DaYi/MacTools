import Foundation

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

    public init(id: String, reference: ActionReference, customTitle: String? = nil) {
        self.id = id
        self.reference = reference
        self.customTitle = customTitle
    }
}

@MainActor
public struct ActionGridHostContext {
    private let catalogHandler: () -> [ActionSurfaceCatalogItem]
    private let itemHandler: (ActionReference) -> ActionSurfaceCatalogItem?
    private let migrationHandler: (ActionReference) -> ActionReference?
    private let openOwnerHandler: (ActionReference) -> Bool
    private let presentationAvailabilityHandler: () -> Bool
    private let presentationHandler: ([ActionGridPresentationEntry]) -> Bool

    public init(
        catalog: @escaping () -> [ActionSurfaceCatalogItem],
        item: @escaping (ActionReference) -> ActionSurfaceCatalogItem?,
        migrate: @escaping (ActionReference) -> ActionReference?,
        openOwner: @escaping (ActionReference) -> Bool = { _ in false },
        canPresent: @escaping () -> Bool,
        present: @escaping ([ActionGridPresentationEntry]) -> Bool
    ) {
        self.catalogHandler = catalog
        self.itemHandler = item
        self.migrationHandler = migrate
        self.openOwnerHandler = openOwner
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

    @discardableResult
    public func present(entries: [ActionGridPresentationEntry]) -> Bool {
        presentationHandler(entries)
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
