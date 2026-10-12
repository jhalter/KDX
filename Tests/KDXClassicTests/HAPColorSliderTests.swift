import AppKit
import XCTest
@testable import KDXClassicUI

final class HAPColorSliderTests: XCTestCase {
    private func chrome(_ data: Data?) throws -> HAPChromeArtwork {
        var json = [String:Any]()
        for (key,size) in [("close",98),("menu",224),("maximize",98),("minimize",98),("resize",153)] { json[key] = Data(repeating:0,count:size).base64EncodedString() }
        if let data { json["horizontalSliderThumb"] = data.base64EncodedString() }
        return try JSONDecoder().decode(HAPChromeArtwork.self,from:JSONSerialization.data(withJSONObject:json))
    }
    func testBoundedThumbCatalogAndOldCatalogCompatibility() throws {
        let valid = try chrome(Data(repeating:0x12,count:112)); try valid.validate()
        let old = try chrome(nil); try old.validate(); XCTAssertNil(old.horizontalSliderThumb)
        let roundTrip = try JSONDecoder().decode(HAPChromeArtwork.self,from:JSONEncoder().encode(valid))
        XCTAssertEqual(roundTrip,valid)
        for data in [Data(),Data(repeating:0,count:111),Data(repeating:0,count:113),Data(repeating:0x17,count:112)] {
            XCTAssertThrowsError(try chrome(data).validate())
        }
    }
    @MainActor func testImportedThumbPixelsAndPaletteTrackStates() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Original application required") }
        let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
        let art = try HAPChromeArtwork(reference:bytes), source = try XCTUnwrap(art.horizontalSliderThumb)
        XCTAssertEqual(source,try bytes.data(0x108dc8,112))
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        var theme = ClassicAppearance(id:"sliders",name:"Sliders",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test")
        theme.chromeArtwork = art; style.appearance = theme
        let rect = NSRect(x:0,y:0,width:280,height:28)
        for (pressed,enabled) in [(false,true),(true,true),(false,false)] { for value in [0,128,255] { for scale in [1,2] {
            let bitmap = try helper.render(scale:scale,width:280,height:28) { HAPColorSliderDrawing.draw(rect,value:value,pressed:pressed,enabled:enabled) }
            let g = HAPColorSliderDrawing.geometry(rect,value:value,pressed:pressed,enabled:enabled)
            XCTAssertEqual(g.track,NSRect(x:0,y:10,width:280,height:7))
            XCTAssertEqual(g.thumb.minX,5+floor(257*CGFloat(value)/255))
            let base = !enabled ? 170 : pressed ? 162 : 158, slots = [0,base,base,base+1,base+2,base+2,base+3]
            for y in 0..<16 { for x in 0..<13 {
                let byte = source[y*7+x/2], index = Int(x%2 == 0 ? byte >> 4 : byte&15)
                guard index > 0 else { continue }
                for dy in 0..<scale { for dx in 0..<scale {
                    XCTAssertEqual(try helper.color(bitmap,x:(Int(g.thumb.minX)+x)*scale+dx,y:(Int(g.thumb.minY)+y)*scale+dy),UInt32(slots[index])*0x010101)
                } }
            } }
            let x = value < 128 ? 200 : 40
            for (y,slot) in [(10,3),(11,!enabled ? 173 : pressed ? 169 : 167),(12,!enabled ? 171 : pressed ? 168 : 166),(16,1)] {
                XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),UInt32(slot)*0x010101)
            }
        } } }
    }
    private func artwork(omitting: Set<Int> = []) throws -> HAPArtwork {
        var bytes = [UInt8](repeating:0,count:2112)
        func put(_ value: Int, at: Int) { for i in 0..<4 { bytes[at+i] = UInt8(truncatingIfNeeded:value >> (24-i*8)) } }
        for id in [110,111,112,114,115,116] where !omitting.contains(id) {
            let start = bytes.count; put(start,at:64+id*4)
            bytes += [UInt8](repeating:0,count:36)
            bytes[start+1] = 3; bytes[start+3] = 3; bytes[start+5] = 1
            for i in 12..<16 { bytes[start+i] = 1 }
            if id < 114 { bytes[start+16] = UInt8(id-105); bytes[start+18] = 7 }
            else { bytes[start+17] = UInt8(id-112) }
            put(id*0x010101,at:start+20)
        }
        return try HAPArtwork(skins:Data(bytes),icons:Data())
    }
    @MainActor func testSkinPlacementPartialThemeFallbackAndStableHitGeometry() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        style.appearance = ClassicAppearance(id:"slider-skins",name:"Slider skins",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test",artwork:try artwork())
        let rect = NSRect(x:0,y:0,width:280,height:28)
        for (pressed,enabled,state) in [(false,true,0),(true,true,1),(false,false,2)] { for scale in [1,2] {
            let g = HAPColorSliderDrawing.geometry(rect,value:255,pressed:pressed,enabled:enabled)
            XCTAssertEqual(g.track.minY,12); XCTAssertEqual(g.thumb.minX,270)
            XCTAssertEqual(g.thumb.minY,CGFloat(10-state))
            let bitmap = try helper.render(scale:scale,width:280,height:28) { HAPColorSliderDrawing.draw(rect,value:255,pressed:pressed,enabled:enabled) }
            XCTAssertEqual(try helper.color(bitmap,x:0,y:12*scale),UInt32(110+state)*0x010101)
            XCTAssertEqual(try helper.color(bitmap,x:271*scale,y:Int(g.thumb.minY)*scale),UInt32(114+state)*0x010101)
        } }
        let slider = ClassicColorSlider("Test"); slider.frame = rect; slider.doubleValue = 0
        let cell = try XCTUnwrap(slider.cell as? NSSliderCell), normal = cell.knobRect(flipped:true)
        cell.isHighlighted = true; XCTAssertEqual(cell.knobRect(flipped:true),normal)
        XCTAssertTrue(cell.startTracking(at:NSPoint(x:normal.minX+1,y:normal.midY),in:slider)); XCTAssertEqual(slider.doubleValue,0)
        _ = cell.continueTracking(last:.zero,current:NSPoint(x:normal.minX+266,y:normal.midY),in:slider)
        XCTAssertEqual(slider.doubleValue,255)
        for omitted: Set<Int> in [[111],[115]] {
            style.appearance.artwork = try artwork(omitting:omitted)
            let bitmap = try helper.render(scale:1,width:280,height:28) { HAPColorSliderDrawing.draw(rect,value:0,pressed:true,enabled:true) }
            XCTAssertEqual(try helper.color(bitmap,x:150,y:12),0xa8a8a8,"Missing either pressed layer uses palette track fill 168.")
            XCTAssertEqual(HAPColorSliderDrawing.geometry(rect,value:0,pressed:true,enabled:true).thumb.minX,5)
        }
    }
}
