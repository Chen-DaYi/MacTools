import Foundation
import XCTest
@testable import AppleShortcutsPlugin

@MainActor
final class AppleShortcutsIconCacheTests: XCTestCase {
    func testStoresAndReturnsIconData() {
        let cache = AppleShortcutsIconCache()
        let shortcutID = UUID()
        let iconData = Data([0x01, 0x02, 0x03])

        XCTAssertNil(cache.data(for: shortcutID))
        cache.store(iconData, for: shortcutID)

        XCTAssertEqual(cache.data(for: shortcutID), iconData)
    }

    func testRemoveAllDiscardsEveryCachedIcon() {
        let cache = AppleShortcutsIconCache()
        let firstID = UUID()
        let secondID = UUID()
        cache.store(Data([0x01]), for: firstID)
        cache.store(Data([0x02]), for: secondID)

        cache.removeAll()

        XCTAssertNil(cache.data(for: firstID))
        XCTAssertNil(cache.data(for: secondID))
    }

    func testEvictsEntriesOnceTheCostLimitIsExceeded() {
        let cache = AppleShortcutsIconCache(totalCostLimit: 10)
        let firstID = UUID()
        let secondID = UUID()

        cache.store(Data(repeating: 0, count: 8), for: firstID)
        cache.store(Data(repeating: 0, count: 8), for: secondID)

        // NSCache doesn't guarantee eviction order, only that it enforces the cost budget.
        let remaining = [firstID, secondID].compactMap { cache.data(for: $0) }
        XCTAssertLessThan(remaining.count, 2, "exceeding the cost limit should evict at least one entry")
    }
}
