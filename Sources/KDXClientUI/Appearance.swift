import Foundation
import CryptoKit
import AppKit

public struct ClassicAppearance: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let colors: [UInt32]
    public let source: String
    public var artwork: HAPArtwork? = nil
    public var fonts: [Data]? = nil
    public var chromeArtwork: HAPChromeArtwork? = nil
    public static let recovery = ClassicAppearance(id: "recovery", name: "Classic Recovery", colors: [
        0, 0xffffff, 0xdddddd, 0x888888, 0, 0, 0x888888, 0x777777, 0xcc0000,
        0x666699, 0xffffff, 0, 0x9999cc, 0, 0x333366, 0xeeeeee, 0, 0x9999cc, 0, 0xdddddd, 0xffffff
    ], source: "Built-in setup appearance; original assets not installed")
    public func color(_ slot: Int) -> NSColor {
        let rgb = colors.indices.contains(slot) ? colors[slot] : Self.recovery.colors[slot % Self.recovery.colors.count]
        return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
    }
    func validate() throws {
        guard Self.validPalette(colors),
              !id.isEmpty, !name.isEmpty, name.count <= 128, (fonts?.count ?? 0) <= 32 else {
            throw AppearanceError.invalid("Invalid appearance catalog entry.")
        }
        _ = try artwork?.decode()
        try chromeArtwork?.validate()
        for data in fonts ?? [] { _ = try HaxialFont(data:data) }
    }
    static func validPalette(_ values: [UInt32]) -> Bool {
        // HAP slots 21–24 hold packed parameters, not RGB. Use the same rule
        // when decoding a HAP and when saving/reloading its catalog entry.
        (204...221).contains(values.count) && values.enumerated().allSatisfy {
            (21...24).contains($0.offset) || $0.element <= 0xffffff
        }
    }
}

public enum AppearanceError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

/// Big-endian reads are checked before indexing. All offsets refer to the supplied data, never memory addresses.
struct AssetBytes {
    let bytes: [UInt8]
    init(_ data: Data) throws {
        guard data.count <= 64 * 1024 * 1024 else { throw AppearanceError.invalid("Asset exceeds 64 MiB.") }
        bytes = Array(data)
    }
    func range(_ offset: Int, _ count: Int) throws -> Range<Int> {
        guard offset >= 0, count >= 0, offset <= bytes.count, count <= bytes.count - offset else { throw AppearanceError.invalid("Truncated or corrupt asset.") }
        return offset..<offset+count
    }
    func u16(_ at: Int) throws -> Int { let r = try range(at, 2); return r.reduce(0) { ($0 << 8) | Int(bytes[$1]) } }
    func u32(_ at: Int) throws -> Int { let r = try range(at, 4); return r.reduce(0) { ($0 << 8) | Int(bytes[$1]) } }
    func data(_ at: Int, _ count: Int) throws -> Data { Data(bytes[try range(at, count)]) }
}

public struct AppearanceImport: Sendable {
    public var appearances: [ClassicAppearance]
    public var assets: [String: Data]
}

