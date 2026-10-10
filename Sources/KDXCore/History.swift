import Foundation

public struct RemoteHistoryEntry: Identifiable, Sendable {
    public let id = UUID()
    public var kind: UInt32
    public var userID: UInt32
    public var address: String
    public var nickname: String
    public var login: String
    public var detail: String
    var time: UInt64
    var header = [UInt8](repeating: 0, count: 76)
    public var date: Date { KDXTime.decode(time) }
    public var event: String {
        switch kind {
        case 184: "Login"
        case 185: "Disconnected"
        case 186: "Download aborted"
        case 187: "Upload aborted"
        case 188: "Download finished"
        case 189: "Upload finished"
        case 190: "Server started"
        case 191: "Login failed"
        case 100: "Profile changed"
        case 150: "Disconnect user"
        case 152: "View user information"
        case 154: "Broadcast"
        case 170: "View server settings"
        case 172: "Update server settings"
        case 180: "View history"
        case 182: "Leave history"
        case 200: "Create private chat"
        case 201: "Delete chat"
        case 202: "Join chat"
        case 204: "Leave chat"
        case 209: "Set chat topic"
        case 211: "Invite to chat"
        case 214: "List chats"
        case 217: "Create chat"
        case 220: "Update chat"
        case 400: "List files"
        case 409: "View file information"
        case 504: "Update account class"
        case 507: "Create account"
        case 508: "Delete account"
        case 511: "Update account"
        case 550: "Change password"
        case 600: "Create newsgroup"
        case 601: "Delete newsgroup"
        case 604: "Update newsgroup"
        default: "Event \(kind)"
        }
    }
    func encode() throws -> [UInt8] {
        let strings = try [address,nickname,login,detail].map(shortText)
        guard header.count == 76 else { throw KDXError.invalid("Invalid history header.") }
        var b = header; b.put(time, at: 0); b.put(kind, at: 8); b.put(userID, at: 12)
        for (index, value) in strings.enumerated() { b[70+index] = UInt8(value.count); b += value }
        b.pad(4); return b
    }
    static func decode(_ b: [UInt8], at: Int = 0) throws -> (Self, Int) {
        try b.require(at+76)
        guard b[at+74] == 0, b[at+75] == 0 else { throw KDXError.invalid("Unsupported history record strings.") }
        var cursor = at+76, strings = [String]()
        for offset in 70..<74 { let end = cursor + Int(b[at+offset]); try b.require(end); strings.append(b.text(cursor..<end)); cursor = end }
        let used = (cursor-at+3) & ~3; try b.require(at+used)
        return (Self(kind: b.u32(at+8), userID: b.u32(at+12), address: strings[0], nickname: strings[1], login: strings[2], detail: strings[3], time: b.u64(at), header: Array(b[at..<at+76])), used)
    }
    static func decodeList(_ b: [UInt8]) throws -> [Self] {
        try b.require(8)
        guard b.u32(4) <= UInt32((b.count-8)/76) else { throw KDXError.invalid("Invalid history count.") }
        var at = 8, entries = [Self]()
        for _ in 0..<b.u32(4) { let (entry, used) = try decode(b, at: at); entries.append(entry); at += used }
        guard at == b.count else { throw KDXError.invalid("Unexpected history data.") }
        return entries
    }
    static func encodeList(_ entries: [Self]) throws -> [UInt8] {
        var b = UInt32(0).beBytes + UInt32(entries.count).beBytes
        for entry in entries { b += try entry.encode() }; return b
    }
}
