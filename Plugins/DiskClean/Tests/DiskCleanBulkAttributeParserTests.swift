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

    // MARK: - RETURNED_ATTRS 缺失组合矩阵

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

    /// 目录条目不携带 ATTR_FILE_*，这是内核的正常行为而非异常，必须视为"已完整解析"。
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

    /// 逐个抽掉一项关键属性：其余字段仍必须解析正确（证明按位图跳过的偏移计算无误），
    /// 且 isFullyResolved 必须转 false 以触发 fstatat 回退。
    func testMissingAttributeCombinationsShiftRemainingFieldsCorrectly() throws {
        let cases: [(String, EntryEncoder.Entry, (DiskCleanBulkAttributeEntry) -> Void)] = [
            ("缺 DEVID", EntryEncoder.Entry(
                name: "a", devid: nil, objectType: UInt32(VREG.rawValue),
                fileID: 11, linkCount: 2, dataLength: 64
            ), { entry in
                XCTAssertNil(entry.devid)
                XCTAssertEqual(entry.fileType, .regularFile)
                XCTAssertEqual(entry.fileID, 11)
                XCTAssertEqual(entry.linkCount, 2)
                XCTAssertEqual(entry.dataLength, 64)
            }),
            ("缺 OBJTYPE", EntryEncoder.Entry(
                name: "b", devid: 5, objectType: nil,
                fileID: 12, linkCount: 1, dataLength: 128
            ), { entry in
                XCTAssertEqual(entry.devid, 5)
                XCTAssertNil(entry.fileType)
                XCTAssertEqual(entry.fileID, 12)
                XCTAssertEqual(entry.dataLength, 128)
            }),
            ("缺 FILEID", EntryEncoder.Entry(
                name: "c", devid: 5, objectType: UInt32(VLNK.rawValue),
                fileID: nil, linkCount: 1, dataLength: 9
            ), { entry in
                XCTAssertEqual(entry.fileType, .symlink)
                XCTAssertNil(entry.fileID)
                XCTAssertEqual(entry.dataLength, 9)
            }),
            ("缺 LINKCOUNT", EntryEncoder.Entry(
                name: "d", devid: 5, objectType: UInt32(VREG.rawValue),
                fileID: 13, linkCount: nil, dataLength: 256
            ), { entry in
                XCTAssertNil(entry.linkCount)
                XCTAssertEqual(entry.dataLength, 256)
            }),
            ("缺 DATALENGTH", EntryEncoder.Entry(
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

    // MARK: - 布局错位检测

    /// 复刻内核对 `ATTR_CMN_ERROR` 的实测行为：请求了但 returned 位为 0，字段却仍占 4 字节。
    /// 朴素的"按位图跳过"解析器会从此错位，把 linkCount 读成 dataLength 的高半部分等等。
    /// 解析器必须借 NAME 的 attr_dataoffset 发现边界不符，置 hasLayoutMismatch 并放弃这批属性值。
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
        XCTAssertFalse(entry.isFullyResolved, "错位后属性不可信，必须触发 fstatat 回退")
        // 名字靠 attr_dataoffset 定位，仍然可用——回退需要它。
        XCTAssertEqual(entry.displayName, "shifted")
        XCTAssertNil(entry.devid)
        XCTAssertNil(entry.fileType)
        XCTAssertNil(entry.fileID)
        XCTAssertNil(entry.linkCount)
        XCTAssertNil(entry.dataLength)
    }

    // MARK: - 多条与截断

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

        // 内核声称 3 条，缓冲区只装得下 1 条。
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

    // MARK: - 与真实内核缓冲区交叉验证

    /// 最重要的一条：不验证"解析器与本测试的编码器是否自洽"，而是验证
    /// **解析器与真实内核输出是否一致**。编码器写错了也骗不过这条。
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
            XCTAssertGreaterThanOrEqual(returnedCount, 0, "getattrlistbulk 失败 errno=\(errno)")
            if returnedCount <= 0 { break }

            let result = DiskCleanBulkAttributeParser.parse(
                buffer: UnsafeRawBufferPointer(start: raw, count: capacity),
                entryCount: Int(returnedCount)
            )
            XCTAssertFalse(result.isTruncated, "真实内核缓冲区不应被判为截断")
            for entry in result.entries {
                XCTAssertFalse(entry.hasLayoutMismatch, "真实内核缓冲区不应错位：\(entry.displayName ?? "?")")
                byName[try XCTUnwrap(entry.displayName)] = entry
            }
        }

        XCTAssertEqual(Set(byName.keys), ["payload.bin", "subdir", "link", "hard.bin"])

        let payload = try XCTUnwrap(byName["payload.bin"])
        XCTAssertEqual(payload.fileType, .regularFile)
        XCTAssertEqual(payload.dataLength, 10)
        XCTAssertEqual(payload.linkCount, 2, "payload.bin 与 hard.bin 互为硬链接")
        XCTAssertTrue(payload.isFullyResolved)

        let hard = try XCTUnwrap(byName["hard.bin"])
        XCTAssertEqual(hard.fileID, payload.fileID, "硬链接共享 fileID，去重键据此成立")
        XCTAssertEqual(hard.devid, payload.devid)

        let directory = try XCTUnwrap(byName["subdir"])
        XCTAssertEqual(directory.fileType, .directory)
        XCTAssertNil(directory.dataLength, "内核不为目录返回 ATTR_FILE_*")
        XCTAssertTrue(directory.isFullyResolved)

        let link = try XCTUnwrap(byName["link"])
        XCTAssertEqual(link.fileType, .symlink)
        XCTAssertEqual(link.dataLength, Int64("payload.bin".utf8.count), "symlink 的逻辑大小是目标字符串长度")
    }

    // MARK: - 辅助

    private func parse(_ bytes: [UInt8], entryCount: Int) -> DiskCleanBulkAttributeParseResult {
        bytes.withUnsafeBytes { buffer in
            DiskCleanBulkAttributeParser.parse(buffer: buffer, entryCount: entryCount)
        }
    }

    /// 按内核实测布局编码条目：4 字节长度 + 20 字节 RETURNED_ATTRS + 固定段（属性位值升序、
    /// 紧密无对齐填充）+ 变长段（唯一变长字段 NAME）。
    private enum EntryEncoder {
        struct Entry {
            var name: String?
            var devid: UInt32?
            var objectType: UInt32?
            var fileID: UInt64?
            var linkCount: UInt32?
            var dataLength: Int64?
            /// 模拟"请求了但 returned 位为 0 却仍占位"的字节数，插在固定段末尾。
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

            // attribute_set_t 顺序：common / vol / dir / file / fork
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
