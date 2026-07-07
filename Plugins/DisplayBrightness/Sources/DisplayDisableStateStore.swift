import Foundation
import OSLog

@MainActor
final class UserDefaultsDisplayDisableStateStore: DisplayDisableStateStoring {
    private enum Constants {
        static let key = "DisplayBrightness.DisplayDisableRecoverySnapshot"
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "DisplayDisableStateStore"
    )
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var snapshot: DisplayDisableRecoverySnapshot? {
        get {
            guard let data = userDefaults.data(forKey: Constants.key) else {
                return nil
            }

            return try? JSONDecoder().decode(DisplayDisableRecoverySnapshot.self, from: data)
        }
        set {
            guard let newValue else {
                userDefaults.removeObject(forKey: Constants.key)
                return
            }

            do {
                let data = try JSONEncoder().encode(newValue)
                userDefaults.set(data, forKey: Constants.key)
            } catch {
                logger.error("failed to encode display disable recovery snapshot: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
