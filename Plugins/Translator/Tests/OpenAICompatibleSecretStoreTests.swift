import Foundation
import XCTest
@testable import TranslatorPlugin

final class OpenAICompatibleSecretStoreTests: XCTestCase {
    private var service: String!
    private var store: OpenAICompatibleSecretStore!

    override func setUpWithError() throws {
        try super.setUpWithError()

        service = "cc.ggbond.mactools.translator.tests.\(UUID().uuidString)"
        store = OpenAICompatibleSecretStore(service: service)
        try store.deleteAPIKey()
    }

    override func tearDownWithError() throws {
        try store?.deleteAPIKey()
        store = nil
        service = nil

        try super.tearDownWithError()
    }

    func testSaveLoadDeleteAPIKey() throws {
        try store.saveAPIKey("  sk-test-value  ")

        XCTAssertEqual(try store.loadAPIKey(), "sk-test-value")

        try store.deleteAPIKey()

        XCTAssertNil(try store.loadAPIKey())
    }

    func testSavingBlankDeletesExistingAPIKey() throws {
        try store.saveAPIKey("sk-test-value")

        try store.saveAPIKey("   \n\t  ")

        XCTAssertNil(try store.loadAPIKey())
    }

    func testLoadAPIKeyThrowsWhenStoredDataIsNotUTF8() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service!,
            kSecAttrAccount as String: OpenAICompatibleSecretStore.defaultAccount,
            kSecValueData as String: Data([0xFF, 0xFE]),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)

        XCTAssertThrowsError(try store.loadAPIKey()) { error in
            XCTAssertEqual(error as? OpenAICompatibleSecretStoreError, .unexpectedItemData)
        }
    }
}
