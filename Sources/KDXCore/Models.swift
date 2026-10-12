import Foundation

public struct KDXUser: Identifiable, Sendable, Equatable {
    public var id: UInt32 = 0
    public var nickname: String
    public var info: String = ""
    public var status: UInt8 = 0
    public var voicePort: UInt16 = 0
    public var colors: [UInt8] = [0,0,0,0,0,0]
    public var badge: UInt8 = 0
    public var server15: UInt8 = 0
    public var server16: UInt8 = 0
    public var flags: UInt8 = 0
    public var icon: [UInt8] = []
    public var extra: [UInt8] = []
    public var isAdmin: Bool {
        get { badge == 255 }
        set { badge = newValue ? 255 : 0 }
    }
    public init(id: UInt32 = 0, nickname: String, info: String = "", isAdmin: Bool = false) {
        self.id = id; self.nickname = nickname; self.info = info; self.isAdmin = isAdmin
    }
    func encode() throws -> [UInt8] {
        let nick = try shortText(nickname), info = try shortText(info)
        guard colors.count == 6, icon.count <= 0x708, extra.count <= 255, info.count <= 127 else { throw KDXError.invalid("Invalid user profile or icon size.") }
        var out = [UInt8](repeating: 0, count: 28)
        out.put(id, at: 0); out[4] = status; out.put(voicePort, at: 10); out.put(UInt16(icon.count), at: 12)
        out.replaceSubrange(14..<20, with: colors); out[20] = badge; out[21] = server15; out[22] = server16; out[23] = flags
        out[24] = UInt8(extra.count); out[25] = UInt8(nick.count); out[26] = UInt8(info.count)
        return out + icon + extra + nick + info
    }
    static func decode(_ b: [UInt8]) throws -> (KDXUser, Int) {
        try b.require(28)
        let at = 28 + Int(b.u16(12)) + Int(b[24]), end = at + Int(b[25]) + Int(b[26])
        try b.require(end)
        var user = KDXUser(id: b.u32(0), nickname: b.text(at..<at+Int(b[25])), info: b.text(at+Int(b[25])..<end), isAdmin: b[20] == 255)
        guard b.u16(12) <= 0x708, b[26] <= 127 else { throw KDXError.invalid("Invalid user profile or icon size.") }
        user.status = b[4]; user.voicePort = b.u16(10); user.colors = Array(b[14..<20])
        user.badge = b[20]; user.server15 = b[21]; user.server16 = b[22]; user.flags = b[23]
        user.icon = Array(b[28..<28+Int(b.u16(12))]); user.extra = Array(b[28+Int(b.u16(12))..<at])
        return (user, end)
    }
    static func list(_ b: [UInt8]) throws -> [KDXUser] {
        var at = 0, users = [KDXUser]()
        while at < b.count { let (user, length) = try decode(Array(b[at...])); users.append(user); at += min((length+3) & ~3, b.count-at) }
        return users
    }
    static func encodeList(_ users: [KDXUser]) throws -> [UInt8] {
        var out = [UInt8]()
        for user in users { out += try user.encode(); out.pad(4) }
        return out
    }
}
public struct ServerInfo: Sendable {
    public var name: String, description: String
    public var userID: UInt32
    public var canModifySettings: Bool
    public var transferPort: UInt16 = 0
    var sessionKey: [UInt8]
    func encode() throws -> [UInt8] {
        let name = try shortText(name), description = try shortText(description)
        var out = [UInt8](repeating: 0, count: 76)
        out.put(UInt32(transferPort), at: 32); out.replaceSubrange(0..<32, with: sessionKey); out.put(userID, at: 36); out.put(UInt16(1620), at: 40)
        out[43] = canModifySettings ? 1 : 0; out[71] = 2; out[72] = UInt8(name.count); out[73] = UInt8(description.count)
        return out + name + description
    }
    static func decode(_ b: [UInt8]) throws -> ServerInfo {
        try b.require(76); let end = 76 + Int(b[72]) + Int(b[73]); try b.require(end + Int(b[74]))
        guard b.u32(32) <= UInt16.max else { throw KDXError.invalid("Invalid transfer port.") }
        return ServerInfo(name: b.text(76..<76+Int(b[72])), description: b.text(76+Int(b[72])..<end), userID: b.u32(36), canModifySettings: b.u16(42) != 0, transferPort: UInt16(b.u32(32)), sessionKey: Array(b.prefix(32)))
    }
}
public struct ChatLine: Identifiable, Sendable {
    public let id = UUID()
    public let date = Date()
    public var userID: UInt32
    public var sender: String
    public var text: String
    public var isPrivate: Bool = false
    public var isOutgoing: Bool = false
    public var roomID: UInt32?
}
public struct ChatRoom: Identifiable, Equatable, Sendable {
    public var id: UInt32, key: UInt32
    public var name: String, description: String
    public var memberCount: Int
    public var flags: UInt16 = 0
    static func encodeList(_ rooms: [ChatRoom]) throws -> [UInt8] {
        var out = UInt32(rooms.count).beBytes
        for room in rooms {
            let name = try shortText(room.name), description = try shortText(room.description)
            guard (0...Int(UInt16.max)).contains(room.memberCount) else { throw KDXError.invalid("Invalid room member count.") }
            var entry = [UInt8](repeating: 0, count: 20)
            entry.put(room.id, at: 0); entry.put(room.key, at: 4); entry.put(room.flags, at: 14); entry.put(UInt16(room.memberCount), at: 16)
            entry[18] = UInt8(name.count); entry[19] = UInt8(description.count)
            out += entry + name + description; out.pad(4)
        }
        return out
    }
    static func list(_ b: [UInt8]) throws -> [ChatRoom] {
        try b.require(4); var at = 4, result = [ChatRoom]()
        guard b.u32(0) <= UInt32(b.count / 20) else { throw KDXError.invalid("Invalid chat count.") }
        for _ in 0..<b.u32(0) {
            try b.require(at+20); let n = Int(b[at+18]), d = Int(b[at+19]); try b.require(at+20+n+d)
            result.append(ChatRoom(id: b.u32(at), key: b.u32(at+4), name: b.text(at+20..<at+20+n), description: b.text(at+20+n..<at+20+n+d), memberCount: Int(b.u16(at+16)), flags: b.u16(at+14)))
            at += min((20+n+d+3) & ~3, b.count-at)
        }
        return result
    }
}
