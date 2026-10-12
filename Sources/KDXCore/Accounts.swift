import Foundation

/// KDX numbers privileges from the most significant bit of the first byte.
public struct AccountPrivileges: Codable, Equatable, Sendable {
    var bytes: [UInt8]
    public init() { bytes = [UInt8](repeating: 0, count: 16) }
    init(bytes: [UInt8]) throws {
        guard bytes.count == 16 else { throw KDXError.invalid("Privileges must contain 16 bytes.") }
        self.bytes = bytes
    }
    public init(from decoder: Decoder) throws {
        try self.init(bytes: decoder.singleValueContainer().decode([UInt8].self))
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(bytes) }
    public func contains(_ bit: Int) -> Bool { (0..<128).contains(bit) && bytes[bit / 8] & (0x80 >> (bit % 8)) != 0 }
    public mutating func set(_ bit: Int, _ enabled: Bool) {
        guard (0..<128).contains(bit) else { return }
        let mask = UInt8(0x80 >> (bit % 8))
        if enabled { bytes[bit / 8] |= mask } else { bytes[bit / 8] &= ~mask }
    }
    func overriding(_ inherited: Self, mask: Self) -> Self {
        var result = Self()
        for i in 0..<16 { result.bytes[i] = (bytes[i] & mask.bytes[i]) | (inherited.bytes[i] & ~mask.bytes[i]) }
        return result
    }
    static func enabled(_ bits: [Int]) -> Self {
        var result = Self(); for bit in bits { result.set(bit, true) }; return result
    }
    public static let editable: [(bit: Int, name: String)] = [
        (0, "Administrator override"), (4, "Can login"), (10, "Download files"), (11, "Upload files"), (13, "Empty trash"), (16, "Move files"), (17, "Rename files"), (18, "Trash files"), (20, "Set file attributes"),
        (22, "View volume information"), (27, "View folder access"), (28, "Modify folder access"),
        (30, "Join chats"), (31, "Send chat"), (32, "Send private messages"), (35, "Set chat topics"), (36, "Join Public Chat on connect"),
        (33, "Send broadcasts"), (34, "Create private chats"), (37, "Manage chats"), (40, "View user information and connections"), (41, "Disconnect users"), (42, "Cannot be disconnected remotely"),
        (50, "View accounts"), (51, "Create accounts"), (52, "Modify accounts"),
        (53, "Change own password"), (54, "Protect account from non-administrators"),
        (60, "Use any nickname"), (61, "Modify server settings"), (62, "Skip greeting on login"), (63, "View server history"), (70, "Read news"),
        (71, "Post news"), (72, "Delete any news post"), (73, "Manage newsgroups")
    ]
}

