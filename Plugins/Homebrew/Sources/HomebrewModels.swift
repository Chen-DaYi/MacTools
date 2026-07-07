import Foundation

public struct BrewPackage: Identifiable, Hashable, Sendable, Codable {
    public var id: String { "\(isCask ? "cask" : "formula"):\(name)" }
    public let name: String
    public let version: String
    public let latestVersion: String
    public let isCask: Bool
    public let desc: String
    public let homepage: String
    public let isOutdated: Bool
    public let isPinned: Bool
    public let dependencies: [String]

    public init(
        name: String,
        version: String,
        latestVersion: String,
        isCask: Bool,
        desc: String,
        homepage: String,
        isOutdated: Bool,
        isPinned: Bool,
        dependencies: [String] = []
    ) {
        self.name = name
        self.version = version
        self.latestVersion = latestVersion
        self.isCask = isCask
        self.desc = desc
        self.homepage = homepage
        self.isOutdated = isOutdated
        self.isPinned = isPinned
        self.dependencies = dependencies
    }

    public func requiredBy(in packages: [BrewPackage]) -> [String] {
        packages.filter { $0.dependencies.contains(self.name) }.map { $0.name }
    }
}

public struct BrewTap: Identifiable, Hashable, Sendable, Codable {
    public var id: String { name }
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public struct BrewCommandLog: Identifiable, Sendable {
    public let id = UUID()
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}
