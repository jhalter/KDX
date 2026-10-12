import Foundation

public struct FolderAccess: Codable, Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var owner = ""
    public var description = ""
    public var currentName = ""
    public var flags: UInt32 = 0
    public var icon: UInt32 = 40
    public var classRules = [UInt16](repeating: 0, count: 32)
    public var ownerRule: UInt16 = 0
    var header = [UInt8](repeating: 0, count: 184)
    public init(name: String) { self.name = name }
    static var defaults: [Self] {
        var item = Self(name: "[Default]"); item.flags = 1
        // Preserve this server's existing policy until an administrator restricts a class.
        // Global action privileges are always required independently.
        item.classRules = [UInt16](repeating: 0xfffe, count: 32)
        return [item]
    }
    public static let permissions = ["See folder", "See contents", "Download files", "Upload files", "Create folders", "Move in", "Move out", "Alias in", "Alias out", "Duplicate in", "Duplicate out", "Delete items", "Rename", "Set attributes", "Modify contents"]
    func validate() throws {
        guard name == "[Default]" || (!name.isEmpty && !name.contains(where: { "[],/".contains($0) })) else { throw KDXError.remote(0x1001e) }
        guard classRules.count == 32, header.count == 184 else { throw KDXError.invalid("Invalid folder access record.") }
        _ = try encode()
    }
    func permits(_ bit: Int, classID: UInt8, login: String, folderOwner: String?) -> Bool {
        guard bit >= 0, bit < 15, classID < 32, classRules.count == 32 else { return false }
        let ownerLogin = flags & 2 != 0 ? folderOwner ?? "" : owner
        let rule = !ownerLogin.isEmpty && ownerLogin == login ? ownerRule : classRules[Int(classID)]
        return rule & (0x8000 >> bit) != 0
    }
    func encode() throws -> [UInt8] {
        guard header.count == 184, classRules.count == 32 else { throw KDXError.invalid("Invalid folder access record.") }
        var b = header; b.put(flags, at: 4); b.put(icon, at: 8)
        for (index, rule) in classRules.enumerated() { b.put(rule, at: 12+index*4) }
        b.put(ownerRule, at: 140)
        for (offset, text) in zip([173,174,175,177], [name,owner,description,currentName]) {
            let bytes = try shortText(text); b[offset] = UInt8(bytes.count); b += bytes
        }
        b.pad(4); return b
    }
    static func decode(_ b: [UInt8]) throws -> Self {
        try b.require(184); var at = 184, strings = [String]()
        for offset in [173,174,175,177] { let end = at+Int(b[offset]); try b.require(end); strings.append(b.text(at..<end)); at = end }
        guard (at+3) & ~3 == b.count else { throw KDXError.invalid("Invalid folder access record size.") }
        var result = Self(name: strings[0]); result.owner = strings[1]; result.description = strings[2]; result.currentName = strings[3]
        result.flags = b.u32(4); result.icon = b.u32(8); result.header = Array(b[..<184]); result.ownerRule = b.u16(140)
        result.classRules = (0..<32).map { b.u16(12+$0*4) }; return result
    }
    static func tag(in name: String) -> (tag: String, owner: String?)? {
        guard name.hasSuffix("]"), let start = name.range(of: " [", options: .backwards) else { return nil }
        let parts = name[start.upperBound..<name.index(before: name.endIndex)].split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let tag = parts.first, !tag.isEmpty else { return nil }
        return (String(tag), parts.count == 2 ? String(parts[1]) : nil)
    }
}
public struct FolderAccessSummary: Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var flags: UInt32
    public var icon: UInt32
    var second = ""
    var header = [UInt8](repeating: 0, count: 20)
    static func encodeList(_ entries: [Self]) throws -> [UInt8] {
        var b = UInt32(entries.count).beBytes
        for entry in entries {
            var record = entry.header; record.put(entry.flags, at: 0); record.put(entry.icon, at: 4)
            for (i,s) in [entry.name,entry.second,entry.description].enumerated() { let text = try shortText(s); record[17+i] = UInt8(text.count); record += text }
            record.pad(4); b += record
        }
        return b
    }
    static func decodeList(_ b: [UInt8]) throws -> [Self] {
        try b.require(4); guard b.u32(0) <= b.count/20 else { throw KDXError.invalid("Invalid access item count.") }
        var at = 4, result = [Self]()
        for _ in 0..<b.u32(0) {
            try b.require(at+20); var cursor = at+20, strings = [String]()
            for offset in 17...19 { let end = cursor+Int(b[at+offset]); try b.require(end); strings.append(b.text(cursor..<end)); cursor = end }
            result.append(Self(name: strings[0], description: strings[2], flags: b.u32(at), icon: b.u32(at+4), second: strings[1], header: Array(b[at..<at+20])))
            at = (cursor+3) & ~3; try b.require(at)
        }
        guard at == b.count else { throw KDXError.invalid("Trailing access data.") }; return result
    }
}
