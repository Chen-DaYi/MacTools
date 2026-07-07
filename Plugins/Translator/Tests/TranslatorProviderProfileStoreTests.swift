import Foundation
import XCTest
@testable import TranslatorPlugin

@MainActor
final class TranslatorProviderProfileStoreTests: XCTestCase {
    func testLoadProfilesReturnsDefaultOpenAIProfileWhenStorageIsEmpty() {
        let storage = TranslatorInMemoryPluginStorage()
        let store = TranslatorProviderProfileStore(storage: storage)

        let profiles = store.loadProfiles()

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].id, "openai")
        XCTAssertEqual(profiles[0].name, "OpenAI")
        XCTAssertTrue(profiles[0].isEnabled)
        XCTAssertEqual(profiles[0].baseURL, "https://api.openai.com")
        XCTAssertEqual(profiles[0].model, "gpt-5.4-mini")
    }

    func testLoadProfilesMigratesLegacySingleProviderConfiguration() {
        let storage = TranslatorInMemoryPluginStorage()
        storage.set("https://gateway.example.com/v1", forKey: "translator.openai.base-url")
        storage.set("gpt-test", forKey: "translator.openai.model")
        storage.set("翻译：{{text}}", forKey: "translator.openai.prompt-template")
        let store = TranslatorProviderProfileStore(storage: storage)

        let profile = store.loadProfiles()[0]

        XCTAssertEqual(profile.id, "openai")
        XCTAssertEqual(profile.name, "OpenAI")
        XCTAssertEqual(profile.baseURL, "https://gateway.example.com/v1")
        XCTAssertEqual(profile.model, "gpt-test")
        XCTAssertEqual(profile.promptTemplate, "翻译：{{text}}")
    }

    func testSaveProfilesPersistsNormalizedJSON() throws {
        let storage = TranslatorInMemoryPluginStorage()
        let store = TranslatorProviderProfileStore(storage: storage)
        let profile = TranslatorProviderProfile(
            id: "deepseek",
            name: "  DeepSeek  ",
            isEnabled: true,
            baseURL: "  https://api.deepseek.com  ",
            model: "  deepseek-chat  ",
            promptTemplate: "{{text}}"
        )

        try store.saveProfiles([profile])

        let reloaded = store.loadProfiles()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded[0].name, "DeepSeek")
        XCTAssertEqual(reloaded[0].baseURL, "https://api.deepseek.com")
        XCTAssertEqual(reloaded[0].model, "deepseek-chat")
    }

    func testDisabledDraftProfileCanHaveInvalidConfiguration() {
        let profile = TranslatorProviderProfile(
            name: "草稿",
            isEnabled: false,
            baseURL: "",
            model: "",
            promptTemplate: ""
        )

        XCTAssertNotNil(profile.validationError)
    }

    func testMakeNewProfileUsesNextAvailableNameAndStartsDisabled() {
        let storage = TranslatorInMemoryPluginStorage()
        let store = TranslatorProviderProfileStore(storage: storage)
        let existing = [
            TranslatorProviderProfile(id: "one", name: "OpenAI 2"),
            TranslatorProviderProfile(id: "two", name: "OpenAI 3"),
        ]

        let profile = store.makeNewProfile(existingProfiles: existing)

        XCTAssertEqual(profile.name, "OpenAI 4")
        XCTAssertFalse(profile.isEnabled)
    }

    func testProfileScopedSecretAccountNameIsStable() {
        XCTAssertEqual(
            OpenAICompatibleSecretStore.account(profileID: "deepseek"),
            "translator.provider.deepseek.api-key"
        )
    }
}
