import XCTest
@testable import MacTools
@testable import LaunchpadPlugin

final class LaunchpadFuzzyTests: XCTestCase {

    func testEmptyQueryMatchesWithZero() {
        XCTAssertEqual(LaunchpadFuzzy.score(name: "Safari", query: ""), 0)
    }

    func testPrefixScoresHighest() {
        XCTAssertEqual(LaunchpadFuzzy.score(name: "Safari", query: "saf"), LaunchpadFuzzy.prefixScore)
    }

    func testSubstringScoresBelowPrefix() {
        let s = LaunchpadFuzzy.score(name: "Google Safari", query: "saf")
        XCTAssertEqual(s, LaunchpadFuzzy.substringScore)
        XCTAssertLessThan(s!, LaunchpadFuzzy.prefixScore)
    }

    func testCaseInsensitive() {
        XCTAssertEqual(LaunchpadFuzzy.score(name: "SAFARI", query: "saf"), LaunchpadFuzzy.prefixScore)
        XCTAssertEqual(LaunchpadFuzzy.score(name: "safari", query: "SAF"), LaunchpadFuzzy.prefixScore)
    }

    func testSubsequenceMatches() {
        // a-m-o-n appears in order across "Activity Monitor" but not contiguously.
        let s = LaunchpadFuzzy.score(name: "Activity Monitor", query: "amon")
        XCTAssertNotNil(s)
        XCTAssertLessThan(s!, LaunchpadFuzzy.substringScore)   // weaker than a substring hit
    }

    func testNonMatchReturnsNil() {
        XCTAssertNil(LaunchpadFuzzy.score(name: "Safari", query: "xyz"))
        XCTAssertNil(LaunchpadFuzzy.score(name: "Safari", query: "safx"))   // 'x' breaks it
    }

    func testOrderMattersForSubsequence() {
        // "fas" is NOT a subsequence of "Safari" (f comes after a, s after r).
        XCTAssertNil(LaunchpadFuzzy.score(name: "Safari", query: "fas"))
    }

    func testRankingPrefixOverSubsequence() {
        let prefix = LaunchpadFuzzy.score(name: "Terminal", query: "ter")!
        let subseq = LaunchpadFuzzy.score(name: "Time Tracker", query: "ter")!  // t..e..r subsequence
        XCTAssertGreaterThan(prefix, subseq)
    }
}
