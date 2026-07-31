import Darwin
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanBulkAttributeParserTests: XCTestCase {
    private var temporaryDirectory: DiskCleanTempDirectory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = try DiskCleanTempDirectory(name: "DiskCleanBulkAttributeParserTests")
    }

    override func tearDownWithError() throws {
        temporaryDirectory?.remove()
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - RETURNED_ATTRS missing-attribute matrix

    func testParsesAllRequestedAttributes() throws {
        let buffer = EntryEncoder.encode([
            EntryEncoder.Entry(
                name: "cache.bin",
                devid: 0x0100_0011,
                objectType: UInt32(VREG.rawValue),
                fileID: 4242,
                linkCount: 1,
                dataLength: 1024
            )
        ])

        let entry = try XCTUnwrap(parse(buffer, entryCount: 1).entries.first)

        XCTAssertEqual(entry.displayName, "cache.bin")
        XCTAssertEqual(entry.devid, 0x0100_0011)
        XCTAssertEqual(entry.fileType, .regularFile)
        XCTAssertEqual(entry.fileID, 4242)
        XCTAssertEqual(entry.linkCount, 1)
        XCTAssertEqual(entry.dataLength, 1024)
        XCTAssertFalse(entry.hasLayoutMismatch)
        XCTAssertTrue(entry.isFullyResolved)
    }

    /// Directory entries omit ATTR_FILE_*; that is normal kernel behavior, not an error, and must count as fully resolved.
    func testDirectoryEntryWithoutFileAttributesIsFullyResolved() throws {
        let buffer = EntryEncoder.encode([
            EntryEncoder.Entry(
                name: "Nested",
                devid: 7,
                objectType: UInt32(VDIR.rawValue),
                fileID: 99,
                linkCount: nil,
                dataLength: nil
            )
        ])

        let entry = try XCTUnwrap(parse(buffer, entryCount: 1).entries.first)

        XCTAssertEqual(entry.displayName, "Nested")
        XCTAssertEqual(entry.fileType, .directory)
        XCTAssertNil(entry.linkCount)
        XCTAssertNil(entry.dataLength)
        XCTAssertTrue(entry.isFullyResolved)
    }

    /// Drop one critical attribute at a time: remaining fields must still parse correctly
    /// (proving bitmap-skip offset math), and isFullyResolved must become false to trigger fstatat fallback.
    func testMissingAttributeCombinationsShiftRemainingFieldsCorrectly() throws {
        let cases: [(String, EntryEncoder.Entry, (DiskCleanBulkAttributeEntry) -> Void)] = [
            ("missing DEVID", EntryEncoder.Entry(
                name: "a", devid: nil, objectType: UInt32(VREG.rawValue),
                fileID: 11, linkCount: 2, dataLength: 64
            ), { entry in
                XCTAssertNil(entry.devid)
                XCTAssertEqual(entry.fileType, .regularFile)
                XCTAssertEqual(entry.fileID, 11)
                XCTAssertEqual(entry.linkCount, 2)
                XCTAssertEqual(entry.dataLength, 64)
            }),
            ("missing OBJTYPE", EntryEncoder.Entry(
                name: "b", devid: 5, objectType: nil,
                fileID: 12, linkCount: 1, dataLength: 128
            ), { entry in
                XCTAssertEqual(entry.devid, 5)
                XCTAssertNil(entry.fileType)
                XCTAssertEqual(entry.fileID, 12)
                XCTAssertEqual(entry.dataLength, 128)
            }),
            ("missing FILEID", EntryEncoder.Entry(
                name: "c", devid: 5, objectType: UInt32(VLNK.rawValue),
                fileID: nil, linkCount: 1, dataLength: 9
            ), { entry in
                XCTAssertEqual(entry.fileType, .symlink)
                XCTAssertNil(entry.fileID)
                XCTAssertEqual(entry.dataLength, 9)
            }),
            ("missing LINKCOUNT", EntryEncoder.Entry(
                name: "d", devid: 5, objectType: UInt32(VREG.rawValue),
                fileID: 13, linkCount: nil, dataLength: 256
            ), { entry in
                XCTAssertNil(entry.linkCount)
                XCTAssertEqual(entry.dataLength, 256)
            }),
            ("missing DATALENGTH", EntryEncoder.Entry(
                name: "e", devid: 5, objectType: UInt32(VREG.rawValue),
                fileID: 14, linkCount: 1, dataLength: nil
            ), { entry in
                XCTAssertEqual(entry.linkCount, 1)
                XCTAssertNil(entry.dataLength)
            })
        ]

        for (label, encoded, assertions) in cases {
            let entry = try XCTUnwrap(parse(EntryEncoder.encode([encoded]), entryCount: 1).entries.first, label)
            XCTAssertEqual(entry.displayName, encoded.name, label)
            XCTAssertFalse(entry.hasLayoutMismatch, label)
            XCTAssertFalse(entry.isFullyResolved, label)
            assertions(entry)
        }
    }

    func testOnlyNameReturned() throws {
        let buffer = EntryEncoder.encode([
            EntryEncoder.Entry(
                name: "lonely", devid: nil, objectType: nil,
                fileID: nil, linkCount: nil, dataLength: nil
            )
        ])

        let entry = try XCTUnwrap(parse(buffer, entryCount: 1).entries.first)

        XCTAssertEqual(entry.displayName, "lonely")
        XCTAssertNil(entry.devid)
        XCTAssertNil(entry.fileType)
        XCTAssertFalse(entry.isFullyResolved)
    }

    func testMapsObjectTypesIncludingUnusualOnes() throws {
        let expectations: [(UInt32, DiskCleanRootIdentity.FileType)] = [
            (UInt32(VDIR.rawValue), .directory),
            (UInt32(VREG.rawValue), .regularFile),
            (UInt32(VLNK.rawValue), .symlink),
            (UInt32(VSOCK.rawValue), .other),
            (UInt32(VFIFO.rawValue), .other)
        ]

        for (objectType, expected) in expectations {
            let buffer = EntryEncoder.encode([
                EntryEncoder.Entry(
                    name: "x", devid: 1, objectType: objectType,
                    fileID: 1, linkCount: 1, dataLength: 0
                )
            ])
            let entry = try XCTUnwrap(parse(buffer, entryCount: 1).entries.first)
            XCTAssertEqual(entry.fileType, expected, "objectType=\(objectType)")
        }
    }

    // MARK: - Layout mismatch detection

    /// Reproduces observed kernel behavior for `ATTR_CMN_ERROR`: requested but returned bit is 0, yet the field still occupies 4 bytes.
    /// A naive "skip by bitmap" parser misaligns from here, reading linkCount as the high half of dataLength, etc.
    /// The parser must use NAME's attr_dataoffset to detect the boundary mismatch, set hasLayoutMismatch, and discard attribute values.
    func testDetectsReservedButUnreturnedAttributeAsLayoutMismatch() throws {
        let buffer = EntryEncoder.encode([
            EntryEncoder.Entry(
                name: "shifted", devid: 5, objectType: UInt32(VREG.rawValue),
                fileID: 20, linkCount: 1, dataLength: 512,
                reservedPaddingBytes: 4
            )
        ])

        let entry = try XCTUnwrap(parse(buffer, entryCount: 1).entries.first)

        XCTAssertTrue(entry.hasLayoutMismatch)
        XCTAssertFalse(entry.isFullyResolved, "attributes are untrustworthy after mismatch; must trigger fstatat fallback")
        // Name is located via attr_dataoffset and remains usable — fallback needs it.
        XCTAssertEqual(entry.displayName, "shifted")
        XCTAssertNil(entry.devid)
        XCTAssertNil(entry.fileType)
        XCTAssertNil(entry.fileID)
        XCTAssertNil(entry.linkCount)
        XCTAssertNil(entry.dataLength)
    }

    // MARK: - Multiple entries and truncation

    func testParsesMultipleEntriesInOneBuffer() {
        let buffer = EntryEncoder.encode([
            EntryEncoder.Entry(
                name: "first", devid: 1, objectType: UInt32(VREG.rawValue),
                fileID: 1, linkCount: 1, dataLength: 10
            ),
            EntryEncoder.Entry(
                name: "second-with-longer-name", devid: 1, objectType: UInt32(VDIR.rawValue),
                fileID: 2, linkCount: nil, dataLength: nil
            ),
            EntryEncoder.Entry(
                name: "third", devid: 1, objectType: UInt32(VREG.rawValue),
                fileID: 3, linkCount: 1, dataLength: 30
            )
        ])

        let result = parse(buffer, entryCount: 3)

        XCTAssertFalse(result.isTruncated)
        XCTAssertEqual(result.entries.map(\.displayName), ["first", "second-with-longer-name", "third"])
        XCTAssertEqual(result.entries.map(\.dataLength), [10, nil, 30])
    }

    func testReportsTruncationWhenBufferHoldsFewerEntriesThanClaimed() {
        let buffer = EntryEncoder.encode([
            EntryEncoder.Entry(
                name: "only", devid: 1, objectType: UInt32(VREG.rawValue),
                fileID: 1, linkCount: 1, dataLength: 10
            )
        ])

        // Kernel claims 3 entries; buffer only fits 1.
        let result = parse(buffer, entryCount: 3)

        XCTAssertTrue(result.isTruncated)
        XCTAssertEqual(result.entries.count, 1)
    }

    func testReportsTruncationOnZeroLengthEntry() {
        let buffer = [UInt8](repeating: 0, count: 64)

        let result = parse(buffer, entryCount: 1)

        XCTAssertTrue(result.isTruncated)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testEmptyEntryCountYieldsNoEntries() {
        let result = parse([UInt8](repeating: 0, count: 64), entryCount: 0)

        XCTAssertFalse(result.isTruncated)
        XCTAssertTrue(result.entries.isEmpty)
    }

    // MARK: - Cross-check against real kernel buffer

    /// Most important case: do not only check "parser agrees with this test's encoder";
    /// verify the **parser matches real kernel output**. A buggy encoder cannot pass this.
    func testParsesRealKernelBuffer() throws {
        try temporaryDirectory.makeFile("payload.bin", bytes: 10)
        try temporaryDirectory.makeDirectory("subdir")
        try temporaryDirectory.makeSymlink("link", destination: "payload.bin")
        try temporaryDirectory.makeHardLink("hard.bin", to: "payload.bin")

        let descriptor = open(temporaryDirectory.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        var attributeList = DiskCleanBulkAttributeParser.makeAttributeList()
        let capacity = 64 * 1024
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { raw.deallocate() }

        var byName: [String: DiskCleanBulkAttributeEntry] = [:]
        while true {
            let returnedCount = getattrlistbulk(descriptor, &attributeList, raw, capacity, 0)
            XCTAssertGreaterThanOrEqual(returnedCount, 0, "getattrlistbulk failed errno=\(errno)")
            if returnedCount <= 0 { break }

            let result = DiskCleanBulkAttributeParser.parse(
                buffer: UnsafeRawBufferPointer(start: raw, count: capacity),
                entryCount: Int(returnedCount)
            )
            XCTAssertFalse(result.isTruncated, "real kernel buffer must not be treated as truncated")
            for entry in result.entries {
                XCTAssertFalse(entry.hasLayoutMismatch, "real kernel buffer must not report layout mismatch: \(entry.displayName ?? "?")")
                byName[try XCTUnwrap(entry.displayName)] = entry
            }
        }

        XCTAssertEqual(Set(byName.keys), ["payload.bin", "subdir", "link", "hard.bin"])

        let payload = try XCTUnwrap(byName["payload.bin"])
        XCTAssertEqual(payload.fileType, .regularFile)
        XCTAssertEqual(payload.dataLength, 10)
        XCTAssertEqual(payload.linkCount, 2, "payload.bin and hard.bin are hard links of each other")
        XCTAssertTrue(payload.isFullyResolved)

        let hard = try XCTUnwrap(byName["hard.bin"])
        XCTAssertEqual(hard.fileID, payload.fileID, "hard links share fileID; the dedupe key depends on that")
        XCTAssertEqual(hard.devid, payload.devid)

        let directory = try XCTUnwrap(byName["subdir"])
        XCTAssertEqual(directory.fileType, .directory)
        XCTAssertNil(directory.dataLength, "kernel does not return ATTR_FILE_* for directories")
        XCTAssertTrue(directory.isFullyResolved)

        let link = try XCTUnwrap(byName["link"])
        XCTAssertEqual(link.fileType, .symlink)
        XCTAssertEqual(link.dataLength, Int64("payload.bin".utf8.count), "symlink logical size is the target string length")
    }

    // MARK: - Helpers

    private func parse(_ bytes: [UInt8], entryCount: Int) -> DiskCleanBulkAttributeParseResult {
        bytes.withUnsafeBytes { buffer in
            DiskCleanBulkAttributeParser.parse(buffer: buffer, entryCount: entryCount)
        }
    }

    /// Encode entries in the observed kernel layout: 4-byte length + 20-byte RETURNED_ATTRS + fixed section
    /// (attributes in ascending bit order, packed without alignment padding) + variable section (NAME only).
    private enum EntryEncoder {
        struct Entry {
            var name: String?
            var devid: UInt32?
            var objectType: UInt32?
            var fileID: UInt64?
            var linkCount: UInt32?
            var dataLength: Int64?
            /// Simulated bytes for "requested but returned bit is 0 yet still occupies space", inserted at end of fixed section.
            var reservedPaddingBytes: Int = 0
        }

        static func encode(_ entries: [Entry]) -> [UInt8] {
            entries.flatMap(encodeOne)
        }

        private static func encodeOne(_ entry: Entry) -> [UInt8] {
            var fixedSize = 4 + 20
            var nameReferenceOffset = -1
            if entry.name != nil {
                nameReferenceOffset = fixedSize
                fixedSize += 8
            }
            if entry.devid != nil { fixedSize += 4 }
            if entry.objectType != nil { fixedSize += 4 }
            if entry.fileID != nil { fixedSize += 8 }
            if entry.linkCount != nil { fixedSize += 4 }
            if entry.dataLength != nil { fixedSize += 8 }
            fixedSize += entry.reservedPaddingBytes

            let nameBytes: [UInt8] = entry.name.map { Array($0.utf8) + [0] } ?? []
            let totalLength = fixedSize + nameBytes.count

            var bytes: [UInt8] = []
            bytes.reserveCapacity(totalLength)
            append(UInt32(totalLength), to: &bytes)

            var commonReturned = UInt32(ATTR_CMN_RETURNED_ATTRS)
            if entry.name != nil { commonReturned |= UInt32(ATTR_CMN_NAME) }
            if entry.devid != nil { commonReturned |= UInt32(ATTR_CMN_DEVID) }
            if entry.objectType != nil { commonReturned |= UInt32(ATTR_CMN_OBJTYPE) }
            if entry.fileID != nil { commonReturned |= UInt32(ATTR_CMN_FILEID) }
            var fileReturned: UInt32 = 0
            if entry.linkCount != nil { fileReturned |= UInt32(ATTR_FILE_LINKCOUNT) }
            if entry.dataLength != nil { fileReturned |= UInt32(ATTR_FILE_DATALENGTH) }

            // attribute_set_t order: common / vol / dir / file / fork
            append(commonReturned, to: &bytes)
            append(UInt32(0), to: &bytes)
            append(UInt32(0), to: &bytes)
            append(fileReturned, to: &bytes)
            append(UInt32(0), to: &bytes)

            if entry.name != nil {
                let dataOffset = Int32(fixedSize - nameReferenceOffset)
                append(dataOffset, to: &bytes)
                append(UInt32(nameBytes.count), to: &bytes)
            }
            if let devid = entry.devid { append(devid, to: &bytes) }
            if let objectType = entry.objectType { append(objectType, to: &bytes) }
            if let fileID = entry.fileID { append(fileID, to: &bytes) }
            if let linkCount = entry.linkCount { append(linkCount, to: &bytes) }
            if let dataLength = entry.dataLength { append(dataLength, to: &bytes) }
            bytes.append(contentsOf: [UInt8](repeating: 0, count: entry.reservedPaddingBytes))
            bytes.append(contentsOf: nameBytes)

            return bytes
        }

        private static func append<T>(_ value: T, to bytes: inout [UInt8]) {
            withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
        }
    }
}
