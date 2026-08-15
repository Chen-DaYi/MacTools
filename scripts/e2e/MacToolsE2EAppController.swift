import AppKit
import Foundation

private enum AppControllerError: Error, CustomStringConvertible {
    case invalidArguments
    case processNotFound(pid_t)
    case terminationRejected(pid_t)

    var description: String {
        switch self {
        case .invalidArguments:
            return "Usage: MacToolsE2EAppController terminate <pid>"
        case let .processNotFound(processIdentifier):
            return "No running application was found for PID \(processIdentifier)."
        case let .terminationRejected(processIdentifier):
            return "The application rejected the termination request for PID \(processIdentifier)."
        }
    }
}

private func run() throws {
    guard CommandLine.arguments.count == 3,
          CommandLine.arguments[1] == "terminate",
          let processIdentifier = pid_t(CommandLine.arguments[2]) else {
        throw AppControllerError.invalidArguments
    }
    guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
        throw AppControllerError.processNotFound(processIdentifier)
    }
    guard application.terminate() else {
        throw AppControllerError.terminationRejected(processIdentifier)
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
