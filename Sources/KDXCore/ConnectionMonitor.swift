import Foundation

public struct MonitoredConnection: Identifiable, Sendable {
    public let id = UUID()
    public var userID: UInt32
    public var nickname: String
    public var login: String
    public var accountClassName: String
    public var address: String
    var loginTime: UInt64 = 0
    var serverTime: UInt64 = 0
    public var path = RemotePath([])
    var header = [UInt8](repeating: 0, count: 104)
    public var connectedAt: Date? { loginTime == 0 ? nil : KDXTime.decode(loginTime) }
    public var sampledAt: Date? { serverTime == 0 ? nil : KDXTime.decode(serverTime) }
    public var transferID: UInt32 { get { header.u32(4) } set { header.put(newValue, at: 4) } }
    public var bytesDone: UInt64 { get { header.u64(32) } set { header.put(newValue, at: 32) } }
    public var totalBytes: UInt64 { get { header.u64(40) } set { header.put(newValue, at: 40) } }
    public var rate: UInt32 { get { header.u32(48) } set { header.put(newValue, at: 48) } }
    public var secondsLeft: UInt32 { get { header.u32(52) } set { header.put(newValue, at: 52) } }
    public var speedLimit: UInt32 { get { header.u32(56) } set { header.put(newValue, at: 56) } }
    public var state: UInt32 { get { header.u32(60) } set { header.put(newValue, at: 60) } }
    public var classID: UInt8 { get { header[66] } set { header[66] = newValue } }

    func encode() throws -> [UInt8] {
        guard header.count == 104 else { throw KDXError.invalid("Invalid connection-monitor header.") }
        let strings = try [nickname,login,accountClassName,address].map(shortText)
        var out = header
        out.put(userID, at: 0); out.put(loginTime, at: 8); out.put(serverTime, at: 24)
        for (index, value) in strings.enumerated() { out[96+index] = UInt8(value.count); out += value }
        let pathBytes = try path.encode()
        guard pathBytes.count <= UInt16.max else { throw KDXError.invalid("Monitor path too long.") }
        out.put(UInt16(pathBytes.count), at: 102); out += pathBytes
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
            let pathEnd = cursor + Int(b.u16(at+102)); try b.require(pathEnd)
            let path = try RemotePath(wire: Array(b[cursor..<pathEnd])); cursor = pathEnd
            let used = (cursor-at+3) & ~3; try b.require(at+used)
            entries.append(Self(userID: b.u32(at), nickname: strings[0], login: strings[1], accountClassName: strings[2], address: strings[3],
                                loginTime: b.u64(at+8), serverTime: b.u64(at+24), path: path, header: Array(b[at..<at+104])))
            at += used
        }
        return entries
    }
    static func encodeList(_ entries: [Self]) throws -> [UInt8] {
        try entries.flatMap { try $0.encode() }
    }
}
