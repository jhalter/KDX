import Foundation
import Darwin

public struct RemoteFile: Identifiable, Sendable {
    public var id: String { Data(nameBytes).base64EncodedString() }
    public var nameBytes: [UInt8] { rawName ?? Array(name.utf8) }
    var rawName: [UInt8]? = nil
    public var name: String
    public var size: UInt64
    public var isDirectory: Bool
    public var modified: Date
    public var created: Date? = nil
    public var kind: String = ""
    var header: [UInt8]? = nil
    static func decodeList(_ b: [UInt8]) throws -> [RemoteFile] {
        if b.isEmpty { return [] }; try b.require(4)
        guard b.u32(0) <= UInt32(b.count / 56) else { throw KDXError.invalid("Invalid file list count.") }
        var at = 4, files = [RemoteFile]()
        for _ in 0..<b.u32(0) {
            try b.require(at+56); let n = Int(b[at+53]), k = Int(b[at+54]); try b.require(at+56+n+k)
            files.append(RemoteFile(rawName: Array(b[at+56..<at+56+n]), name: b.text(at+56..<at+56+n), size: b.u64(at), isDirectory: b.u32(at+32) & 2 != 0, modified: KDXTime.decode(b.u64(at+16)), created: b.u64(at+8) == 0 ? nil : KDXTime.decode(b.u64(at+8)), kind: b.text(at+56+n..<at+56+n+k), header: Array(b[at..<at+56])))
            at += min((56+n+k+3) & ~3, b.count-at)
        }
        return files
    }
    static func encodeList(_ files: [RemoteFile]) throws -> [UInt8] {
        if files.isEmpty { return [] }
        var out = UInt32(files.count).beBytes
        for file in files {
            let name = file.nameBytes, kind = try shortText(file.kind)
            try RemotePath.validateBytes(name)
            var b = file.header ?? [UInt8](repeating: 0, count: 56)
            guard b.count == 56 else { throw KDXError.invalid("Invalid file-list header.") }
            b.put(file.size, at: 0); b.put(file.created.map(KDXTime.encode) ?? 0, at: 8); b.put(KDXTime.encode(file.modified), at: 16)
            if file.header == nil {
                b.put(UInt32(file.isDirectory ? 0x01000002 : 1), at: 32)
                b.put(UInt16(file.isDirectory ? 0xffff : 0), at: 46)
            }
            b[53] = UInt8(name.count); b[54] = UInt8(kind.count)
            out += b + name + kind; out.pad(4)
        }
        guard out.count <= 0x100000 else { throw KDXError.invalid("Directory listing exceeds the KDX protocol limit.") }
        return out
    }
}
/// A remote path retains the server's exact filename bytes independently of display text.
public struct RemotePath: Equatable, Hashable, Sendable {
    public let components: [[UInt8]]
    public var names: [String] { components.map { String(decoding: $0, as: UTF8.self) } }
    public init(_ names: [String]) { components = names.map { Array($0.utf8) } }
    public init(components: [[UInt8]]) { self.components = components }
    public func appending(_ file: RemoteFile) -> Self { Self(components: components + [file.nameBytes]) }
    public func prefix(_ count: Int) -> Self { Self(components: Array(components.prefix(count))) }
    public var parent: Self { Self(components: Array(components.dropLast())) }
    static func validateName(_ name: String) throws { try validateBytes(Array(name.utf8)) }
    static func validateBytes(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty, bytes.count <= 255, bytes != [46], bytes != [46,46], !bytes.contains(47), !bytes.contains(0), !bytes.starts(with: Array(".kdx-".utf8)) else { throw KDXError.remote(0x10014) }
    }
    func encode(delimited: Bool = false) throws -> [UInt8] {
        guard components.count <= 1024 else { throw KDXError.invalid("Path is too deep.") }
        if components.isEmpty { return delimited ? [0,0] : [] }
        var out = [UInt8](repeating: 0, count: 2); out.put(UInt16(components.count), at: 0)
        for bytes in components { try Self.validateBytes(bytes); out += [0,0,UInt8(bytes.count)] + bytes }
        return out
    }
    init(wire b: [UInt8]) throws {
        if b.isEmpty { components = []; return }
        let (path, used) = try Self.decodeDelimited(b)
        guard !path.components.isEmpty, used == b.count else { throw KDXError.invalid("Invalid file path.") }
        self = path
    }
    static func decodeDelimited(_ b: [UInt8], at start: Int = 0) throws -> (Self, Int) {
        try b.require(start+2); let count = Int(b.u16(start))
        guard count <= 1024 else { throw KDXError.invalid("Invalid path depth.") }
        var at = start+2, components = [[UInt8]]()
        for _ in 0..<count {
            try b.require(at+3); let length = Int(b[at+2]); try b.require(at+3+length)
            let bytes = Array(b[at+3..<at+3+length]); try Self.validateBytes(bytes)
            components.append(bytes); at += 3+length
        }
        return (Self(components: components), at-start)
    }
    /// macOS filesystem calls require valid UTF-8; never substitute a different name.
    func localNames() throws -> [String] {
        try components.map { bytes in
            guard let name = String(bytes: bytes, encoding: .utf8) else { throw KDXError.invalid("Invalid local file name encoding.") }
            try Self.validateName(name); return name
        }
    }
}

