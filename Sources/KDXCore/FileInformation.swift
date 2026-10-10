import Foundation

public struct RemoteFileInformation: Sendable {
    public var name: String
    public var kind: String
    public var size: UInt64
    public var created: Date?
    public var modified: Date?
    public var isDirectory: Bool { kind == "folder" }
    var header = [UInt8](repeating: 0, count: 64)
    func encode() throws -> [UInt8] {
        guard header.count == 64 else { throw KDXError.invalid("Invalid file-information header.") }
        let name = try shortText(name), kind = try shortText(kind)
        var b = header
        b.put(size, at: 8); b.put(created.map(KDXTime.encode) ?? 0, at: 16); b.put(modified.map(KDXTime.encode) ?? 0, at: 24)
        b[61] = UInt8(name.count); b[62] = UInt8(kind.count)
        return b + name + kind
    }
    static func decode(_ b: [UInt8]) throws -> Self {
        try b.require(64); let kindAt = 64 + Int(b[61]), end = kindAt + Int(b[62]); try b.require(end)
        return Self(name: b.text(64..<kindAt), kind: b.text(kindAt..<end), size: b.u64(8),
                    created: b.u64(16) == 0 ? nil : KDXTime.decode(b.u64(16)), modified: b.u64(24) == 0 ? nil : KDXTime.decode(b.u64(24)), header: Array(b[..<64]))
    }
}

/// This is the only file-kind notation independently observed in the reference.
enum FileKind {
    static func from(name: String, isDirectory: Bool) -> String {
        if isDirectory { return "folder" }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty || ext.utf8.count > 247 ? "" : "exttype/" + ext
    }
}
