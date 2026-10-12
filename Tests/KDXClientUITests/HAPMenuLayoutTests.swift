import AppKit
import XCTest
@testable import KDXClientUI

final class HAPMenuLayoutTests: XCTestCase {
    @MainActor func testUniformRowsMinimumMaximumWidthAndSharedGutterSelection() throws {
        let style = ClassicStyle.shared
        defer { style.configureAssets([]); style.fontChoiceID = nil; style.appearance = .recovery }
        style.configureAssets([])
        let menu = ClassicMenu(title:"Layout")
        let plain = menuItem("A") {}, separator = NSMenuItem.separator(), icon = menuItem("A",iconID:17) {}
        icon.isHidden = true
        menu.addItem(plain); menu.addItem(separator); menu.addItem(icon)
        menu.prepareForDisplay()
        let plainView = try XCTUnwrap(plain.view as? ClassicMenuItemView)
        let separatorView = try XCTUnwrap(separator.view as? ClassicMenuItemView)
        XCTAssertEqual(plainView.frame.size,NSSize(width:80,height:16))
        XCTAssertEqual(separatorView.frame.size,NSSize(width:80,height:16))
        XCTAssertEqual(separatorView.menuOffset,16)
        XCTAssertEqual(plainView.menuHeight,32)
        XCTAssertNil(icon.view)
        icon.isHidden = false; menu.prepareForDisplay()
        let iconView = try XCTUnwrap(icon.view as? ClassicMenuItemView)
        XCTAssertEqual(plainView.layout,.sharedIcons)
        XCTAssertEqual(iconView.layout,.sharedIcons)
        XCTAssertEqual(plainView.frame.size,NSSize(width:80,height:18))
        XCTAssertEqual(separatorView.frame.height,18)
        XCTAssertEqual(iconView.menuOffset,36)
        XCTAssertEqual(iconView.menuHeight,54)
        menu.layoutOverride = .standard; menu.prepareForDisplay()
        XCTAssertEqual(plainView.layout,.standard)
        XCTAssertEqual(iconView.frame.height,16)
        XCTAssertEqual(iconView.menuOffset,32)
        plain.title = String(repeating:"A",count:200); menu.prepareForDisplay()
        XCTAssertEqual(plainView.frame.width,600)
        XCTAssertEqual(iconView.frame.width,600)
        plain.title = "A"; menu.removeItem(icon); menu.layoutOverride = nil; menu.prepareForDisplay()
        XCTAssertEqual(plainView.frame.size,NSSize(width:80,height:16),"Recompute geometry when menu content changes.")
    }

