import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// 所有权归属与祖先分解（设计 §5.3）。
final class DiskCleanCandidateAssemblerTests: XCTestCase {
    // MARK: - 路径所有权

    func testMoreSpecificGlobPrefixWinsOwnership() {
        let generic = DiskCleanRuleTarget.test(id: "cache.generic", risk: .low)
        let specific = DiskCleanRuleTarget.test(id: "cache.specific", risk: .low)
        let hits = [
            DiskCleanTargetHit(target: generic, item: .testDirectory("/Caches/akd"), specificity: 7),
            DiskCleanTargetHit(target: specific, item: .testDirectory("/Caches/akd"), specificity: 11)
        ]

        let owners = DiskCleanCandidateAssembler.resolveOwnership(hits: hits)

        XCTAssertEqual(owners["/Caches/akd"]?.target.id, "cache.specific")
    }

    func testEqualSpecificityPrefersHigherRisk() {
        let low = DiskCleanRuleTarget.test(id: "cache.low", risk: .low)
        let medium = DiskCleanRuleTarget.test(id: "cache.medium", risk: .medium)
        let hits = [
            DiskCleanTargetHit(target: low, item: .testDirectory("/Caches/x"), specificity: 7),
            DiskCleanTargetHit(target: medium, item: .testDirectory("/Caches/x"), specificity: 7)
        ]

        let owners = DiskCleanCandidateAssembler.resolveOwnership(hits: hits)

        XCTAssertEqual(
            owners["/Caches/x"]?.target.id,
            "cache.medium",
            "并列时取更高风险：宁严勿宽（更高风险默认不勾选）"
        )
    }

    func testOwnershipIsIndependentOfHitOrder() {
        let first = DiskCleanRuleTarget.test(id: "cache.aaa", risk: .low)
        let second = DiskCleanRuleTarget.test(id: "cache.bbb", risk: .low)
        let forward = DiskCleanCandidateAssembler.resolveOwnership(hits: [
            DiskCleanTargetHit(target: first, item: .testDirectory("/x"), specificity: 2),
            DiskCleanTargetHit(target: second, item: .testDirectory("/x"), specificity: 2)
        ])
        let backward = DiskCleanCandidateAssembler.resolveOwnership(hits: [
            DiskCleanTargetHit(target: second, item: .testDirectory("/x"), specificity: 2),
            DiskCleanTargetHit(target: first, item: .testDirectory("/x"), specificity: 2)
        ])

        XCTAssertEqual(forward["/x"]?.target.id, backward["/x"]?.target.id)
    }

    // MARK: - 祖先分解

    func testAncestorIsDecomposedIntoDirectChildrenWhileDescendantKeepsIdentity() {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setChildren(
            [.testDirectory("/root/child"), .testDirectory("/root/other")],
            of: "/root"
        )
        fileSystem.setChildren(
            [.testDirectory("/root/child/deep"), .testFile("/root/child/sibling.bin")],
            of: "/root/child"
        )
        let ancestor = DiskCleanRuleTarget.test(id: "cache.ancestor", risk: .low)
        let descendant = DiskCleanRuleTarget.test(id: "cache.descendant", risk: .medium)
        let assembler = DiskCleanCandidateAssembler(fileSystem: fileSystem)

        let owned = assembler.assemble(hits: [
            DiskCleanTargetHit(target: ancestor, item: .testDirectory("/root"), specificity: 5),
            DiskCleanTargetHit(target: descendant, item: .testDirectory("/root/child/deep"), specificity: 16)
        ])

        XCTAssertEqual(
            owned.map(\.item.path),
            ["/root/child/deep", "/root/child/sibling.bin", "/root/other"]
        )
        XCTAssertEqual(
            Dictionary(owned.map { ($0.item.path, $0.target.id) }, uniquingKeysWith: { first, _ in first }),
            [
                "/root/child/deep": "cache.descendant",
                "/root/child/sibling.bin": "cache.ancestor",
                "/root/other": "cache.ancestor"
            ],
            "分解出的子项继承祖先的 target；后代候选保留自己的身份与风险"
        )
        XCTAssertFalse(owned.contains { $0.item.path == "/root" }, "祖先本身不再作为候选")
    }

