import Foundation

struct CreateFolderRequest {
    var path: RemotePath
    var name: String
    var access = ""
    var owner = ""
    func encode() throws -> [UInt8] {
        let name = try shortText(name), access = try shortText(access), owner = try shortText(owner), path = try path.encode()
        guard path.count <= UInt16.max else { throw KDXError.invalid("Path too long.") }
        var b = [UInt8](repeating: 0, count: 24); b[19] = UInt8(access.count); b.put(UInt16(path.count), at: 20); b[22] = UInt8(name.count); b[23] = UInt8(owner.count)
        return b+name+access+owner+path
    }
    static func decode(_ b: [UInt8]) throws -> Self {
        try b.require(24); let n = 24+Int(b[22]), a = n+Int(b[19]), o = a+Int(b[23]), end = o+Int(b.u16(20)); try b.require(end)
        guard end == b.count else { throw KDXError.invalid("Trailing folder data.") }
        return Self(path: try RemotePath(wire: Array(b[o..<end])), name: b.text(24..<n), access: b.text(n..<a), owner: b.text(a..<o))
    }
}
struct MoveItemsRequest {
    var destination: RemotePath
    var source: RemotePath
    var items: RemotePath
    func encode() throws -> [UInt8] { try destination.encode(delimited: true)+source.encode(delimited: true)+items.encode(delimited: true) }
    static func decode(_ b: [UInt8]) throws -> Self {
        let (destination,n) = try RemotePath.decodeDelimited(b), (source,m) = try RemotePath.decodeDelimited(b, at: n), (items,k) = try RemotePath.decodeDelimited(b, at: n+m)
        guard n+m+k == b.count, !items.components.isEmpty else { throw KDXError.invalid("Invalid item list.") }
        return Self(destination: destination, source: source, items: items)
    }
}
struct TrashItemsRequest {
    var folder: RemotePath
    var items: RemotePath
    func encode() throws -> [UInt8] { try folder.encode(delimited: true)+items.encode(delimited: true) }
    static func decode(_ b: [UInt8]) throws -> Self {
        let (folder,n) = try RemotePath.decodeDelimited(b), (items,m) = try RemotePath.decodeDelimited(b, at: n)
        guard n+m == b.count, !items.components.isEmpty else { throw KDXError.invalid("Invalid item list.") }
        return Self(folder: folder, items: items)
    }
}
struct SetFileInfoRequest {
    var path: RemotePath
    var name: [UInt8]
    var flags: UInt32 = 1
    var header = [UInt8](repeating: 0, count: 52)
    func encode() throws -> [UInt8] {
        let path = try path.encode(); guard path.count <= UInt16.max, name.count <= 255, header.count == 52 else { throw KDXError.invalid("Invalid file information.") }
        var b = header; b.put(flags, at: 40); b.put(UInt16(path.count), at: 46); b[49] = UInt8(name.count)
        return b+path+name
    }
    static func decode(_ b: [UInt8]) throws -> Self {
        try b.require(52); let end = 52+Int(b.u16(46)), nameEnd = end+Int(b[49]); try b.require(nameEnd)
        guard nameEnd == b.count, b[50] == 0, b[51] == 0 else { throw KDXError.remote(0x10004) }
        return Self(path: try RemotePath(wire: Array(b[52..<end])), name: Array(b[end..<nameEnd]), flags: b.u32(40), header: Array(b[..<52]))
    }
}
public struct VolumeInformation: Sendable {
    public var totalSize: UInt64 = .max
    public var freeSpace: UInt64 = .max
    public var modified: UInt64 = 0
    public var created: UInt64 = 0
    public var itemCount: UInt32 = .max
    public var name: String
    public var format = ""
    public var comments = ""
    public var flags: UInt32 = 0
    public var flagsMask: UInt32 = 0
    var header = [UInt8](repeating: 0, count: 84)
    func encode() throws -> [UInt8] {
        var b = header; guard b.count == 84 else { throw KDXError.invalid("Invalid volume header.") }
        b.put(totalSize, at: 0); b.put(freeSpace, at: 8); b.put(modified, at: 16); b.put(created, at: 24); b.put(itemCount, at: 32); b.put(flags, at: 68); b.put(flagsMask, at: 72)
        for (offset,s) in zip([78,80,81],[name,format,comments]) { let text = try shortText(s); b[offset] = UInt8(text.count); b += text }; return b
    }
    static func decode(_ b: [UInt8]) throws -> Self {
        try b.require(84); var at = 84, strings = [String]()
        for offset in [78,80,81] { let end = at+Int(b[offset]); try b.require(end); strings.append(b.text(at..<end)); at = end }
        return Self(totalSize: b.u64(0), freeSpace: b.u64(8), modified: b.u64(16), created: b.u64(24), itemCount: b.u32(32), name: strings[0], format: strings[1], comments: strings[2], flags: b.u32(68), flagsMask: b.u32(72), header: Array(b[..<84]))
    }
}
public enum FileOrVolumeInformation: Sendable { case file(RemoteFileInformation), volume(VolumeInformation) }
public struct CatalogProgress: Equatable, Sendable {
    public var complete: Bool
    public var count: UInt32
    func encode() -> [UInt8] { (complete ? UInt32(1) : 0).beBytes+count.beBytes }
    static func decode(_ b: [UInt8]) throws -> Self { try b.require(8); return Self(complete: b.u32(0)&1 != 0, count: b.u32(4)) }
}
public struct FileSearchResult: Identifiable, Sendable {
    public var id: RemotePath { path }
    public var path: RemotePath
    public var file: RemoteFile
    var header = [UInt8](repeating: 0, count: 56)
    var nameBytes: [UInt8] = []
    static func encodeList(_ results: [Self]) throws -> [UInt8] {
        if results.isEmpty { return [] }; var b = UInt32(results.count).beBytes
        for result in results {
            var h = result.header
            if h.allSatisfy({ $0 == 0 }) { h.put(UInt16(result.file.isDirectory ? 0xffff : 0), at: 46); h[52] = result.file.isDirectory ? 0 : 0x10 }
            let path = try result.path.encode(); guard result.nameBytes.count <= 255 else { throw KDXError.invalid("Invalid search name.") }
            h.put(result.file.size, at: 0); h.put(result.file.created.map(KDXTime.encode) ?? 0, at: 8); h.put(KDXTime.encode(result.file.modified), at: 16)
            h.put(UInt32(path.count), at: 24); h.put(UInt32(result.file.isDirectory ? 0x01000002 : 1), at: 32); h[54] = UInt8(result.nameBytes.count)
            b += h+result.nameBytes+path; b.pad(4)
        }; return b
    }
    static func decodeList(_ b: [UInt8]) throws -> [Self] {
        if b.isEmpty { return [] }; try b.require(4); guard b.u32(0) <= 100 else { throw KDXError.invalid("Too many search results.") }
        var at = 4, result = [Self]()
        for _ in 0..<b.u32(0) {
            try b.require(at+56); let nameEnd = at+56+Int(b[at+54]), end = nameEnd+Int(b.u32(at+24)); try b.require(end)
            let path = try RemotePath(wire: Array(b[nameEnd..<end])), name = Array(b[at+56..<nameEnd])
            let raw = name.isEmpty ? path.components.last ?? [] : name
            let file = RemoteFile(rawName: raw, name: String(decoding: raw, as: UTF8.self), size: b.u64(at), isDirectory: b.u32(at+32)&2 != 0, modified: KDXTime.decode(b.u64(at+16)), created: b.u64(at+8) == 0 ? nil : KDXTime.decode(b.u64(at+8)))
            result.append(Self(path: path, file: file, header: Array(b[at..<at+56]), nameBytes: name)); at = (end+3) & ~3; try b.require(at)
        }; guard at == b.count else { throw KDXError.invalid("Trailing search data.") }; return result
    }
}
