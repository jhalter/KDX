import Foundation

public struct ChatRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UInt32 = 0
    public var key: UInt32 = 0
    public var joinClasses: UInt32 = .max
    public var sendClasses: UInt32 = .max
    public var topicClasses: UInt32 = .max
    public var flags: UInt16 = 0
    public var name: String
    public var description: String = ""
    public var third: String = ""
    public var fourth: String = ""
    public init(name: String, description: String = "") { self.name = name; self.description = description }
    public static var publicChat: Self { var chat = Self(name: "Public Chat", description: "Everyone is welcome"); chat.id = 1; return chat }
    func encode() throws -> [UInt8] {
        let strings = try [name, description, third, fourth].map(shortText)
        var out = [UInt8](repeating: 0, count: 48)
        out.put(id, at: 0); out.put(key, at: 4)
        out.put(joinClasses, at: 20); out.put(sendClasses, at: 24); out.put(topicClasses, at: 28); out.put(flags, at: 40)
        for (i, string) in strings.enumerated() { out[42+i] = UInt8(string.count); out += string }
        return out
    }
    static func decode(_ b: [UInt8]) throws -> Self {
        try b.require(48)
        var at = 48, strings = [String]()
        for index in 42..<46 { let end = at + Int(b[index]); try b.require(end); strings.append(b.text(at..<end)); at = end }
        var result = Self(name: strings[0], description: strings[1])
        result.id = b.u32(0); result.key = b.u32(4); result.joinClasses = b.u32(20); result.sendClasses = b.u32(24)
        result.topicClasses = b.u32(28); result.flags = b.u16(40); result.third = strings[2]; result.fourth = strings[3]
        return result
    }
    static func permits(_ mask: UInt32, classID: UInt8) -> Bool { classID < 32 && mask & (UInt32(1) << (31 - Int(classID))) != 0 }
}

public struct ChatWindow: Equatable, Sendable {
    public var time: UInt64 = 0
    public var id: UInt32
    public var key: UInt32 = 0
    public var flags: UInt16 = 0
    public var members: [UInt32] = []
    // Only the third string's meaning (name) is verified by the reference.
    public var strings: [String] = ["", "", "", "", ""]
    public var name: String { strings[2] }
    func encode() throws -> [UInt8] {
        guard strings.count == 5, members.count <= Int(UInt16.max) else { throw KDXError.invalid("Invalid chat window.") }
        let text = try strings.map(shortText)
        var out = [UInt8](repeating: 0, count: 36)
        out.put(time, at: 0); out.put(id, at: 8); out.put(key, at: 12); out.put(flags, at: 20); out.put(UInt16(members.count), at: 22)
        for (i, string) in text.enumerated() { out[30+i] = UInt8(string.count) }
        return out + members.flatMap(\.beBytes) + text.flatMap { $0 }
    }
    static func decode(_ b: [UInt8]) throws -> Self {
        try b.require(36)
        let count = Int(b.u16(22)); var at = 36 + count * 4; try b.require(at)
        var result = Self(id: b.u32(8))
        result.time = b.u64(0); result.key = b.u32(12); result.flags = b.u16(20)
        result.members = (0..<count).map { b.u32(36 + $0 * 4) }
        for index in 0..<5 { let end = at + Int(b[30+index]); try b.require(end); result.strings[index] = b.text(at..<end); at = end }
        return result
    }
}

public struct ChatTopic: Equatable, Sendable {
    public var time: UInt64 = 0
    public var roomID: UInt32
    public var userID: UInt32
    public var text: String
    public var nickname: String
    func encode() throws -> [UInt8] {
        let text = try shortText(text), nickname = try shortText(nickname)
        var out = [UInt8](repeating: 0, count: 28)
        out.put(time, at: 0); out.put(roomID, at: 8); out.put(userID, at: 12); out[24] = UInt8(text.count); out[25] = UInt8(nickname.count)
        return out + text + nickname
    }
    static func decode(_ b: [UInt8]) throws -> Self {
        try b.require(28); let nickAt = 28 + Int(b[24]), end = nickAt + Int(b[25]); try b.require(end)
        return Self(time: b.u64(0), roomID: b.u32(8), userID: b.u32(12), text: b.text(28..<nickAt), nickname: b.text(nickAt..<end))
    }
}
