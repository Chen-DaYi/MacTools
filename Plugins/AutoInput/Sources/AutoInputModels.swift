import Foundation

struct AutoInputSource: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

enum AutoInputHUDSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case large

    var id: String { rawValue }
}

enum AutoInputHUDPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case above
    case below
    case screenCenter

    var id: String { rawValue }
}

struct AutoInputHUDConfiguration: Equatable, Sendable {
    let size: AutoInputHUDSize
    let position: AutoInputHUDPosition
}

struct AutoInputApplication: Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let bundleURL: URL?
}

struct AutoInputRule: Codable, Identifiable, Equatable {
    var id: String { bundleIdentifier }

    let bundleIdentifier: String
    var displayName: String
    var bundleURLString: String?
    var inputSourceID: String

    var bundleURL: URL? {
        bundleURLString.flatMap(URL.init(string:))
    }

    init(
        bundleIdentifier: String,
        displayName: String,
        bundleURL: URL?,
        inputSourceID: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.bundleURLString = bundleURL?.absoluteString
        self.inputSourceID = inputSourceID
    }
}

enum AutoInputSwitchReason: Equatable {
    case fixedRule
    case remembered
}

struct AutoInputTarget: Equatable {
    let source: AutoInputSource
    let reason: AutoInputSwitchReason
}