public struct AccountClass: Identifiable, Codable, Equatable, Sendable {
    public var id: UInt8
    public var name: String
    public var privileges: AccountPrivileges
    var time: UInt64 = 0
    public var floodLimit: UInt8 = 0
    var unknown25: UInt8 { get { floodLimit } set { floodLimit = newValue } }
    var extra26: [UInt8] = [0, 0]
    public var second = ""
    public var editor = ""
    var afterIndex: [UInt8] = [0, 0, 0]
    public init(id: UInt8, name: String, privileges: AccountPrivileges = AccountPrivileges()) {
        self.id = id; self.name = name; self.privileges = privileges
    }
    private enum CodingKeys: String, CodingKey { case id, name, privileges, time, unknown25, floodLimit, afterIndex, extra26, second, editor }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt8.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        privileges = try c.decode(AccountPrivileges.self, forKey: .privileges)
        time = try c.decodeIfPresent(UInt64.self, forKey: .time) ?? 0
        floodLimit = try c.decodeIfPresent(UInt8.self, forKey: .floodLimit) ?? c.decodeIfPresent(UInt8.self, forKey: .unknown25) ?? 0
        afterIndex = try c.decodeIfPresent([UInt8].self, forKey: .afterIndex) ?? [0,0,0]
        extra26 = try c.decodeIfPresent([UInt8].self, forKey: .extra26) ?? [0,0]
        second = try c.decodeIfPresent(String.self, forKey: .second) ?? ""
        editor = try c.decodeIfPresent(String.self, forKey: .editor) ?? ""
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(privileges, forKey: .privileges)
        try c.encode(time, forKey: .time); try c.encode(floodLimit, forKey: .floodLimit)
        try c.encode(afterIndex, forKey: .afterIndex); try c.encode(extra26, forKey: .extra26)
        try c.encode(second, forKey: .second); try c.encode(editor, forKey: .editor)
    }
    public static let defaults: [AccountClass] = [
        AccountClass(id: 0, name: "Administrator", privileges: .enabled([0,4,10,11,13,16,17,18,20,22,27,28,30,31,32,33,34,35,37,40,41,50,51,52,53,60,61,63,70,71,72,73,74])),
        AccountClass(id: 1, name: "Member", privileges: .enabled([4,10,11,20,30,31,32,34,35,40,53,60,70,71,74])),
        AccountClass(id: 2, name: "Guest", privileges: .enabled([4,10,30,31,32,60,70]))
    ]
    func encode(info: Bool, padded: Bool = true) throws -> [UInt8] {
        let indexAt = info ? 48 : 40, name = try shortText(name)
        guard id < 32, afterIndex.count == 3, extra26.count == 2 else { throw KDXError.invalid("Invalid account class.") }
        var out = [UInt8](repeating: 0, count: indexAt + 8)
        out.replaceSubrange(0..<16, with: privileges.bytes); out.put(time, at: 16); out[37] = unknown25
        out[indexAt] = id; out.replaceSubrange(indexAt+1..<indexAt+4, with: afterIndex); out[indexAt+4] = UInt8(name.count)
        out.replaceSubrange(38..<40, with: extra26)
        out += name
        if info {
            let second = try shortText(second), editor = try shortText(editor)
            out[53] = UInt8(second.count); out[54] = UInt8(editor.count); out += second + editor
        }
        if padded { out.pad(4) }; return out
    }
    static func decode(_ b: [UInt8], info: Bool) throws -> (Self, Int) {
        let indexAt = info ? 48 : 40
        try b.require(indexAt+8); guard b[indexAt] < 32 else { throw KDXError.invalid("Invalid account class index.") }; let end = indexAt+8+Int(b[indexAt+4]); try b.require(end)
        var result = AccountClass(id: b[indexAt], name: b.text(indexAt+8..<end), privileges: try AccountPrivileges(bytes: Array(b[..<16])))
        result.time = b.u64(16); result.unknown25 = b[37]; result.afterIndex = Array(b[indexAt+1..<indexAt+4])
        result.extra26 = Array(b[38..<40])
        var used = end
        if info {
            let secondEnd = end + Int(b[53]), editorEnd = end + Int(b[53]) + Int(b[54]); try b.require(editorEnd)
            result.second = b.text(end..<secondEnd); result.editor = b.text(secondEnd..<editorEnd); used = editorEnd
        }
        return (result, (used+3) & ~3)
    }
    static func encodeList(_ classes: [Self]) throws -> [UInt8] {
        var out = UInt32(classes.count).beBytes
        for entry in classes { out += try entry.encode(info: false) }; return out
    }
    static func decodeList(_ b: [UInt8]) throws -> [Self] {
        try b.require(4); guard b.u32(0) <= UInt32(b.count / 48) else { throw KDXError.invalid("Invalid account class count.") }
        var at = 4, result = [Self]()
        for _ in 0..<b.u32(0) { let (entry, length) = try decode(Array(b.dropFirst(at)), info: false); result.append(entry); at += min(length, b.count-at) }
        return result
    }
}

