import Foundation
import MacToolsPluginKit
import XCTest

final class ActionModelsTests: XCTestCase {
    func testParameterSetCanonicalizesOrderAndRoundTripsDeterministically() throws {
        let first = try ActionParameterSet(entries: [
            .init(name: "target", value: .string("internal")),
            .init(name: "enabled", value: .boolean(true)),
        ])
        let second = try ActionParameterSet(entries: [
            .init(name: "enabled", value: .boolean(true)),
            .init(name: "target", value: .string("internal")),
        ])

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.entries.map(\.name), ["enabled", "target"])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(first)
        XCTAssertEqual(encoded, try encoder.encode(second))
        XCTAssertEqual(try JSONDecoder().decode(ActionParameterSet.self, from: encoded), first)
    }

    func testParameterSetRejectsDuplicatesAndOversizedSensitiveValues() throws {
        XCTAssertThrowsError(
            try ActionParameterSet(entries: [
                .init(name: "value", value: .integer(1)),
                .init(name: "value", value: .integer(2)),
            ])
        ) { error in
            XCTAssertEqual(error as? ActionParameterSetError, .duplicateName("value"))
        }

        XCTAssertThrowsError(
            try ActionParameterSet(entries: [
                .init(
                    name: "secret",
                    value: .string(String(repeating: "x", count: ActionParameterSet.maximumStringByteCount + 1))
                ),
            ])
        ) { error in
            XCTAssertEqual(error as? ActionParameterSetError, .stringTooLong("secret"))
        }
    }

    func testParameterSchemaCarriesPrivacyAndPortabilityMetadata() {
        let parameter = ActionParameterDefinition(
            id: "bookmark",
            title: "文件",
            kind: .string,
            privacy: .sensitive,
            portability: .localOnly
        )

        XCTAssertEqual(parameter.privacy, .sensitive)
        XCTAssertEqual(parameter.portability, .localOnly)
    }

    func testNonFiniteDoubleCannotEnterCanonicalIdentity() {
        XCTAssertThrowsError(
            try ActionParameterSet(entries: [
                .init(name: "value", value: .double(.infinity)),
            ])
        ) { error in
            XCTAssertEqual(error as? ActionParameterSetError, .nonFiniteNumber("value"))
        }
    }
}
