import XCTest
@testable import MacTools

final class PluginPackageManifestTests: XCTestCase {
    func testManifestValidationAcceptsCurrentPackageFormat() throws {
        let manifest = PluginPackageManifest(
            id: "com.example.demo",
            displayName: "Demo",
            version: "1.0.0",
            minHostVersion: "0.15.0",
            bundleRelativePath: "Demo.bundle",
            capabilities: .init(primaryPanel: true)
        )

        XCTAssertNoThrow(try PluginPackageManifestLoader.validate(manifest, hostVersion: "0.16.0"))
    }

    func testManifestValidationRejectsPreviousPluginKitVersion() {
        let manifest = PluginPackageManifest(
            id: "com.example.demo",
            displayName: "Demo",
            version: "1.0.0",
            minHostVersion: "0.15.0",
            pluginKitVersion: 1,
            bundleRelativePath: "Demo.bundle"
        )

        XCTAssertThrowsError(try PluginPackageManifestLoader.validate(manifest, hostVersion: "0.16.0")) { error in
            XCTAssertEqual(error as? PluginPackageManifestError, .unsupportedPluginKitVersion(1))
        }
    }

    func testManifestValidationRejectsUnsafeBundlePath() {
        let manifest = PluginPackageManifest(
            id: "com.example.demo",
            displayName: "Demo",
            version: "1.0.0",
            minHostVersion: "0.15.0",
            bundleRelativePath: "../Demo.bundle"
        )

        XCTAssertThrowsError(try PluginPackageManifestLoader.validate(manifest, hostVersion: "0.16.0")) { error in
            XCTAssertEqual(error as? PluginPackageManifestError, .invalidBundleRelativePath("../Demo.bundle"))
        }
    }

    func testManifestValidationRejectsInvalidVersion() {
        let manifest = PluginPackageManifest(
            id: "com.example.demo",
            displayName: "Demo",
            version: "1.0-beta",
            minHostVersion: "0.15.0",
            bundleRelativePath: "Demo.bundle"
        )

        XCTAssertThrowsError(try PluginPackageManifestLoader.validate(manifest, hostVersion: "0.16.0")) { error in
            XCTAssertEqual(error as? PluginPackageManifestError, .invalidVersion("1.0-beta"))
        }
    }

    func testManifestValidationRejectsReservedOrTerminatedPluginIdentifiers() {
        for id in ["marketplace", "fan-control\n", "fan-control\r"] {
            let manifest = PluginPackageManifest(
                id: id,
                displayName: "Demo",
                version: "1.0.0",
                minHostVersion: "0.15.0",
                bundleRelativePath: "Demo.bundle"
            )

            XCTAssertThrowsError(
                try PluginPackageManifestLoader.validate(manifest, hostVersion: "0.16.0")
            ) { error in
                XCTAssertEqual(error as? PluginPackageManifestError, .invalidIdentifier(id))
            }
        }
    }

    func testManifestValidationRejectsIncompatibleHostVersion() {
        let manifest = PluginPackageManifest(
            id: "com.example.demo",
            displayName: "Demo",
            version: "1.0.0",
            minHostVersion: "1.0.0",
            bundleRelativePath: "Demo.bundle"
        )

        XCTAssertThrowsError(try PluginPackageManifestLoader.validate(manifest, hostVersion: "0.16.0")) { error in
            XCTAssertEqual(
                error as? PluginPackageManifestError,
                .incompatibleHostVersion(required: "1.0.0", current: "0.16.0")
            )
        }
    }