/// A wire account has different key semantics for info, create, and update.
/// The key is intentionally internal so an info flag cannot accidentally be saved as a password.
public struct RemoteAccount: Identifiable, Equatable, Sendable {
    public var id: String { login }
    public var login: String
    public var name: String
    public var classID: UInt8
    public var privileges = AccountPrivileges()
    public var privilegeMask = AccountPrivileges()
    public var hasPassword: Bool { key.first != 0 }
    public private(set) var created: UInt64 = 0
    public private(set) var modified: UInt64 = 0
    public private(set) var lastLogin: UInt64 = 0
    var key = [UInt8](repeating: 0, count: 32)
    var unknown77: [UInt8] = [0, 0, 0]
    var third = ""
    var editor = ""
    public init(login: String = "", name: String = "", classID: UInt8 = 1) { self.login = login; self.name = name; self.classID = classID }
    func encode() throws -> [UInt8] {
        let parts = try [login, name, third, editor].map(shortText)
        guard key.count == 32, unknown77.count == 3 else { throw KDXError.invalid("Invalid account record.") }
        var out = [UInt8](repeating: 0, count: 128)
        out.replaceSubrange(0..<16, with: privileges.bytes); out.replaceSubrange(16..<32, with: privilegeMask.bytes)
        out.replaceSubrange(32..<64, with: key)
        out.put(created, at: 64); out.put(modified, at: 72); out.put(lastLogin, at: 80)
        out[118] = classID; out.replaceSubrange(119..<122, with: unknown77)
        for (i, part) in parts.enumerated() { out[122+i] = UInt8(part.count); out += part }
        out.pad(4); return out
    }
    static func decode(_ b: [UInt8]) throws -> Self {
        try b.require(128)
        var at = 128, parts = [String]()
        for i in 122..<126 { let end = at+Int(b[i]); try b.require(end); parts.append(b.text(at..<end)); at = end }
        var result = Self(login: parts[0], name: parts[1], classID: b[118])
        result.privileges = try AccountPrivileges(bytes: Array(b[..<16])); result.privilegeMask = try AccountPrivileges(bytes: Array(b[16..<32]))
        result.key = Array(b[32..<64]); result.created = b.u64(64); result.modified = b.u64(72); result.lastLogin = b.u64(80)
        result.unknown77 = Array(b[119..<122]); result.third = parts[2]; result.editor = parts[3]
        return result
    }
    static func info(_ account: ServerAccount) -> Self {
        var result = Self(login: account.login, name: account.name, classID: account.classID)
        result.privileges = account.privileges; result.privilegeMask = account.privilegeMask
        result.key[0] = account.key == AccountKey(password: "").bytes ? 0 : 1
        result.created = account.created; result.modified = account.modified; result.lastLogin = account.lastLogin
        result.editor = account.editor; result.third = account.third; result.unknown77 = account.unknown77
        return result
    }
}

public struct AccountListEntry: Identifiable, Equatable, Sendable {
    public var id: String { login }
    public let login: String, name: String
    public let classID: UInt8
    public let created: UInt64, lastLogin: UInt64
    var unknown1b: UInt8 = 0, unknown21: UInt8 = 0
    static func decodeList(_ b: [UInt8]) throws -> [Self] {
        try b.require(4); guard b.u32(0) <= UInt32(b.count / 40) else { throw KDXError.invalid("Invalid account count.") }
        var at = 4, entries = [Self]()
        for _ in 0..<b.u32(0) {
            try b.require(at+40); let n = Int(b[at+36]), m = Int(b[at+37]); try b.require(at+40+n+m)
            entries.append(Self(login: b.text(at+40..<at+40+n), name: b.text(at+40+n..<at+40+n+m), classID: b[at+32], created: b.u64(at), lastLogin: b.u64(at+8), unknown1b: b[at+27], unknown21: b[at+33]))
            at += min((40+n+m+3) & ~3, b.count-at)
        }
        return entries
    }
    static func encodeList(_ entries: [Self]) throws -> [UInt8] {
        var out = UInt32(entries.count).beBytes
        for entry in entries {
            let login = try shortText(entry.login), name = try shortText(entry.name)
            var b = [UInt8](repeating: 0, count: 40)
            b.put(entry.created, at: 0); b.put(entry.lastLogin, at: 8); b[27] = entry.unknown1b
            b[32] = entry.classID; b[33] = entry.unknown21; b[36] = UInt8(login.count); b[37] = UInt8(name.count)
            out += b + login + name; out.pad(4)
        }
        return out
    }
}

