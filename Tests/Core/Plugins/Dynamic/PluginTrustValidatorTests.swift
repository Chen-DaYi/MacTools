import XCTest
@testable import MacTools

final class PluginTrustValidatorTests: XCTestCase {
    private let hostURL = URL(fileURLWithPath: "/tmp/MacTools.app")
    private let pluginURL = URL(fileURLWithPath: "/tmp/Example.mactoolsplugin")

    /// Controllable signature/team source so the validator can be exercised
    /// without touching the real Security framework.
    private struct FakeCodeSignatureInfoProvider: CodeSignatureInfoProviding {
        var hostURL: URL
        var hostTeam: String?
        var pluginTeam: String?
        var pluginSignatureValid = true

        func validateCodeSignature(at url: URL) throws {
            if !pluginSignatureValid {
                throw PluginTrustValidatorError.signatureCheckFailed("fake")
            }
        }

        func teamIdentifier(for url: URL) throws -> String? {
            url == hostURL ? hostTeam : pluginTeam
        }
    }

    private func makeValidator(
        hostTeam: String?,
        pluginTeam: String?,
        allowsUntrustedHostTeam: Bool
    ) -> SameTeamPluginTrustValidator {
        let provider = FakeCodeSignatureInfoProvider(
            hostURL: hostURL,
            hostTeam: hostTeam,
            pluginTeam: pluginTeam
        )
        return SameTeamPluginTrustValidator(
            hostBundleURL: hostURL,
            codeSignatureInfoProvider: provider,
            allowsUntrustedHostTeam: allowsUntrustedHostTeam
        )
    }

    func testRejectsPluginWhenHostTeamUnavailableAndEnforcing() {
        // Release-style behavior: an unreadable host team must NOT silently
        // accept any validly-signed bundle (fail closed).
        let validator = makeValidator(hostTeam: nil, pluginTeam: "ATTACKERTEAM", allowsUntrustedHostTeam: false)
        XCTAssertThrowsError(try validator.validatePluginBundle(at: pluginURL)) { error in
            XCTAssertEqual(error as? PluginTrustValidatorError, .hostTeamIdentifierUnavailable)
        }
    }

    func testAllowsPluginWhenHostTeamUnavailableAndPermissive() {
        // DEBUG-style behavior: local dev host has no team, keep loading plugins.
        let validator = makeValidator(hostTeam: nil, pluginTeam: "ANYTEAM", allowsUntrustedHostTeam: true)
        XCTAssertNoThrow(try validator.validatePluginBundle(at: pluginURL))
    }

    func testRejectsTeamMismatchWhenHostTeamKnown() {
        let validator = makeValidator(hostTeam: "HOSTTEAM", pluginTeam: "OTHERTEAM", allowsUntrustedHostTeam: false)
        XCTAssertThrowsError(try validator.validatePluginBundle(at: pluginURL)) { error in
            XCTAssertEqual(
                error as? PluginTrustValidatorError,
                .teamIdentifierMismatch(expected: "HOSTTEAM", actual: "OTHERTEAM")
            )
        }
    }

    func testAcceptsMatchingTeam() {
        let validator = makeValidator(hostTeam: "SAMETEAM", pluginTeam: "SAMETEAM", allowsUntrustedHostTeam: false)
        XCTAssertNoThrow(try validator.validatePluginBundle(at: pluginURL))
    }

    func testRejectsPluginWithMissingTeamWhenHostTeamKnown() {
        let validator = makeValidator(hostTeam: "HOSTTEAM", pluginTeam: nil, allowsUntrustedHostTeam: false)
        XCTAssertThrowsError(try validator.validatePluginBundle(at: pluginURL)) { error in
            XCTAssertEqual(error as? PluginTrustValidatorError, .teamIdentifierUnavailable(pluginURL))
        }
    }
}
