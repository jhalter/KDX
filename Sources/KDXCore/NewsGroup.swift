import Foundation

public struct NewsGroupInfo: Codable, Identifiable, Equatable, Sendable {
    public var id: UInt32 = 0
    public var name: String
    public var description: String = ""
    public var readClasses: UInt32 = .max
    public var postClasses: UInt32 = .max
    public var sizeLimitKiB: UInt16 = 50
    var time: UInt64 = 0
    var unknown20: [UInt8] = [0,0,0,0]
    var messageCount: UInt16 = 0
    public init(name: String) { self.name = name }
    static var general: Self { var value = Self(name: "General"); value.id = 1; return value }
    func encode() throws -> [UInt8] {
        let name = try shortText(name), description = try shortText(description)
        guard name.count <= 63, description.count <= 127, unknown20.count == 4 else { throw KDXError.invalid("Invalid newsgroup name or description.") }
        var b = [UInt8](repeating: 0, count: 64)
        b.put(id, at: 0); b.put(time, at: 16); b.put(readClasses, at: 24); b.put(postClasses, at: 28)
        b.replaceSubrange(32..<36, with: unknown20); b.put(messageCount, at: 48); b.put(sizeLimitKiB, at: 50)
        b[60] = UInt8(name.count); b[61] = UInt8(description.count)
        return b + name + description
    }
    static func decode(_ b: [UInt8]) throws -> Self {
        try b.require(64); let end = 64 + Int(b[60]) + Int(b[61]); try b.require(end)
        var value = Self(name: b.text(64..<64+Int(b[60])))
        value.id = b.u32(0); value.description = b.text(64+Int(b[60])..<end)
        value.readClasses = b.u32(24); value.postClasses = b.u32(28); value.time = b.u64(16)
        value.unknown20 = Array(b[32..<36]); value.messageCount = b.u16(48); value.sizeLimitKiB = b.u16(50)
        _ = try value.encode(); return value
    }
    func validate() throws {
        guard !name.isEmpty, sizeLimitKiB > 0 else { throw KDXError.invalid("A newsgroup needs a name and a positive storage limit.") }
        _ = try encode()
    }
}