/// Resolve each component relative to an open directory descriptor. Symlinks are never followed.
final class SharedFiles {
    private let root: Int32
    init(path: String) throws {
        guard !path.isEmpty else { throw KDXError.remote(0x10014) }
        root = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    deinit { Darwin.close(root) }
    func directory(_ names: [String]) throws -> Int32 {
        var fd = dup(root)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        do {
            for name in names {
                try RemotePath.validateName(name)
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw KDXError.remote(0x10014) }
                Darwin.close(fd); fd = next
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    func list(_ names: [String]) throws -> [RemoteFile] {
        let fd = try directory(names)
        guard let dir = fdopendir(fd) else { Darwin.close(fd); throw POSIXError(.EIO) }
        defer { closedir(dir) }
        var result = [RemoteFile]()
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)+1) { String(cString: $0) }
            }
            if name == "." || name == ".." || name.hasPrefix(".kdx-") { continue }
            var attributes = stat()
            guard fstatat(fd, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = attributes.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else { continue }
            result.append(RemoteFile(name: name, size: UInt64(max(0, attributes.st_size)), isDirectory: kind == S_IFDIR, modified: Self.date(attributes.st_mtimespec), created: Self.date(attributes.st_birthtimespec), kind: kind == S_IFDIR ? "" : FileKind.from(name: name, isDirectory: false)))
            guard result.count <= 10000 else { throw KDXError.invalid("Directory has too many entries.") }
        }
        return result.sorted { if $0.isDirectory != $1.isDirectory { return $0.isDirectory }; return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private static func date(_ value: timespec) -> Date {
        Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_nsec)/1_000_000_000)
    }
    func information(_ names: [String]) throws -> RemoteFileInformation {
        let fd: Int32
        if let name = names.last {
            try RemotePath.validateName(name)
            let parent = try directory(Array(names.dropLast())); defer { Darwin.close(parent) }
            fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        } else { fd = dup(root) }
        guard fd >= 0 else { throw KDXError.remote(0x10014) }
        defer { Darwin.close(fd) }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, [S_IFDIR,S_IFREG].contains(attributes.st_mode & S_IFMT) else { throw KDXError.remote(0x10014) }
        let isDirectory = attributes.st_mode & S_IFMT == S_IFDIR, name = names.last ?? "Shared Files"
        var info = RemoteFileInformation(name: name, kind: FileKind.from(name: name, isDirectory: isDirectory), size: UInt64(max(0, attributes.st_size)),
                                         created: Self.date(attributes.st_birthtimespec), modified: Self.date(attributes.st_mtimespec))
        info.header.put(UInt32(isDirectory ? 2 : 1), at: 40)
        return info
    }
    func openFile(_ names: [String]) throws -> (FileHandle, UInt64) {
        guard let name = names.last else { throw KDXError.remote(0x1000a) }; try RemotePath.validateName(name)
        let parent = try directory(Array(names.dropLast())); defer { Darwin.close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw KDXError.remote(0x10014) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { Darwin.close(fd); throw KDXError.remote(0x10014) }
        return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), UInt64(info.st_size))
    }
    func beginUpload(folder: [String], name: String) throws -> PendingUpload {
        try RemotePath.validateName(name)
        let parent = try directory(folder)
        let temp = ".kdx-\(UUID().uuidString).part"
        let fd = openat(parent, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { Darwin.close(parent); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return PendingUpload(parent: parent, temporary: temp, name: name, handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }
}
final class PendingUpload {
    let parent: Int32, temporary: String, name: String, handle: FileHandle
    init(parent: Int32, temporary: String, name: String, handle: FileHandle) { self.parent = parent; self.temporary = temporary; self.name = name; self.handle = handle }
    deinit { try? handle.close(); unlinkat(parent, temporary, 0); Darwin.close(parent) }
    func commit() throws {
        try handle.synchronize()
        // linkat fails when the destination exists: never overwrite a shared file.
        guard linkat(parent, temporary, parent, name, 0) == 0 else { throw KDXError.remote(errno == EEXIST ? 0x1000d : 0x10014) }
        unlinkat(parent, temporary, 0)
    }
}

extension SharedFiles {
    func createFolder(parent names: [String], name: String) throws {
        try RemotePath.validateName(name)
        let parent = try directory(names); defer { Darwin.close(parent) }
        guard mkdirat(parent, name, 0o755) == 0 else { throw KDXError.remote(errno == EEXIST ? 0x1000d : 0x10014) }
    }
    private func requireItem(parent: Int32, name: String) throws {
        try RemotePath.validateName(name)
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              [S_IFDIR,S_IFREG].contains(info.st_mode & S_IFMT) else { throw KDXError.remote(0x10014) }
    }
    func move(source: [String], destination: [String], names: [String]) throws {
        let from = try directory(source); defer { Darwin.close(from) }
        let to = try directory(destination); defer { Darwin.close(to) }
        guard source != destination else { return }
        for name in names {
            try requireItem(parent: from, name: name)
            var info = stat()
            guard fstatat(to, name, &info, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT,
                  !destination.starts(with: source+[name]) else { throw KDXError.remote(0x10014) }
        }
        for name in names {
            guard renameatx_np(from, name, to, name, UInt32(RENAME_EXCL)) == 0 else { throw KDXError.remote(errno == EEXIST ? 0x1000d : 0x10014) }
        }
    }
    func rename(_ path: [String], to name: String) throws {
        guard let original = path.last else { throw KDXError.remote(0x10014) }
        try RemotePath.validateName(name)
        let parent = try directory(Array(path.dropLast())); defer { Darwin.close(parent) }
        try requireItem(parent: parent, name: original)
        if original == name { return }
        guard renameatx_np(parent, original, parent, name, UInt32(RENAME_EXCL)) == 0 else { throw KDXError.remote(errno == EEXIST ? 0x1000d : 0x10014) }
    }
    private func trashDirectory() throws -> Int32 {
        if mkdirat(root, ".kdx-trash", 0o700) != 0 && errno != EEXIST { throw POSIXError(.EIO) }
        let fd = openat(root, ".kdx-trash", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw KDXError.remote(0x10014) }; return fd
    }
    func trash(folder: [String], names: [String]) throws {
        let parent = try directory(folder); defer { Darwin.close(parent) }
        let trash = try trashDirectory(); defer { Darwin.close(trash) }
        for name in names { try requireItem(parent: parent, name: name) }
        for name in names {
            guard renameatx_np(parent, name, trash, UUID().uuidString, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
    func emptyTrash() throws {
        let fd = try trashDirectory(); defer { Darwin.close(fd) }
        try Self.removeContents(fd, depth: 0)
    }
    private static func removeContents(_ fd: Int32, depth: Int) throws {
        guard depth < 256 else { throw KDXError.invalid("Trash nesting exceeds the limit.") }
        let copy = dup(fd); guard copy >= 0 else { throw POSIXError(.EIO) }
        guard let dir = fdopendir(copy) else { Darwin.close(copy); throw POSIXError(.EIO) }; defer { closedir(dir) }
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)+1) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            var info = stat(); guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError(.EIO) }
            let isDirectory = info.st_mode & S_IFMT == S_IFDIR
            if isDirectory {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw KDXError.remote(0x10014) }
                do { try removeContents(child, depth: depth+1); Darwin.close(child) } catch { Darwin.close(child); throw error }
            }
            guard unlinkat(fd, name, isDirectory ? AT_REMOVEDIR : 0) == 0 else { throw POSIXError(.EIO) }
        }
    }
    func volumeInformation() throws -> VolumeInformation {
        var info = statfs(); guard fstatfs(root, &info) == 0 else { throw POSIXError(.EIO) }
        let format = withUnsafePointer(to: &info.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        return VolumeInformation(totalSize: UInt64(info.f_blocks)*UInt64(info.f_bsize), freeSpace: UInt64(info.f_bavail)*UInt64(info.f_bsize), name: "Shared Files", format: format)
    }
}
