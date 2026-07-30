import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Ownership resolution and ancestor decomposition (design §5.3).
final class DiskCleanCandidateAssemblerTests: XCTestCase {
    // MARK: - Path ownership

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
            "on a tie, prefer higher risk: fail closed (higher risk is unchecked by default)"
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

    // MARK: - Ancestor decomposition

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
            "decomposed children inherit the ancestor target; descendant candidates keep their own identity and risk"
        )
        XCTAssertFalse(owned.contains { $0.item.path == "/root" }, "the ancestor itself is no longer a candidate")
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
            "prefix siblings are not descendants and must not trigger decomposition"
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
            "if the directory is unlistable, drop the ancestor entirely: keeping it would erase independent descendant decisions"
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

    // MARK: - Glob fixed prefix

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
            "a glob without wildcards is itself the fixed prefix, and therefore most specific"
        )
    }

    func testMoreSpecificGlobHasLongerFixedPrefix() {
        let generic = DiskCleanGlobPrefix.fixedPrefix(of: "~/Library/Caches/*").count
        let specific = DiskCleanGlobPrefix.fixedPrefix(of: "~/Library/Caches/com.apple.akd").count

        XCTAssertGreaterThan(specific, generic)
    }
}
