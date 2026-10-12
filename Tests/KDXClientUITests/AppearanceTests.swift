import XCTest
import AppKit
@testable import KDXClientUI

final class AppearanceTests: XCTestCase {
    func hap(version: UInt16 = 1) -> Data {
        var bytes = [UInt8](repeating:0,count:0x88+816)
        func put(_ value: Int,_ offset: Int) { for i in 0..<4 { bytes[offset+i] = UInt8(truncatingIfNeeded:value >> (24-i*8)) } }
        bytes.replaceSubrange(0..<4,with:Array("%HAP".utf8)); bytes[4] = UInt8(version >> 8); bytes[5] = UInt8(truncatingIfNeeded:version)
        put(0x88,0x3c); put(816,0x40)
        for i in 0..<204 { put(i*0x010101,0x88+i*4) }
        return Data(bytes)
    }
    func testHAPBoundsVersionsAndFailedImportRecovery() throws {
        let imported = try AppearanceDecoder.hap(hap(),name:"Synthetic")
        XCTAssertEqual(imported.appearances[0].colors.count,204)
        XCTAssertEqual(imported.appearances[0].colors[7],0x070707)
        XCTAssertThrowsError(try AppearanceDecoder.hap(hap(version:2),name:"Unsupported"))
        for count in [0,4,135,136,200,951] { XCTAssertThrowsError(try AppearanceDecoder.hap(hap().prefix(count),name:"Truncated")) }
        var corrupt = hap(); corrupt[0x3c] = 0xff
        XCTAssertThrowsError(try AppearanceDecoder.hap(corrupt,name:"Overflow"))
        corrupt = hap(); corrupt[0x2f] = 0x88; corrupt[0x33] = 4
        XCTAssertThrowsError(try AppearanceDecoder.hap(corrupt,name:"Overlap"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let library = AppearanceLibrary(root:root); try library.install(imported)
        XCTAssertEqual(library.load().count,2)
        var bad = imported; bad.assets["../escape"] = Data([1])
        XCTAssertThrowsError(try library.install(bad)); XCTAssertEqual(library.load().last,imported.appearances[0])
        let oversized = ClassicAppearance(id:"too-large",name:"Oversized",colors:imported.appearances[0].colors,source:String(repeating:"x",count:4_000_000))
        XCTAssertThrowsError(try library.install(AppearanceImport(appearances:[oversized],assets:[:])))
        XCTAssertEqual(library.load().last,imported.appearances[0])
        try Data("broken".utf8).write(to:root.appendingPathComponent("catalog.json"))
        XCTAssertEqual(library.load(),[.recovery])
    }
    func testCompactPaletteBounds() throws {
        let data = Data([2,204,0,0,0,255,128,64] + [UInt8](repeating:1,count:204))
        XCTAssertEqual(try AppearanceDecoder.compactPalette(data),[UInt32](repeating:0xff8040,count:204))
        XCTAssertThrowsError(try AppearanceDecoder.compactPalette(data.dropLast()))
        var bad = data; bad[8] = 2; XCTAssertThrowsError(try AppearanceDecoder.compactPalette(bad))
        bad = data; bad[1] = 203; XCTAssertThrowsError(try AppearanceDecoder.compactPalette(bad))
    }
    func testArchivePreflight() throws {
        try ClassicAssetImporter.validate(entries:[["XADFileName":"KDX/KDXClient.app","XADFileSize":100]])
        for path in ["../out", "/out", "x/../../out", "x\\..\\out", "x:y", "x\0y"] {
            XCTAssertThrowsError(try ClassicAssetImporter.validate(entries:[["XADFileName":path,"XADFileSize":1]]))
        }
        for extra in [["XADIsLink":true],["XADIsEncrypted":true],["XADFileSize":-1],["XADFileSize":65*1024*1024]] as [[String:Any]] {
            var entry: [String:Any] = ["XADFileName":"safe","XADFileSize":1]; entry.merge(extra) { _,new in new }
            XCTAssertThrowsError(try ClassicAssetImporter.validate(entries:[entry]))
        }
        XCTAssertThrowsError(try ClassicAssetImporter.validate(entries:Array(repeating:["XADFileName":"x","XADFileSize":1],count:129)))
        XCTAssertThrowsError(try AppearanceDecoder.application(Data("Joy!peff".utf8)))
        XCTAssertThrowsError(try AppearanceDecoder.resources(Data(repeating:255,count:200)))
    }
    func testReferenceApplicationWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Set KDX_REFERENCE to the extracted KDXClient.app; original assets are never committed.") }
        let result = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path))
        XCTAssertEqual(result.appearances.count,16)
        XCTAssertEqual(result.appearances.first { $0.name == "Mach Lavender" }?.colors[9],0x6666cc)
        XCTAssertNotEqual(result.appearances.first { $0.name == "Amber CRT" }?.colors,result.appearances.first { $0.name == "Mach Lavender" }?.colors)
        XCTAssertTrue(result.assets.keys.contains { $0.hasPrefix("resource-69636e73") })
        XCTAssertFalse(result.assets.values.contains { $0.starts(with:Data("Joy!peff".utf8)) })
    }
    @MainActor func testOffscreenControlsAtBothScales() throws {
        var appearances = [ClassicAppearance.recovery]
        if let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] {
            appearances += try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances.filter { ["Mach Lavender","Amber CRT"].contains($0.name) }
        }
        defer { ClassicStyle.shared.appearance = .recovery; ClassicStyle.shared.configureAssets([]) }
        for appearance in appearances {
            ClassicStyle.shared.configureAssets([appearance])
            ClassicStyle.shared.appearance = appearance
            for scale in [1,2] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:440*scale,pixelsHigh:260*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                bitmap.size = NSSize(width:440,height:260)
                let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep:bitmap))
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                let transform = NSAffineTransform(); transform.translateX(by:0,yBy:260); transform.scaleX(by:1,yBy:-1); transform.concat()
                NSGraphicsContext.current = NSGraphicsContext(cgContext:context.cgContext,flipped:true)
                let bounds = NSRect(x:0,y:0,width:440,height:260)
                appearance.color(2).setFill(); bounds.fill()
                HAPWindowDrawing.frame(bounds,active:true)
                for control in HAPWindowControl.allCases { HAPWindowDrawing.control(control,in:bounds,active:true,pressed:false) }
                HAPWindowDrawing.title(appearance.name,in:bounds,active:true)
                HAPWindowDrawing.resize(in:bounds,active:true)
                for (i,title) in ["Connect","Address Book","Disabled","Focused"].enumerated() {
                    ClassicPainter.button(NSRect(x:12+CGFloat(i)*106,y:36,width:100,height:25),title:title,pressed:i==1,enabled:i != 2,defaultButton:i==3)
                }
                appearance.color(10).setFill(); NSRect(x:12,y:75,width:416,height:135).fill()
                appearance.color(12).setFill(); NSRect(x:12,y:100,width:416,height:20).fill()
                ClassicPainter.button(NSRect(x:304,y:224,width:100,height:25),title:"Send",pressed:false,enabled:true,defaultButton:false)
                NSGraphicsContext.restoreGraphicsState()
                let png = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
                XCTAssertGreaterThan(png.count,1000)
                if let folder = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"] {
                    let url = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                    try png.write(to:url.appendingPathComponent("\(appearance.name)-\(scale)x.png"))
                }
            }
        }
    }
}
