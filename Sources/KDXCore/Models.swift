import Foundation

public struct KDXUser: Identifiable, Sendable, Equatable {
    public var id: UInt32 = 0
    public var nickname: String
    public var info: String = ""
    public var status: UInt8 = 0
    public var isAdmin: Bool = false
    public init(id: UInt32 = 0, nickname: String, info: String = "", isAdmin: Bool = false) {
        self.id = id; self.nickname = nickname; self.info = info; self.isAdmin = isAdmin
    }
    func encode() throws -> [UInt8] {
        let nick = try shortText(nickname), info = try shortText(info)
        var out = [UInt8](repeating: 0, count: 28)
        out.put(id, at: 0); out[4] = status; out[20] = isAdmin ? 255 : 0
        out[25] = UInt8(nick.count); out[26] = UInt8(info.count)
        return out + nick + info
    }
    static func decode(_ b: [UInt8]) throws -> (KDXUser, Int) {
        try b.require(28)
        let at = 28 + Int(b.u16(12)) + Int(b[24]), end = at + Int(b[25]) + Int(b[26])
        try b.require(end)
        var user = KDXUser(id: b.u32(0), nickname: b.text(at..<at+Int(b[25])), info: b.text(at+Int(b[25])..<end), isAdmin: b[20] == 255)
        user.status = b[4]
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
    var sessionKey: [UInt8]
    func encode() throws -> [UInt8] {
        let name = try shortText(name), description = try shortText(description)
        var out = [UInt8](repeating: 0, count: 76)
        out.replaceSubrange(0..<32, with: sessionKey); out.put(userID, at: 36); out.put(UInt16(1620), at: 40)
        out[43] = canModifySettings ? 1 : 0; out[71] = 2; out[72] = UInt8(name.count); out[73] = UInt8(description.count)
        return out + name + description
    }
    static func decode(_ b: [UInt8]) throws -> ServerInfo {
        try b.require(76); let end = 76 + Int(b[72]) + Int(b[73]); try b.require(end + Int(b[74]))
        return ServerInfo(name: b.text(76..<76+Int(b[72])), description: b.text(76+Int(b[72])..<end), userID: b.u32(36), canModifySettings: b.u16(42) != 0, sessionKey: Array(b.prefix(32)))
    }
}
public struct ChatLine: Identifiable, Sendable {
    public let id = UUID()
    public let date = Date()
    public var userID: UInt32
    public var sender: String
    public var text: String
    public var isPrivate: Bool = false
}
public struct ChatRoom: Identifiable, Sendable {
    public var id: UInt32, key: UInt32
    public var name: String, description: String
    public var memberCount: Int
    static func list(_ b: [UInt8]) throws -> [ChatRoom] {
        try b.require(4); var at = 4, result = [ChatRoom]()
        guard b.u32(0) <= UInt32(b.count / 20) else { throw KDXError.invalid("Invalid chat count.") }
        for _ in 0..<b.u32(0) {
            try b.require(at+20); let n = Int(b[at+18]), d = Int(b[at+19]); try b.require(at+20+n+d)
            result.append(ChatRoom(id: b.u32(at), key: b.u32(at+4), name: b.text(at+20..<at+20+n), description: b.text(at+20+n..<at+20+n+d), memberCount: Int(b.u16(at+16))))
            at += min((20+n+d+3) & ~3, b.count-at)
        }
        return result
    }
}
