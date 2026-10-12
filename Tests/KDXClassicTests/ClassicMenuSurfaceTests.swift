import AppKit
import XCTest
@testable import KDXClassicUI

final class ClassicMenuSurfaceTests: XCTestCase {
    @MainActor func testOriginalContentGeometryHasNoNativeOuterPadding() throws {
        let menu = ClassicMenu(title:"Window")
        menu.addItem(menuItem("Open") {})
        menu.addItem(.separator())
        menu.addItem(menuItem("Close") {})
        let hidden = menuItem("Hidden") {}; hidden.isHidden = true; menu.addItem(hidden)
        let surface = ClassicMenuSurface(menu:menu,maximumHeight:1000)
        XCTAssertEqual(surface.frame.height,48)
        XCTAssertEqual(surface.contentHeight,48)
        XCTAssertEqual(surface.rows.map(\.frame.minY),[0,16,32])
        XCTAssertEqual(surface.rows.map(\.frame.minX),[0,0,0])
        XCTAssertTrue(surface.rows.allSatisfy { $0.frame.width == surface.bounds.width })
        XCTAssertEqual(surface.index(at:NSPoint(x:0,y:0)),0)
        XCTAssertEqual(surface.index(at:NSPoint(x:surface.bounds.maxX-1,y:47)),2)
        XCTAssertNil(surface.index(at:NSPoint(x:0,y:48)))
        XCTAssertEqual(surface.accessibilityRole(),.menu)
        menu.items[0].image = NSImage(size:NSSize(width:16,height:16))
        let icons = ClassicMenuSurface(menu:menu,maximumHeight:1000)
        XCTAssertEqual(icons.frame.height,54)
        XCTAssertTrue(icons.rows.allSatisfy { $0.layout == .sharedIcons })
    }
    @MainActor func testKeyboardSelectionSkipsIneligibleRowsAndRevealsScrolledItems() throws {
        let menu = ClassicMenu(title:"Choices")
        for index in 0..<10 { menu.addItem(menuItem("Choice \(index)") {}) }
        menu.items[1].isEnabled = false
        menu.items[2].isHidden = true
        menu.insertItem(.separator(),at:3)
        let surface = ClassicMenuSurface(menu:menu,maximumHeight:48)
        surface.move(1); XCTAssertEqual(surface.selectedItem?.title,"Choice 0")
        surface.move(1); XCTAssertEqual(surface.selectedItem?.title,"Choice 3")
        XCTAssertGreaterThan(surface.scrollOffset,0)
        surface.edge(last:true); XCTAssertEqual(surface.selectedItem?.title,"Choice 9")
        XCTAssertEqual(surface.scrollOffset,surface.contentHeight-48)
        surface.move(1); XCTAssertEqual(surface.selectedItem?.title,"Choice 0"); XCTAssertEqual(surface.scrollOffset,0)
        surface.move(-1); XCTAssertEqual(surface.selectedItem?.title,"Choice 9")
        surface.movePage(-1); XCTAssertEqual(surface.selectedItem?.title,"Choice 6")
        surface.movePage(1); XCTAssertEqual(surface.selectedItem?.title,"Choice 9")
        surface.scroll(by:-10000); XCTAssertEqual(surface.scrollOffset,0)
        surface.scroll(by:10000); XCTAssertEqual(surface.scrollOffset,surface.contentHeight-48)
        let index = try XCTUnwrap(surface.selectedIndex)
        surface.items[index].isEnabled = false; surface.select(index)
        XCTAssertNil(surface.selectedItem)
        XCTAssertTrue(surface.accessibilitySelectedChildren()?.isEmpty == true)
    }
    @MainActor func testTypingSelectionCyclesAndStartsNewPrefixAfterTimeout() {
        let menu = ClassicMenu(title:"Destinations")
        for title in ["Amber","Apple","Banana","Árbol","Unavailable"] { menu.addItem(menuItem(title) {}) }
        menu.items[4].isEnabled = false
        let surface = ClassicMenuSurface(menu:menu,maximumHeight:1000)
        surface.typeSelect("a",time:10); XCTAssertEqual(surface.selectedItem?.title,"Amber")
        surface.typeSelect("a",time:10.2); XCTAssertEqual(surface.selectedItem?.title,"Apple")
        surface.typeSelect("a",time:10.4); XCTAssertEqual(surface.selectedItem?.title,"Árbol")
        surface.typeSelect("ap",time:12); XCTAssertEqual(surface.selectedItem?.title,"Apple")
        surface.typeSelect("b",time:14); XCTAssertEqual(surface.selectedItem?.title,"Banana")
        surface.typeSelect("u",time:16); XCTAssertEqual(surface.selectedItem?.title,"Banana")
    }
    @MainActor func testScreenConfinementAndSubmenusOnNegativeCoordinateDisplay() {
        let screen = NSRect(x:-1280,y:-200,width:1280,height:800)
        let size = NSSize(width:180,height:160)
        XCTAssertEqual(ClassicMenuSurface.frame(size:size,topLeft:NSPoint(x:-20,y:580),screen:screen),NSRect(x:-180,y:420,width:180,height:160))
        XCTAssertEqual(ClassicMenuSurface.frame(size:size,topLeft:NSPoint(x:-1300,y:-190),screen:screen),NSRect(x:-1280,y:-200,width:180,height:160))
        let rightParent = NSRect(x:-180,y:0,width:180,height:100)
        XCTAssertEqual(ClassicMenuSurface.submenuFrame(size:size,parent:rightParent,rowTop:100,screen:screen).minX,-360)
        let leftParent = NSRect(x:-1280,y:0,width:180,height:100)
        XCTAssertEqual(ClassicMenuSurface.submenuFrame(size:size,parent:leftParent,rowTop:100,screen:screen).minX,-1100)
        XCTAssertEqual(ClassicMenuSurface.frame(size:NSSize(width:2000,height:2000),topLeft:.zero,screen:screen),screen)
    }
    @MainActor func testActionsRecheckIdentityAncestorsAndNativePopupSelection() throws {
        _ = NSApplication.shared
        let root = ClassicMenu(title:"Root"), parent = menuItem("Server") {}, child = ClassicMenu(title:"Server")
        var calls = 0
        let action = menuItem("Files",key:"f") { calls += 1 }; action.keyEquivalentModifierMask = [.command]
        child.addItem(action); parent.submenu = child; root.addItem(parent)
        let event = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.command],timestamp:0,windowNumber:0,context:nil,characters:"f",charactersIgnoringModifiers:"f",isARepeat:false,keyCode:3))
        XCTAssertTrue(ClassicMenuTracking.keyEquivalent(event,in:root) === action)
        XCTAssertTrue(ClassicMenuTracking.canActivate(action,in:root))
        for disabled in [true,false] {
            parent.isEnabled = !disabled; parent.isHidden = !disabled
            XCTAssertFalse(ClassicMenuTracking.canActivate(action,in:root))
            XCTAssertNil(ClassicMenuTracking.keyEquivalent(event,in:root))
        }
        parent.isEnabled = true; parent.isHidden = false
        child.removeItem(action)
        XCTAssertFalse(ClassicMenuTracking.canActivate(action,in:root))
        XCTAssertEqual(calls,0)
        let popup = ClassicPopUpButton("Service")
        popup.addItems(withTitles:["Server","Tracker"])
        let target = Target { calls += 1 }; popup.target = target; popup.action = #selector(Target.invoke)
        let tracker = try XCTUnwrap(popup.item(at:1))
        XCTAssertTrue(popup.choose(tracker)); XCTAssertEqual(popup.indexOfSelectedItem,1); XCTAssertEqual(calls,1)
        tracker.isEnabled = false; XCTAssertFalse(popup.choose(tracker)); XCTAssertEqual(calls,1)
        tracker.isEnabled = true; popup.isEnabled = false; XCTAssertFalse(popup.choose(tracker))
        popup.isEnabled = true; popup.removeItem(at:1); XCTAssertFalse(popup.choose(tracker))
    }
    @MainActor func testPopupSurfaceRendersOriginalEdgesAndAccessibleRowsAtBothScales() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        style.appearance = ClassicAppearance(id:"menu-edges",name:"Menu edges",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test")
        let menu = ClassicMenu(title:"Actions")
        menu.addItem(menuItem("Open") {}); menu.addItem(menuItem("Disabled") {}); menu.items[1].isEnabled = false
        let surface = ClassicMenuSurface(menu:menu,maximumHeight:1000)
        surface.select(0)
        var activated: NSMenuItem?
        surface.activateItem = { item in activated = item; return true }
        XCTAssertTrue(surface.rows[0].accessibilityPerformPress()); XCTAssertTrue(activated === menu.items[0])
        XCTAssertTrue(surface.rows[0].isAccessibilityFocused()); XCTAssertFalse(surface.rows[1].isAccessibilityFocused())
        var canceled = false; surface.cancel = { canceled = true }
        XCTAssertTrue(surface.accessibilityPerformCancel()); XCTAssertTrue(canceled)
        XCTAssertEqual(surface.rows[0].accessibilityLabel(),"Open")
        XCTAssertFalse(surface.rows[1].isAccessibilityEnabled())
        XCTAssertFalse(surface.rows[1].accessibilityPerformPress())
        XCTAssertTrue(activated === menu.items[0])
        for scale in [1,2] {
            let width = Int(surface.frame.width), height = Int(surface.frame.height)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width*scale,pixelsHigh:height*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
            bitmap.size = surface.bounds.size; surface.cacheDisplay(in:surface.bounds,to:bitmap)
            for (x,y,slot) in [(0,0,108),(width-1,0,109),(0,5,108),(width-1,5,110),(0,20,104),(width-1,20,106),(1,height-1,106)] {
                XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),UInt32(slot)*0x010101,"\(x),\(y) at \(scale)x")
            }
        }
    }
    @MainActor func testImportedMenuSurfacesAtBothScales() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Set KDX_CLASSIC_REFERENCE for imported popup surfaces.") }
        let appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances.filter { ["Mach Lavender","Amber CRT"].contains($0.name) }
        let style = ClassicStyle.shared, oldFont = style.fontChoiceID
        defer { style.fontChoiceID = oldFont; style.appearance = .recovery; style.configureAssets([]) }
        style.fontChoiceID = nil
        for appearance in appearances {
            style.configureAssets([appearance]); style.appearance = appearance
            let menu = ClassicMenu(title:"Commands")
            for (index,title) in ["Connect…","Address Book","Files","Chat","Unavailable","Disconnect"].enumerated() {
                let item = menuItem(title,iconID:index == 2 ? 17 : nil) {}
                item.isEnabled = index != 4
                if index == 1 { item.state = .on }
                if index == 3 { item.submenu = ClassicMenu(title:"Rooms") }
                menu.addItem(item)
            }
            for layout in [HAPMenuLayout.standard,.sharedIcons] {
                menu.layoutOverride = layout
                let surface = ClassicMenuSurface(menu:menu,maximumHeight:1000); surface.select(2)
                for scale in [1,2] {
                    let width = Int(surface.frame.width), height = Int(surface.frame.height)
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width*scale,pixelsHigh:height*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                    bitmap.size = surface.bounds.size; surface.cacheDisplay(in:surface.bounds,to:bitmap)
                    let helper = HAPWindowTests()
                    XCTAssertEqual(try helper.color(bitmap,x:0,y:0),appearance.colors[104])
                    XCTAssertEqual(try helper.color(bitmap,x:(width-1)*scale,y:(height-1)*scale),appearance.colors[106])
                    if let folder = ProcessInfo.processInfo.environment["KDX_CLASSIC_RENDER_DIR"] {
                        let url = URL(fileURLWithPath:folder,isDirectory:true)
                        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(appearance.name)-popup-surface-\(layout)-\(scale)x.png"))
                    }
                }
            }
        }
    }
    @MainActor private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }
}
