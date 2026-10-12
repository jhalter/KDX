import AppKit
import XCTest
@testable import KDXClientUI

final class HAPIconButtonTests: XCTestCase {
    private func artwork(small: Int = 10, large: Int? = 20, skins: Data = Data()) throws -> HAPArtwork {
        let helper = HAPArtworkTests()
        var bytes = [UInt8](repeating:0,count:3072)
        for (slot,size) in [small,large].enumerated() {
            guard let size else { continue }
            let offset = bytes.count, stride = ((size+31)/32)*4
            bytes += [UInt8](repeating:0,count:12+stride*size)
            helper.put(offset,17*16+slot*4,in:&bytes)
            bytes[offset+1] = UInt8(size); bytes[offset+3] = UInt8(size); bytes[offset+5] = 1
            helper.put(slot == 0 ? 0xaa0000 : 0x00aa00,offset+8,in:&bytes)
        }
        return try HAPArtwork(skins:skins,icons:Data(bytes))
    }
    private func appearance(_ artwork: HAPArtwork? = nil) -> ClassicAppearance {
        ClassicAppearance(id:"icon-layout",name:"Icon layout",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test",artwork:artwork)
    }

    @MainActor func testSquareBezelEveryPixelAndStateAtBothScales() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        style.configureAssets([]); style.appearance = appearance()
        let grid = ["555555555555","500000000025","501111111245","501222222345","501222222345",
                    "501222222345","501222222345","502333333345","524444444445","555555555555"]
        let rect = NSRect(x:3,y:2,width:12,height:10)
        for (pressed,enabled,base) in [(false,true,29),(true,true,36),(false,false,43),(true,false,43)] { for scale in [1,2] {
            let bitmap = try helper.render(scale:scale,width:18,height:14) {
                NSColor.magenta.setFill(); NSRect(x:0,y:0,width:18,height:14).fill()
                ClassicPainter.button(rect,title:"",pressed:pressed,enabled:enabled,defaultButton:false,iconID:17,iconOnly:true)
            }
            for (y,line) in grid.enumerated() { for (x,character) in line.enumerated() {
                let rgb = UInt32(base+Int(String(character))!)*0x010101
                for sy in 0..<scale { for sx in 0..<scale {
                    XCTAssertEqual(try helper.color(bitmap,x:(x+3)*scale+sx,y:(y+2)*scale+sy),rgb,"(\(x),\(y)), base \(base)")
                } }
            } }
            XCTAssertEqual(try helper.color(bitmap,x:2*scale,y:2*scale),0xff00ff)
            XCTAssertEqual(try helper.color(bitmap,x:15*scale,y:11*scale),0xff00ff)
        } }
        let ordinary = try helper.render(scale:1,width:18,height:14) {
            NSColor.magenta.setFill(); NSRect(x:0,y:0,width:18,height:14).fill()
            ClassicPainter.button(rect,title:"",pressed:false,enabled:true,defaultButton:false)
        }
        XCTAssertEqual(try helper.color(ordinary,x:3,y:2),0xff00ff,"Ordinary pushbuttons must retain their clipped corners.")
    }

