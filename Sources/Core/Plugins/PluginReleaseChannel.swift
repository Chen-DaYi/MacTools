import Foundation

enum PluginReleaseChannel: String, Equatable {
    case beta

    init?(rawString: String?) {
        guard let rawString else {
            return nil
        }

        self.init(rawValue: rawString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    var displayName: String {
        switch self {
        case .beta:
            return "Beta"
        }
    }
}
