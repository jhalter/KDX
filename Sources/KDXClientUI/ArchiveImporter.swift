import Foundation

/// Internal injection points let tests exercise real subprocess cancellation without executing legacy code.
struct ArchiveImportOptions: Sendable {
    var unar: String?
    var lsar: String?
    var temporaryParent = FileManager.default.temporaryDirectory
    var maximumBytes = ClassicAssetImporter.maximumBytes
    var maximumEntries = 256
    var processTimeout: TimeInterval = 30
    var totalTimeout: TimeInterval = 60
}

private struct ArchiveImportContext {
    let root: URL
    let options: ArchiveImportOptions
    let deadline: ContinuousClock.Instant

    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw AppearanceError.invalid("Appearance import timed out.") }
    }
    func inspectTree() throws {
        try check()
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .totalFileSizeKey]
        var enumerationError: Error?
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
            enumerationError = error; return false
        }) else { throw AppearanceError.invalid("Could not inspect extracted files.") }
        var count = 0, total = 0
        for case let item as URL in items {
            try check()
            count += 1
            let values = try item.resourceValues(forKeys: keys)
            guard count <= options.maximumEntries, values.isSymbolicLink != true,
                  values.isRegularFile == true || values.isDirectory == true else { throw AppearanceError.invalid("Unsafe archive output or too many extracted entries.") }
            if values.isRegularFile == true {
                // Total size includes named forks on filesystems that expose them; sidecars are counted separately.
                guard let size = values.totalFileSize ?? values.fileSize, size >= 0,
                      size <= options.maximumBytes - total else { throw AppearanceError.invalid("Extracted archive exceeds its size limit.") }
                total += size
            }
        }
        if let enumerationError { throw enumerationError }
    }
    func directory() throws -> URL {
        try check()
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    func verified(_ result: AppearanceImport) throws -> AppearanceImport {
        try check()
        guard result.appearances.count <= 64, result.assets.count <= 1024 else { throw AppearanceError.invalid("Appearance or asset count limit exceeded.") }
        var bytes = 0
        for data in result.assets.values {
            guard data.count <= options.maximumBytes - bytes else { throw AppearanceError.invalid("Imported assets exceed their size limit.") }
            bytes += data.count
        }
        return result
    }
}