    @MainActor func testReferenceMetricsAndTitlePixelsAtBothScales() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Set KDX_REFERENCE for original menu metrics.") }
        let imported = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path))
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.configureAssets([]); style.fontChoiceID = nil; style.appearance = .recovery }
        style.configureAssets(imported.appearances); style.fontChoiceID = nil
        let data = try XCTUnwrap(imported.appearances.compactMap(\.fonts).flatMap { $0 }.first { (try? HaxialFont(data:$0).name) == "Myoklonika" })
        let strike = try HaxialFont(data:data).strikes[0], glyph = strike.glyphs[65]
        XCTAssertEqual(strike.height,15)
        XCTAssertEqual(glyph.advance,10)
        for appearance in imported.appearances.filter({ ["Mach Lavender","Amber CRT"].contains($0.name) }) {
            style.appearance = appearance
            for layout in [HAPMenuLayout.standard,.sharedIcons] {
                let plain = menuItem("A") {}, icon = menuItem("A",iconID:17) {}
                XCTAssertEqual(HAPMenuDrawing.size(plain,layout:layout).width,layout == .standard ? 42 : 50)
                XCTAssertEqual(HAPMenuDrawing.size(icon,layout:layout).width,layout == .standard ? 62 : 50)
                for item in [plain,icon] { for scale in [1,2] {
                    let height = Int(layout.rowHeight), inset = layout == .sharedIcons ? 24 : item === plain ? 16 : 36
                    let bitmap = try helper.render(scale:scale,width:80,height:height) {
                        let rect = NSRect(x:0,y:0,width:80,height:height)
                        HAPMenuDrawing.background(rect)
                        HAPMenuDrawing.content(item,in:rect,color:style.color(107),layout:layout)
                    }
                    // Compare every pixel in the original glyph's advance/line box, including its blank padding.
                    for y in 0..<height { for x in 0..<glyph.advance {
                        let set = glyph.isSet(x:x-glyph.x,y:y-(height-strike.height)/2-glyph.y)
                        let expected = appearance.colors[set ? 107 : 105]
                        for sy in 0..<scale { for sx in 0..<scale {
                            XCTAssertEqual(try helper.color(bitmap,x:(inset+x)*scale+sx,y:y*scale+sy),expected,"\(appearance.name), \(layout), glyph (\(x),\(y))")
                        } }
                    } }
                } }
            }
        }
    }

    @MainActor func testSharedGutterIconAndCheckStatePixels() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Set KDX_REFERENCE for original menu icons.") }
        let imported = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path))
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.configureAssets([]); style.fontChoiceID = nil; style.appearance = .recovery }
        style.configureAssets(imported.appearances); style.fontChoiceID = nil
        style.appearance = try XCTUnwrap(imported.appearances.first { $0.name == "Mach Lavender" })
        let item = menuItem("",iconID:17) {}
        let source = try XCTUnwrap(style.artwork?.icon(17,small:true)), pixels = Array(source.rgba)
        for layout in [HAPMenuLayout.standard,.sharedIcons] { for scale in [1,2] {
            let height = Int(layout.rowHeight), left = (layout == .sharedIcons ? 4 : 16)+(16-source.width)/2
            let top = (height-source.height)/2
            func render(_ state: NSControl.StateValue) throws -> NSBitmapImageRep {
                item.state = state
                return try helper.render(scale:scale,width:80,height:height) {
                    let rect = NSRect(x:0,y:0,width:80,height:height)
                    HAPMenuDrawing.background(rect)
                    HAPMenuDrawing.content(item,in:rect,color:style.color(107),layout:layout)
                }
            }
            let off = try render(.off), on = try render(.on), mixed = try render(.mixed)
            for y in 0..<source.height { for x in 0..<source.width {
                let at = (y*source.width+x)*4
                if pixels[at+3] == 255 {
                    let rgb = UInt32(pixels[at])<<16 | UInt32(pixels[at+1])<<8 | UInt32(pixels[at+2])
                    XCTAssertEqual(try helper.color(off,x:(left+x)*scale,y:(top+y)*scale),rgb)
                }
            } }
            var checkPixels = 0, mixedPixels = 0
            for y in 0..<height*scale { for x in 0..<80*scale {
                if try helper.color(off,x:x,y:y) != helper.color(on,x:x,y:y) { checkPixels += 1 }
                if try helper.color(off,x:x,y:y) != helper.color(mixed,x:x,y:y) { mixedPixels += 1 }
            } }
            XCTAssertGreaterThan(mixedPixels,0,"The mixed-state dash is drawn after the icon in both modes.")
            if layout == .sharedIcons { XCTAssertEqual(checkPixels,0,"An icon suppresses the check in the shared gutter.") }
            else { XCTAssertGreaterThan(checkPixels,0,"Standard menus retain a separate check beside the icon.") }
        } }
    }

    func testReferenceInstructionsForMenuGeometry() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Set KDX_REFERENCE for reference instruction checks.") }
        let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
        // Constructor, later mode update, width bounds, and separator insertion all use these rules.
        for (address,instruction) in [(0x8c1f0,0x38800010),(0x8c21c,0x38800012),(0x8f564,0x38000010),(0x8f56c,0x38000012),
                                      (0x8c46c,0x281b0050),(0x8c578,0x2c1e0258),(0x8e274,0x88fd0060)] {
            XCTAssertEqual(try bytes.u32(address+0x1de0),instruction)
        }
    }
}
