import Foundation
import os

enum TranslatorLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools"

    static let capture = Logger(subsystem: subsystem, category: "TranslatorCapture")
    static let provider = Logger(subsystem: subsystem, category: "TranslatorProvider")
}