    func testExtractionPackagesDeclareTheirRequiredHostCompatibility() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expectations = [
            (
                path: "Plugins/MouseEnhancer/plugin.json",
                minimum: "1.2.0",
                compatibleHost: "1.2.0",
                incompatibleHost: "1.1.6" as String?
            ),
            (
                path: "Plugins/TrackpadGestures/plugin.json",
                minimum: "1.2.0",
                compatibleHost: "1.2.0",
                incompatibleHost: "1.1.6"
            ),
        ]
        for expectation in expectations {
            let relativePath = expectation.path
            let manifestURL = repositoryRoot.appendingPathComponent(relativePath)
            let manifest = try JSONDecoder().decode(
                PluginPackageManifest.self,
                from: PluginSourceManifestTestProjection.data(
                    pluginDirectoryName: manifestURL.deletingLastPathComponent().lastPathComponent
                )
            )

            XCTAssertEqual(manifest.minHostVersion, expectation.minimum)
            XCTAssertNoThrow(
                try PluginPackageManifestLoader.validate(
                    manifest,
                    hostVersion: expectation.compatibleHost
                )
            )
            if let incompatibleHost = expectation.incompatibleHost {
                XCTAssertThrowsError(
                    try PluginPackageManifestLoader.validate(
                        manifest,
                        hostVersion: incompatibleHost
                    )
                ) { error in
                    XCTAssertEqual(
                        error as? PluginPackageManifestError,
                        .incompatibleHostVersion(
                            required: expectation.minimum,
                            current: incompatibleHost
                        )
                    )
                }
            }
        }
    }

    func testCurrentHostVersionCanLoadEveryRepositoryPluginManifest() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let versionConfiguration = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Configs/AppVersion.xcconfig"),
            encoding: .utf8
        )
        let hostVersion = try XCTUnwrap(
            versionConfiguration
                .split(separator: "\n")
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("MARKETING_VERSION =") }?
                .split(separator: "=", maxSplits: 1)
                .last?
                .trimmingCharacters(in: .whitespaces)
        )
        let pluginDirectory = repositoryRoot.appendingPathComponent("Plugins", isDirectory: true)
        let pluginURLs = try FileManager.default.contentsOfDirectory(
            at: pluginDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for pluginURL in pluginURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifestURL = pluginURL.appendingPathComponent("plugin.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            let manifest = try JSONDecoder().decode(
                PluginPackageManifest.self,
                from: PluginSourceManifestTestProjection.data(
                    pluginDirectoryName: pluginURL.lastPathComponent
                )
            )

            XCTAssertNoThrow(
                try PluginPackageManifestLoader.validate(manifest, hostVersion: hostVersion),
                "\(pluginURL.lastPathComponent) requires host \(manifest.minHostVersion), current host is \(hostVersion)"
            )
        }
    }

    func testManifestDecodesWithCategoryAndReleaseChannel() throws {
        let json = """
        {
          "id": "demo",
          "displayName": "Demo",
          "version": "1.0.0",
          "minHostVersion": "0.15.0",
          "pluginKitVersion": 3,
          "bundleRelativePath": "Demo.bundle",
          "capabilities": { "primaryPanel": true, "componentPanel": false, "configuration": true },
          "permissions": [],
          "category": "display",
          "releaseChannel": "beta",
          "localizedMetadata": {
            "en": {
              "displayName": "Demo",
              "summary": "Demo plugin"
            },
            "zh-Hans": {
              "displayName": "示例",
              "summary": "示例插件"
            }
          }
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(PluginPackageManifest.self, from: json)
        XCTAssertEqual(manifest.category, "display")
        XCTAssertEqual(manifest.releaseChannel, "beta")
        XCTAssertEqual(manifest.capabilities.settings, .form)
        XCTAssertEqual(manifest.localizedMetadata?["en"]?.summary, "Demo plugin")
    }

    func testManifestDecodesWithoutCategoryAndReleaseChannelGracefully() throws {
        // Legacy plugin.json files without category/releaseChannel should still decode.
        let json = """
        {
          "id": "demo",
          "displayName": "Demo",
          "version": "1.0.0",
          "minHostVersion": "0.15.0",
          "pluginKitVersion": 3,
          "bundleRelativePath": "Demo.bundle",
          "capabilities": { "primaryPanel": true, "componentPanel": false, "configuration": false },
          "permissions": []
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(PluginPackageManifest.self, from: json)
        XCTAssertNil(manifest.category)
        XCTAssertNil(manifest.releaseChannel)
    }

    func testRichProjectedManifestDecodesProductMetadata() throws {
        let manifest = try JSONDecoder().decode(
            PluginPackageManifest.self,
            from: PluginSourceManifestTestProjection.data(pluginDirectoryName: "Appearance")
        )

        XCTAssertEqual(manifest.presentation?.publisher, "MacTools")
        XCTAssertEqual(
            manifest.presentation?.longDescription.localizedValue(preferredLanguages: ["en-US"]),
            "Switch macOS between light and dark appearance from any MacTools action surface."
        )
        XCTAssertEqual(manifest.actions?.providers.first?.kind, "static")
        XCTAssertEqual(
            manifest.actions?.providers.first?.staticActions.map(\.id),
            ["toggle", "set-enabled"]
        )
        XCTAssertEqual(manifest.requirements?.architectures, ["arm64", "x86_64"])
        XCTAssertEqual(manifest.privacy?.networkUse, "none")
        let searchKeywords = PluginProductMetadata.searchKeywords(
            presentation: manifest.presentation,
            discovery: manifest.discovery,
            requirements: manifest.requirements,
            privacy: manifest.privacy,
            actions: manifest.actions,
            setup: manifest.setup,
            relationships: manifest.relationships
        )
        XCTAssertTrue(searchKeywords.contains("Toggle Appearance"))
        XCTAssertTrue(searchKeywords.contains("night-shift"))
    }

    func testUnknownOptionalProductFieldDoesNotBreakRuntimeDecoding() throws {
        let json = """
        {
          "id": "demo",
          "displayName": "Demo",
          "version": "1.0.0",
          "minHostVersion": "1.0.0",
          "pluginKitVersion": 4,
          "bundleRelativePath": "Demo.bundle",
          "capabilities": {"primaryPanel": false, "componentPanel": false, "settings": "none"},
          "permissions": [],
          "futureProductSection": {"newField": true}
        }
        """.data(using: .utf8)!

        XCTAssertNoThrow(try JSONDecoder().decode(PluginPackageManifest.self, from: json))
    }

    func testLocalizedMetadataMatchesPreferredLanguageAndFallbacks() {
        let metadata = [
            "en": PluginLocalizedMetadata(displayName: "Calendar", summary: "Events"),
            "zh-Hans": PluginLocalizedMetadata(displayName: "日历", summary: "日程"),
            "zh-Hant": PluginLocalizedMetadata(displayName: "行事曆", summary: "事件")
        ]

        XCTAssertEqual(
            PluginLocalizationMatcher.localizedMetadata(
                from: metadata,
                preferredLanguages: ["en-US"]
            )?.displayName,
            "Calendar"
        )
        XCTAssertEqual(
            PluginLocalizationMatcher.localizedMetadata(
                from: metadata,
                preferredLanguages: ["zh-HK"]
            )?.displayName,
            "行事曆"
        )
        XCTAssertEqual(
            PluginLocalizationMatcher.localizedMetadata(
                from: metadata,
                preferredLanguages: ["fr-FR"]
            )?.displayName,
            "Calendar"
        )
    }
}

