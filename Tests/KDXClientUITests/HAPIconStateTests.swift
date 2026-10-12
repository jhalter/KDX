import AppKit
import XCTest
@testable import KDXClientUI

final class HAPIconStateTests: XCTestCase {
    private func appearance(template: Bool = false, skins: Bool = false, width: Int = 16) throws -> ClassicAppearance {
        let helper = HAPArtworkTests(), offset = 3072
        var bytes = [UInt8](repeating:0,count:offset+16+16*4)
        helper.put(offset,17*16,in:&bytes)
        bytes[offset+1] = UInt8(width); bytes[offset+3] = 16
        bytes[offset+4] = 1; bytes[offset+5] = 1; bytes[offset+6] = 1
        helper.put(template ? 0xffffff : 0x123456,offset+8,in:&bytes)
        helper.put(template ? 0 : 0xabcdef,offset+12,in:&bytes)
        for y in 0..<16 { for x in 0..<4 { bytes[offset+16+y*4+x] = 0x55 } }
        var skinBytes = skins ? Array(helper.skinSection()) : []
        if skins {
            helper.put(0,64+9*4,in:&skinBytes)
            helper.put(0x13579b,2120,in:&skinBytes)
            for id in [33,34,35,186,187,188] { helper.put(2112,64+id*4,in:&skinBytes) }
        }
        var colors = (0..<221).map { UInt32($0)*0x010101 }
        colors[35] = 0x2468ac; colors[38] = 0x204060; colors[42] = 0xb06020; colors[45] = 0x604020; colors[49] = 0x406080
        colors[105] = 0x806040; colors[109] = 0x102030
        colors[107] = 0x224466; colors[111] = 0xbbccdd; colors[112] = 0x6688aa
        return ClassicAppearance(id:"icon-states-\(template)-\(skins)-\(width)",name:"Icon states",colors:colors,source:"test",artwork:try HAPArtwork(skins:Data(skinBytes),icons:Data(bytes)))
    }

    @MainActor func testButtonsUseOriginalStateTintAndSkinTemplateText() throws {
        _ = NSApplication.shared
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for template in [false,true] { for skins in [false,true] {
            let appearance = try appearance(template:template,skins:skins)
            style.configureAssets([appearance]); style.appearance = appearance
            let button = ClassicButton("") {}; button.iconID = 17; button.iconOnly = true
            button.frame = NSRect(x:0,y:0,width:32,height:24)
            for (enabled,pressed,index) in [(true,false,0),(true,true,1),(false,false,2),(false,true,2)] {
                button.isEnabled = enabled; button.cell?.isHighlighted = pressed
                let expected: UInt32 = template ? (skins ? 0x13579b : [0x2468ac,0xb06020,0x406080][index]) : [0xabcdef,0x6586a7,0x858687][index]
                for scale in [1,2] {
                    let bitmap = try helper.render(scale:scale,width:32,height:24) { button.cell?.draw(withFrame:button.bounds,in:button) }
                    for sy in 0..<scale { for sx in 0..<scale {
                        XCTAssertEqual(try helper.color(bitmap,x:9*scale+sx,y:10*scale+sy),expected)
                    } }
                    let background = try helper.color(bitmap,x:8*scale,y:10*scale)
                    XCTAssertNotEqual(background,expected,"The transparent column must expose the themed button background.")
                }
            }
        } }
    }

