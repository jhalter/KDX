import AppKit
import XCTest
@testable import KDXClassicUI

final class HAPPopUpTests: XCTestCase {
    @MainActor func testPaletteSelectorGeometryAndStates() throws {
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery }
        style.appearance = ClassicAppearance(id:"selectors",name:"Selectors",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test")
        let helper = HAPWindowTests()
        for scale in [1,2] { for (pressed,enabled,base) in [(false,true,29),(true,true,36),(false,false,43),(true,false,43)] {
            let bitmap = try helper.render(scale:scale,width:100,height:24) {
                HAPPopUpDrawing.draw(NSRect(x:0,y:0,width:100,height:24),title:"",pressed:pressed,enabled:enabled)
            }
            // From 0x96ABC...0x96D44: the label has a flat interior and the
            // last 22 pixels have a separate three-pixel raised arrow bezel.
            for (x,y,slot) in [(40,10,2),(2,10,2),(1,10,0),(0,10,5),(40,0,5),(40,1,0),(40,22,4),(40,23,5),(78,1,2),(78,10,4),(79,10,0),(80,10,1),(85,2,1),(97,2,2),(81,21,3),(97,21,4),(96,20,3),(98,10,4),(99,10,5)] {
                for sy in 0..<scale { for sx in 0..<scale {
                    XCTAssertEqual(try helper.color(bitmap,x:x*scale+sx,y:y*scale+sy),UInt32(base+slot)*0x010101,"pixel \(x),\(y)")
                } }
            }
            // 0x96890 draws rows 9,7,5,3,1 starting at (84,9).
            for row in 0..<5 { for x in 0..<9 {
                let slot = x >= row && x < 9-row ? 6 : 2
                XCTAssertEqual(try helper.color(bitmap,x:(84+x)*scale,y:(9+row)*scale),UInt32(base+slot)*0x010101)
            } }
        } }
        for width in [28,29,37,38] {
            let rect = NSRect(x:3,y:5,width:width,height:24)
            XCTAssertEqual(HAPPopUpDrawing.textRect(rect).width, width < 38 ? 0 : 7)
            XCTAssertEqual(HAPPopUpDrawing.arrowRect(rect).minX, width == 28 ? 12 : CGFloat(width)-13)
        }
    }

    func skins(placement: [UInt8] = [0,0,6,0], omit: Set<Int> = []) throws -> HAPArtwork {
        var bytes = [UInt8](repeating:0,count:2112)
        func put(_ value: Int, at: Int) {
            for i in 0..<4 { bytes[at+i] = UInt8(truncatingIfNeeded:value >> (24-8*i)) }
        }
        for id in [9,10,11,73,74,75,77,78,79,81,82,83] where !omit.contains(id) {
            let offset = bytes.count
            put(offset,at:64+id*4)
            // Solid 3x3 indexed bitmap: its RGB identifies the selected skin.
            bytes += [0,3,0,3,0,1,0,0, 0,0x12,0x34,0x56, 1,1,1,1] + placement
            bytes += [0,UInt8(id),UInt8(id),UInt8(id)] + [UInt8](repeating:0,count:12)
        }
        return try HAPArtwork(skins:Data(bytes),icons:Data())
    }

