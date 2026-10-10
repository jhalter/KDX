import Foundation
import Darwin

/// Resource-fork I/O stays attached to an already validated regular-file descriptor.
enum ResourceFork {
    private static let attribute = "com.apple.ResourceFork"
    static func size(_ fd: Int32) throws -> UInt64 {
        let result = fgetxattr(fd, attribute, nil, 0, 0, 0)
        if result < 0 {
            if errno == ENOATTR || errno == ENOTSUP { return 0 }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return UInt64(result)
    }
    static func read(_ fd: Int32, offset: UInt64, count: Int) throws -> Data {
        guard offset <= UInt32.max, count >= 0 else { throw KDXError.invalid("Invalid resource-fork offset.") }
        if count == 0 { return Data() }
        var bytes = Data(count: count)
        let result = bytes.withUnsafeMutableBytes { fgetxattr(fd, attribute, $0.baseAddress, count, UInt32(offset), 0) }
        guard result >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        bytes.count = result; return bytes
    }
    static func write(_ fd: Int32, offset: UInt64, bytes: Data) throws {
        guard offset <= UInt32.max, UInt64(bytes.count) <= UInt64(UInt32.max) - offset else { throw KDXError.invalid("Resource fork exceeds 4 GiB.") }
        guard !bytes.isEmpty else { return }
        let result = bytes.withUnsafeBytes { fsetxattr(fd, attribute, $0.baseAddress, bytes.count, UInt32(offset), 0) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    static func clear(_ fd: Int32) throws {
        if fremovexattr(fd, attribute, 0) != 0 && errno != ENOATTR && errno != ENOTSUP { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
