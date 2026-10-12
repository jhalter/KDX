import Foundation

/// Milliseconds since 1900-01-01 UTC, verified in the original server.
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
    init(path: RemotePath, dataOffset: UInt64 = 0, resourceOffset: UInt64 = 0) { self.path = path; self.dataOffset = dataOffset; self.resourceOffset = resourceOffset }
    init(wire b: [UInt8]) throws {
        try b.require(24)
        dataOffset = b.u64(0); resourceOffset = b.u64(8); options = b[23]
        path = try RemotePath(wire: Array(b.dropFirst(24)))
    }
    func alignedOffset(size: UInt64) -> UInt64 { Self.alignedOffset(dataOffset, size: size) }
    static func alignedOffset(_ offset: UInt64, size: UInt64) -> UInt64 { offset >= size ? size : offset & ~UInt64(4095) }
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

struct UploadRequest: Equatable {
    var dataSize: UInt64
    var resourceSize: UInt64 = 0
    var options: UInt8 = 0
    var strings: [String]
    var folder: RemotePath
    init(dataSize: UInt64, name: String, folder: RemotePath) { self.dataSize = dataSize; self.strings = [name, "", "", ""]; self.folder = folder }
    init(wire b: [UInt8]) throws {
        try b.require(76)
        dataSize = b.u64(0); resourceSize = b.u64(8); options = b[23]
        strings = []; var at = 76
        for i in 72..<76 { let end = at + Int(b[i]); try b.require(end); strings.append(b.text(at..<end)); at = end }
        let end = at + Int(b.u16(70)); try b.require(end)
        guard end == b.count, !strings[0].isEmpty else { throw KDXError.invalid("Invalid upload metadata.") }
        folder = try RemotePath(wire: Array(b[at..<end]))
    }
    func encode() throws -> [UInt8] {
        guard strings.count == 4, !strings[0].isEmpty else { throw KDXError.invalid("Invalid upload metadata.") }
        let path = try folder.encode(); guard path.count <= UInt16.max else { throw KDXError.invalid("Upload path is too long.") }
        var b = [UInt8](repeating: 0, count: 76)
        b.put(dataSize, at: 0); b.put(resourceSize, at: 8); b[23] = options; b.put(UInt16(path.count), at: 70)
        for (i, string) in strings.enumerated() { let bytes = try shortText(string); b[72+i] = UInt8(bytes.count); b += bytes }
        return b + path
    }
}
struct UploadReply {
    var dataOffset: UInt64
    var resourceOffset: UInt64 = .max
    init(dataOffset: UInt64) { self.dataOffset = dataOffset }
    init(wire b: [UInt8]) throws { try b.require(24); dataOffset = b.u64(0); resourceOffset = b.u64(8) }
    func encode() -> [UInt8] { var b = [UInt8](repeating: 0, count: 24); b.put(dataOffset, at: 0); b.put(resourceOffset, at: 8); return b }
    func alignedOffset(size: UInt64) throws -> UInt64 {
        guard dataOffset <= size else { throw KDXError.invalid("Invalid upload resume offset.") }
        return dataOffset & ~UInt64(4095)
    }
}