    @MainActor func testBitmapVariantsPlacementAndMissingSkinFallback() throws {
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery }
        let helper = HAPWindowTests(), colors = (0..<221).map { UInt32($0)*0x010101 }
        for width in [28,29,100] { for scale in [1,2] { for (pressed,enabled,variant) in [(false,true,0),(true,true,1),(false,false,2)] {
            style.appearance = ClassicAppearance(id:"skins",name:"Skins",colors:colors,source:"test",artwork:try skins())
            let rect = NSRect(x:0,y:0,width:width,height:24)
            let bitmap = try helper.render(scale:scale,width:width,height:24) { HAPPopUpDrawing.draw(rect,title:"",pressed:pressed,enabled:enabled) }
            XCTAssertEqual(try helper.color(bitmap,x:4*scale,y:4*scale),UInt32((width <= 28 ? 77 : 73)+variant)*0x010101)
            let arrowX = width <= 28 ? 12 : width-9
            XCTAssertEqual(try helper.color(bitmap,x:arrowX*scale,y:10*scale),UInt32(81+variant)*0x010101)
        } } }
        let rect = NSRect(x:10,y:20,width:100,height:24)
        for (placement,expected) in [([4,5,6,7],NSPoint(x:14,y:25)),([0,0,6,7],NSPoint(x:101,y:34)),([0,0,6,0],NSPoint(x:101,y:30))] {
            let bitmap = try XCTUnwrap(try skins(placement:placement.map(UInt8.init)).decode().skins[81])
            XCTAssertEqual(HAPPopUpDrawing.arrowRect(rect,skin:bitmap).origin,expected)
        }
        // Missing arrow uses a triangle in the body's text RGB; missing pressed
        // body uses the entire palette renderer even if an arrow skin exists.
        for omit: Set<Int> in [[82],[74]] {
            style.appearance = ClassicAppearance(id:"missing",name:"Missing",colors:colors,source:"test",artwork:try skins(omit:omit))
            let bitmap = try helper.render(scale:1,width:100,height:24) { HAPPopUpDrawing.draw(NSRect(x:0,y:0,width:100,height:24),title:"",pressed:true,enabled:true) }
            XCTAssertEqual(try helper.color(bitmap,x:88,y:11),omit.contains(74) ? 0x2a2a2a : 0x123456)
            XCTAssertEqual(try helper.color(bitmap,x:4,y:4),omit.contains(74) ? 0x262626 : 0x4a4a4a)
        }
        style.appearance.artwork = try skins(omit:[78])
        let compact = try helper.render(scale:1,width:28,height:24) { HAPPopUpDrawing.draw(NSRect(x:0,y:0,width:28,height:24),title:"",pressed:true,enabled:true) }
        XCTAssertEqual(try helper.color(compact,x:4,y:4),0x0a0a0a,"Compact fallback passes through the ordinary pushbutton bitmap renderer.")
        XCTAssertEqual(try helper.color(compact,x:13,y:11),0x2a2a2a,"Compact fallback retains the palette arrow color.")
    }

    @MainActor func testNativeSelectionSizingAndReferenceRenders() throws {
        var appearances = [ClassicAppearance.recovery]
        if let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] {
            appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances.filter { ["Mach Lavender","Amber CRT"].contains($0.name) }
        }
        let style = ClassicStyle.shared
        let previousFont = style.fontChoiceID
        defer { style.fontChoiceID = previousFont; style.appearance = .recovery; style.configureAssets([]) }
        style.fontChoiceID = nil
        for appearance in appearances {
            style.configureAssets([appearance]); style.appearance = appearance
            let surface = ClassicSurface(frame:NSRect(x:0,y:0,width:280,height:150))
            for index in 0..<5 {
                let popup = ClassicPopUpButton("Appearance")
                popup.addItems(withTitles:["Mach Lavender","Amber CRT","A long name with 日本語 and 👩🏽‍💻"])
                popup.item(at:1)?.representedObject = "session-2"
                popup.selectItem(at:1)
                XCTAssertEqual(popup.titleOfSelectedItem,"Amber CRT")
                XCTAssertEqual(popup.selectedItem?.representedObject as? String,"session-2")
                XCTAssertEqual(popup.accessibilityRole(),.popUpButton)
                XCTAssertEqual(popup.accessibilityLabel(),"Appearance")
                XCTAssertEqual(popup.accessibilityValue() as? String,"Amber CRT")
                let cell = try XCTUnwrap(popup.cell as? ClassicPopUpButtonCell)
                XCTAssertEqual(cell.title,"Amber CRT")
                let longest = (popup.itemTitles[2] as NSString).size(withAttributes:[.font:style.font]).width
                XCTAssertGreaterThanOrEqual(cell.cellSize.width,longest+31)
                popup.frame = NSRect(x:10,y:CGFloat(8+index*28),width:index == 4 ? 28 : 250,height:24)
                if index == 1 { cell.isHighlighted = true }
                if index == 2 { popup.isEnabled = false }
                if index == 3 { popup.selectItem(at:2) }
                surface.addSubview(popup)
            }
            for scale in [1,2] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:280*scale,pixelsHigh:150*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                bitmap.size = surface.bounds.size; surface.cacheDisplay(in:surface.bounds,to:bitmap)
                // Exercise the actual NSPopUpButton drawing path, not only helpers.
                if appearance.colors.count >= 204 {
                    for (row,base) in [(0,29),(1,36),(2,43)] {
                        XCTAssertEqual(try HAPWindowTests().color(bitmap,x:10*scale,y:(18+row*28)*scale),appearance.colors[base+5])
                    }
                }
                if let folder = ProcessInfo.processInfo.environment["KDX_CLASSIC_RENDER_DIR"] {
                    let url = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(appearance.name)-selectors-\(scale)x.png"))
                }
            }
            let attributes: [NSAttributedString.Key:Any] = [.font:style.font]
            let title = "日本語👩🏽‍💻abcdef"
            let width = ("日本語…" as NSString).size(withAttributes:attributes).width
            let shortened = HAPPopUpDrawing.truncatedTitle(title,width:width,attributes:attributes)
            XCTAssertTrue(shortened.hasSuffix("…")); XCTAssertTrue(title.hasPrefix(String(shortened.dropLast())))
            XCTAssertLessThanOrEqual((shortened as NSString).size(withAttributes:attributes).width,width)
        }
    }
}