public enum AppearanceDecoder {
    public static let referenceSHA256 = "fb3876cd557c3a077f5cd3dbf1b0546d95de8cee7fb56f276b94aa6275fbca18"
    public static let windowsReferenceSHA256 = "99d4a8f45c61fca1ee5753028de28479e040f43a08c507ccfcc23be92c20b983"
    static let referenceIconAtlasSHA256 = "a7e18bf724aece58b9fc39566c50c3f6d9bd2a142917ce35635f95623a7ebdfc"
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// RGB dictionary followed by one-byte palette indices (PPC routine 0x9F620).
    public static func compactPalette(_ data: Data) throws -> [UInt32] {
        let b = try AssetBytes(data); _ = try b.range(0, 2)
        let count = Int(b.bytes[0]), slots = Int(b.bytes[1]), indexOffset = 2 + count * 3
        guard count > 0, (204...221).contains(slots), data.count == indexOffset + slots else { throw AppearanceError.invalid("Unsupported compact palette.") }
        return try b.bytes[indexOffset...].map { index in
            guard Int(index) < count else { throw AppearanceError.invalid("Invalid palette index.") }
            let at = 2 + Int(index) * 3
            return UInt32(b.bytes[at]) << 16 | UInt32(b.bytes[at+1]) << 8 | UInt32(b.bytes[at+2])
        }
    }
    public static func hap(_ data: Data, name: String) throws -> AppearanceImport {
        let b = try AssetBytes(data); _ = try b.range(0, 0x88)
        guard try b.data(0, 4) == Data("%HAP".utf8), try b.u16(4) == 1 else { throw AppearanceError.invalid("Unsupported HAP signature or version (only version 1 is supported).") }
        var sections = [Data]()
        var ranges = [Range<Int>]()
        for at in stride(from: 0x2c, through: 0x4c, by: 8) {
            let offset = try b.u32(at), size = try b.u32(at+4)
            guard offset % 4 == 0, size == 0 || offset >= 0x88 else { throw AppearanceError.invalid("Invalid HAP section.") }
            let range = try b.range(offset, size)
            if size > 0 {
                guard !ranges.contains(where: { $0.overlaps(range) }) else { throw AppearanceError.invalid("Overlapping HAP sections.") }
                ranges.append(range)
            }
            sections.append(try b.data(offset, size))
        }
        let palette = try AssetBytes(sections[2])
        guard (816...884).contains(palette.bytes.count), palette.bytes.count % 4 == 0 else { throw AppearanceError.invalid("Unsupported HAP palette size.") }
        let colors = try stride(from: 0, to: palette.bytes.count, by: 4).map { UInt32(try palette.u32($0)) }
        // Slots 21–24 contain packed metrics, not RGB. Other high bytes are reserved.
        guard ClassicAppearance.validPalette(colors) else { throw AppearanceError.invalid("Unsupported HAP color encoding.") }
        // Decode bounded raster records; the original executable is never run.
        let artwork = try HAPArtwork(skins: sections[1], icons: sections[3])
        var assets: [String: Data] = ["appearance.hap": data]
        for (index, section) in sections.enumerated() where !section.isEmpty { assets["section-\(index).dat"] = section }
        let appearance = ClassicAppearance(id: digest(data), name: String(name.prefix(128)), colors: colors, source: "Imported HAP v1", artwork: artwork)
        return AppearanceImport(appearances: [appearance], assets: assets)
    }
    public static func application(_ data: Data, resourceFork: Data? = nil) throws -> AppearanceImport {
        let hash = digest(data), windows = hash == windowsReferenceSHA256
        guard hash == referenceSHA256 || windows else { throw AppearanceError.invalid("Unsupported application revision. Import the verified KDX Client 1.600 PowerPC or Windows reference, or a version 1 .hap file.") }
        let b = try AssetBytes(data)
        var result = try hap(b.data(windows ? 0x1053a0 : 0x10b380, 0x7d60), name: "Evil Chiaroscuro")
        let offsets = windows
            ? [0x1034f8,0x101ce8,0x101ea3,0x10206a,0x10223a,0x10240a,0x1025cb,0x10273b,0x1028f3,0x102a99,0x102c51,0x102e0f,0x102fc7,0x10318b,0x103343]
            : [0x10add0,0x1095a8,0x109764,0x109930,0x109b00,0x109cd0,0x109e98,0x10a008,0x10a1c0,0x10a368,0x10a520,0x10a6e0,0x10a898,0x10aa60,0x10ac18]
        let names = ["Alternate Romp", "Amber CRT", "Blue Jeans", "Blue Tram Café", "Bubblegum Crisis", "Chocolate Raspberry", "Mach Lavender", "Oxygen", "Sunset Chiaroscuro", "Techno Electric", "The Dream Scheme (Blue)", "The Dream Scheme (Green)", "The Dream Scheme (Purple)", "Tropical Water", "Turquoise Hilites"]
        for (offset, name) in zip(offsets, names) {
            let size = 2 + Int(b.bytes[offset]) * 3 + Int(b.bytes[offset+1])
            let palette = try b.data(offset, size)
            result.appearances.append(ClassicAppearance(id: digest(palette), name: name, colors: try compactPalette(palette), source: "KDX Client 1.600", artwork: result.appearances[0].artwork))
            result.assets["palette-\(offset).dat"] = palette
        }
        var fonts: [Data] = []
        for offset in windows ? [0x10d100,0x110d30,0x115a48,0x118034] : [0xf8af0,0xfc720,0x101438,0x103a28] {
            let font = try b.data(offset,b.u32(offset+8))
            _ = try HaxialFont(data:font)
            fonts.append(font); result.assets["font-\(offset).fnt"] = font
        }
        let chrome = try windows ? HAPChromeArtwork(windowsClientReference:b) : HAPChromeArtwork(reference:b)
        for index in result.appearances.indices {
            result.appearances[index].fonts = fonts
            result.appearances[index].chromeArtwork = chrome
        }
        if let resourceFork {
            for (key, value) in try resources(resourceFork) { result.assets[key] = value }
        }
        return result
    }
    /// Extract only artwork/font resource types. Code, loader and application resources are excluded.
    public static func resources(_ data: Data) throws -> [String: Data] {
        var b = try AssetBytes(data)
        if try b.u32(0) == 0x00051607 {
            guard try b.u32(4) == 0x00020000 else { throw AppearanceError.invalid("Unsupported AppleDouble version.") }
            let count = try b.u16(24); guard count <= 32 else { throw AppearanceError.invalid("Too many AppleDouble entries.") }
            var fork: Data?
            for i in 0..<count {
                let at = 26+i*12
                if try b.u32(at) == 2 { fork = try b.data(b.u32(at+4), b.u32(at+8)) }
            }
            guard let fork else { throw AppearanceError.invalid("Resource fork is missing.") }; b = try AssetBytes(fork)
        }
        let dataOffset = try b.u32(0), mapOffset = try b.u32(4)
        let dataRange = try b.range(dataOffset, b.u32(8)), mapRange = try b.range(mapOffset, b.u32(12))
        guard mapRange.count >= 30 else { throw AppearanceError.invalid("Invalid resource map.") }
        let types = try mapOffset + b.u16(mapOffset+24), count = try b.u16(types) + 1
        guard count <= 256, types >= mapOffset, types+2+count*8 <= mapRange.upperBound else { throw AppearanceError.invalid("Invalid resource types.") }
        var result = [String: Data]()
        for i in 0..<count {
            let at = types+2+i*8, type = try b.data(at, 4)
            let n = try b.u16(at+4)+1, refs = try types+b.u16(at+6)
            guard n <= 4096, refs >= mapOffset, refs+n*12 <= mapRange.upperBound else { throw AppearanceError.invalid("Invalid resource references.") }
            for j in 0..<n {
                let ref = refs+j*12, raw = try b.u32(ref+4), offset = dataOffset + (raw & 0xffffff)
                guard offset >= dataRange.lowerBound, offset+4 <= dataRange.upperBound else { throw AppearanceError.invalid("Invalid resource offset.") }
                let size = try b.u32(offset)
                guard size <= dataRange.upperBound-offset-4 else { throw AppearanceError.invalid("Invalid resource length.") }
                if ["icns", "ICN#", "icl8", "ics8", "FONT", "NFNT", "FOND", "sfnt"].contains(String(decoding: type, as: UTF8.self)) {
                    let key = "resource-" + type.map { String(format: "%02x", $0) }.joined() + "-\(try b.u16(ref)).dat"
                    result[key] = try b.data(offset+4, size)
                }
            }
        }
        return result
    }
}

