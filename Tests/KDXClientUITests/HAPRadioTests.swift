import AppKit
import XCTest
@testable import KDXClientUI

final class HAPRadioTests: XCTestCase {
    @MainActor func testRadioSkinStatesAndNativeGroupSelection() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.configureAssets([]); style.appearance = .recovery }
        for (state,base) in [(NSControl.StateValue.off,53),(.on,57),(.mixed,61)] {
            for (pressed,enabled,offset) in [(false,true,0),(true,true,1),(false,false,2),(true,false,2)] {
                var bytes = [UInt8](HAPArtworkTests().skinSection())
                let id = base+offset
                bytes.replaceSubrange((64+id*4)..<(68+id*4),with:bytes[100..<104])
                style.appearance = ClassicAppearance(id:"radio",name:"Radio",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test",artwork:try HAPArtwork(skins:Data(bytes),icons:Data()))
                XCTAssertEqual(HAPCheckboxDrawing.skinID(state:state,pressed:pressed,enabled:enabled,radio:true),id)
                let radio = ClassicRadioButton(""); radio.allowsMixedState = true; radio.state = state; radio.isEnabled = enabled
                radio.cell?.isHighlighted = pressed; radio.frame = NSRect(x:0,y:0,width:60,height:23)
                for scale in [1,2] {
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:60*scale,pixelsHigh:23*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                    bitmap.size = radio.bounds.size; radio.cacheDisplay(in:radio.bounds,to:bitmap)
                    for (x,y,color) in [(2,10,0xff0000),(3,11,0x0000ff),(2,12,0x0000ff)] {
                        XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),UInt32(color))
                    }
                }
            }
        }
        let group = ClassicRadioGroup("Endpoint type",titles:["Server","Tracker"])
        var changes = [Int](); group.selectionChanged = { changes.append($0) }
        XCTAssertEqual(group.accessibilityRole(),.radioGroup)
        XCTAssertEqual(group.accessibilityLabel(),"Endpoint type")
        XCTAssertEqual(group.buttons.map(\.state),[.on,.off])
        for button in group.buttons {
            XCTAssertEqual(button.accessibilityRole(),.radioButton)
            XCTAssertEqual(button.accessibilityLabel(),button.title)
        }
        group.buttons[1].performClick(nil)
        XCTAssertEqual(group.indexOfSelectedItem,1); XCTAssertEqual(group.buttons.map(\.state),[.off,.on])
        group.buttons[1].performClick(nil)
        XCTAssertEqual(group.buttons.map(\.state),[.off,.on],"A selected radio cannot toggle the group off.")
        group.buttons[0].isEnabled = false; group.buttons[0].performClick(nil)
        XCTAssertEqual(group.indexOfSelectedItem,1); XCTAssertEqual(changes,[1,1])
        group.selectItem(at:0)
        XCTAssertEqual(group.buttons.map(\.state),[.on,.off])
        group.selectItem(at:5); XCTAssertEqual(group.indexOfSelectedItem,0)
        XCTAssertEqual(changes,[1,1],"Restoring an endpoint must not invoke a user-change action.")
        group.buttons[0].isEnabled = true
        group.buttons[0].performClick(nil)
        XCTAssertEqual(group.indexOfSelectedItem,0); XCTAssertEqual(changes,[1,1,0])
    }

    @MainActor func testOriginalRoundArtworkPixelsTransparencyAndCatalogCompatibility() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Set KDX_REFERENCE for original radio artwork checks.") }
        let source = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
        let appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.configureAssets([]); style.appearance = .recovery }
        style.configureAssets(appearances)
        let chrome = try XCTUnwrap(style.chromeArtwork)
        let states: [(NSControl.StateValue,Data,Int)] = [(.off,try XCTUnwrap(chrome.radioOff),0x109080),(.on,try XCTUnwrap(chrome.radioOn),0x1090e4),(.mixed,try XCTUnwrap(chrome.radioMixed),0x109148)]
        for (_,data,offset) in states { XCTAssertEqual(data,try source.data(offset,98)) }
        for appearance in appearances where ["Mach Lavender","Amber CRT"].contains(appearance.name) {
            style.appearance = appearance
            for scale in [1,2] {
                for (state,data,_) in states {
                    for (pressed,enabled,roles) in [(false,true,[0,35,29,29,30,31,32,33,34]),(true,true,[0,42,36,36,37,38,39,40,41]),(false,false,[0,49,43,43,44,45,46,47,48]),(true,false,[0,49,43,43,44,45,46,47,48])] {
                        let bitmap = try helper.render(scale:scale,width:30,height:22) {
                            NSColor.magenta.setFill(); NSRect(x:0,y:0,width:30,height:22).fill()
                            HAPCheckboxDrawing.draw(NSRect(x:0,y:0,width:30,height:22),title:"",state:state,pressed:pressed,enabled:enabled,radio:true)
                        }
                        for y in 0..<14 { for x in 0..<14 {
                            let packed = data[y*7+x/2], index = Int(x.isMultiple(of:2) ? packed>>4 : packed&15)
                            let expected = index == 0 ? 0xff00ff : appearance.colors[roles[index]]
                            for sy in 0..<scale { for sx in 0..<scale {
                                XCTAssertEqual(try helper.color(bitmap,x:(x+2)*scale+sx,y:(y+4)*scale+sy),expected)
                            } }
                        } }
                    }
                }
                if let directory = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"] {
                    let bitmap = try helper.render(scale:scale,width:300,height:260) {
                        style.color(2).setFill(); NSRect(x:0,y:0,width:300,height:260).fill()
                        for (row,state) in [NSControl.StateValue.off,.on,.mixed].enumerated() {
                            for (column,flags) in [(false,true),(true,true),(false,false)].enumerated() {
                                HAPCheckboxDrawing.draw(NSRect(x:8,y:8+(row*3+column)*28,width:280,height:22),title:flags.1 ? (flags.0 ? "Pressed" : "Server") : "Disabled",state:state,pressed:flags.0,enabled:flags.1,radio:true)
                            }
                        }
                    }
                    let folder = URL(fileURLWithPath:directory,isDirectory:true)
                    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent("\(appearance.name)-radios-\(scale)x.png"))
                }
            }
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(chrome)) as? [String:Any])
        XCTAssertEqual(try JSONDecoder().decode(HAPChromeArtwork.self,from:JSONEncoder().encode(chrome)),chrome)
        for key in ["radioOff","radioOn","radioMixed"] {
            let original = object[key]
            for bad in [Data([0]),Data(repeating:0xff,count:98)] {
                object[key] = bad.base64EncodedString()
                let corrupt = try JSONDecoder().decode(HAPChromeArtwork.self,from:JSONSerialization.data(withJSONObject:object))
                XCTAssertThrowsError(try corrupt.validate())
            }
            object[key] = original
        }
        for key in ["radioOff","radioOn","radioMixed"] { object.removeValue(forKey:key) }
        let legacy = try JSONDecoder().decode(HAPChromeArtwork.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertNil(legacy.radioOff); XCTAssertNoThrow(try legacy.validate())
    }

    func testReferenceRadioDispatchAndTransparentBlitter() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Set KDX_REFERENCE for radio dispatch evidence.") }
        let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
        for (address,instruction) in [(0x9821c,0x540306b5),(0x98274,0x80028f5c),(0x98288,0x80028f58),(0x98294,0x80028f54),
                                      (0x982b4,0x3d200100),(0x982bc,0x4bfcb0e5),(0x9c19c,0x38000035),(0x9c1b4,0x38000039),(0x9c1cc,0x3800003d)] {
            XCTAssertEqual(try bytes.u32(address+0x1de0),instruction)
        }
    }
}
