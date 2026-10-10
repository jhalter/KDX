import Foundation

public enum KDXError: Error, LocalizedError, Sendable {
    case invalid(String), disconnected, authentication, remote(UInt32)
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): reason
        case .disconnected: "The connection closed."
        case .authentication: "Authentication failed. Check the account and password."
        case .remote(let code):
            switch code {
            case 0x10014: "You do not have permission for this action."
            case 0x1000c: "The requested item or user is no longer available."
            case 0x1000d, 0x30073: "An item with this name already exists. Choose a different name."
            case 0x10004: "The server does not support this action."
            case 0x40074: "The uploaded data did not match its declared size."
            case 0x640005: "You cannot grant permissions that your own account does not have."
            default: "Server error 0x\(String(code, radix: 16))."
            }
        }
    }
}

extension Array where Element == UInt8 {
    func require(_ count: Int) throws {
        guard count >= 0, self.count >= count else { throw KDXError.invalid("Truncated protocol data.") }
    }
    func u16(_ at: Int) -> UInt16 { UInt16(self[at]) << 8 | UInt16(self[at + 1]) }
    func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { ($0 << 8) | UInt32(self[at + $1]) } }
    func u64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { ($0 << 8) | UInt64(self[at + $1]) } }
    func le32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(self[at + $1]) << ($1 * 8) } }
    mutating func put<T: FixedWidthInteger>(_ value: T, at: Int) {
        for i in 0..<(T.bitWidth / 8) { self[at + i] = UInt8(truncatingIfNeeded: value >> (T.bitWidth - 8 - 8 * i)) }
    }
    mutating func pad(_ alignment: Int) { while count % alignment != 0 { append(0) } }
    func text(_ range: Range<Int>) -> String { String(decoding: self[range], as: UTF8.self) }
}
extension UInt32 {
    func rol(_ n: Int) -> UInt32 { (self << n) | (self >> (32 - n)) }
    func ror(_ n: Int) -> UInt32 { (self >> n) | (self << (32 - n)) }
    var beBytes: [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: self >> (24 - $0 * 8)) } }
    var leBytes: [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: self >> ($0 * 8)) } }
}
func shortText(_ text: String) throws -> [UInt8] {
    let bytes = Array(text.utf8)
    guard bytes.count <= 255 else { throw KDXError.invalid("Text exceeds 255 UTF-8 bytes.") }
    return bytes
}
