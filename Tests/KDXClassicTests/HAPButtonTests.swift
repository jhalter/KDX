import AppKit
import XCTest
@testable import KDXClassicUI

final class HAPButtonTests: XCTestCase {
    @MainActor func testDefaultBitmapVariantsAndPaletteFallback() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery }
        let colors = (0..<221).map { UInt32($0)*0x010101 }
        for scale in [1,2] { for (pressed,enabled,id,base) in [(false,true,21,29),(true,true,22,36),(false,false,23,43)] {
            var skins = [UInt8](HAPArtworkTests().skinSection())
            skins.replaceSubrange((64+id*4)..<(68+id*4),with:skins[100..<104])
            style.appearance = ClassicAppearance(id:"buttons",name:"Buttons",colors:colors,source:"test",artwork:try HAPArtwork(skins:Data(skins),icons:Data()))
            let bitmap = try helper.render(scale:scale,width:100,height:24) {
                ClassicPainter.button(NSRect(x:0,y:0,width:100,height:24),title:"",pressed:pressed,enabled:enabled,defaultButton:true)
            }
            // An override covers the whole default button: no extra outer frame.
            XCTAssertEqual(try helper.color(bitmap,x:0,y:0),0xff0000)
            XCTAssertEqual(try helper.color(bitmap,x:50*scale,y:12*scale),0x0000ff)
            skins.replaceSubrange((64+id*4)..<(68+id*4),with:[0,0,0,0])
            style.appearance.artwork = try HAPArtwork(skins:Data(skins),icons:Data())
            let fallback = try helper.render(scale:scale,width:100,height:24) {
                ClassicPainter.button(NSRect(x:0,y:0,width:100,height:24),title:"",pressed:pressed,enabled:enabled,defaultButton:true)
            }
            XCTAssertEqual(try helper.color(fallback,x:50*scale,y:12*scale),UInt32(base+2)*0x010101,"Missing default skin must not reuse ordinary skin 9.")
            XCTAssertEqual(try helper.color(fallback,x:50*scale,y:3*scale),UInt32(base+5)*0x010101,"Inner button stays inset by three pixels.")
            if !enabled { XCTAssertEqual(try helper.color(fallback,x:50*scale,y:0),0xffffff) }
        } }
    }

    @MainActor func testReferenceDefaultFrameCornersAndLabelPositions() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Provide the original application for default-button artwork checks") }
        let appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared, helper = HAPWindowTests(), oldFont = style.fontChoiceID
        defer { style.fontChoiceID = oldFont; style.appearance = .recovery; style.configureAssets([]) }
        style.configureAssets(appearances); style.fontChoiceID = nil
        let chrome = try XCTUnwrap(style.chromeArtwork), corners = try XCTUnwrap(chrome.defaultButtonCorners)
        XCTAssertEqual(corners.count,60)
        style.appearance = ClassicAppearance(id:"roles",name:"Roles",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test")
        for scale in [1,2] { for pressed in [false,true] {
            let bitmap = try helper.render(scale:scale,width:100,height:24) {
                ClassicPainter.button(NSRect(x:0,y:0,width:100,height:24),title:"",pressed:pressed,enabled:true,defaultButton:true)
            }
            for (offset,slot) in [53,50,51].enumerated() {
                XCTAssertEqual(try helper.color(bitmap,x:50*scale,y:offset*scale),UInt32(slot)*0x010101)
                XCTAssertEqual(try helper.color(bitmap,x:offset*scale,y:12*scale),UInt32(slot)*0x010101)
            }
            for (offset,slot) in [51,52,53].enumerated() {
                XCTAssertEqual(try helper.color(bitmap,x:50*scale,y:(21+offset)*scale),UInt32(slot)*0x010101)
                XCTAssertEqual(try helper.color(bitmap,x:(97+offset)*scale,y:12*scale),UInt32(slot)*0x010101)
            }
            // Check every pixel belonging to the imported outer corners;
            // the inner button overlaps the inward portion of each 5x5 tile.
            for cy in 0..<2 { for cx in 0..<2 { for y in 0..<5 { for x in 0..<5 {
                let dx = (cx == 0 ? 0 : 95)+x, dy = (cy == 0 ? 0 : 19)+y
                guard dx < 3 || dx >= 97 || dy < 3 || dy >= 21 else { continue }
                let sx = cx*5+x, sy = cy*5+y
                let index = Int(corners[sy*6+sx/2] >> (sx.isMultiple(of:2) ? 4 : 0) & 15)
                let color = index == 0 ? UInt32(0xffffff) : UInt32(index+49)*0x010101
                for py in 0..<scale { for px in 0..<scale {
                    XCTAssertEqual(try helper.color(bitmap,x:dx*scale+px,y:dy*scale+py),color)
                } }
            } } } }
        } }
        // Original normal/pressed/disabled labels are centered in the SAME
        // full control rect. Compare the foreground mask, independent of colors.
        for scale in [1,2] {
            var masks: [Set<Int>] = []
            for (pressed,enabled,slot) in [(false,true,35),(true,true,42),(false,false,49)] {
                let bitmap = try helper.render(scale:scale,width:100,height:24) {
                    ClassicPainter.button(NSRect(x:0,y:0,width:100,height:24),title:"Save",pressed:pressed,enabled:enabled,defaultButton:true)
                }
                var mask = Set<Int>()
                for y in 0..<24*scale { for x in 0..<100*scale {
                    if try helper.color(bitmap,x:x,y:y) == UInt32(slot)*0x010101 { mask.insert(y*100*scale+x) }
                } }
                XCTAssertFalse(mask.isEmpty); masks.append(mask)
            }
            XCTAssertEqual(masks[0],masks[1]); XCTAssertEqual(masks[0],masks[2])
        }
        for appearance in appearances where ["Mach Lavender","Amber CRT"].contains(appearance.name) {
            style.appearance = appearance
            let surface = ClassicSurface(frame:NSRect(x:0,y:0,width:280,height:150))
            for row in 0..<5 {
                let button = ClassicButton(row == 0 ? "Ordinary" : "Save",key:row == 0 ? "" : "\r") {}
                button.translatesAutoresizingMaskIntoConstraints = true
                button.frame = NSRect(x:10,y:8+row*28,width:260,height:24)
                if row == 2 { button.cell?.isHighlighted = true }
                if row == 3 { button.isEnabled = false }
                if row == 4 { button.keyEquivalent = "" }
                surface.addSubview(button)
            }
            for scale in [1,2] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:280*scale,pixelsHigh:150*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                bitmap.size = surface.bounds.size; surface.cacheDisplay(in:surface.bounds,to:bitmap)
                if let folder = ProcessInfo.processInfo.environment["KDX_CLASSIC_RENDER_DIR"] {
                    let url = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(appearance.name)-default-buttons-\(scale)x.png"))
                }
            }
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(chrome)) as? [String:Any])
        for bad in [Data([0]),Data(repeating:0xff,count:60)] {
            object["defaultButtonCorners"] = bad.base64EncodedString()
            XCTAssertThrowsError(try JSONDecoder().decode(HAPChromeArtwork.self,from:JSONSerialization.data(withJSONObject:object)).validate())
        }
        object.removeValue(forKey:"defaultButtonCorners")
        XCTAssertNoThrow(try JSONDecoder().decode(HAPChromeArtwork.self,from:JSONSerialization.data(withJSONObject:object)).validate())
    }

    @MainActor func testNativeButtonShortcutsAndDisabledAction() throws {
        var actions = 0
        let button = ClassicButton("Save",key:"\r") { actions += 1 }
        XCTAssertEqual(button.accessibilityRole(),.button)
        XCTAssertEqual(button.keyEquivalentModifierMask,[])
        button.performClick(nil); XCTAssertEqual(actions,1)
        let event = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36))
        XCTAssertTrue(button.performKeyEquivalent(with:event)); XCTAssertEqual(actions,2)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.numericPad],timestamp:0,windowNumber:0,context:nil,characters:"\u{3}",charactersIgnoringModifiers:"\u{3}",isARepeat:false,keyCode:76))
        XCTAssertTrue(button.performKeyEquivalent(with:enter)); XCTAssertEqual(actions,3)
        button.isEnabled = false
        button.performClick(nil); XCTAssertEqual(actions,3)
        XCTAssertFalse(button.performKeyEquivalent(with:event)); XCTAssertEqual(actions,3)
        XCTAssertFalse(button.performKeyEquivalent(with:enter)); XCTAssertEqual(actions,3)
        let cancel = ClassicButton("Cancel",key:"\u{1b}") { actions += 1 }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53))
        XCTAssertTrue(cancel.performKeyEquivalent(with:escape)); XCTAssertEqual(actions,4)
    }
}
