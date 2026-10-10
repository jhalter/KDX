import Foundation

public struct ChatInvitation: Identifiable, Equatable, Sendable {
    public var id: UInt32 { roomID }
    public var roomID: UInt32
    public var key: UInt32
    public var inviterID: UInt32
    public var name: String
    // Captures show a changing word at 12 and a 1 at 16; their semantics remain inferred.
    var opaque: [UInt8] = [UInt8](repeating: 0, count: 12)
    func encode() throws -> [UInt8] {
        let name = try shortText(name)
        guard opaque.count == 12 else { throw KDXError.invalid("Invalid invitation fields.") }
        var b = roomID.beBytes + key.beBytes + inviterID.beBytes + opaque + [0, UInt8(name.count), 0, 0]
        b += name; return b
    }
    static func decode(_ b: [UInt8]) throws -> Self {
        try b.require(28); let end = 28 + Int(b[25]); try b.require(end)
        // Nonempty invitation text has not been independently decoded.
        guard b[24] == 0, b[26] == 0, b[27] == 0, b.count == end else { throw KDXError.invalid("Unsupported invitation text format.") }
        return Self(roomID: b.u32(0), key: b.u32(4), inviterID: b.u32(8), name: b.text(28..<end), opaque: Array(b[12..<24]))
    }
}

struct ChatInviteRequest {
    var roomID: UInt32
    var users: [UInt32]
    func encode() throws -> [UInt8] {
        guard !users.isEmpty, users.count <= 20 else { throw KDXError.invalid("Invite between 1 and 20 users.") }
        var b = [UInt8](repeating: 0, count: 16); b.put(roomID, at: 0); b.put(UInt16(users.count), at: 8)
        return b + users.flatMap(\.beBytes)
    }
    static func decode(_ b: [UInt8]) throws -> Self {
        try b.require(16); let count = Int(b.u16(8))
        guard count > 0, count <= 20 else { throw KDXError.remote(0x1000a) }
        try b.require(16 + count * 4 + Int(b[15]))
        guard b[15] == 0 else { throw KDXError.remote(0x10004) }
        return Self(roomID: b.u32(0), users: (0..<count).map { b.u32(16+$0*4) })
    }
}
