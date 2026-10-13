import Foundation

public enum KDXStorage {
    public static func directory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("macOS-KDX", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
    public static func loadTable() throws -> ChallengeTable {
        try loadTable(bundled:Bundle.main.url(forResource:"challenge-table",withExtension:"bin"))
    }
    static func loadTable(bundled: URL?) throws -> ChallengeTable {
        guard let bundled else {
            throw KDXError.invalid("This installation is missing required authentication data. Reinstall the app.")
        }
        do { return try ChallengeTable(file:bundled) }
        catch {
            throw KDXError.invalid("This installation's authentication data is damaged or unreadable. Reinstall the app.")
        }
    }
    public static func configurationURL() throws -> URL { try directory().appendingPathComponent("server.json") }
}
