import Foundation

public enum KDXStorage {
    public static func directory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("macOS-KDX", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
    public static func tableURL() throws -> URL { try directory().appendingPathComponent("challenge-table.bin") }
    public static func loadTable() throws -> ChallengeTable { try ChallengeTable(file: tableURL()) }
    public static func importTable(from file: URL) throws {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        try ChallengeTable(file: file).save(to: tableURL())
    }
    public static func configurationURL() throws -> URL { try directory().appendingPathComponent("server.json") }
}
