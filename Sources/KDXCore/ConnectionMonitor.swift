import Foundation

public struct MonitoredConnection: Identifiable, Sendable {
    public let id = UUID()
    public var userID: UInt32
    public var nickname: String
    public var login: String
    public var accountName: String
    public var address: String
    var loginTime: UInt64 = 0
    var lastActivity: UInt64 = 0
    var header = [UInt8](repeating: 0, count: 104)
    public var connectedAt: Date? { loginTime == 0 ? nil : KDXTime.decode(loginTime) }
    // The reference infers this timestamp's meaning; the middle timestamp stays opaque.
    public var lastActiveAt: Date? { lastActivity == 0 ? nil : KDXTime.decode(lastActivity) }

    func encode() throws -> [UInt8] {
        guard header.count == 104 else { throw KDXError.invalid("Invalid connection-monitor header.") }
        let strings = try [nickname,login,accountName,address].map(shortText)
        var out = header
        out.put(userID, at: 0); out.put(loginTime, at: 8); out.put(lastActivity, at: 24)
        for (index, value) in strings.enumerated() { out[96+index] = UInt8(value.count); out += value }
        out.pad(4); return out
    }
    static func decodeList(_ b: [UInt8]) throws -> [Self] {
        var at = 0, entries = [Self]()
        while at < b.count {
            try b.require(at+104)
            var cursor = at+104, strings = [String]()
            for offset in 96..<100 {
                let end = cursor + Int(b[at+offset]); try b.require(end)
                strings.append(b.text(cursor..<end)); cursor = end
            }
            let used = (cursor-at+3) & ~3; try b.require(at+used)
            entries.append(Self(userID: b.u32(at), nickname: strings[0], login: strings[1], accountName: strings[2], address: strings[3],
                                loginTime: b.u64(at+8), lastActivity: b.u64(at+24), header: Array(b[at..<at+104])))
            at += used
        }
        return entries
    }
    static func encodeList(_ entries: [Self]) throws -> [UInt8] {
        try entries.flatMap { try $0.encode() }
    }
}
