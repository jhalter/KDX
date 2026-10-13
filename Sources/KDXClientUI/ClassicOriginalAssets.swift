import Foundation
import KDXCore

/// Build-time extraction from the verified OSX Intel distribution. Only data is exported.
public enum ClassicOriginalAssets {
    public static let archiveSHA256 = "b35e72925181e0044f3d6f587fa249d86df59965a5a07bd4e0843962fb286152"
    static let clientEntry = "KDX 1.6 OSX intel/KDX client.app/Contents/Resources/drive_c/Program Files/KDXClient1600-Win/KDXClient.exe"
    static let serverEntry = "KDX 1.6 OSX intel/KDX Server.app/" + ClassicServerReference.executablePath

    public static func export(from archive: URL, to destination: URL) throws {
        let data = try ClassicAssetImporter.read(archive)
        guard AppearanceDecoder.digest(data) == archiveSHA256 else {
            throw AppearanceError.invalid("Unsupported original archive. Supply the verified KDX_1.6_OSX_intel.7z (SHA-256 \(archiveSHA256)).")
        }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator:":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        guard let unar = paths.map({ URL(fileURLWithPath:$0).appendingPathComponent("unar").path })
            .first(where:{ FileManager.default.isExecutableFile(atPath:$0) }) else {
            throw AppearanceError.invalid("Install unar (brew install unar) to extract KDX_1.6_OSX_intel.7z.")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("kdx-build-assets-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:temporary) }
        // Extract from the exact bytes just verified, even if the input is replaced during the build.
        let snapshot = temporary.appendingPathComponent("original.7z")
        try data.write(to:snapshot,options:.atomic)
        func extract(_ entry: String, limit: Int) throws -> Data {
            // Selected entries stream to bounded memory; no archive paths are written to disk.
            try ArchiveProcess.run(unar,arguments:["-q","-o","-","-nr",snapshot.path,entry],directory:temporary,outputLimit:limit)
        }
        let client = try extract(clientEntry,limit:1_231_872)
        let server = try extract(serverEntry,limit:675_328)
        let clientCatalog = try JSONEncoder().encode(AppearanceDecoder.application(client).appearances)
        let serverCatalog = try JSONEncoder().encode(ClassicServerReference.decode(server))
        _ = try ClassicBundledAppearances.decode(clientCatalog)
        _ = try ClassicBundledAppearances.decode(serverCatalog)
        let table = try ChallengeTable(data:client)
        _ = try ChallengeTable(data:server)
        // Validate every input before replacing any previously generated output.
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        try clientCatalog.write(to:destination.appendingPathComponent("OriginalAppearances.json"),options:.atomic)
        try serverCatalog.write(to:destination.appendingPathComponent("OriginalServerAppearances.json"),options:.atomic)
        try table.save(to:destination.appendingPathComponent("challenge-table.bin"))
    }
}
