import Foundation

/// A build-generated, data-only catalog. The reference executable is never bundled or run.
public enum ClassicBundledAppearances {
    public static func export(from source: URL, to destination: URL) async throws {
        let imported = try await ClassicAssetImporter.load(source)
        let data = try JSONEncoder().encode(imported.appearances)
        _ = try decode(data)
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:destination,options:.atomic)
    }
    public static func load(from source: URL) throws -> [ClassicAppearance] {
        let handle = try FileHandle(forReadingFrom:source)
        defer { try? handle.close() }
        return try decode(handle.read(upToCount:4_000_000) ?? Data())
    }
    static func decode(_ data: Data) throws -> [ClassicAppearance] {
        guard data.count < 4_000_000 else { throw AppearanceError.invalid("Bundled appearance catalog exceeds its size limit.") }
        let appearances = try JSONDecoder().decode([ClassicAppearance].self,from:data)
        guard appearances.count == 16, Set(appearances.map(\.id)).count == 16,
              appearances.contains(where:{ $0.name == "Mach Lavender" }),
              appearances.contains(where:{ $0.name == "Amber CRT" }) else {
            throw AppearanceError.invalid("Bundled appearances require all 16 original KDX Client 1.600 themes.")
        }
        for appearance in appearances {
            try appearance.validate()
            guard let artwork = appearance.artwork,
                  AppearanceDecoder.digest(artwork.icons) == AppearanceDecoder.referenceIconAtlasSHA256,
                  appearance.fonts?.count == 4, appearance.chromeArtwork != nil else {
                throw AppearanceError.invalid("Bundled appearance artwork or fonts are missing.")
            }
        }
        return appearances
    }
}
