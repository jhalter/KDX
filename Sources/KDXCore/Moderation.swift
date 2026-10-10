import Foundation

struct DisconnectRequest {
    var userID: UInt32
    var banSeconds: UInt32 = 0
    var options: UInt8 = 0
    var reason: String = ""
    func encode() throws -> [UInt8] {
        let text = try shortText(reason)
        guard banSeconds <= 0x80000, options & ~1 == 0 else { throw KDXError.invalid("Unsupported disconnection options.") }
        var b = [UInt8](repeating: 0, count: 24)
        b.put(userID, at: 0); b.put(banSeconds, at: 8); b[17] = options; b[20] = UInt8(text.count)
        return b + text
    }
    static func decode(_ b: [UInt8]) throws -> Self {
        try b.require(24); try b.require(24 + Int(b[20]))
        let value = Self(userID: b.u32(0), banSeconds: b.u32(8), options: b[17], reason: b.text(24..<24+Int(b[20])))
        _ = try value.encode(); return value
    }
}

public struct DisconnectNotice: Equatable, Sendable {
    public var senderID: UInt32
    public var flags: UInt16 = 0
    public var reason: String
    public var sender: String
    func encode() throws -> [UInt8] {
        let reason = try shortText(reason), sender = try shortText(sender)
        var b = [UInt8](repeating: 0, count: 20)
        b.put(senderID, at: 0); b.put(flags, at: 12); b[18] = UInt8(reason.count); b[19] = UInt8(sender.count)
        return b + reason + sender
    }
    static func decode(_ b: [UInt8]) throws -> Self {
        try b.require(20); let nameAt = 20 + Int(b[18]), end = nameAt + Int(b[19]); try b.require(end)
        return Self(senderID: b.u32(0), flags: b.u16(12), reason: b.text(20..<nameAt), sender: b.text(nameAt..<end))
    }
    public var description: String {
        let action = flags & 4 != 0 ? "Server shutting down" : flags & 2 != 0 ? "Disconnected and banned" : "Disconnected"
        let source = sender.isEmpty ? "" : " by \(sender)"
        return action + source + (reason.isEmpty ? "." : ": \(reason)")
    }
}

public struct BroadcastMessage: Identifiable, Sendable {
    public let id = UUID()
    public let date = Date()
    public var senderID: UInt32 = 0
    public var sender: String = ""
    public var text: String
    var options: UInt16 = 0
    func encode(received: Bool) throws -> [UInt8] {
        let text = Array(text.utf8)
        guard text.count <= 2048 else { throw KDXError.invalid("Broadcast text exceeds 2048 UTF-8 bytes.") }
        var b = [UInt8](repeating: 0, count: received ? 16 : 4)
        if received { b.put(senderID, at: 0) }
        b.put(options, at: received ? 14 : 2)
        return b + text
    }
    static func decode(_ b: [UInt8], received: Bool) throws -> Self {
        let offset = received ? 16 : 4; try b.require(offset)
        guard b.count - offset <= 2048 else { throw KDXError.invalid("Oversized broadcast.") }
        return Self(senderID: received ? b.u32(0) : 0, text: b.text(offset..<b.count), options: b.u16(offset-2))
    }
}
