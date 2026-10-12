import AppKit
import XCTest
@testable import KDXClassicUI

final class ClassicButtonBarTests: XCTestCase {
    @MainActor func testCompactPreferenceAndIndependentFrames() throws {
        let suite = "kdx-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let prefs = ClassicPreferences(defaults:defaults)
        XCTAssertFalse(prefs.smallButtonBar)
        prefs.smallButtonBar = true
        let vertical = NSRect(x:20,y:30,width:270,height:320), compact = NSRect(x:400,y:500,width:520,height:60)
        prefs.save(frame:vertical,key:"button-bar"); prefs.save(frame:compact,key:"button-bar.compact")
        let restored = ClassicPreferences(defaults:defaults), screens = [NSRect(x:0,y:0,width:1440,height:900)]
        XCTAssertTrue(restored.smallButtonBar)
        XCTAssertEqual(restored.frame(key:"button-bar",fallback:.zero,screens:screens),vertical)
        XCTAssertEqual(restored.frame(key:"button-bar.compact",fallback:.zero,screens:screens),compact)
        XCTAssertTrue(screens[0].contains(restored.frame(key:"button-bar.compact",fallback:compact,screens:screens)))
    }

    @MainActor func testIconOnlyNativeActionsAndFallback() throws {
        _ = NSApplication.shared
        ClassicStyle.shared.appearance = .recovery
        var calls = 0
        let button = ClassicButton("Address Book") { calls += 1 }
        button.iconID = 78; button.iconOnly = true
        XCTAssertEqual(button.title,"Address Book")
        XCTAssertEqual(button.accessibilityLabel(),"Address Book")
        XCTAssertEqual(button.toolTip,"Address Book")
        XCTAssertEqual(button.intrinsicContentSize,NSSize(width:32,height:24))
        button.performClick(nil); XCTAssertEqual(calls,1)
        button.isEnabled = false; button.performClick(nil); XCTAssertEqual(calls,1)
        button.iconOnly = false
        XCTAssertNil(button.toolTip); XCTAssertGreaterThan(button.intrinsicContentSize.width,32)
        let helper = HAPWindowTests()
        let bitmap = try helper.render(scale:1,width:32,height:24) {
            ClassicPainter.button(NSRect(x:0,y:0,width:32,height:24),title:"Address Book",pressed:false,enabled:true,defaultButton:false,iconID:78,iconOnly:true)
        }
        let background = try helper.color(bitmap,x:4,y:4)
        var textPixels = 0
        for y in 5..<19 { for x in 4..<28 {
            if try helper.color(bitmap,x:x,y:y) != background { textPixels += 1 }
        } }
        XCTAssertGreaterThan(textPixels,0,"Recovery draws a short label until icons are imported.")
    }