    @MainActor func testMenusUsePaletteTintAndNativeSizeWithSkinText() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for template in [false,true] { for skins in [false,true] { for width in [10,16] {
            let appearance = try appearance(template:template,skins:skins,width:width)
            style.configureAssets([appearance]); style.appearance = appearance
            let item = menuItem("",iconID:17) {}
            let rect = NSRect(x:0,y:0,width:80,height:24), left = 16+(16-width)/2
            for (enabled,selected,index) in [(true,false,0),(true,true,1),(false,false,2),(false,true,2)] {
                item.isEnabled = enabled
                let expected: UInt32 = template ? (skins ? 0x13579b : [0x224466,0xbbccdd,0x6688aa][index]) : [0xabcdef,0x5d768f,0x959697][index]
                for scale in [1,2] {
                    let bitmap = try helper.render(scale:scale,width:80,height:24) {
                        HAPMenuDrawing.background(rect)
                        let color = HAPMenuDrawing.row(rect,selected:selected,enabled:enabled)
                        HAPMenuDrawing.content(item,in:rect,color:color,selected:selected)
                    }
                    for sy in 0..<scale { for sx in 0..<scale {
                        XCTAssertEqual(try helper.color(bitmap,x:(left+1)*scale+sx,y:10*scale+sy),expected)
                    } }
                    XCTAssertNotEqual(try helper.color(bitmap,x:left*scale,y:10*scale),expected)
                    XCTAssertNotEqual(try helper.color(bitmap,x:(left+width)*scale,y:10*scale),expected,"Narrow icons must remain at native width.")
                }
            }
        } } }
    }

    @MainActor func testMenuCopiesRetainIconIdentityActionAndResolveCurrentTheme() throws {
        _ = NSApplication.shared
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        let first = try appearance(), second = try appearance(template:true)
        style.configureAssets([first]); style.appearance = first
        var actions = 0
        let item = menuItem("Open",key:"o",iconID:17) { actions += 1 }
        let copy = try XCTUnwrap(item.copy() as? NSMenuItem)
        let menu = ClassicMenu(title:"Copy"); menu.addItem(copy); menu.prepareForDisplay()
        let view = try XCTUnwrap(copy.view as? ClassicMenuItemView)
        XCTAssertEqual((copy.representedObject as? ClassicMenuAction)?.iconID,17)
        XCTAssertTrue(view.activate()); XCTAssertEqual(actions,1)
        copy.isEnabled = false; XCTAssertFalse(view.activate()); XCTAssertEqual(actions,1)
        style.configureAssets([second]); style.appearance = second
        let rect = NSRect(x:0,y:0,width:100,height:24)
        let bitmap = try helper.render(scale:1,width:100,height:24) {
            HAPMenuDrawing.background(rect)
            HAPMenuDrawing.content(copy,in:rect,color:style.color(112))
        }
        XCTAssertEqual(try helper.color(bitmap,x:17,y:10),0x6688aa,"Resolve the retained icon ID from the new theme, not the old NSImage snapshot.")
        style.appearance = .recovery; style.configureAssets([])
        let missing = try helper.render(scale:1,width:100,height:24) {
            NSColor.black.setFill(); rect.fill(); HAPMenuDrawing.content(copy,in:rect,color:.white)
        }
        XCTAssertEqual(try helper.color(missing,x:17,y:10),0,"A missing current icon must not resurrect the stale image.")
    }

    @MainActor func testImportedButtonAndMenuIconStatesAtBothScales() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Set KDX_REFERENCE for imported icon-state checks.") }
        let imported = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path))
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for appearance in imported.appearances.filter({ ["Mach Lavender","Amber CRT"].contains($0.name) }) {
            style.configureAssets([appearance]); style.appearance = appearance
            for id in [73,84,78,88,90,93,86,85] {
                let source = try XCTUnwrap(style.artwork?.icon(id,small:true)), pixels = Array(source.rgba)
                let item = menuItem("",iconID:id) {}
                for menu in [false,true] { for state in 0..<3 { for scale in [1,2] {
                    item.isEnabled = state != 2
                    let rect = NSRect(x:0,y:0,width:80,height:24)
                    let bitmap = try helper.render(scale:scale,width:80,height:24) {
                        if menu {
                            HAPMenuDrawing.background(rect)
                            let color = HAPMenuDrawing.row(rect,selected:state == 1,enabled:state != 2)
                            HAPMenuDrawing.content(item,in:rect,color:color,selected:state == 1)
                        } else { ClassicPainter.button(rect,title:"",pressed:state == 1,enabled:state != 2,defaultButton:false,iconID:id,iconOnly:true) }
                    }
                    let tint = state == 0 ? nil : appearance.colors[menu ? (state == 2 ? 105 : 109) : (state == 2 ? 45 : 38)]
                    let text = appearance.colors[menu ? [107,111,112][state] : [35,42,49][state]]
                    let left = menu ? 16+(16-source.width)/2 : (80-source.width)/2, top = (24-source.height)/2
                    var count = 0
                    for y in 0..<source.height { for x in 0..<source.width {
                        let at = (y*source.width+x)*4
                        guard source.monochromeIconTemplate ? pixels[at] != 255 : pixels[at+3] == 255 else { continue }
                        var expected: UInt32 = 0
                        for (component,shift) in [16,8,0].enumerated() {
                            let raw = Int(pixels[at+component])
                            let value = source.monochromeIconTemplate ? Int((text >> shift)&255) : tint.map { $0 == 0xffffff ? raw/2+128 : (raw+Int(($0 >> shift)&255))/2 } ?? raw
                            expected |= UInt32(value) << shift
                        }
                        XCTAssertEqual(try helper.color(bitmap,x:(left+x)*scale,y:(top+y)*scale),expected,"\(appearance.name), id \(id), menu=\(menu), state=\(state)"); count += 1
                    } }
                    XCTAssertGreaterThan(count,0)
                    if let folder = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"], id == 84 {
                        let url = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(appearance.name)-icon-\(menu ? "menu" : "button")-\(state)-\(scale)x.png"))
                    }
                } } }
            }
        }
    }
}
