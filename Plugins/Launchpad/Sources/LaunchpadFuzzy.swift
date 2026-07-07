import Foundation

/// Subsequence fuzzy matching with relevance scoring for the launcher search.
///
/// A query matches a name when its characters appear in order (case-insensitive).
/// Scoring keeps the common cases on top: a prefix outranks a substring, which
/// outranks a scattered subsequence; consecutive runs are rewarded so "saf" still
/// surfaces "Safari" above incidental subsequence hits.
enum LaunchpadFuzzy {
    static let prefixScore = 1000
    static let substringScore = 500

    /// Returns a relevance score (higher = better) if `query` matches `name`, else nil.
    /// An empty query matches everything with score 0 (caller keeps its own order).
    static func score(name: String, query: String) -> Int? {
        let q = query.lowercased()
        guard !q.isEmpty else { return 0 }
        let n = name.lowercased()

        if n.hasPrefix(q) { return prefixScore }
        if n.contains(q) { return substringScore }

        var index = n.startIndex
        var score = 0
        var run = 0
        for qc in q {
            var matched = false
            while index < n.endIndex {
                let nc = n[index]
                index = n.index(after: index)
                if nc == qc {
                    run += 1
                    score += 1 + run        // reward consecutive matches
                    matched = true
                    break
                }
                run = 0
            }
            if !matched { return nil }       // query char never found → no match
        }
        return score
    }
}
