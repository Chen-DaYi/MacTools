import ApplicationServices

@MainActor
enum MouseEnhancerAccessibilityCheck {
    private static let trustedCheckOptionPromptKey = "AXTrustedCheckOptionPrompt"

    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestTrust(prompt: Bool) -> Bool {
        guard prompt else {
            return AXIsProcessTrusted()
        }

        let options = [trustedCheckOptionPromptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
