import AppKit
import XCTest
@testable import KDXClientUI

final class HAPBackgroundTests: XCTestCase {
    private let colors: [UInt32] = [0xff0000,0x00ff00,0x0000ff,0xffff00]
    private func theme(tileID: Int = 1) throws -> ClassicAppearance {
        var bytes = [UInt8](repeating:0,count:2160)
        let helper = HAPArtworkTests()
        helper.put(2112,64+tileID*4,in:&bytes)
        bytes[2113] = 2; bytes[2115] = 3; bytes[2116] = 1; bytes[2117] = 2; bytes[2118] = 3
        for (i,rgb) in colors.enumerated() { helper.put(Int(rgb),2132+i*4,in:&bytes) }
        bytes[2148] = 0x10; bytes[2152] = 0xb0; bytes[2156] = 0x60
        return ClassicAppearance(id:"background",name:"Background",colors:[UInt32](repeating:0x112233,count:204),source:"test",artwork:try HAPArtwork(skins:Data(bytes),icons:Data()))
    }
    private func expected(x: Int, y: Int) -> UInt32 {
        let indices = [[0,1],[2,3],[1,2]]
        return colors[indices[(y%3+3)%3][(x%2+2)%2]]
    }
    @MainActor func testSkinOneTilesAtNativeSizeWithOpaquePixelsAndStableDirtyPhase() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.configureAssets([]); style.appearance = .recovery }
        style.appearance = try theme()
        let tile = try XCTUnwrap(style.artwork?.skins[1])
        XCTAssertEqual(tile.rgba[3],0,"Fixture really has a keyed transparent source pixel.")
        for scale in [1,2] {
            let bitmap = try helper.render(scale:scale,width:12,height:10) {
                NSColor.magenta.setFill(); NSRect(x:0,y:0,width:12,height:10).fill()
                HAPBackgroundDrawing.fill(NSRect(x:3,y:2,width:7,height:6))
            }
            for y in 0..<10 { for x in 0..<12 {
                let color = (3..<10).contains(x) && (2..<8).contains(y) ? expected(x:x,y:y) : 0xff00ff
                for sy in 0..<scale { for sx in 0..<scale { XCTAssertEqual(try helper.color(bitmap,x:x*scale+sx,y:y*scale+sy),color) } }
            } }
        }
        style.appearance = try theme(tileID:9)
        let fallback = try helper.render(scale:1,width:4,height:4) { HAPBackgroundDrawing.fill(NSRect(x:0,y:0,width:4,height:4)) }
        XCTAssertEqual(try helper.color(fallback,x:1,y:1),0x112233,"Other control skins cannot replace the window background.")
        style.appearance = .recovery
        let recovery = try helper.render(scale:1,width:4,height:4) { HAPBackgroundDrawing.fill(NSRect(x:0,y:0,width:4,height:4)) }
        XCTAssertEqual(try helper.color(recovery,x:1,y:1),0xdddddd)
    }
    @MainActor func testOneColumnAndSolidFastPathsRemainOpaque() throws {
        let helper = HAPWindowTests()
        for height in [1,3] { for scale in [1,2] {
            let rgba: [UInt8] = [0xff,0,0,0, 0,0xff,0,128, 0,0,0xff,255]
            let tile = HAPBitmap(width:1,height:height,rgba:Data(rgba.prefix(height*4)),textColor:nil,margins:[0,0,0,0],placement:[0,0,0,0])
            let bitmap = try helper.render(scale:scale,width:11,height:8) {
                NSColor.magenta.setFill(); NSRect(x:0,y:0,width:11,height:8).fill()
                HAPBackgroundDrawing.tile(tile,in:NSRect(x:2,y:1,width:7,height:6))
            }
            for y in 1..<7 { for x in 2..<9 { XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),colors[y%height]) } }
        } }
    }
    @MainActor func testClippedTranslatedTilesPreservePhaseAndGraphicsState() throws {
        let helper = HAPWindowTests()
        let artwork = try XCTUnwrap(theme().artwork)
        let indexed = try XCTUnwrap(artwork.decode().skins[1])
        let column = HAPBitmap(width:1,height:3,rgba:Data([255,0,0,0, 0,255,0,128, 0,0,255,255]),textColor:nil,margins:[0,0,0,0],placement:[0,0,0,0])
        for tile in [indexed,column] { for scale in [1,2] {
            let bitmap = try helper.render(scale:scale,width:16,height:12) {
                NSColor.magenta.setFill(); NSRect(x:0,y:0,width:16,height:12).fill()
                NSGraphicsContext.saveGraphicsState()
                // This is the menu-row case: one small visible region of a much
                // larger background, with a translated common pattern origin.
                NSRect(x:3,y:2,width:8,height:7).clip()
                let transform = NSAffineTransform(); transform.translateX(by:-5,yBy:-7); transform.concat()
                HAPBackgroundDrawing.tile(tile,in:NSRect(x:0,y:0,width:10_000,height:10_000))
                // A disjoint requested rectangle must not affect the visible area.
                HAPBackgroundDrawing.tile(column,in:NSRect(x:100,y:100,width:10,height:10))
                NSGraphicsContext.restoreGraphicsState()
                NSColor.cyan.setFill(); NSRect(x:14,y:10,width:2,height:2).fill()
            }
            for y in 0..<12 { for x in 0..<16 {
                let expected: UInt32
                if x >= 14 && y >= 10 { expected = 0x00ffff }
                else if (3..<11).contains(x) && (2..<9).contains(y) {
                    expected = tile.width == 1 ? colors[(y+7)%3] : self.expected(x:x+5,y:y+7)
                } else { expected = 0xff00ff }
                for sy in 0..<scale { for sx in 0..<scale {
                    XCTAssertEqual(try helper.color(bitmap,x:x*scale+sx,y:y*scale+sy),expected)
                } }
            } }
        } }
    }
    @MainActor func testNestedSurfacesAndSplitDividersShareWindowTileOrigin() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.configureAssets([]); style.appearance = .recovery }
        style.appearance = try theme()
        let root = ClassicSurface(frame:NSRect(x:0,y:0,width:30,height:30))
        let parent = ClassicSurface(frame:NSRect(x:3,y:4,width:24,height:22)); root.addSubview(parent)
        let nested = ClassicSurface(frame:NSRect(x:2,y:3,width:10,height:8)); parent.addSubview(nested)
        let split = ClassicSplitView(frame:NSRect(x:2,y:3,width:10,height:8)); parent.addSubview(split)
        XCTAssertEqual(split.dividerThickness,6)
        for vertical in [false,true] { for scale in [1,2] {
            split.isVertical = vertical
            for useSplit in [false,true] {
                let bitmap = try helper.render(scale:scale,width:10,height:8) {
                    let rect = NSRect(x:0,y:0,width:10,height:8)
                    if useSplit { split.drawDivider(in:rect) } else { nested.draw(rect) }
                }
                for y in 0..<8 { for x in 0..<10 {
                    XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),expected(x:x+5,y:y+7))
                } }
            }
        } }
        // Moving the pane changes its window position, not the wallpaper origin.
        nested.setFrameOrigin(NSPoint(x:4,y:2))
        let moved = try helper.render(scale:1,width:10,height:8) { nested.draw(nested.bounds) }
        XCTAssertEqual(try helper.color(moved,x:0,y:0),expected(x:7,y:6))
        split.addArrangedSubview(NSView(frame:NSRect(x:0,y:0,width:10,height:3)))
        split.addArrangedSubview(NSView(frame:NSRect(x:0,y:0,width:10,height:3)))
        XCTAssertEqual(split.arrangedSubviews.count,2,"The adapter retains native split-view pane ownership.")
    }
    @MainActor func testMenuTilesUseSameOpaqueBlitterButFramesKeepTransparency() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.configureAssets([]); style.appearance = .recovery }
        for id in [184,186,185] {
            style.appearance = try theme(tileID:id)
            let bitmap = try helper.render(scale:1,width:2,height:3) {
                let rect = NSRect(x:0,y:0,width:2,height:3)
                HAPMenuDrawing.background(rect)
                if id == 186 { HAPMenuDrawing.row(rect,selected:false,enabled:true) }
            }
            XCTAssertEqual(try helper.color(bitmap,x:0,y:0),id == 185 ? 0x112233 : 0xff0000)
        }
    }
    @MainActor func testWindowContentPaintsTileOverOpaqueFrameCenter() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.configureAssets([]); style.appearance = .recovery }
        var appearance = try theme(), bytes = [UInt8](try XCTUnwrap(appearance.artwork).skins)
        let frameAt = bytes.count
        bytes += HAPArtworkTests().skinSection().dropFirst(2112)
        HAPArtworkTests().put(frameAt,64+204*4,in:&bytes)
        bytes.replaceSubrange(frameAt+16..<frameAt+20,with:[6,22,6,6])
        appearance.artwork = try HAPArtwork(skins:Data(bytes),icons:Data())
        style.appearance = appearance
        let chrome = ClassicChrome(); chrome.frame = NSRect(x:0,y:0,width:80,height:60); chrome.layout()
        XCTAssertEqual(chrome.content.frame,NSRect(x:6,y:22,width:68,height:32))
        for scale in [1,2] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:80*scale,pixelsHigh:60*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
            bitmap.size = chrome.bounds.size
            chrome.cacheDisplay(in:chrome.bounds,to:bitmap)
            for y in 25..<45 { for x in 10..<60 {
                XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),expected(x:x,y:y),"Content must repaint over an opaque frame interior.")
            } }
        }
    }
    func testReferenceInstructionsForBackgroundTileAndOpaqueBlitter() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Set KDX_REFERENCE for background drawing evidence.") }
        let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
        for (address,instruction) in [(0x9bf8c,0x28050002),(0x9bf94,0x80030044),(0x9bfb8,0x4bfc5d89),
                                      (0x61d70,0x4bffeef1),(0x61d80,0x4bffd071),(0x61d88,0x41820104),
                                      (0x61d94,0x2c170001),(0x61dc8,0x4800c219),(0x61e60,0x39200000),(0x61e64,0x480012cd)] {
            XCTAssertEqual(try bytes.u32(address+0x1de0),instruction)
        }
    }
}
