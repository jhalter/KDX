import AppKit
import XCTest
@testable import KDXClientUI

final class HAPMenuTests: XCTestCase {
    @MainActor func testPaletteRowsAndSeparators() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery }
        style.appearance = ClassicAppearance(id:"menu",name:"Menu",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test")
        for scale in [1,2] { for (selected,enabled) in [(false,true),(true,true),(true,false)] {
            let bitmap = try helper.render(scale:scale,width:100,height:24) {
                let rect = NSRect(x:0,y:0,width:100,height:24)
                HAPMenuDrawing.background(rect)
                let color = HAPMenuDrawing.row(rect,selected:selected,enabled:enabled,first:true,last:true)
                XCTAssertEqual(color,style.color(!enabled ? 112 : selected ? 111 : 107))
            }
            let upper = selected && enabled ? 108 : 104, fill = selected && enabled ? 109 : 105, lower = selected && enabled ? 110 : 106
            for (x,y,index) in [(0,10,upper),(99,10,lower),(50,10,fill),(50,0,upper),(99,0,fill),(0,23,fill),(50,23,lower)] {
                XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),UInt32(index)*0x010101)
            }
        } }
        let separator = try helper.render(scale:1,width:100,height:6) {
            let rect = NSRect(x:0,y:0,width:100,height:6)
            HAPMenuDrawing.background(rect); HAPMenuDrawing.row(rect,selected:true,enabled:true,separator:true)
        }
        XCTAssertEqual(try helper.color(separator,x:50,y:1),0x696969)
        XCTAssertEqual(try helper.color(separator,x:50,y:2),0x6a6a6a)
        XCTAssertEqual(try helper.color(separator,x:50,y:3),0x686868)
    }

    func skins(_ ids: [Int]) throws -> HAPArtwork {
        var bytes = [UInt8](repeating:0,count:2112)
        for id in ids {
            let offset = bytes.count
            for i in 0..<4 { bytes[64+id*4+i] = UInt8(truncatingIfNeeded:offset >> (24-8*i)) }
            bytes += [0,3,0,3,0,1,0,0,0,UInt8(id),0,0,1,1,1,1,0,0,0,0]
            bytes += [0,UInt8(id),UInt8(id),UInt8(id)] + [UInt8](repeating:0,count:12)
        }
        return try HAPArtwork(skins:Data(bytes),icons:Data())
    }

    @MainActor func testSkinLayersStateFallbackAndTilePhase() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery }
        for ids in [[184],[184,185],[186,189],[187],[188,191],[192]] {
            style.appearance = ClassicAppearance(id:"menu",name:"Menu",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test",artwork:try skins(ids))
            for scale in [1,2] {
                let selected = ids.contains(187), enabled = !ids.contains(188), separator = ids.contains(192)
                let bitmap = try helper.render(scale:scale,width:100,height:24) {
                    let rect = NSRect(x:0,y:0,width:100,height:24)
                    HAPMenuDrawing.background(rect)
                    HAPMenuDrawing.row(rect,selected:selected,enabled:enabled,separator:separator)
                }
                XCTAssertEqual(try helper.color(bitmap,x:50*scale,y:11*scale),UInt32(ids.last!)*0x010101)
            }
        }
        style.appearance.artwork = try skins([186,189])
        let missing = try helper.render(scale:1,width:100,height:24) {
            let rect = NSRect(x:0,y:0,width:100,height:24)
            HAPMenuDrawing.background(rect); HAPMenuDrawing.row(rect,selected:true,enabled:true)
        }
        XCTAssertEqual(try helper.color(missing,x:50,y:10),0x6d6d6d,"Absent selected artwork uses its palette, not normal artwork.")
        let pattern = HAPBitmap(width:1,height:2,rgba:Data([255,0,0,255,0,255,0,255]),textColor:nil,margins:[0,0,0,0],placement:[0,0,0,0])
        let tiled = try helper.render(scale:1,width:10,height:10) { HAPMenuDrawing.tile(pattern,in:NSRect(x:0,y:3,width:10,height:7)) }
        XCTAssertEqual(try helper.color(tiled,x:5,y:3),0x00ff00)
        XCTAssertEqual(try helper.color(tiled,x:5,y:4),0xff0000)
    }

    @MainActor func testNativeActionAndItemIdentity() throws {
        _ = NSApplication.shared
        var calls = 0
        let menu = ClassicMenu(title:"Actions"), item = menuItem("Open",key:"o") { calls += 1 }
        let handler = item.representedObject as AnyObject?
        item.keyEquivalentModifierMask = [.command,.option,.shift]
        menu.addItem(item); menu.addItem(.separator())
        let hidden = NSMenuItem(title:"Hidden",action:nil,keyEquivalent:""); hidden.isHidden = true; menu.addItem(hidden)
        menu.menuWillOpen(menu)
        let view = try XCTUnwrap(item.view as? ClassicMenuItemView)
        XCTAssertTrue(item.representedObject as AnyObject? === handler)
        XCTAssertEqual(HAPMenuDrawing.shortcut(item),"^:!O")
        XCTAssertEqual(view.accessibilityLabel(),"Open"); XCTAssertTrue(view.isAccessibilityEnabled())
        XCTAssertTrue(view.activate()); XCTAssertEqual(calls,1)
        item.isEnabled = false; XCTAssertFalse(view.activate()); XCTAssertEqual(calls,1)
        item.isEnabled = true; item.isHidden = true; XCTAssertFalse(view.activate())
        item.isHidden = false; item.submenu = ClassicMenu(title:"Children"); XCTAssertFalse(view.activate())
        XCTAssertFalse(try XCTUnwrap(menu.item(at:1)?.view as? ClassicMenuItemView).activate())
        XCTAssertNil(hidden.view)
        XCTAssertTrue(view.first); XCTAssertFalse(view.last)
        XCTAssertEqual(view.menuHeight,view.frame.height+16)
        let copy = try XCTUnwrap(item.copy() as? NSMenuItem)
        let copiedMenu = ClassicMenu(title:"Copy"); copiedMenu.addItem(copy); copiedMenu.prepareForDisplay()
        XCTAssertTrue((copy.view as? ClassicMenuItemView)?.item === copy)
        let popup = ClassicPopUpButton("Destination")
        popup.addItems(withTitles:["First","Second"])
        let popupMenu = try XCTUnwrap(popup.menu as? ClassicMenu)
        XCTAssertTrue(popupMenu.delegate === popupMenu)
        popupMenu.menuWillOpen(popupMenu)
        XCTAssertNotNil(popup.item(at:1)?.view as? ClassicMenuItemView)
    }

    @MainActor func testReferenceMenuRenders() throws {
        var appearances = [ClassicAppearance.recovery]
        if let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] {
            appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances.filter { ["Mach Lavender","Amber CRT"].contains($0.name) }
        }
        let style = ClassicStyle.shared, oldFont = style.fontChoiceID
        defer { style.fontChoiceID = oldFont; style.appearance = .recovery; style.configureAssets([]) }
        style.fontChoiceID = nil
        for appearance in appearances { for layout in [HAPMenuLayout.standard,.sharedIcons] {
            style.configureAssets([appearance]); style.appearance = appearance
            let menu = ClassicMenu(title:"Window"); menu.layoutOverride = layout
            for (index,title) in ["Close Window","Minimize","Files","Unavailable","Submenu"].enumerated() {
                let item = menuItem(title,key:index == 0 ? "w" : "",iconID:index == 2 ? 17 : nil) {}
                item.isEnabled = index != 3
                if index == 1 { item.state = .on }
                if index == 4 { item.submenu = ClassicMenu(title:"Submenu") }
                menu.addItem(item)
                if index == 2 { menu.addItem(.separator()) }
            }
            menu.prepareForDisplay()
            let width = Int(menu.items[0].view!.frame.width), height = Int((menu.items[0].view as! ClassicMenuItemView).menuHeight)
            let surface = ClassicSurface(frame:NSRect(x:0,y:0,width:width*2+20,height:height))
            for item in menu.items {
                let view = try XCTUnwrap(item.view as? ClassicMenuItemView)
                // AppKit keeps a menu item's view at origin zero. Place its
                // host at the row offset, as the native menu container does.
                let host = ClassicSurface(frame:NSRect(x:0,y:view.menuOffset,width:view.frame.width,height:view.frame.height))
                surface.addSubview(host); host.addSubview(view)
                XCTAssertEqual(host.frame.minY,view.menuOffset)
            }
            for scale in [1,2] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:(width*2+20)*scale,pixelsHigh:height*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                bitmap.size = surface.bounds.size; surface.cacheDisplay(in:surface.bounds,to:bitmap)
                // Second column explicitly exercises selected rendering without
                // opening a native menu or interacting with the desktop.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
                let transform = NSAffineTransform(); transform.translateX(by:0,yBy:CGFloat(height)); transform.scaleX(by:1,yBy:-1); transform.concat()
                NSGraphicsContext.current = NSGraphicsContext(cgContext:NSGraphicsContext.current!.cgContext,flipped:true)
                for item in menu.items {
                    let view = item.view as! ClassicMenuItemView
                    let rect = NSRect(x:width+20,y:Int(view.menuOffset),width:width,height:Int(view.frame.height))
                    HAPMenuDrawing.background(rect)
                    let color = HAPMenuDrawing.row(rect,selected:true,enabled:item.isEnabled,separator:item.isSeparatorItem,first:view.first,last:view.last)
                    HAPMenuDrawing.content(item,in:rect,color:color,selected:true,layout:view.layout)
                }
                NSGraphicsContext.restoreGraphicsState()
                if let folder = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"] {
                    let url = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(appearance.name)-menus-\(layout)-\(scale)x.png"))
                }
            }
        } }
    }
}
