import Darwin
import Foundation

/// `getattrlistbulk` 返回的单条原始属性。缺失字段为 nil——非 APFS 卷会缺属性，
/// 解析器不得假设固定布局（设计 §3.3）。
struct DiskCleanBulkAttributeEntry: Equatable, Sendable {
    /// 条目名，以 NUL 结尾的**原始字节**。
    ///
    /// 文件名不保证是合法 UTF-8（HFS+ / 外置卷 / FUSE 都可能出现非法序列）。
    /// 先转 String 再传回 `openat`/`fstatat` 会丢字节导致下潜失败并被误记为 walkError，
    /// 因此按字节保存，只在展示时才做有损转换。
    var nameBytes: [CChar]?
    var fileType: DiskCleanRootIdentity.FileType?
    var devid: UInt64?
    var fileID: UInt64?
    var linkCount: UInt32?
    var dataLength: Int64?
    /// true = 固定段实际边界与 `ATTR_CMN_NAME` 的 `attr_dataoffset` 不符。
    ///
    /// 说明见 `DiskCleanBulkAttributeParser` 的布局校验注释。此时除 `nameBytes` 外
    /// 的所有属性都不可信，调用方必须走 `fstatat` 逐条回退。
    var hasLayoutMismatch: Bool = false

    var displayName: String? {
        guard let nameBytes else { return nil }
        let bytes = nameBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 关键属性是否齐备。目录不携带 `ATTR_FILE_*`，故其 linkCount/dataLength 允许缺失。
    var isFullyResolved: Bool {
        guard !hasLayoutMismatch, nameBytes != nil, let fileType, devid != nil, fileID != nil else {
            return false
        }
        if fileType == .directory {
            return true
        }
        return linkCount != nil && dataLength != nil
    }
}

struct DiskCleanBulkAttributeParseResult: Equatable, Sendable {
    let entries: [DiskCleanBulkAttributeEntry]
    /// 缓冲区结构异常导致提前终止：实际解析出的条目少于内核声明的条数。
    let isTruncated: Bool
}

/// `getattrlistbulk` 缓冲区解析器。
///
/// **布局事实（已对内核实测验证，勿凭 man page 推测）**：
/// 1. 条目内固定段按属性位值升序紧密排列，无对齐填充，故必须用非对齐读取。
/// 2. `RETURNED_ATTRS` 恒为首个字段（紧随 4 字节条目长度之后）。
/// 3. 请求了但未返回的属性**不一定**从缓冲区消失：目录条目的 `ATTR_FILE_*` 确实缺席，
///    而 `ATTR_CMN_ERROR` 即使 returned 位为 0 也仍占 4 字节。因此本解析器
///    **不请求 `ATTR_CMN_ERROR`**——按位图跳过它会让其后所有字段错位。
///    逐条失败的检测改由调用方的 `fstatat` 回退承担（信息量严格更大）。
/// 4. 为防御同类未知的"保留但不置位"行为，解析完固定段后用 `ATTR_CMN_NAME` 的
///    `attr_dataoffset`（变长段起点，独立于位图）复核边界；不符即置
///    `hasLayoutMismatch`，把静默错位转成可检测的安全回退。
enum DiskCleanBulkAttributeParser {
    static let requestedCommonAttributes: attrgroup_t =
        attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        | attrgroup_t(ATTR_CMN_NAME)
        | attrgroup_t(ATTR_CMN_DEVID)
        | attrgroup_t(ATTR_CMN_OBJTYPE)
        | attrgroup_t(ATTR_CMN_FILEID)

    static let requestedFileAttributes: attrgroup_t =
        attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_DATALENGTH)

    /// 内核返回的属性位图在 `attribute_set_t` 中的下标：common/vol/dir/file/fork。
    private static let commonGroupIndex = 0
    private static let fileGroupIndex = 3
    private static let returnedAttributesSize = 20

