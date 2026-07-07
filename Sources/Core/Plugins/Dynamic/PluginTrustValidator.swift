import Foundation
import Security

enum PluginTrustValidatorError: LocalizedError, Equatable {
    case signatureCheckFailed(String)
    case teamIdentifierUnavailable(URL)
    case teamIdentifierMismatch(expected: String, actual: String)
    case hostTeamIdentifierUnavailable

    var errorDescription: String? {
        switch self {
        case let .signatureCheckFailed(reason):
            return AppL10n.pluginsFormat("plugin.error.trust.signatureCheckFailedFormat", defaultValue: "插件签名校验失败：%@", reason)
        case let .teamIdentifierUnavailable(url):
            return AppL10n.pluginsFormat("plugin.error.trust.teamUnavailableFormat", defaultValue: "无法读取插件签名团队：%@", url.path)
        case let .teamIdentifierMismatch(expected, actual):
            return AppL10n.pluginsFormat(
                "plugin.error.trust.teamMismatchFormat",
                defaultValue: "插件签名团队不匹配，期望 %@，实际 %@。",
                expected,
                actual
            )
        case .hostTeamIdentifierUnavailable:
            return AppL10n.plugins("plugin.error.trust.hostTeamUnavailable", defaultValue: "无法确定宿主签名团队，已拒绝加载插件。")
        }
    }
}

protocol PluginTrustValidating {
    func validatePluginBundle(at bundleURL: URL) throws
}

struct SameTeamPluginTrustValidator: PluginTrustValidating {
    private let hostTeamIdentifier: String?
    private let codeSignatureInfoProvider: CodeSignatureInfoProviding
    private let allowsUntrustedHostTeam: Bool

    init(
        hostBundleURL: URL = Bundle.main.bundleURL,
        codeSignatureInfoProvider: CodeSignatureInfoProviding = SecurityCodeSignatureInfoProvider(),
        allowsUntrustedHostTeam: Bool = SameTeamPluginTrustValidator.defaultAllowsUntrustedHostTeam
    ) {
        self.codeSignatureInfoProvider = codeSignatureInfoProvider
        self.hostTeamIdentifier = try? codeSignatureInfoProvider.teamIdentifier(for: hostBundleURL)
        self.allowsUntrustedHostTeam = allowsUntrustedHostTeam
    }

    // DEBUG host builds are often ad-hoc/unsigned and report no team identifier;
    // default to permissive there. Release builds default to enforcing same-team.
    static var defaultAllowsUntrustedHostTeam: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    func validatePluginBundle(at bundleURL: URL) throws {
        try codeSignatureInfoProvider.validateCodeSignature(at: bundleURL)

        guard let expectedTeamID = hostTeamIdentifier, !expectedTeamID.isEmpty else {
            // Fail closed: an unreadable host team must not silently bypass the
            // same-team check (which would otherwise accept any validly-signed bundle).
            if allowsUntrustedHostTeam {
                return
            }
            throw PluginTrustValidatorError.hostTeamIdentifierUnavailable
        }

        guard let actualTeamID = try codeSignatureInfoProvider.teamIdentifier(for: bundleURL), !actualTeamID.isEmpty else {
            throw PluginTrustValidatorError.teamIdentifierUnavailable(bundleURL)
        }

        guard actualTeamID == expectedTeamID else {
            throw PluginTrustValidatorError.teamIdentifierMismatch(
                expected: expectedTeamID,
                actual: actualTeamID
            )
        }
    }
}

protocol CodeSignatureInfoProviding {
    func validateCodeSignature(at url: URL) throws
    func teamIdentifier(for url: URL) throws -> String?
}

struct SecurityCodeSignatureInfoProvider: CodeSignatureInfoProviding {
    func validateCodeSignature(at url: URL) throws {
        let code = try staticCode(for: url)
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(), nil)

        guard status == errSecSuccess else {
            throw PluginTrustValidatorError.signatureCheckFailed(secErrorMessage(status))
        }
    }

    func teamIdentifier(for url: URL) throws -> String? {
        let code = try staticCode(for: url)
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )

        guard status == errSecSuccess else {
            throw PluginTrustValidatorError.signatureCheckFailed(secErrorMessage(status))
        }

        guard let dictionary = info as? [String: Any] else {
            return nil
        }

        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func staticCode(for url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code)

        guard status == errSecSuccess, let code else {
            throw PluginTrustValidatorError.signatureCheckFailed(secErrorMessage(status))
        }

        return code
    }

    private func secErrorMessage(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }
}
