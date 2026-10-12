import AppKit
import XCTest
@testable import KDXClassicUI

final class ClassicMenuTrackingTests: XCTestCase {
    @MainActor private final class Host: ClassicMenuHosting {
        let surface: ClassicMenuSurface
        let frame: NSRect
        var displays = 0, closes = 0
        var onClose: (() -> Void)?
        init(_ surface: ClassicMenuSurface, _ frame: NSRect) { self.surface = surface; self.frame = frame; surface.frame.size = frame.size }
        func displayIfNeeded() { displays += 1 }
        func close() { closes += 1; onClose?() }
        func point(row: Int) -> NSPoint { NSPoint(x:frame.minX+10,y:frame.maxY-surface.rows[row].frame.midY) }
    }
    @MainActor private final class Harness {
        var hosts: [Host] = []
        var engine: ClassicMenuTracking!
        init(openingMouseDown: Bool = false, screen: NSRect = NSRect(x:0,y:0,width:1000,height:800), pointer: NSPoint = NSPoint(x:10,y:100)) {
            engine = ClassicMenuTracking(screen:screen,initialPointer:pointer,openingMouseDown:openingMouseDown) { [unowned self] surface, frame in
                let host = Host(surface,frame); hosts.append(host); return host
            }
        }
        func open(_ menu: ClassicMenu, at point: NSPoint = NSPoint(x:10,y:100)) { engine.start(menu:menu,at:point) }
        func mouse(_ type: NSEvent.EventType, at point: NSPoint, time: TimeInterval = 1) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:time,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:0))
            engine.handle(event,pointer:point,time:time)
        }
        @discardableResult func key(_ code: UInt16, text: String = "", flags: NSEvent.ModifierFlags = [], time: TimeInterval = 1) throws -> ClassicMenuTracking.EventDisposition {
            let event = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:time,windowNumber:0,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code))
            return engine.handle(event,pointer:.zero,time:time)
        }
    }
    @MainActor func testOpeningReleaseKeepsMenuOpenAndLaterClickSelectsWithoutDispatch() throws {
        _ = NSApplication.shared
        let harness = Harness(openingMouseDown:true), menu = ClassicMenu(title:"Context")
        var calls = 0
        menu.addItem(menuItem("Open") {
            XCTAssertTrue(harness.hosts.allSatisfy { $0.closes == 1 })
            calls += 1
        })
        harness.open(menu)
        XCTAssertEqual(harness.hosts.count,1)
        XCTAssertNil(harness.hosts[0].surface.window,"The event tests must never construct desktop windows.")
        try harness.mouse(.leftMouseUp,at:NSPoint(x:10,y:100))
        XCTAssertFalse(harness.engine.finished); XCTAssertNil(harness.engine.result)
        let point = harness.hosts[0].point(row:0)
        try harness.mouse(.leftMouseDown,at:point); try harness.mouse(.leftMouseUp,at:point)
        XCTAssertTrue(harness.engine.finished); XCTAssertTrue(harness.engine.result === menu.items[0]); XCTAssertEqual(calls,0)
        harness.engine.close(); harness.engine.close()
        menu.performActionForItem(at:0); XCTAssertEqual(calls,1)
        XCTAssertEqual(harness.hosts[0].closes,1)
    }
    @MainActor func testDragReleaseOutsideAndOutsideClickCancel() throws {
        for drag in [false,true] {
            let harness = Harness(openingMouseDown:true), menu = ClassicMenu(title:"Context")
            menu.addItem(menuItem("Open") {}); harness.open(menu)
            let outside = NSPoint(x:900,y:700)
            if drag { try harness.mouse(.leftMouseDragged,at:outside); XCTAssertFalse(harness.engine.finished) }
            try harness.mouse(drag ? .leftMouseUp : .rightMouseDown,at:outside)
            XCTAssertTrue(harness.engine.finished); XCTAssertNil(harness.engine.result)
            harness.engine.close(); XCTAssertEqual(harness.hosts[0].closes,1)
        }
    }
    @MainActor func testKeyboardSubmenusSkipDisabledRowsAndCloseBeforeAction() throws {
        let harness = Harness(), root = ClassicMenu(title:"Servers"), child = ClassicMenu(title:"Server")
        let unavailable = menuItem("Offline") {}; unavailable.isEnabled = false; root.addItem(unavailable)
        let parent = menuItem("Server") {}; parent.submenu = child; root.addItem(parent)
        let disabled = menuItem("Unavailable") {}; disabled.isEnabled = false; child.addItem(disabled)
        let leaf = menuItem("Files") {}; child.addItem(leaf)
        harness.open(root)
        try harness.key(125); XCTAssertTrue(harness.hosts[0].surface.selectedItem === parent)
        try harness.key(124); XCTAssertEqual(harness.hosts.count,2); XCTAssertTrue(harness.hosts[1].surface.selectedItem === leaf)
        try harness.key(123); XCTAssertEqual(harness.hosts[1].closes,1); XCTAssertFalse(harness.engine.finished)
        try harness.key(124); XCTAssertEqual(harness.hosts.count,3)
        var order: [Int] = []; harness.hosts[0].onClose = { order.append(0) }; harness.hosts[2].onClose = { order.append(2) }
        try harness.key(76)
        XCTAssertTrue(harness.engine.finished); XCTAssertTrue(harness.engine.result === leaf)
        harness.engine.close(); XCTAssertEqual(order,[2,0])
    }
    @MainActor func testHoverDelayOpensSubmenuAndTrackingFlushesRedraws() throws {
        let harness = Harness(), root = ClassicMenu(title:"Root"), child = ClassicMenu(title:"Child")
        child.addItem(menuItem("Files") {}); let parent = menuItem("Server") {}; parent.submenu = child; root.addItem(parent)
        harness.open(root)
        let point = harness.hosts[0].point(row:0)
        try harness.mouse(.mouseMoved,at:point,time:1)
        harness.engine.tick(pointer:point,time:1.19); XCTAssertEqual(harness.hosts.count,1)
        harness.engine.tick(pointer:point,time:1.21); XCTAssertEqual(harness.hosts.count,2)
        XCTAssertGreaterThan(harness.hosts[0].displays,1); XCTAssertGreaterThan(harness.hosts[1].displays,0)
        let childPoint = harness.hosts[1].point(row:0)
        try harness.mouse(.leftMouseUp,at:childPoint,time:2)
        XCTAssertTrue(harness.engine.result === child.items[0])
        let count = harness.hosts.reduce(0) { $0+$1.displays }
        harness.engine.tick(pointer:point,time:3)
        XCTAssertEqual(harness.hosts.reduce(0) { $0+$1.displays },count,"Finished tracking must not reopen or repaint menus.")
        harness.engine.close()
    }
    @MainActor func testEdgeScrollingAndKeyboardPagingUseTheVisibleViewport() throws {
        let harness = Harness(screen:NSRect(x:0,y:0,width:200,height:64)), menu = ClassicMenu(title:"Long menu")
        for index in 0..<20 { menu.addItem(menuItem("Row \(index)") {}) }
        harness.open(menu,at:NSPoint(x:0,y:64))
        let host = harness.hosts[0], bottom = NSPoint(x:10,y:2)
        try harness.mouse(.mouseMoved,at:bottom,time:1)
        harness.engine.tick(pointer:bottom,time:1); XCTAssertEqual(host.surface.scrollOffset,16)
        XCTAssertEqual(host.surface.selectedIndex,4)
        harness.engine.tick(pointer:bottom,time:1.04); XCTAssertEqual(host.surface.scrollOffset,16)
        harness.engine.tick(pointer:bottom,time:1.09); XCTAssertEqual(host.surface.scrollOffset,32)
        XCTAssertEqual(host.surface.selectedIndex,5)
        try harness.key(115); XCTAssertEqual(host.surface.selectedIndex,0); XCTAssertEqual(host.surface.scrollOffset,0)
        try harness.key(121); XCTAssertEqual(host.surface.selectedIndex,4); XCTAssertGreaterThan(host.surface.scrollOffset,0)
        try harness.key(116); XCTAssertEqual(host.surface.selectedIndex,0)
        try harness.key(53); XCTAssertTrue(harness.engine.finished); XCTAssertNil(harness.engine.result)
        harness.engine.close()
    }
    @MainActor func testKeyboardEquivalentsOrRepostingNeverDispatchWhileMenusAreOpen() throws {
        for functionKey in [false,true] { for matching in [false,true] {
            let harness = Harness(), menu = ClassicMenu(title:"Commands")
            let text = functionKey ? String(UnicodeScalar(NSF1FunctionKey)!) : "q"
            let flags: NSEvent.ModifierFlags = functionKey ? [] : [.command]
            let item = menuItem("Command",key:matching ? text : "x") {}
            item.keyEquivalentModifierMask = flags; menu.addItem(item); harness.open(menu)
            let result = try harness.key(functionKey ? 122 : 12,text:text,flags:flags)
            XCTAssertTrue(harness.engine.finished)
            if matching { XCTAssertEqual(result,.consumed); XCTAssertTrue(harness.engine.result === item) }
            else { XCTAssertEqual(result,.repostAfterClosing); XCTAssertNil(harness.engine.result) }
            XCTAssertEqual(harness.hosts[0].closes,0)
            harness.engine.close(); XCTAssertEqual(harness.hosts[0].closes,1)
        } }
    }
    @MainActor func testDiagonalSubmenuTraversalKeepsParentUntilEntryOrTimeout() throws {
        for action in ["enter","wait","click"] {
            let harness = Harness(), root = ClassicMenu(title:"Servers"), child = ClassicMenu(title:"Actions")
            for index in 0..<8 { child.addItem(menuItem("Action \(index)") {}) }
            let parent = menuItem("Server") {}; parent.submenu = child; root.addItem(parent)
            root.addItem(menuItem("Other server") {})
            harness.open(root,at:NSPoint(x:10,y:300))
            let origin = harness.hosts[0].point(row:0)
            try harness.mouse(.mouseMoved,at:origin,time:1); try harness.key(124)
            let crossing = NSPoint(x:harness.hosts[0].frame.maxX-2,y:harness.hosts[0].frame.maxY-24)
            try harness.mouse(.mouseMoved,at:crossing,time:1.1)
            XCTAssertTrue(harness.hosts[0].surface.selectedItem === parent)
            XCTAssertEqual(harness.hosts[1].closes,0)
            if action == "enter" {
                let target = harness.hosts[1].point(row:5)
                try harness.mouse(.mouseMoved,at:target,time:1.2)
                try harness.mouse(.leftMouseUp,at:target,time:1.21)
                XCTAssertTrue(harness.engine.result === child.items[5])
            } else if action == "click" {
                try harness.mouse(.leftMouseDown,at:crossing,time:1.2)
                try harness.mouse(.leftMouseUp,at:crossing,time:1.21)
                XCTAssertTrue(harness.engine.result === root.items[1])
                XCTAssertEqual(harness.hosts[1].closes,1)
            } else {
                harness.engine.tick(pointer:crossing,time:1.36)
                XCTAssertTrue(harness.hosts[0].surface.selectedItem === root.items[1])
                XCTAssertEqual(harness.hosts[1].closes,1)
            }
            harness.engine.close()
        }
        let parent = NSRect(x:200,y:200,width:100,height:100), left = NSRect(x:100,y:100,width:100,height:200)
        XCTAssertTrue(ClassicMenuTracking.aimsAtSubmenu(from:NSPoint(x:280,y:280),through:NSPoint(x:205,y:210),parent:parent,child:left))
        XCTAssertFalse(ClassicMenuTracking.aimsAtSubmenu(from:NSPoint(x:280,y:280),through:NSPoint(x:290,y:210),parent:parent,child:left))
        XCTAssertFalse(ClassicMenuTracking.aimsAtSubmenu(from:NSPoint(x:280,y:280),through:NSPoint(x:205,y:50),parent:parent,child:left))
    }
    @MainActor func testRemovedRowsCannotBePickedAndAccessibilityCancelEndsTracking() throws {
        let harness = Harness(), menu = ClassicMenu(title:"Server")
        let item = menuItem("Files") {}; menu.addItem(item); harness.open(menu)
        let surface = harness.hosts[0].surface, point = harness.hosts[0].point(row:0)
        menu.removeItem(item); menu.addItem(menuItem("Different action") {})
        try harness.mouse(.leftMouseDown,at:point); try harness.mouse(.leftMouseUp,at:point)
        XCTAssertNil(harness.engine.result)
        XCTAssertFalse(surface.rows[0].accessibilityPerformPress())
        XCTAssertTrue(surface.accessibilityPerformCancel()); XCTAssertTrue(harness.engine.finished)
        harness.engine.close()
    }
}
