import Foundation

/// Static, bounded decoding of the KDX Server.exe inside the user's OSX Wineskin app.
/// Never loads or executes the reference program, or reads its account/settings files.
public enum ClassicServerReference {
    public static let sha256 = "bc121d47c7f5e408cd5cffbbfaa4bf087b52e59dafa7ba01b8552464dc33ba58"
    public static let executablePath = "Contents/Resources/drive_c/Program Files/KDXServer1600-Win/KDXServer.exe"
    public static func load(_ source: URL) throws -> [ClassicAppearance] {
        let url = source.pathExtension.lowercased() == "app" ? source.appendingPathComponent(executablePath) : source
        let handle = try FileHandle(forReadingFrom:url)
        defer { try? handle.close() }
        return try decode(handle.read(upToCount:675329) ?? Data())
    }
    static func decode(_ data: Data) throws -> [ClassicAppearance] {
        guard AppearanceDecoder.digest(data) == sha256 else {
            throw AppearanceError.invalid("Unsupported server revision. Select the original KDX Server 1.600 OSX wrapper or its KDXServer.exe.")
        }
        let b = try AssetBytes(data)
        var appearances = try AppearanceDecoder.hap(b.data(0x850f8,0x7d60),name:"Evil Chiaroscuro").appearances
        let offsets = [0x82820,0x81010,0x811cb,0x81392,0x81562,0x81732,0x818f3,0x81a63,0x81c1b,0x81dc1,0x81f79,0x82137,0x822ef,0x824b3,0x8266b]
        let names = ["Alternate Romp","Amber CRT","Blue Jeans","Blue Tram Café","Bubblegum Crisis","Chocolate Raspberry","Mach Lavender","Oxygen","Sunset Chiaroscuro","Techno Electric","The Dream Scheme (Blue)","The Dream Scheme (Green)","The Dream Scheme (Purple)","Tropical Water","Turquoise Hilites"]
        for (offset,name) in zip(offsets,names) {
            let palette = try b.data(offset,2+Int(b.bytes[offset])*3+Int(b.bytes[offset+1]))
            appearances.append(ClassicAppearance(id:AppearanceDecoder.digest(palette),name:name,colors:try AppearanceDecoder.compactPalette(palette),source:"KDX Server 1.600",artwork:appearances[0].artwork))
        }
        let fonts = try [0x8ce58,0x90a88,0x957a0,0x97d8c].map { offset in
            let font = try b.data(offset,b.u32(offset+8)); _ = try HaxialFont(data:font); return font
        }
        let chrome = try HAPChromeArtwork(serverReference:b)
        for i in appearances.indices { appearances[i].fonts = fonts; appearances[i].chromeArtwork = chrome }
        _ = try ClassicBundledAppearances.decode(JSONEncoder().encode(appearances))
        return appearances
    }
    public static func export(from source: URL, to destination: URL) throws {
        let data = try JSONEncoder().encode(load(source))
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:destination,options:.atomic)
    }
}