public enum ClassicAssetImporter {
    public static let maximumBytes = 64 * 1024 * 1024
    static func read(_ url: URL) throws -> Data {
        try Task.checkCancellation()
        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize, size <= maximumBytes else { throw AppearanceError.invalid("Import requires a regular file no larger than 64 MiB.") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes+1) ?? Data()
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw AppearanceError.invalid("Import exceeds 64 MiB.") }
        return data
    }
    public static func load(_ url: URL) async throws -> AppearanceImport {
        try await load(url, options: ArchiveImportOptions())
    }
    static func load(_ url: URL, options: ArchiveImportOptions) async throws -> AppearanceImport {
        try Task.checkCancellation()
        let worker = Task.detached { try loadSync(url, options: options) }
        return try await withTaskCancellationHandler {
            // Await worker cleanup even when the caller is already cancelled.
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }
    static func loadSync(_ url: URL, depth: Int = 0, options: ArchiveImportOptions = ArchiveImportOptions()) throws -> AppearanceImport {
        try Task.checkCancellation()
        let temporary = options.temporaryParent.appendingPathComponent("kdx-classic-import-"+UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let context = ArchiveImportContext(root: temporary, options: options, deadline: ContinuousClock.now.advanced(by: .seconds(options.totalTimeout)))
        return try context.verified(loadSync(url, depth: depth, context: context))
    }
    private static func loadSync(_ url: URL, depth: Int, context: ArchiveImportContext) throws -> AppearanceImport {
        try context.check()
        guard depth <= 2 else { throw AppearanceError.invalid("Archive nesting exceeds two levels.") }
        let data = try read(url)
        if data.starts(with: Data("%HAP".utf8)) { return try AppearanceDecoder.hap(data, name: url.deletingPathExtension().lastPathComponent) }
        if data.starts(with: Data("Joy!peff".utf8)) {
            let sidecar = url.appendingPathExtension("rsrc")
            var fork: Data?
            if FileManager.default.fileExists(atPath: sidecar.path) { fork = try read(sidecar) }
            else {
                let forkURL = URL(fileURLWithPath: url.path + "/..namedfork/rsrc")
                if let handle = try? FileHandle(forReadingFrom: forkURL) {
                    defer { try? handle.close() }
                    fork = try handle.read(upToCount: maximumBytes+1)
                    if fork?.isEmpty == true { fork = nil }
                    guard (fork?.count ?? 0) <= maximumBytes else { throw AppearanceError.invalid("Resource fork exceeds 64 MiB.") }
                }
            }
            try context.check()
            return try AppearanceDecoder.application(data, resourceFork: fork)
        }
        // All nested extraction lives beneath one monitored, private temporary root.
        let temporary = try context.directory()
        if url.pathExtension.lowercased() == "bin", data.count >= 128, data[0] == 0, (1...63).contains(data[1]) {
            let b = try AssetBytes(data), size = try b.u32(83), resourceSize = try b.u32(87)
            let dataFork = try b.data(128, size), resourceOffset = 128 + ((size + 127) & ~127)
            let resourceFork = try b.data(resourceOffset, resourceSize)
            if dataFork.starts(with: Data("Joy!peff".utf8)) { return try AppearanceDecoder.application(dataFork, resourceFork: resourceFork.isEmpty ? nil : resourceFork) }
            let unpacked = temporary.appendingPathComponent("archive.sit")
            try dataFork.write(to: unpacked)
            try context.inspectTree()
            return try loadSync(unpacked, depth: depth+1, context: context)
        }
        guard let unar = context.options.unar ?? ["/opt/homebrew/bin/unar", "/usr/local/bin/unar"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let lsar = context.options.lsar ?? ["/opt/homebrew/bin/lsar", "/usr/local/bin/lsar"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AppearanceError.invalid("Install unar, or select an already-extracted KDXClient.app with its resource fork (or .rsrc sidecar).")
        }
        let listing = try ArchiveProcess.run(lsar, arguments: ["-j", url.path], directory: temporary, timeout: context.options.processTimeout, monitor: context.inspectTree)
        guard let json = try JSONSerialization.jsonObject(with: listing) as? [String: Any], let entries = json["lsarContents"] as? [[String: Any]] else { throw AppearanceError.invalid("Unrecognized archive listing.") }
        try validate(entries: entries)
        // Paths are argv elements. A hard per-file limit complements the polled aggregate quota.
        // The shell execs unar, so the monitored PID is the extractor itself.
        _ = try ArchiveProcess.run("/bin/sh", arguments: ["-c", "ulimit -f 131072 || exit 1; exec \"$@\"", "kdx-unar", unar, "-q", "-f", "-D", "-o", temporary.path, url.path], directory: temporary, timeout: context.options.processTimeout, monitor: context.inspectTree)
        try context.inspectTree()
        guard let enumerator = FileManager.default.enumerator(at: temporary, includingPropertiesForKeys: [.isRegularFileKey]) else { throw AppearanceError.invalid("Could not inspect extracted files.") }
        var candidates = [URL]()
        for case let item as URL in enumerator {
            try context.check()
            if try item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true && ["app","hap","sit"].contains(item.pathExtension.lowercased()) { candidates.append(item) }
        }
        var result = AppearanceImport(appearances: [], assets: [:])
        for candidate in candidates.sorted(by: { $0.path < $1.path }) {
            let loaded = try context.verified(loadSync(candidate, depth: depth+1, context: context))
            result.appearances += loaded.appearances
            for (key, value) in loaded.assets { result.assets["\(result.appearances.count)-"+key] = value }
            result = try context.verified(result)
        }
        guard !result.appearances.isEmpty else { throw AppearanceError.invalid("No supported KDX application or HAP appearance was found.") }
        return result
    }
    static func validate(entries: [[String: Any]]) throws {
        guard !entries.isEmpty, entries.count <= 128 else { throw AppearanceError.invalid("Archive entry limit exceeded.") }
        var total = 0
        for entry in entries {
            guard let name = entry["XADFileName"] as? String, !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !name.split(separator: "/").contains(".."), !name.contains("\0"),
                  entry["XADIsLink"] as? Bool != true, entry["XADLinkDestination"] == nil,
                  entry["XADIsEncrypted"] as? Bool != true else { throw AppearanceError.invalid("Archive contains unsafe paths, links, or encrypted entries.") }
            let directory = entry["XADIsDirectory"] as? Bool == true
            guard let number = entry["XADFileSize"] as? NSNumber ?? (directory ? NSNumber(value: 0) : nil), number.int64Value >= 0, number.int64Value <= maximumBytes else { throw AppearanceError.invalid("Archive has missing or excessive sizes.") }
            total += number.intValue
            guard total <= maximumBytes else { throw AppearanceError.invalid("Archive exceeds 64 MiB expanded.") }
        }
    }
}