public struct AppearanceLibrary: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func load(bundled: [ClassicAppearance] = []) -> [ClassicAppearance] {
        let base = [.recovery] + bundled.filter { $0.id != "recovery" && (try? $0.validate()) != nil }
        guard let handle = try? FileHandle(forReadingFrom: root.appendingPathComponent("catalog.json")) else { return base }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4_000_000), data.count < 4_000_000,
              let catalog = try? JSONDecoder().decode([ClassicAppearance].self, from: data) else { return base }
        let local = catalog.filter { $0.id != "recovery" && (try? $0.validate()) != nil }
        let localIDs = Set(local.map(\.id))
        return base.filter { !localIDs.contains($0.id) } + local
    }
    /// Stage everything, then atomically replace the catalog. A failed import leaves the selected catalog usable.
    public func install(_ imported: AppearanceImport) throws {
        guard !imported.appearances.isEmpty, imported.appearances.count <= 64,
              imported.assets.count <= 1024, imported.assets.values.reduce(0, { $0 + $1.count }) <= 64*1024*1024,
              imported.assets.keys.allSatisfy({ !$0.contains("/") && !$0.contains("..") && !$0.isEmpty }) else { throw AppearanceError.invalid("Invalid asset package.") }
        for appearance in imported.appearances { try appearance.validate() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: stage) } }
        for (name, data) in imported.assets { try data.write(to: stage.appendingPathComponent(name), options: .atomic) }
        let all = load().filter { $0.id != "recovery" && !imported.appearances.map(\.id).contains($0.id) } + imported.appearances
        let catalog = try JSONEncoder().encode(all)
        guard catalog.count < 4_000_000 else { throw AppearanceError.invalid("Appearance catalog exceeds its size limit.") }
        try catalog.write(to: root.appendingPathComponent("catalog.json"), options: .atomic)
        committed = true
    }
}