public struct ServerAccount: Codable, Identifiable, Equatable, Sendable {
    public var id: String { login }
    public var login: String
    public var name: String
    public var classID: UInt8
    public var privileges: AccountPrivileges
    public var privilegeMask: AccountPrivileges
    public var isAdmin: Bool {
        get { privileges.overriding(AccountClass.defaults.first { $0.id == classID }?.privileges ?? AccountPrivileges(), mask: privilegeMask).contains(0) }
        set { classID = newValue ? 0 : 1; privileges.set(0, newValue); privilegeMask.set(0, true) }
    }
    var key: [UInt8]
    var created: UInt64 = 0, modified: UInt64 = 0, lastLogin: UInt64 = 0
    var editor = "", third = ""
    var unknown77: [UInt8] = [0, 0, 0]
    public init(login: String, password: String, isAdmin: Bool = false) {
        self.login = login; name = login; classID = isAdmin ? 0 : 1
        privileges = AccountPrivileges(); privilegeMask = AccountPrivileges()
        if isAdmin { privileges.set(0, true); privilegeMask.set(0, true) }
        key = AccountKey(password: password).bytes
    }
    private enum CodingKeys: String, CodingKey { case login, name, classID, privileges, privilegeMask, key, created, modified, lastLogin, editor, third, unknown77, isAdmin }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        login = try c.decode(String.self, forKey: .login)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? login
        let oldAdmin = try c.decodeIfPresent(Bool.self, forKey: .isAdmin) ?? false
        classID = try c.decodeIfPresent(UInt8.self, forKey: .classID) ?? (oldAdmin ? 0 : 1)
        privileges = try c.decodeIfPresent(AccountPrivileges.self, forKey: .privileges) ?? .enabled(oldAdmin ? [0] : [])
        privilegeMask = try c.decodeIfPresent(AccountPrivileges.self, forKey: .privilegeMask) ?? .enabled(oldAdmin ? [0] : [])
        key = try c.decode([UInt8].self, forKey: .key)
        created = try c.decodeIfPresent(UInt64.self, forKey: .created) ?? 0; modified = try c.decodeIfPresent(UInt64.self, forKey: .modified) ?? 0
        lastLogin = try c.decodeIfPresent(UInt64.self, forKey: .lastLogin) ?? 0
        editor = try c.decodeIfPresent(String.self, forKey: .editor) ?? ""; third = try c.decodeIfPresent(String.self, forKey: .third) ?? ""
        unknown77 = try c.decodeIfPresent([UInt8].self, forKey: .unknown77) ?? [0, 0, 0]
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(login, forKey: .login); try c.encode(name, forKey: .name); try c.encode(classID, forKey: .classID)
        try c.encode(privileges, forKey: .privileges); try c.encode(privilegeMask, forKey: .privilegeMask); try c.encode(key, forKey: .key)
        try c.encode(created, forKey: .created); try c.encode(modified, forKey: .modified); try c.encode(lastLogin, forKey: .lastLogin)
        try c.encode(editor, forKey: .editor); try c.encode(third, forKey: .third); try c.encode(unknown77, forKey: .unknown77)
    }
    public func effective(in classes: [AccountClass]) -> AccountPrivileges {
        privileges.overriding(classes.first { $0.id == classID }?.privileges ?? AccountPrivileges(), mask: privilegeMask)
    }
    static func validateLogin(_ login: String) throws {
        guard !login.isEmpty, login.utf8.count <= 31, !login.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw KDXError.remote(0x10002) }
    }
    mutating func apply(_ record: RemoteAccount, editor: String, creating: Bool) {
        login = record.login; name = record.name; classID = record.classID; privileges = record.privileges; privilegeMask = record.privilegeMask
        if creating || record.key.contains(where: { $0 != 0 }) { key = record.key }
        third = record.third; unknown77 = record.unknown77; self.editor = editor
        modified = Self.now; if creating { created = modified }
    }
    // Milliseconds since 1900, verified upstream against the original server.
    static var now: UInt64 { KDXTime.encode(Date()) }
}