enum PluginSourceManifestTestProjection {
    private static let productSections = [
        "presentation", "discovery", "requirements", "privacy", "actions", "setup",
        "relationships",
    ]
    private static let referencePrefix = "@productStrings."
    private static let localizablePrefix = "@localizable."
    private static let standardActionPrefix = "@standardAction."

    static func data(pluginDirectoryName: String) throws -> Data {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Plugins", isDirectory: true)
            .appendingPathComponent(pluginDirectoryName, isDirectory: true)
            .appendingPathComponent("plugin.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: sourceURL))
        guard var manifest = object as? [String: Any],
              let productStrings = manifest["productStrings"] as? [String: Any],
              let localizedMetadata = manifest["localizedMetadata"] as? [String: [String: String]] else {
            throw projectionError("Missing source localization metadata in \(sourceURL.path)")
        }
        let stringCatalogURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        let stringCatalog = try? JSONSerialization.jsonObject(
            with: Data(contentsOf: stringCatalogURL)
        ) as? [String: Any]
        let catalogStrings = stringCatalog?["strings"] as? [String: Any]

        let resolvedStrings = try Dictionary(uniqueKeysWithValues: productStrings.map { key, value in
            if let reference = value as? String,
               reference == "@displayName" || reference == "@summary" {
                let field = String(reference.dropFirst())
                let localized = try Dictionary(uniqueKeysWithValues: localizedMetadata.map { locale, values in
                    guard let text = values[field], !text.isEmpty else {
                        throw projectionError("Missing \(locale).\(field) for \(key)")
                    }
                    return (locale, text)
                })
                return (key, localized as Any)
            }
            if let reference = value as? String,
               reference.hasPrefix(localizablePrefix) {
                let catalogKey = String(reference.dropFirst(localizablePrefix.count))
                guard let catalogEntry = catalogStrings?[catalogKey] as? [String: Any],
                      let localizations = catalogEntry["localizations"] as? [String: Any] else {
                    throw projectionError("Missing string catalog entry \(catalogKey) for \(key)")
                }
                let localized = try Dictionary(uniqueKeysWithValues: localizations.map { locale, value in
                    guard let localization = value as? [String: Any],
                          let stringUnit = localization["stringUnit"] as? [String: Any],
                          let text = stringUnit["value"] as? String,
                          !text.isEmpty else {
                        throw projectionError("Missing \(catalogKey).\(locale) for \(key)")
                    }
                    return (locale, text)
                })
                return (key, localized as Any)
            }
            if let reference = value as? String,
               reference.hasPrefix(standardActionPrefix) {
                let actionKey = String(reference.dropFirst(standardActionPrefix.count))
                let localized = try Dictionary(uniqueKeysWithValues: localizedMetadata.map { locale, values in
                    guard let displayName = values["displayName"], !displayName.isEmpty else {
                        throw projectionError("Missing \(locale).displayName for \(key)")
                    }
                    return (locale, "\(actionKey): \(displayName)")
                })
                return (key, localized as Any)
            }
            guard let localized = value as? [String: String] else {
                throw projectionError("Invalid product string \(key)")
            }
            return (key, localized as Any)
        })

        func expand(_ value: Any) throws -> Any {
            if let reference = value as? String, reference.hasPrefix(referencePrefix) {
                let key = String(reference.dropFirst(referencePrefix.count))
                guard let localized = resolvedStrings[key] else {
                    throw projectionError("Missing product string \(key)")
                }
                return localized
            }
            if let values = value as? [Any] {
                return try values.map(expand)
            }
            if let values = value as? [String: Any] {
                return try Dictionary(uniqueKeysWithValues: values.map { key, item in
                    (key, try expand(item))
                })
            }
            return value
        }

        for section in productSections where manifest[section] != nil {
            manifest[section] = try expand(manifest[section] as Any)
        }
        manifest.removeValue(forKey: "productStrings")
        manifest.removeValue(forKey: "build")
        manifest.removeValue(forKey: "package")
        return try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    }

    private static func projectionError(_ message: String) -> NSError {
        NSError(
            domain: "PluginSourceManifestTestProjection",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
