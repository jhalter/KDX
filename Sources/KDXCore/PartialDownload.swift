import Foundation
import CryptoKit
import Darwin

struct DownloadIdentity: Codable {
    let server: String
    let account: String
    let path: [String]
    let destination: String
    func digest() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A locked, descriptor-relative checkpoint retained until a download commits or is discarded.
final class PartialDownload {
    private let parent: Int32
    private let directory: Int32
    private let stem: String
    private let destination: String
    let handle: FileHandle
    private(set) var info: DownloadInfo?
    let offset: UInt64, resourceOffset: UInt64
    private struct Saved: Codable { let version: Int; let info: DownloadInfo }
    init(destination: URL, identity: DownloadIdentity) throws {
        try RemotePath.validateName(destination.lastPathComponent)
        let files = try SharedFiles(path: destination.deletingLastPathComponent().path)
        let parent = try files.directory([])
        var directory: Int32 = -1, dataFD: Int32 = -1
        do {
            var existing = stat()
            guard fstatat(parent, destination.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT else { throw KDXError.remote(0x1000d) }
            if mkdirat(parent, ".kdx-downloads", 0o700) != 0 && errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            directory = openat(parent, ".kdx-downloads", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw KDXError.invalid("The download checkpoint folder cannot be opened safely.") }
            let stem = try identity.digest()
            dataFD = openat(directory, stem + ".part", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard dataFD >= 0 else { throw KDXError.invalid("The partial download cannot be opened safely.") }
            var attributes = stat()
            guard fstat(dataFD, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG, attributes.st_nlink == 1, attributes.st_uid == getuid() else { throw KDXError.invalid("Invalid partial download file.") }
            guard flock(dataFD, LOCK_EX | LOCK_NB) == 0 else { throw KDXError.invalid("This download is already running.") }
            let info = try Self.loadInfo(directory: directory, stem: stem)
            if info == nil { guard ftruncate(dataFD, 0) == 0 else { throw POSIXError(.EIO) }; try ResourceFork.clear(dataFD); attributes.st_size = 0 }
            guard attributes.st_size >= 0, UInt64(attributes.st_size) <= (info?.dataSize ?? 0) else { throw KDXError.invalid("The partial download has an invalid size.") }
            let resourceSize = try ResourceFork.size(dataFD)
            guard resourceSize <= (info?.resourceSize ?? 0) else { throw KDXError.invalid("The partial resource fork has an invalid size.") }
            self.resourceOffset = resourceSize == info?.resourceSize ? resourceSize : resourceSize & ~UInt64(4095)
            self.parent = parent; self.directory = directory; self.stem = stem; self.destination = destination.lastPathComponent
            self.handle = FileHandle(fileDescriptor: dataFD, closeOnDealloc: true); self.info = info
            let size = UInt64(attributes.st_size)
            offset = size == info?.dataSize ? size : size & ~UInt64(4095)
        } catch {
            if dataFD >= 0 { Darwin.close(dataFD) }; if directory >= 0 { Darwin.close(directory) }; Darwin.close(parent); throw error
        }
    }
    deinit { try? handle.close(); Darwin.close(directory); Darwin.close(parent) }
    private static func loadInfo(directory: Int32, stem: String) throws -> DownloadInfo? {
        let fd = openat(directory, stem + ".json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw KDXError.invalid("The download checkpoint cannot be read safely.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(), info.st_size <= 65536 else { throw KDXError.invalid("Invalid download checkpoint.") }
        let saved = try JSONDecoder().decode(Saved.self, from: handle.readToEnd() ?? Data())
        guard saved.version == 1 else { throw KDXError.invalid("Unsupported download checkpoint version.") }
        return saved.info
    }
    func prepare(_ received: DownloadInfo) throws {
        if let info, !info.matches(received) {
            discard()
            throw KDXError.invalid("The remote file changed since the download stopped. Download it again to start from the beginning.")
        }
        let temporary = stem + ".\(UUID().uuidString).tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let metadata = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? metadata.close(); unlinkat(directory, temporary, 0) }
        try metadata.write(contentsOf: JSONEncoder().encode(Saved(version: 1, info: received))); try metadata.synchronize()
        guard renameat(directory, temporary, directory, stem + ".json") == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        info = received
        try handle.truncate(atOffset: offset); try handle.seek(toOffset: offset)
    }
    func discard() {
        unlinkat(directory, stem + ".json", 0); unlinkat(directory, stem + ".part", 0)
    }
    func commit() throws {
        if let info, info.modified != 0 {
            let date = KDXTime.decode(info.modified).timeIntervalSince1970
            var attributes = stat()
            guard fstat(handle.fileDescriptor, &attributes) == 0 else { throw POSIXError(.EIO) }
            var times = [attributes.st_atimespec, timespec(tv_sec: Int(floor(date)), tv_nsec: Int((date-floor(date))*1_000_000_000))]
            guard futimens(handle.fileDescriptor, &times) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        try handle.synchronize()
        guard linkat(directory, stem + ".part", parent, destination, 0) == 0 else { throw KDXError.remote(errno == EEXIST ? 0x1000d : 0x10014) }
        discard()
    }
}
