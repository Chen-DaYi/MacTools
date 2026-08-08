import Foundation
import Darwin
import IOKit

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCVers {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCParam {
    var key: UInt32 = 0
    var vers = SMCVers()
    var pLimit = SMCPLimit()
    var keyInfo = SMCKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

private struct SMCValue {
    var dataSize: UInt32
    var dataType: UInt32
    var bytes: [UInt8]
}

private let kernelIndexSMC: UInt32 = 2
private let smcCmdReadBytes: UInt8 = 5
private let smcCmdWriteBytes: UInt8 = 6
private let smcCmdReadKeyInfo: UInt8 = 9
private let writeMaxAttempts = 2
private let writeVerifyReads = 3
private let writeVerifyInterval: TimeInterval = 0.1
private let supportedFanIndices = 0..<16
private let supportedRPMRange = 500...8_000

private let typeFLT = fourCC("flt ")
private let typeFPE2 = fourCC("fpe2")
private let typeSP78 = fourCC("sp78")
private let typeUI8 = fourCC("ui8 ")
private let typeUI16 = fourCC("ui16")
private let typeUI32 = fourCC("ui32")

private enum SMCHelperError: LocalizedError {
    case serviceNotFound
    case openFailed(kern_return_t)
    case keyInfoFailed(String, kern_return_t)
    case invalidKeyInfo(String)
    case readFailed(String, kern_return_t)
    case writeFailed(String, kern_return_t)
    case writeVerificationFailed(String, expected: [UInt8], actual: [UInt8])
    case unsupportedWriteType(String, UInt32, UInt32)
    case insufficientPrivileges(uid_t)
    case invalidArguments

    var errorDescription: String? {
        switch self {
        case .serviceNotFound:
            return "AppleSMC service not found"
        case .openFailed(let code):
            return "Failed to open SMC connection: \(String(format: "%08x", code))"
        case .keyInfoFailed(let key, let code):
            return "Failed to read key info for \(key): \(String(format: "%08x", code))"
        case .invalidKeyInfo(let key):
            return "Invalid key info for \(key)"
        case .readFailed(let key, let code):
            return "Failed to read \(key): \(String(format: "%08x", code))"
        case .writeFailed(let key, let code):
            return "Failed to write \(key): \(String(format: "%08x", code))"
        case .writeVerificationFailed(let key, let expected, let actual):
            return "Failed to verify \(key): expected \(hexString(expected)), read \(hexString(actual))"
        case .unsupportedWriteType(let key, let type, let size):
            return "Unsupported SMC type for \(key): \(fourCCString(type))/\(size)"
        case .insufficientPrivileges(let effectiveUserID):
            return "Fan control requires root privileges (effective uid: \(effectiveUserID))"
        case .invalidArguments:
            return "Invalid arguments"
        }
    }
}

private final class SMCConnection {
    private var connection: io_connect_t = 0
    private var keyInfoCache: [UInt32: SMCKeyInfo] = [:]

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            throw SMCHelperError.serviceNotFound
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else {
            throw SMCHelperError.openFailed(result)
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    func readValue(key: String) throws -> SMCValue {
        let keyCode = fourCC(key)
        let info = try keyInfo(for: key, keyCode: keyCode)

        var input = SMCParam()
        input.key = keyCode
        input.keyInfo.dataSize = info.dataSize
        input.data8 = smcCmdReadBytes

        var output = SMCParam()
        var outputSize = MemoryLayout<SMCParam>.size
        let result = IOConnectCallStructMethod(
            connection,
            kernelIndexSMC,
            &input,
            MemoryLayout<SMCParam>.size,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess, output.result == 0 else {
            throw SMCHelperError.readFailed(key, result)
        }

        return SMCValue(
            dataSize: info.dataSize,
            dataType: info.dataType,
            bytes: byteArray(output.bytes)
        )
    }

    func writeValue(key: String, value: SMCValue) throws {
        var bytes = value.bytes
        if bytes.count < 32 {
            bytes.append(contentsOf: Array(repeating: 0, count: 32 - bytes.count))
        }

        var input = SMCParam()
        input.key = fourCC(key)
        input.keyInfo.dataSize = value.dataSize
        input.data8 = smcCmdWriteBytes
        input.bytes = bytesTuple(bytes)

        var output = SMCParam()
        var outputSize = MemoryLayout<SMCParam>.size
        let result = IOConnectCallStructMethod(
            connection,
            kernelIndexSMC,
            &input,
            MemoryLayout<SMCParam>.size,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess, output.result == 0 else {
            throw SMCHelperError.writeFailed(key, result)
        }
    }

    private func keyInfo(for key: String, keyCode: UInt32) throws -> SMCKeyInfo {
        if let cached = keyInfoCache[keyCode] {
            return cached
        }

        var input = SMCParam()
        input.key = keyCode
        input.data8 = smcCmdReadKeyInfo

        var output = SMCParam()
        var outputSize = MemoryLayout<SMCParam>.size
        let result = IOConnectCallStructMethod(
            connection,
            kernelIndexSMC,
            &input,
            MemoryLayout<SMCParam>.size,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess, output.result == 0 else {
            throw SMCHelperError.keyInfoFailed(key, result)
        }
        guard output.keyInfo.dataSize > 0, output.keyInfo.dataSize <= 32 else {
            throw SMCHelperError.invalidKeyInfo(key)
        }

        keyInfoCache[keyCode] = output.keyInfo
        return output.keyInfo
    }
}

/// Write an SMC value and verify that the firmware exposes the requested bytes.
/// Some Macs briefly return the old value after accepting a write, so retry the
/// read before treating a successful IOKit call as a successful fan change.
private func writeAndVerify(key: String, value: SMCValue, connection: SMCConnection) throws {
    let byteCount = Int(value.dataSize)
    let expected = Array(value.bytes.prefix(byteCount))
    var actual: [UInt8] = []
    var lastError: Error?

    for writeAttempt in 1...writeMaxAttempts {
        do {
            try connection.writeValue(key: key, value: value)

            for verifyAttempt in 1...writeVerifyReads {
                let readBack = try connection.readValue(key: key)
                actual = Array(readBack.bytes.prefix(byteCount))
                if actual == expected {
                    return
                }
                if verifyAttempt < writeVerifyReads {
                    Thread.sleep(forTimeInterval: writeVerifyInterval)
                }
            }

            lastError = SMCHelperError.writeVerificationFailed(key, expected: expected, actual: actual)
        } catch {
            lastError = error
        }

        if writeAttempt < writeMaxAttempts {
            Thread.sleep(forTimeInterval: writeVerifyInterval)
        }
    }

    throw lastError ?? SMCHelperError.writeVerificationFailed(key, expected: expected, actual: actual)
}

private func setFanSpeed(_ rpm: Int, fanIndex: Int, connection: SMCConnection) throws {
    try setFanMode(1, fanIndex: fanIndex, connection: connection, allowMissing: true)

    let key = "F\(fanIndex)Tg"
    var value = try connection.readValue(key: key)

    switch (value.dataType, value.dataSize) {
    case (typeFLT, 4):
        var float = Float32(rpm)
        value.bytes = withUnsafeBytes(of: &float) { Array($0) }
    case (typeFPE2, 2):
        let encoded = UInt16(rpm << 2)
        value.bytes[0] = UInt8((encoded >> 8) & 0xff)
        value.bytes[1] = UInt8(encoded & 0xff)
    default:
        throw SMCHelperError.unsupportedWriteType(key, value.dataType, value.dataSize)
    }

    try writeAndVerify(key: key, value: value, connection: connection)
}

private func setFanMode(
    _ mode: UInt8,
    fanIndex: Int,
    connection: SMCConnection,
    allowMissing: Bool = false
) throws {
    let key = "F\(fanIndex)Md"
    var value: SMCValue

    do {
        value = try connection.readValue(key: key)
    } catch {
        // Some Macs do not expose F{n}Md. Setting F{n}Tg can still control the
        // target, but restoring automatic mode has no safe fallback.
        switch error {
        case SMCHelperError.keyInfoFailed,
             SMCHelperError.invalidKeyInfo,
             SMCHelperError.readFailed:
            guard allowMissing else {
                throw error
            }
            return
        default:
            throw error
        }
    }

    guard value.dataSize == 1 else {
        if allowMissing {
            return
        }
        throw SMCHelperError.unsupportedWriteType(key, value.dataType, value.dataSize)
    }
    value.bytes[0] = mode
    try writeAndVerify(key: key, value: value, connection: connection)
}

private func fanCount(connection: SMCConnection) throws -> Int {
    let value = try connection.readValue(key: "FNum")
    return Int(parseDouble(value) ?? 0)
}

private func printFanInfo(connection: SMCConnection) throws {
    let count = try fanCount(connection: connection)
    print("Total fans: \(count)")

    for index in 0..<count {
        print("")
        print("Fan #\(index):")
        for suffix in ["Ac", "Mn", "Mx", "Tg"] {
            let key = "F\(index)\(suffix)"
            if let value = try? connection.readValue(key: key),
               let double = parseDouble(value) {
                print("  \(key): \(Int(double)) RPM")
            }
        }
    }
}

private func printKey(_ key: String, connection: SMCConnection) throws {
    let value = try connection.readValue(key: key)
    print("Key: \(key)")
    print("Type: \(fourCCString(value.dataType))")
    print("Size: \(value.dataSize)")
    if let double = parseDouble(value) {
        print("Value: \(double)")
    }
}

private func parseDouble(_ value: SMCValue) -> Double? {
    switch value.dataType {
    case typeFLT:
        guard value.dataSize == 4, value.bytes.count >= 4 else { return nil }
        let float = value.bytes.withUnsafeBufferPointer {
            $0.baseAddress!.withMemoryRebound(to: Float32.self, capacity: 1) { $0.pointee }
        }
        return Double(float)
    case typeSP78:
        guard value.dataSize == 2, value.bytes.count >= 2 else { return nil }
        let raw = (Int(value.bytes[0]) << 8) | Int(value.bytes[1])
        return Double(Int16(bitPattern: UInt16(raw))) / 256.0
    case typeFPE2:
        guard value.dataSize == 2, value.bytes.count >= 2 else { return nil }
        return Double((Int(value.bytes[0]) << 6) + (Int(value.bytes[1]) >> 2))
    case typeUI8:
        guard value.dataSize == 1, value.bytes.count >= 1 else { return nil }
        return Double(value.bytes[0])
    case typeUI16:
        guard value.dataSize == 2, value.bytes.count >= 2 else { return nil }
        return Double((Int(value.bytes[0]) << 8) | Int(value.bytes[1]))
    case typeUI32:
        guard value.dataSize == 4, value.bytes.count >= 4 else { return nil }
        let raw = (UInt32(value.bytes[0]) << 24)
            | (UInt32(value.bytes[1]) << 16)
            | (UInt32(value.bytes[2]) << 8)
            | UInt32(value.bytes[3])
        return Double(raw)
    default:
        if value.dataSize == 2, value.bytes.count >= 2 {
            return Double((Int(value.bytes[0]) << 8) | Int(value.bytes[1]))
        }
        return nil
    }
}

private func fourCC(_ value: String) -> UInt32 {
    var result: UInt32 = 0
    for (index, byte) in value.utf8.prefix(4).enumerated() {
        result |= UInt32(byte) << (8 * (3 - index))
    }
    return result
}

private func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func fourCCString(_ value: UInt32) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "\(value)"
}

private func byteArray(_ bytes: SMCBytes) -> [UInt8] {
    [
        bytes.0, bytes.1, bytes.2, bytes.3,
        bytes.4, bytes.5, bytes.6, bytes.7,
        bytes.8, bytes.9, bytes.10, bytes.11,
        bytes.12, bytes.13, bytes.14, bytes.15,
        bytes.16, bytes.17, bytes.18, bytes.19,
        bytes.20, bytes.21, bytes.22, bytes.23,
        bytes.24, bytes.25, bytes.26, bytes.27,
        bytes.28, bytes.29, bytes.30, bytes.31
    ]
}

private func bytesTuple(_ bytes: [UInt8]) -> SMCBytes {
    (
        bytes[safe: 0], bytes[safe: 1], bytes[safe: 2], bytes[safe: 3],
        bytes[safe: 4], bytes[safe: 5], bytes[safe: 6], bytes[safe: 7],
        bytes[safe: 8], bytes[safe: 9], bytes[safe: 10], bytes[safe: 11],
        bytes[safe: 12], bytes[safe: 13], bytes[safe: 14], bytes[safe: 15],
        bytes[safe: 16], bytes[safe: 17], bytes[safe: 18], bytes[safe: 19],
        bytes[safe: 20], bytes[safe: 21], bytes[safe: 22], bytes[safe: 23],
        bytes[safe: 24], bytes[safe: 25], bytes[safe: 26], bytes[safe: 27],
        bytes[safe: 28], bytes[safe: 29], bytes[safe: 30], bytes[safe: 31]
    )
}

private extension Array where Element == UInt8 {
    subscript(safe index: Int) -> UInt8 {
        indices.contains(index) ? self[index] : 0
    }
}

private func usage() {
    let program = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "mactools-fan-smc-helper"
    print("MacTools Fan SMC Helper")
    print("Usage:")
    print("  \(program) info")
    print("  \(program) identity")
    print("  \(program) read <KEY>")
    print("  \(program) set <FAN#> <RPM>")
    print("  \(program) auto <FAN#>")
}

private func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        usage()
        throw SMCHelperError.invalidArguments
    }

    switch arguments[1] {
    case "info":
        let connection = try SMCConnection()
        try printFanInfo(connection: connection)
    case "identity":
        print("uid=\(getuid()) euid=\(geteuid()) gid=\(getgid()) egid=\(getegid())")
    case "read":
        guard arguments.count >= 3 else {
            throw SMCHelperError.invalidArguments
        }
        let connection = try SMCConnection()
        try printKey(arguments[2], connection: connection)
    case "set":
        guard geteuid() == 0 else {
            throw SMCHelperError.insufficientPrivileges(geteuid())
        }
        guard arguments.count >= 4,
              let fanIndex = Int(arguments[2]),
              supportedFanIndices.contains(fanIndex),
              let rpm = Int(arguments[3]),
              supportedRPMRange.contains(rpm)
        else {
            throw SMCHelperError.invalidArguments
        }
        let connection = try SMCConnection()
        try setFanSpeed(rpm, fanIndex: fanIndex, connection: connection)
    case "auto":
        guard geteuid() == 0 else {
            throw SMCHelperError.insufficientPrivileges(geteuid())
        }
        guard arguments.count >= 3,
              let fanIndex = Int(arguments[2]),
              supportedFanIndices.contains(fanIndex)
        else {
            throw SMCHelperError.invalidArguments
        }
        let connection = try SMCConnection()
        try setFanMode(0, fanIndex: fanIndex, connection: connection)
    default:
        usage()
        throw SMCHelperError.invalidArguments
    }
}

do {
    try run()
} catch let error as SMCHelperError {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    switch error {
    case .insufficientPrivileges:
        exit(77) // EX_NOPERM
    case .writeVerificationFailed:
        exit(74) // EX_IOERR
    default:
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
