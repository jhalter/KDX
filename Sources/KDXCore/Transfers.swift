import Foundation

/// Milliseconds using the reference's inferred 1900 epoch, consistent with capture dates.
enum KDXTime {
    static let unixOffset: TimeInterval = 2_208_988_800
    static func decode(_ value: UInt64) -> Date { Date(timeIntervalSince1970: Double(value) / 1000 - unixOffset) }
    static func encode(_ date: Date) -> UInt64 { UInt64(max(0, min(Double(UInt64.max).nextDown, ((date.timeIntervalSince1970 + unixOffset) * 1000).rounded()))) }
}
struct DownloadRequest {
    var dataOffset: UInt64 = 0
    var resourceOffset: UInt64 = 0
    var options: UInt8 = 0
    var path: RemotePath
    func encode() throws -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 24)
        b.put(dataOffset, at: 0); b.put(resourceOffset, at: 8); b[23] = options
        return b + (try path.encode())
    }
    init(path: RemotePath, dataOffset: UInt64 = 0) { self.path = path; self.dataOffset = dataOffset }
    init(wire b: [UInt8]) throws {
        try b.require(24)
        dataOffset = b.u64(0); resourceOffset = b.u64(8); options = b[23]
        path = try RemotePath(wire: Array(b.dropFirst(24)))
    }
    func alignedOffset(size: UInt64) -> UInt64 { dataOffset >= size ? size : dataOffset & ~UInt64(4095) }
}
struct DownloadInfo: Codable, Equatable {
    var dataSize: UInt64
    var resourceSize: UInt64 = 0
    var created: UInt64 = 0
    var modified: UInt64 = 0
    var unknown30: UInt32 = 1
    var strings: [String]
    init(dataSize: UInt64, name: String) { self.dataSize = dataSize; strings = [name, "", "", ""] }
    init(wire b: [UInt8]) throws {
        try b.require(76)
        dataSize = b.u64(0); resourceSize = b.u64(8); created = b.u64(24); modified = b.u64(32); unknown30 = b.u32(48)
        strings = []; var at = 76
        for i in 72..<76 { let end = at + Int(b[i]); try b.require(end); strings.append(b.text(at..<end)); at = end }
        guard at == b.count else { throw KDXError.invalid("Unexpected download metadata.") }
    }
    func encode() throws -> [UInt8] {
        guard strings.count == 4 else { throw KDXError.invalid("Invalid file metadata.") }
        var b = [UInt8](repeating: 0, count: 76)
        b.put(dataSize, at: 0); b.put(resourceSize, at: 8); b.put(created, at: 24); b.put(modified, at: 32); b.put(unknown30, at: 48)
        for (i, string) in strings.enumerated() { let bytes = try shortText(string); b[72+i] = UInt8(bytes.count); b += bytes }
        return b
    }
    func matches(_ other: Self) -> Bool {
        dataSize == other.dataSize && resourceSize == other.resourceSize && created == other.created && modified == other.modified && strings == other.strings
    }
}