    func testCandidateWithoutDescendantsIsKeptAsIs() {
        let fileSystem = FakeDiskCleanFileSystem()
        let target = DiskCleanRuleTarget.test(id: "cache.a")
        let assembler = DiskCleanCandidateAssembler(fileSystem: fileSystem)

        let owned = assembler.assemble(hits: [
            DiskCleanTargetHit(target: target, item: .testDirectory("/root/a"), specificity: 5),
            DiskCleanTargetHit(target: target, item: .testDirectory("/root/b"), specificity: 5)
        ])

        XCTAssertEqual(owned.map(\.item.path), ["/root/a", "/root/b"])
    }

    func testPrefixSiblingIsNotTreatedAsDescendant() {
        let fileSystem = FakeDiskCleanFileSystem()
        let target = DiskCleanRuleTarget.test(id: "cache.a")
        let assembler = DiskCleanCandidateAssembler(fileSystem: fileSystem)

        let owned = assembler.assemble(hits: [
            DiskCleanTargetHit(target: target, item: .testDirectory("/root/cache"), specificity: 5),
            DiskCleanTargetHit(target: target, item: .testDirectory("/root/cache-backup"), specificity: 5)
        ])

        XCTAssertEqual(
            owned.map(\.item.path),
            ["/root/cache", "/root/cache-backup"],
            "同前缀兄弟不是后代，不得触发分解"
        )
    }

    func testUnlistableAncestorIsDroppedRatherThanSwallowingDescendant() {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.markUnlistable("/root")
        let ancestor = DiskCleanRuleTarget.test(id: "cache.ancestor")
        let descendant = DiskCleanRuleTarget.test(id: "cache.descendant", risk: .medium)
        let assembler = DiskCleanCandidateAssembler(fileSystem: fileSystem)

        let owned = assembler.assemble(hits: [
            DiskCleanTargetHit(target: ancestor, item: .testDirectory("/root"), specificity: 5),
            DiskCleanTargetHit(target: descendant, item: .testDirectory("/root/deep"), specificity: 10)
        ])

        XCTAssertEqual(
            owned.map(\.item.path),
            ["/root/deep"],
            "列不出目录就整块放弃祖先：保留它会连带删掉后代的独立判定"
        )
    }

    func testMultipleDescendantsUnderSameAncestorAreAllPreserved() {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setChildren(
            [.testDirectory("/root/a"), .testDirectory("/root/b"), .testDirectory("/root/c")],
            of: "/root"
        )
        let ancestor = DiskCleanRuleTarget.test(id: "cache.ancestor")
        let first = DiskCleanRuleTarget.test(id: "cache.first", risk: .medium)
        let second = DiskCleanRuleTarget.test(id: "cache.second", risk: .medium)
        let assembler = DiskCleanCandidateAssembler(fileSystem: fileSystem)

        let owned = assembler.assemble(hits: [
            DiskCleanTargetHit(target: ancestor, item: .testDirectory("/root"), specificity: 5),
            DiskCleanTargetHit(target: first, item: .testDirectory("/root/a"), specificity: 7),
            DiskCleanTargetHit(target: second, item: .testDirectory("/root/b"), specificity: 7)
        ])

        XCTAssertEqual(
            Dictionary(owned.map { ($0.item.path, $0.target.id) }, uniquingKeysWith: { first, _ in first }),
            [
                "/root/a": "cache.first",
                "/root/b": "cache.second",
                "/root/c": "cache.ancestor"
            ]
        )
    }

    // MARK: - glob 固定前缀

    func testFixedPrefixIsLastCompleteComponentBeforeFirstWildcard() {
        XCTAssertEqual(
            DiskCleanGlobPrefix.fixedPrefix(of: "~/Library/Caches/*"),
            "~/Library/Caches"
        )
        XCTAssertEqual(
            DiskCleanGlobPrefix.fixedPrefix(of: "~/Library/Caches/com.apple.iconservices*"),
            "~/Library/Caches"
        )
        XCTAssertEqual(
            DiskCleanGlobPrefix.fixedPrefix(of: "~/Library/Application Support/Google/Chrome/*/Service Worker/*"),
            "~/Library/Application Support/Google/Chrome"
        )
        XCTAssertEqual(
            DiskCleanGlobPrefix.fixedPrefix(of: "~/Library/Caches/com.apple.akd"),
            "~/Library/Caches/com.apple.akd",
            "无通配符的 glob 本身就是固定前缀，因此最特定"
        )
    }

    func testMoreSpecificGlobHasLongerFixedPrefix() {
        let generic = DiskCleanGlobPrefix.fixedPrefix(of: "~/Library/Caches/*").count
        let specific = DiskCleanGlobPrefix.fixedPrefix(of: "~/Library/Caches/com.apple.akd").count

        XCTAssertGreaterThan(specific, generic)
    }
}