    @MainActor func testFixedColumnsNativeCenteringAndLargeSlotThreshold() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for hasLarge in [true,false] {
            let art = try artwork(large:hasLarge ? 20 : nil)
            let theme = appearance(art); style.configureAssets([theme]); style.appearance = theme
            for (width,height,iconOnly,small,left,top,labelLeft) in [
                (100,24,false,true,12,9,29), (100,39,false,true,12,16,29),
                (100,40,false,false,hasLarge ? 15 : 20,hasLarge ? 12 : 17,45),
                (32,24,true,true,14,9,0), (40,40,true,false,hasLarge ? 13 : 18,hasLarge ? 12 : 17,0)
            ] {
                let bounds = NSRect(x:3,y:2,width:width,height:height)
                let layout = HAPIconButtonLayout(bounds:bounds,iconOnly:iconOnly)
                let icon = try XCTUnwrap(art.decode().icon(17,small:small))
                XCTAssertEqual(layout.small,small)
                XCTAssertEqual(layout.iconRect(icon).origin,NSPoint(x:left,y:top))
                XCTAssertEqual(layout.labelRegion.minX,CGFloat(labelLeft))
                if !iconOnly { XCTAssertEqual(layout.labelRegion.maxX,bounds.maxX-3) }
                let color: UInt32 = !small && hasLarge ? 0x00aa00 : 0xaa0000
                for scale in [1,2] {
                    let bitmap = try helper.render(scale:scale,width:width+6,height:height+4) {
                        ClassicPainter.button(bounds,title:"",pressed:false,enabled:true,defaultButton:false,iconID:17,iconOnly:iconOnly)
                    }
                    for y in top..<top+icon.height { for x in left..<left+icon.width {
                        XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),color)
                    } }
                    XCTAssertNotEqual(try helper.color(bitmap,x:(left-1)*scale,y:top*scale),color)
                    XCTAssertNotEqual(try helper.color(bitmap,x:(left+icon.width)*scale,y:top*scale),color)
                }
            }
        }
    }

    @MainActor func testNarrowCustomIconDoesNotMoveTheLabel() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for scale in [1,2] {
            var rasters = [NSBitmapImageRep]()
            for width in [10,16] {
                let theme = appearance(try artwork(small:width))
                style.configureAssets([theme]); style.appearance = theme
                rasters.append(try helper.render(scale:scale,width:90,height:24) {
                    ClassicPainter.button(NSRect(x:0,y:0,width:90,height:24),title:"Address",pressed:false,enabled:true,defaultButton:false,iconID:17)
                })
            }
            var ink = 0
            for y in 4*scale..<20*scale { for x in 26*scale..<87*scale {
                let first = try helper.color(rasters[0],x:x,y:y)
                XCTAssertEqual(first,try helper.color(rasters[1],x:x,y:y))
                if first != 0x1f1f1f { ink += 1 }
            } }
            XCTAssertGreaterThan(ink,0,"Compare actual rendered text, not two blank label regions.")
        }
    }

    @MainActor func testSkinOverrideAndMissingStateUseDifferentBorders() throws {
        let helper = HAPArtworkTests(), pixels = HAPWindowTests(), style = ClassicStyle.shared
        defer { style.appearance = .recovery; style.configureAssets([]) }
        var skins = Array(helper.skinSection()); helper.put(0,64+9*4,in:&skins); helper.put(2112,64+33*4,in:&skins)
        let theme = appearance(try artwork(skins:Data(skins)))
        style.configureAssets([theme]); style.appearance = theme
        for (pressed,enabled,expected) in [(false,true,UInt32(0xff0000)),(true,true,0x292929),(false,false,0x303030)] {
            let bitmap = try pixels.render(scale:1,width:100,height:24) {
                ClassicPainter.button(NSRect(x:0,y:0,width:100,height:24),title:"",pressed:pressed,enabled:enabled,defaultButton:false,iconID:17)
            }
            XCTAssertEqual(try pixels.color(bitmap,x:0,y:0),expected)
        }
    }

    func testOriginalBarRecordsSelectTheSquareBorderAndLabelModes() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Set KDX_REFERENCE to verify original button flags.") }
        let data = try Data(contentsOf:URL(fileURLWithPath:path))
        guard AppearanceDecoder.digest(data) == AppearanceDecoder.referenceSHA256 else { return XCTFail("Unexpected reference revision") }
        for (offset,flags) in [(0x124c4,0x2a),(0x1250c,0x2a),(0x12598,0x2a),(0x12710,0x2a),(0x12758,0x2a),
                               (0x12a70,0x22),(0x12aac,0x22),(0x12b24,0x22),(0x12c8c,0x22),(0x12cc8,0x22)] {
            let start = 0xd7a30+offset
            XCTAssertEqual(data[start..<start+4],Data("IBTN".utf8))
            XCTAssertEqual(data[start+44..<start+48].reduce(0) { ($0 << 8)|Int($1) },flags)
            XCTAssertEqual(flags&1,0,"0x96F44 selects the square 0x95790 renderer.")
        }
    }
}
