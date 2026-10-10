import Foundation

public struct UserInformation: Identifiable, Equatable, Sendable {
    public var id: UInt32
    var loginTime: UInt64 = 0
    var time10: UInt64 = 0
    var time18: UInt64 = 0
    public var address: String
    public var nickname: String
    var name3f: String = ""
    public var login: String
    var name41: String = ""
    public var connectedAt: Date? { loginTime == 0 ? nil : KDXTime.decode(loginTime) }
    func encode() throws -> [UInt8] {
        let strings = try [address, nickname, name3f, login, name41].map(shortText), offsets = [59,61,63,64,65]
        var out = [UInt8](repeating: 0, count: 68)
        out.put(id, at: 0); out.put(loginTime, at: 8); out.put(time10, at: 16); out.put(time18, at: 24)
        for (index, string) in strings.enumerated() { out[offsets[index]] = UInt8(string.count); out += string }
        out.pad(4); return out
    }
    static func decode(_ b: [UInt8]) throws -> Self {
        try b.require(68); var at = 68, strings = [String]()
        for offset in [59,61,63,64,65] { let end = at + Int(b[offset]); try b.require(end); strings.append(b.text(at..<end)); at = end }
        return Self(id: b.u32(0), loginTime: b.u64(8), time10: b.u64(16), time18: b.u64(24), address: strings[0], nickname: strings[1], name3f: strings[2], login: strings[3], name41: strings[4])
    }
}
