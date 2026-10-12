import Foundation
import CryptoKit
import Darwin

/// Private upload staging survives disconnects and server restarts, isolated by account and folder.
final class PartialUpload {
    private let parent: Int32, directory: Int32
    private let stem: String, name: String
    private let retainOnFailure: Bool
    let handle: FileHandle
    let reportedOffset: UInt64, offset: UInt64
    init(files: SharedFiles, request: UploadRequest, owner: String?) throws {
        let name = request.strings[0]; try RemotePath.validateName(name)
        let parent = try files.directory(request.folder.localNames())
        var directory: Int32 = -1, dataFD: Int32 = -1
        do {
            var existing = stat()
            guard fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT else { throw KDXError.remote(0x30073) }
            if mkdirat(parent, ".kdx-uploads", 0o700) != 0 && errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            directory = openat(parent, ".kdx-uploads", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw KDXError.remote(0x10014) }
            let identity = try JSONEncoder().encode([owner ?? UUID().uuidString, name])
            let stem = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            dataFD = openat(directory, stem + ".part", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard dataFD >= 0 else { throw KDXError.remote(0x10014) }
            var attributes = stat()
            guard fstat(dataFD, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG, attributes.st_nlink == 1, attributes.st_uid == getuid(), attributes.st_size >= 0 else { throw KDXError.remote(0x10014) }
            guard flock(dataFD, LOCK_EX | LOCK_NB) == 0 else { throw KDXError.invalid("This upload is already running.") }
            let metadata = Data(try request.encode())
            let prior = try Self.readMetadata(directory: directory, stem: stem)
            let size = prior == metadata && UInt64(attributes.st_size) <= request.dataSize ? UInt64(attributes.st_size) : 0
            let offset = size & ~UInt64(4095)
            guard ftruncate(dataFD, off_t(offset)) == 0, lseek(dataFD, off_t(offset), SEEK_SET) >= 0 else { throw POSIXError(.EIO) }
            try ResourceFork.clear(dataFD)
            try Self.saveMetadata(metadata, directory: directory, stem: stem)
            self.parent = parent; self.directory = directory; self.stem = stem; self.name = name
            handle = FileHandle(fileDescriptor: dataFD, closeOnDealloc: true); reportedOffset = size; self.offset = offset; retainOnFailure = owner != nil
        } catch {
            if dataFD >= 0 { Darwin.close(dataFD) }; if directory >= 0 { Darwin.close(directory) }; Darwin.close(parent); throw error
        }
    }
    deinit {
        try? handle.synchronize(); try? handle.close()
        if !retainOnFailure { unlinkat(directory, stem + ".part", 0); unlinkat(directory, stem + ".metadata", 0) }
        Darwin.close(directory); Darwin.close(parent)
    }
    private static func readMetadata(directory: Int32, stem: String) throws -> Data? {
        let fd = openat(directory, stem + ".metadata", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw KDXError.remote(0x10014) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG, attributes.st_nlink == 1, attributes.st_uid == getuid(), attributes.st_size <= 0x20000 else { throw KDXError.remote(0x10014) }
        return try handle.readToEnd()
    }
    private static func saveMetadata(_ data: Data, directory: Int32, stem: String) throws {
        let name = stem + ".\(UUID().uuidString).tmp"
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); unlinkat(directory, name, 0) }
        try handle.write(contentsOf: data); try handle.synchronize()
        guard renameat(directory, name, directory, stem + ".metadata") == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    func commit() throws {
        try handle.synchronize()
        guard linkat(directory, stem + ".part", parent, name, 0) == 0 else { throw KDXError.remote(errno == EEXIST ? 0x30073 : 0x10014) }
        unlinkat(directory, stem + ".part", 0); unlinkat(directory, stem + ".metadata", 0)
    }
}
