import AppKit
import XCTest
@testable import KDXClientUI

final class HAPArtworkTests: XCTestCase {
    func put(_ value: Int, _ offset: Int, in bytes: inout [UInt8]) {
        for i in 0..<4 { bytes[offset+i] = UInt8(truncatingIfNeeded: value >> (24-i*8)) }
    }
    func skinSection(depth: Int = 2) -> Data {
        // A 3x3 image with one-pixel corner/edge margins and four distinct colors.
        var b = [UInt8](repeating: 0, count: 2112+20+16+12)
        put(2112,64+9*4,in:&b)
        b[2113] = 3; b[2115] = 3; b[2117] = UInt8(depth); b[2118] = 3
        put(0x123456,2120,in:&b)
        for i in 2124..<2128 { b[i] = 1 }
        for (i,c) in [0xff0000,0x00ff00,0x0000ff,0xffffff].enumerated() { put(c,2132+i*4,in:&b) }
        b[2148] = 0x18 // red green blue
        b[2152] = 0xec // white blue white
        b[2156] = 0x90 // blue green red
        return Data(b)
    }
    func testPackedPixelsAndMargins() throws {
        let artwork = try HAPArtwork(skins:skinSection(),icons:Data()).decode()
        let b = try XCTUnwrap(artwork.skins[9])
        XCTAssertEqual(b.width,3); XCTAssertEqual(b.height,3)
        XCTAssertEqual(b.margins,[1,1,1,1]); XCTAssertEqual(b.textColor,0x123456)
        XCTAssertEqual(Array(b.rgba.prefix(12)),[255,0,0,255,0,255,0,255,0,0,255,255])
        XCTAssertEqual(Array(b.rgba.suffix(4)),[255,0,0,255])
    }
    func testCorruptRasterRecordsAreRejected() throws {
        let good = skinSection()
        for length in [0,20,2111,2132,good.count-1] where length > 0 {
            XCTAssertThrowsError(try HAPArtwork(skins:good.prefix(length),icons:Data()))
        }
        for (offset,value) in [(2112,255),(2117,3),(2116,2),(2124,3),(2118,4),(2148,255)] {
            var b = Array(good); b[offset] = UInt8(value)
            if offset == 2148 { b[2118] = 2 }
            XCTAssertThrowsError(try HAPArtwork(skins:Data(b),icons:Data()),"offset \(offset)")
        }
        var b = Array(good); put(2116,64+10*4,in:&b)
        XCTAssertThrowsError(try HAPArtwork(skins:Data(b),icons:Data()))
    }
    func testAllPackedDepthsAndKeyedTransparency() throws {
        for depth in [1,2,4,8] {
            var b = [UInt8](repeating:0,count:3072+8+8+4)
            put(3072,0,in:&b); b[3073] = 2; b[3075] = 1
            b[3076] = 1; b[3077] = UInt8(depth); b[3078] = 1
            put(0xff0000,3080,in:&b); put(0x0000ff,3084,in:&b)
            if depth == 8 { b[3089] = 1 } else { b[3088] = UInt8(1 << (8-depth*2)) }
            let bitmap = try XCTUnwrap(HAPArtwork(skins:Data(),icons:Data(b)).decode().icon(0,small:true))
            XCTAssertEqual(Array(bitmap.rgba),[255,0,0,0,0,0,255,255])
        }
    }
    @MainActor func testSingleAxisStretchPreservesCrossAxisPixels() throws {
        let helper = HAPWindowTests()
        for horizontal in [false,true] {
            var bytes = [UInt8](skinSection())
            if horizontal { bytes[2125] = 0; bytes[2127] = 0 }
            else { bytes[2124] = 0; bytes[2126] = 0 }
            let skin = try XCTUnwrap(HAPArtwork(skins:Data(bytes),icons:Data()).decode().skins[9])
            for scale in [1,2] {
                let rect = NSRect(x:0,y:0,width:horizontal ? 50 : 3,height:horizontal ? 3 : 50)
                let bitmap = try helper.render(scale:scale,width:Int(rect.width),height:Int(rect.height)) { skin.draw(in:rect,stretch:true,axis:horizontal ? .horizontal : .vertical) }
                let expected: [UInt32] = horizontal ? [0x00ff00,0x0000ff,0x00ff00] : [0xffffff,0x0000ff,0xffffff]
                for (cross,color) in expected.enumerated() {
                    XCTAssertEqual(try helper.color(bitmap,x:(horizontal ? 25 : cross)*scale,y:(horizontal ? cross : 25)*scale),color)
                }
            }
        }
    }
    @MainActor func testOriginalAtlasAndStretchRenderAtBothScales() throws {
        var decoded: HAPDecodedArtwork?
        if let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] {
            let imported = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path))
            decoded = try XCTUnwrap(imported.appearances.first?.artwork).decode()
            XCTAssertEqual(decoded?.icons.count,67)
            XCTAssertTrue(decoded?.skins.isEmpty == true) // Reference uses palette-driven built-in control geometry.
        }
        let skin = try XCTUnwrap(HAPArtwork(skins:skinSection(),icons:Data()).decode().skins[9])
        for scale in [1,2] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:640*scale,pixelsHigh:520*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
            bitmap.size = NSSize(width:640,height:520)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep:bitmap))
            let transform = NSAffineTransform(); transform.translateX(by:0,yBy:520); transform.scaleX(by:1,yBy:-1); transform.concat()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: NSGraphicsContext.current!.cgContext, flipped: true)
            NSColor.gray.setFill(); NSRect(x:0,y:0,width:640,height:520).fill()
            skin.draw(in:NSRect(x:0,y:0,width:100,height:50),stretch:true)
            if let decoded {
                for (i,key) in decoded.icons.keys.sorted().enumerated() {
                    let x = CGFloat(i%12)*52, y = CGFloat(i/12)*64+64
                    decoded.icons[key]?.draw(in:NSRect(x:x+8,y:y,width:32,height:32))
                    ("\(key/4):\(key%4)" as NSString).draw(at:NSPoint(x:x+4,y:y+34),withAttributes:[.font:NSFont.systemFont(ofSize:9),.foregroundColor:NSColor.white])
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            let color = try XCTUnwrap(bitmap.colorAt(x:50*scale,y:25*scale)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(color.blueComponent,1,accuracy:0.01)
            XCTAssertEqual(color.redComponent,0,accuracy:0.01)
            if let folder = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"] {
                let url = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("HAP-atlas-\(scale)x.png"))
            }
        }
    }
    @MainActor func testDefaultPreferencesCanInitialize() {
        let preferences = ClassicPreferences()
        XCTAssertTrue(preferences.root.isFileURL)
        XCTAssertEqual(preferences.root.lastPathComponent,"KDX Classic")
    }

    @MainActor func testButtonUsesImportedSkinAndOriginalPaletteRoles() throws {
        let colors = (0..<204).map { UInt32($0)*0x010101 }
        defer { ClassicStyle.shared.appearance = .recovery }
        for scale in [1,2] {
            for (pressed,enabled,expected) in [(false,true,31),(true,true,38),(false,false,45)] {
                for useSkin in [false,true] {
                    let artwork = try HAPArtwork(skins:skinSection(),icons:Data())
                    ClassicStyle.shared.appearance = ClassicAppearance(id:"fixture",name:"Fixture",colors:colors,source:"test",artwork:useSkin ? artwork : nil)
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:80*scale,pixelsHigh:24*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                    bitmap.size = NSSize(width:80,height:24)
                    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep:bitmap))
                    ClassicPainter.button(NSRect(x:0,y:0,width:80,height:24),title:"",pressed:pressed,enabled:enabled,defaultButton:false)
                    NSGraphicsContext.restoreGraphicsState()
                    let center = try XCTUnwrap(bitmap.colorAt(x:40*scale,y:12*scale)?.usingColorSpace(.deviceRGB))
                    if useSkin && !pressed && enabled {
                        XCTAssertEqual(center.blueComponent,1,accuracy:0.01)
                        XCTAssertEqual(center.redComponent,0,accuracy:0.01)
                    } else { XCTAssertEqual(center.redComponent,CGFloat(expected)/255,accuracy:0.01) }
                }
            }
        }
    }
}