    func testBarGeometryAndIconsMatchOriginalResources() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Provide the original application for bar geometry checks") }
        let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path))), rez = 0xd7a30
        for compact in [false,true] {
            let base = rez+(compact ? 0x12920 : 0x12360)
            XCTAssertEqual(try bytes.u16(base+16),compact ? 520 : 152)
            XCTAssertEqual(try bytes.u16(base+18),compact ? 40 : 282)
            let records = compact ? [0xc0,0x108,0x150,0x27c,0x18c,0x36c,0x3a8,0x1c8,0x204,0x240] : [0xc0,0x110,0x164,0x2c0,0x1ac,0x3b0,0x3f8,0x1f8,0x238,0x280]
            for (action,offset) in zip(ClassicBarAction.allCases,records) {
                let x = try bytes.u16(base+offset+4), y = try bytes.u16(base+offset+6)
                let right = try bytes.u16(base+offset+8), bottom = try bytes.u16(base+offset+10)
                XCTAssertEqual(action.rect(compact:compact),NSRect(x:Int(x),y:Int(y),width:Int(right-x),height:Int(bottom-y)))
                if action != .messages { XCTAssertEqual(try bytes.u32(base+offset+40),action.iconID) }
            }
        }
        // Messages is a dynamically populated HOLD in the bar; MENU maan binds its icon.
        XCTAssertEqual(try bytes.u32(rez+0xbde0+0x138),ClassicBarAction.messages.iconID)
    }

    @MainActor func testReferenceBarLayoutsAndIconPixels() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Provide the original application for button-bar artwork checks") }
        let source = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
        let appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared, previousFont = style.fontChoiceID
        defer { style.fontChoiceID = previousFont; style.appearance = .recovery; style.configureAssets([]) }
        style.configureAssets(appearances); style.fontChoiceID = nil
        let actions = ClassicBarAction.allCases
        let titles = actions.map(\.title), ids = actions.map(\.iconID)
        for appearance in appearances.filter({ ["Mach Lavender","Amber CRT"].contains($0.name) }) {
            style.appearance = appearance
            for compact in [false,true] {
                let picker = ClassicPopUpButton("Connection")
                picker.addItems(withTitles:["First server","Second server"]); picker.selectItem(at:1)
                let buttons = actions.map { action in
                    let button = ClassicButton(action.title,height:action.rect(compact:compact).height) {}; button.iconID = action.iconID; return button
                }
                let view = ClassicButtonBarView(compact:compact,picker:picker,status:classicLabel("[2] connections   [0] transfers"),buttons:buttons)
                view.frame = NSRect(origin:.zero,size:ClassicButtonBarView.referenceSize(compact:compact))
                view.updateCounts(connections:2,transfers:0)
                view.layoutSubtreeIfNeeded()
                XCTAssertEqual(picker.indexOfSelectedItem,1)
                XCTAssertEqual(view.connectionCount.stringValue,"2")
                XCTAssertEqual(view.transferCount.stringValue,"0")
                for (index,button) in buttons.enumerated() {
                    let rect = view.convert(button.bounds,from:button)
                    XCTAssertTrue(view.bounds.contains(rect),"\(titles[index]): \(rect)")
                    XCTAssertEqual(button.iconOnly,compact)
                    XCTAssertEqual(rect,actions[index].rect(compact:compact))
                    if index > 0 {
                        let previous = view.convert(buttons[index-1].bounds,from:buttons[index-1])
                        if compact { XCTAssertEqual(rect.minX,previous.maxX-1) }
                        else { XCTAssertEqual(rect.minY,previous.maxY-1) }
                    }
                }
                for scale in [1,2] {
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(view.frame.width)*scale,pixelsHigh:Int(view.frame.height)*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                    bitmap.size = view.bounds.size; view.cacheDisplay(in:view.bounds,to:bitmap)
                    if let folder = ProcessInfo.processInfo.environment["KDX_CLASSIC_RENDER_DIR"] {
                        let url = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(appearance.name)-bar-\(compact ? "compact" : "vertical")-\(scale)x.png"))
                    }
                    // Compare every banner pixel to the original indexed raster, independently of the decoder.
                    let bannerHelper = HAPWindowTests()
                    for y in 0..<40 { for x in 0..<152 {
                        let index = Int(source.bytes[0xf4140+y*152+x])
                        let expected = UInt32(try source.u32(0xf3e20+index*4))
                        for sy in 0..<scale { for sx in 0..<scale {
                            XCTAssertEqual(try bannerHelper.color(bitmap,x:x*scale+sx,y:y*scale+sy),expected)
                        } }
                    } }
                    // Verify every opaque source icon pixel at its native size,
                    // centered in the compact button without resampling.
                    if compact {
                        let helper = HAPWindowTests()
                        for (button,id) in zip(buttons,ids) where id != ClassicBarAction.messages.iconID {
                            let icon = try XCTUnwrap(style.artwork?.icon(id,small:true))
                            let rect = view.convert(button.bounds,from:button)
                            let left = Int(floor(rect.midX-CGFloat(icon.width)/2)), top = Int(floor(rect.midY-CGFloat(icon.height)/2))
                            let pixels = [UInt8](icon.rgba)
                            for y in 0..<icon.height { for x in 0..<icon.width {
                                let i = (y*icon.width+x)*4
                                guard pixels[i+3] == 255 else { continue }
                                let rgb = UInt32(pixels[i])<<16 | UInt32(pixels[i+1])<<8 | UInt32(pixels[i+2])
                                XCTAssertEqual(try helper.color(bitmap,x:(left+x)*scale,y:(top+y)*scale),rgb)
                            } }
                        }
                    }
                }
                let chrome = ClassicChrome(); chrome.title = "KDX"; chrome.allowsResize = false
                chrome.frame = NSRect(x:0,y:0,width:view.frame.width+12,height:view.frame.height+28)
                chrome.layoutSubtreeIfNeeded(); view.frame = chrome.content.bounds; chrome.content.addSubview(view)
                chrome.layoutSubtreeIfNeeded()
                XCTAssertEqual(view.frame.size,ClassicButtonBarView.referenceSize(compact:compact))
                XCTAssertTrue(try XCTUnwrap(chrome.subviews.compactMap { $0 as? ChromeButton }.first { $0.kind == .maximize }).isHidden)
                for scale in [1,2] {
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(chrome.frame.width)*scale,pixelsHigh:Int(chrome.frame.height)*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                    bitmap.size = chrome.bounds.size; chrome.cacheDisplay(in:chrome.bounds,to:bitmap)
                    if let folder = ProcessInfo.processInfo.environment["KDX_CLASSIC_RENDER_DIR"] {
                        let url = URL(fileURLWithPath:folder,isDirectory:true)
                        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(appearance.name)-bar-window-\(compact ? "compact" : "vertical")-\(scale)x.png"))
                    }
                }
            }
        }
    }
}
