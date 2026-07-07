import Foundation

enum OCRTextMerge {
    static func merge(_ lines: [OCRRecognizedLine]) -> String {
        let normalizedLines = lines.compactMap { line -> OCRRecognizedLine? in
            let text = normalizeFragment(line.text)
            guard !text.isEmpty else { return nil }
            return OCRRecognizedLine(
                text: text,
                boundingBox: line.boundingBox,
                confidence: line.confidence
            )
        }

        guard !normalizedLines.isEmpty else { return "" }

        let positiveHeights = normalizedLines
            .map(\.boundingBox.height)
            .filter { $0 > 0 }
        let averageHeight = positiveHeights.reduce(CGFloat.zero, +) / CGFloat(max(1, positiveHeights.count))
        let rowTolerance = max(averageHeight * 0.65, CGFloat(0.015))

        let sorted = normalizedLines.sorted { lhs, rhs in
            let lhsCenterY = lhs.boundingBox.midY
            let rhsCenterY = rhs.boundingBox.midY
            if abs(lhsCenterY - rhsCenterY) > rowTolerance {
                return lhsCenterY > rhsCenterY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        var rows: [[OCRRecognizedLine]] = []
        for line in sorted {
            if let lastIndex = rows.indices.last,
               let rowCenterY = averageCenterY(rows[lastIndex]),
               abs(line.boundingBox.midY - rowCenterY) <= rowTolerance {
                rows[lastIndex].append(line)
            } else {
                rows.append([line])
            }
        }

        return rows
            .map { row in
                mergeRow(row.sorted { $0.boundingBox.minX < $1.boundingBox.minX })
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mergeRow(_ row: [OCRRecognizedLine]) -> String {
        var output = ""

        for line in row {
            guard !line.text.isEmpty else { continue }

            if output.isEmpty {
                output = line.text
            } else if shouldJoinWithoutSpace(output, line.text) {
                output += line.text
            } else {
                output += " " + line.text
            }
        }

        return normalizeFragment(output)
    }

    private static func averageCenterY(_ row: [OCRRecognizedLine]) -> CGFloat? {
        guard !row.isEmpty else { return nil }
        return row.map(\.boundingBox.midY).reduce(0, +) / CGFloat(row.count)
    }

    private static func normalizeFragment(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shouldJoinWithoutSpace(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = lhs.unicodeScalars.last,
              let right = rhs.unicodeScalars.first
        else {
            return false
        }

        return isCJK(left) || isCJK(right)
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x3040...0x30FF,
             0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }
}
