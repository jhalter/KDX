import AppKit
import XCTest
@testable import KDXClassicUI

final class HAPCheckboxTests: XCTestCase {
    @MainActor func testSkinStateSelectionAndNativeSwitchBehavior() throws {
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery; style.configureAssets([]) }
        let helper = HAPWindowTests()
        for (state,base) in [(NSControl.StateValue.off,41),(.on,45),(.mixed,49)] {
            for (pressed,enabled,offset) in [(false,true,0),(true,true,1),(false,false,2)] {
                var bytes = [UInt8](HAPArtworkTests().skinSection())
                let id = base+offset
                bytes.replaceSubrange((64+id*4)..<(68+id*4),with:bytes[100..<104])
                style.appearance = ClassicAppearance(id:"check",name:"Check",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test",artwork:try HAPArtwork(skins:Data(bytes),icons:Data()))
                let check = ClassicCheckbox(""); check.allowsMixedState = true; check.state = state; check.isEnabled = enabled
                check.cell?.isHighlighted = pressed; check.frame = NSRect(x:0,y:0,width:60,height:23)
                XCTAssertEqual(HAPCheckboxDrawing.skinID(state:state,pressed:pressed,enabled:enabled),id)
                for scale in [1,2] {
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:60*scale,pixelsHigh:23*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                    bitmap.size = check.bounds.size; check.cacheDisplay(in:check.bounds,to:bitmap)
                    for (x,y,color) in [(2,10,0xff0000),(3,11,0x0000ff),(2,12,0x0000ff)] {
                        XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),UInt32(color))
                    }
                }
            }
        }
        let check = ClassicCheckbox("Open Public Chat on connect")
        XCTAssertEqual(check.accessibilityRole(),.checkBox)
        XCTAssertEqual(check.accessibilityLabel(),check.title)
        XCTAssertEqual(check.state,.off)
        check.performClick(nil); XCTAssertEqual(check.state,.on)
        check.performClick(nil); XCTAssertEqual(check.state,.off)
        check.isEnabled = false; check.performClick(nil); XCTAssertEqual(check.state,.off)
    }

    @MainActor func testReferenceCheckboxPixelsAndThemeSheets() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Set KDX_CLASSIC_REFERENCE for original checkbox checks") }
        let appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        style.configureAssets(appearances)
        let chrome = try XCTUnwrap(style.chromeArtwork)
        // Every decoded pixel must use the original raster and the independently
        // verified 0x98100 palette mapping, including the pressed/disabled check mark.
        let pixels = [(NSControl.StateValue.off,try XCTUnwrap(chrome.checkboxOff)),(.on,try XCTUnwrap(chrome.checkboxOn)),(.mixed,try XCTUnwrap(chrome.checkboxMixed))]
        style.appearance = ClassicAppearance(id:"pixels",name:"Pixels",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test")
        for (state,data) in pixels {
            for (pressed,enabled,roles) in [(false,true,[2,35,29,29,30,31,32,33,34]),(true,true,[2,42,36,36,37,38,39,40,41]),(false,false,[2,49,43,43,44,45,46,47,48])] {
                for scale in [1,2] {
                    let bitmap = try helper.render(scale:scale,width:30,height:22) { HAPCheckboxDrawing.draw(NSRect(x:0,y:0,width:30,height:22),title:"",state:state,pressed:pressed,enabled:enabled) }
                    for y in 0..<14 { for x in 0..<14 {
                        let packed = data[y*7+x/2], index = Int(x.isMultiple(of:2) ? packed>>4 : packed&15)
                        XCTAssertEqual(try helper.color(bitmap,x:(x+2)*scale,y:(y+4)*scale),UInt32(roles[index])*0x010101)
                    } }
                }
            }
        }
        for appearance in appearances where ["Mach Lavender","Amber CRT"].contains(appearance.name) {
            style.appearance = appearance
            for scale in [1,2] {
                let bitmap = try helper.render(scale:scale,width:390,height:270) {
                    style.color(2).setFill(); NSRect(x:0,y:0,width:390,height:270).fill()
                    for (row,state) in [NSControl.StateValue.off,.on,.mixed].enumerated() {
                        for (column,flags) in [(false,true),(true,true),(false,false)].enumerated() {
                            HAPCheckboxDrawing.draw(NSRect(x:8,y:8+(row*3+column)*28,width:375,height:22),title:flags.1 ? (flags.0 ? "Pressed" : "Open Public Chat on connect") : "Disabled",state:state,pressed:flags.0,enabled:flags.1)
                        }
                    }
                }
                if let directory = ProcessInfo.processInfo.environment["KDX_CLASSIC_RENDER_DIR"] {
                    let folder = URL(fileURLWithPath:directory,isDirectory:true); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent("\(appearance.name)-checkboxes-\(scale)x.png"))
                }
            }
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(chrome)) as? [String:Any])
        for bad in [Data([0]),Data(repeating:0xff,count:98)] {
            object["checkboxOn"] = bad.base64EncodedString()
            let corrupt = try JSONDecoder().decode(HAPChromeArtwork.self,from:JSONSerialization.data(withJSONObject:object))
            XCTAssertThrowsError(try corrupt.validate())
        }
        for key in ["checkboxOff","checkboxOn","checkboxMixed"] { object.removeValue(forKey:key) }
        XCTAssertNoThrow(try JSONDecoder().decode(HAPChromeArtwork.self,from:JSONSerialization.data(withJSONObject:object)).validate())
    }
}
