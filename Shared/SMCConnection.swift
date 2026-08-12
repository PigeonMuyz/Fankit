import Foundation
import IOKit

enum SMCError: LocalizedError {
    case connectionFailed(kern_return_t)
    case invalidKey(String)
    case ioKit(kern_return_t)
    case firmware(UInt8)
    case unsupportedValueType(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let result):
            "Unable to connect to AppleSMC (0x\(String(UInt32(bitPattern: result), radix: 16)))."
        case .invalidKey(let key):
            "The SMC key must contain exactly four ASCII characters: \(key)."
        case .ioKit(let result):
            "The IOKit call failed (0x\(String(UInt32(bitPattern: result), radix: 16)))."
        case .firmware(let result):
            "The SMC firmware rejected the request (0x\(String(result, radix: 16)))."
        case .unsupportedValueType(let type):
            "The SMC data type \(type) is not supported."
        }
    }
}

private enum SMCCommand: UInt8 {
    case readBytes = 5
    case writeBytes = 6
    case readKeyInfo = 9
}

private struct SMCParamStruct {
    typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PowerLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuLimit: UInt32 = 0
        var gpuLimit: UInt32 = 0
        var memoryLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var attributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var version = Version()
    var powerLimit = PowerLimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

struct SMCValue {
    let bytes: [UInt8]
    let type: String
    let size: UInt32

    func number() throws -> Double {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return 0 }
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "ui8 ":
            return Double(bytes.first ?? 0)
        case "ui16":
            return Double(unsigned16)
        case "ui32":
            guard bytes.count >= 4 else { return 0 }
            return Double(bytes.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
        case "fpe2": return Double(unsigned16) / 4
        case "fp88": return Double(unsigned16) / 256
        case "sp78": return Double(signed16) / 256
        case "sp87": return Double(signed16) / 128
        case "sp96": return Double(signed16) / 64
        case "sp5a": return Double(signed16) / 1024
        case "sp4b": return Double(signed16) / 2048
        case "sp3c": return Double(signed16) / 4096
        case "sp1e": return Double(signed16) / 16384
        default: throw SMCError.unsupportedValueType(type)
        }
    }

    func encoded(_ value: Double) throws -> [UInt8] {
        switch type {
        case "flt ":
            var value = Float(value)
            return withUnsafeBytes(of: &value) { Array($0) }
        case "ui8 ":
            return [UInt8(clamping: Int(value.rounded()))]
        case "ui16":
            return bigEndianBytes(UInt16(clamping: Int(value.rounded())))
        case "fpe2":
            return bigEndianBytes(UInt16(clamping: Int((value * 4).rounded())))
        case "fp88":
            return bigEndianBytes(UInt16(clamping: Int((value * 256).rounded())))
        default:
            throw SMCError.unsupportedValueType(type)
        }
    }

    private var unsigned16: UInt16 {
        guard bytes.count >= 2 else { return 0 }
        return bytes.withUnsafeBytes { UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self)) }
    }

    private var signed16: Int16 { Int16(bitPattern: unsigned16) }

    private func bigEndianBytes(_ value: UInt16) -> [UInt8] {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Array($0) }
    }
}

final class SMCConnection {
    private let connection: io_connect_t

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.connectionFailed(kIOReturnNotFound) }
        defer { IOObjectRelease(service) }

        var openedConnection: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &openedConnection)
        guard result == kIOReturnSuccess else { throw SMCError.connectionFailed(result) }
        connection = openedConnection
    }

    deinit { IOServiceClose(connection) }

    func read(_ key: String) throws -> SMCValue {
        var infoRequest = SMCParamStruct()
        infoRequest.key = try fourCharacterCode(key)
        infoRequest.data8 = SMCCommand.readKeyInfo.rawValue
        let info = try call(infoRequest)
        guard info.result == 0 else { throw SMCError.firmware(info.result) }

        var readRequest = infoRequest
        readRequest.keyInfo.dataSize = info.keyInfo.dataSize
        readRequest.data8 = SMCCommand.readBytes.rawValue
        let output = try call(readRequest)
        guard output.result == 0 else { throw SMCError.firmware(output.result) }

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.keyInfo.dataSize))) }
        return SMCValue(bytes: bytes, type: fourCharacterString(info.keyInfo.dataType), size: info.keyInfo.dataSize)
    }

    func write(_ key: String, bytes: [UInt8]) throws {
        var infoRequest = SMCParamStruct()
        infoRequest.key = try fourCharacterCode(key)
        infoRequest.data8 = SMCCommand.readKeyInfo.rawValue
        let info = try call(infoRequest)
        guard info.result == 0 else { throw SMCError.firmware(info.result) }

        var request = infoRequest
        request.data8 = SMCCommand.writeBytes.rawValue
        request.keyInfo.dataSize = info.keyInfo.dataSize
        request.bytes = byteTuple(bytes)
        let output = try call(request)
        guard output.result == 0 else { throw SMCError.firmware(output.result) }
    }

    private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParamStruct>.stride, &output, &outputSize)
        guard result == kIOReturnSuccess else { throw SMCError.ioKit(result) }
        return output
    }

    private func fourCharacterCode(_ string: String) throws -> UInt32 {
        let bytes = Array(string.utf8)
        guard bytes.count == 4 else { throw SMCError.invalidKey(string) }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func fourCharacterString(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private func byteTuple(_ input: [UInt8]) -> SMCParamStruct.Bytes32 {
        let bytes = Array((input + Array(repeating: 0, count: 32)).prefix(32))
        return (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
            bytes[16], bytes[17], bytes[18], bytes[19], bytes[20], bytes[21], bytes[22], bytes[23],
            bytes[24], bytes[25], bytes[26], bytes[27], bytes[28], bytes[29], bytes[30], bytes[31]
        )
    }
}