    static func makeAttributeList() -> attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = requestedCommonAttributes
        list.fileattr = requestedFileAttributes
        return list
    }

    static func parse(
        buffer: UnsafeRawBufferPointer,
        entryCount: Int
    ) -> DiskCleanBulkAttributeParseResult {
        guard entryCount > 0 else {
            return DiskCleanBulkAttributeParseResult(entries: [], isTruncated: false)
        }

        var entries: [DiskCleanBulkAttributeEntry] = []
        entries.reserveCapacity(entryCount)
        var cursor = 0

        for _ in 0..<entryCount {
            guard cursor + 4 <= buffer.count else {
                return DiskCleanBulkAttributeParseResult(entries: entries, isTruncated: true)
            }
            let entryLength = Int(buffer.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
            guard entryLength >= 4, cursor + entryLength <= buffer.count else {
                return DiskCleanBulkAttributeParseResult(entries: entries, isTruncated: true)
            }

            entries.append(
                parseEntry(
                    buffer: UnsafeRawBufferPointer(rebasing: buffer[cursor..<(cursor + entryLength)])
                )
            )
            cursor += entryLength
        }

        return DiskCleanBulkAttributeParseResult(entries: entries, isTruncated: false)
    }

    private static func parseEntry(buffer: UnsafeRawBufferPointer) -> DiskCleanBulkAttributeEntry {
        var entry = DiskCleanBulkAttributeEntry()

        // 4 字节条目长度 + 20 字节 RETURNED_ATTRS 是解析一切的前提。
        guard buffer.count >= 4 + returnedAttributesSize else {
            entry.hasLayoutMismatch = true
            return entry
        }

        let commonReturned = buffer.loadUnaligned(
            fromByteOffset: 4 + commonGroupIndex * 4,
            as: attrgroup_t.self
        )
        let fileReturned = buffer.loadUnaligned(
            fromByteOffset: 4 + fileGroupIndex * 4,
            as: attrgroup_t.self
        )

        var reader = Reader(buffer: buffer, offset: 4 + returnedAttributesSize)
        var expectedNameDataOffset: Int?

        if commonReturned & attrgroup_t(ATTR_CMN_NAME) != 0 {
            let referenceOffset = reader.offset
            guard let dataOffset = reader.readInt32(), let length = reader.readUInt32() else {
                entry.hasLayoutMismatch = true
                return entry
            }
            let nameDataOffset = referenceOffset + Int(dataOffset)
            expectedNameDataOffset = nameDataOffset
            entry.nameBytes = readName(buffer: buffer, offset: nameDataOffset, length: Int(length))
        }

        if commonReturned & attrgroup_t(ATTR_CMN_DEVID) != 0 {
            guard let value = reader.readInt32() else {
                entry.hasLayoutMismatch = true
                return entry
            }
            entry.devid = UInt64(UInt32(bitPattern: value))
        }

        if commonReturned & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            guard let value = reader.readUInt32() else {
                entry.hasLayoutMismatch = true
                return entry
            }
            entry.fileType = fileType(objectType: value)
        }

        if commonReturned & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            guard let value = reader.readUInt64() else {
                entry.hasLayoutMismatch = true
                return entry
            }
            entry.fileID = value
        }

        if fileReturned & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            guard let value = reader.readUInt32() else {
                entry.hasLayoutMismatch = true
                return entry
            }
            entry.linkCount = value
        }

        if fileReturned & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            guard let value = reader.readInt64() else {
                entry.hasLayoutMismatch = true
                return entry
            }
            entry.dataLength = value
        }

        // 固定段终点必须正好是变长段（唯一变长字段 NAME）的起点，否则说明存在
        // 位图未声明却仍占位的属性，其后字段全部错位。
        if let expectedNameDataOffset, reader.offset != expectedNameDataOffset {
            entry.hasLayoutMismatch = true
            entry.fileType = nil
            entry.devid = nil
            entry.fileID = nil
            entry.linkCount = nil
            entry.dataLength = nil
        }

        return entry
    }

    private static func readName(
        buffer: UnsafeRawBufferPointer,
        offset: Int,
        length: Int
    ) -> [CChar]? {
        guard offset >= 0, length > 0, offset < buffer.count else { return nil }
        let available = min(length, buffer.count - offset)
        var bytes: [CChar] = []
        bytes.reserveCapacity(available)
        for index in 0..<available {
            let byte = buffer.loadUnaligned(fromByteOffset: offset + index, as: UInt8.self)
            if byte == 0 { break }
            bytes.append(CChar(bitPattern: byte))
        }
        guard !bytes.isEmpty else { return nil }
        bytes.append(0)
        return bytes
    }

    private static func fileType(objectType: UInt32) -> DiskCleanRootIdentity.FileType {
        switch objectType {
        case UInt32(VDIR.rawValue): return .directory
        case UInt32(VREG.rawValue): return .regularFile
        case UInt32(VLNK.rawValue): return .symlink
        default: return .other
        }
    }

    /// 带边界检查的非对齐游标：越界一律返回 nil，交由调用方置 `hasLayoutMismatch`。
    private struct Reader {
        let buffer: UnsafeRawBufferPointer
        var offset: Int

        mutating func readInt32() -> Int32? { read(as: Int32.self) }
        mutating func readUInt32() -> UInt32? { read(as: UInt32.self) }
        mutating func readInt64() -> Int64? { read(as: Int64.self) }
        mutating func readUInt64() -> UInt64? { read(as: UInt64.self) }

        private mutating func read<T>(as type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset >= 0, offset + size <= buffer.count else { return nil }
            let value = buffer.loadUnaligned(fromByteOffset: offset, as: type)
            offset += size
            return value
        }
    }
}
