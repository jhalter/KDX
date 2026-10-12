import AppKit
import XCTest
@testable import KDXClientUI

final class ClassicDockTests: XCTestCase {
    @MainActor private func withPreferences(_ run: (ClassicPreferences) throws -> Void) throws {
        _ = NSApplication.shared
        let suite = "KDX-dock-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        try run(ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults))
    }
    @MainActor private func owner(_ title: String, _ preferences: ClassicPreferences) -> ClassicWindowController {
        ClassicWindowController(title:title,key:UUID().uuidString,size:NSSize(width:400,height:260),preferences:preferences)
    }
    @MainActor func testOrderedIdentityAndExactRestorationTarget() throws {
        try withPreferences { preferences in
            let a = owner("Same title",preferences), b = owner("Same title",preferences), c = owner("Alphabetically first",preferences)
            var state = ClassicDockState()
            state.add(a); state.add(b); state.add(a); state.add(c)
            XCTAssertEqual(state.controllers.map(ObjectIdentifier.init),[a,b,c].map(ObjectIdentifier.init))
            let view = ClassicDockView()
            var restored = [ObjectIdentifier]()
            view.update(state.controllers) { restored.append(ObjectIdentifier($0)); state.remove($0) }
            XCTAssertEqual(view.frame.size,NSSize(width:200,height:66))
            for (index,button) in view.buttons.enumerated() {
                XCTAssertEqual(button.frame,NSRect(x:0,y:index*22,width:200,height:22))
                XCTAssertEqual(button.accessibilityRole(),.button)
                XCTAssertTrue(button.nextKeyView === view.buttons[(index+1)%3])
            }
            view.buttons[1].performClick(nil)
            XCTAssertEqual(restored,[ObjectIdentifier(b)])
            XCTAssertEqual(state.controllers.map(ObjectIdentifier.init),[a,c].map(ObjectIdentifier.init))
            state.remove(a); state.add(b)
            XCTAssertEqual(state.controllers.map(ObjectIdentifier.init),[c,b].map(ObjectIdentifier.init))
            view.update(state.controllers) { restored.append(ObjectIdentifier($0)) }
            view.buttons[0].isEnabled = false; view.buttons[0].performClick(nil)
            XCTAssertEqual(restored,[ObjectIdentifier(b)])
            for controller in [a,b,c] { XCTAssertFalse(try XCTUnwrap(controller.window).isVisible) }
        }
    }
    @MainActor func testDockFitsRowsRestoresSmallFrameAndCannotHideItsEntries() throws {
        let style = ClassicStyle.shared; style.appearance = .recovery
        defer { style.appearance = .recovery }
        try withPreferences { preferences in
            preferences.save(frame:NSRect(x:260,y:240,width:212,height:50),key:"dock")
            let screen = NSRect(x:0,y:0,width:800,height:600)
            XCTAssertEqual(preferences.frame(key:"dock",fallback:NSRect(x:0,y:0,width:212,height:50),screens:[screen],minimumSize:NSSize(width:1,height:1)),NSRect(x:260,y:240,width:212,height:50))
            let dock = ClassicDockWindow(preferences:preferences), a = owner("Users",preferences)
            dock.update([a]) { _ in XCTFail("Fitting must not restore a window") }
            dock.fitDock(screens:[screen])
            let window = try XCTUnwrap(dock.window)
            XCTAssertEqual(window.frame.size,NSSize(width:212,height:50))
            XCTAssertEqual(dock.chrome.content.bounds.size,NSSize(width:200,height:22))
            XCTAssertEqual(dock.entries.buttons[0].frame,NSRect(x:0,y:0,width:200,height:22))
            XCTAssertTrue(dock.chrome.buttons.allSatisfy(\.isHidden))
            XCTAssertFalse(dock.scroll.hasVerticalScroller); XCTAssertFalse(dock.chrome.allowsResize)
            XCTAssertTrue(dock.windowMenu.items.isEmpty)
            let before = window.frame
            dock.requestClose(); dock.minimize(); dock.maximize()
            XCTAssertEqual(dock.entries.buttons.count,1); XCTAssertEqual(window.frame,before)
            let many = (0..<35).map { owner("Window \($0)",preferences) }
            dock.update(many) { _ in }
            dock.fitDock(screens:[screen])
            XCTAssertTrue(screen.contains(window.frame)); XCTAssertTrue(dock.scroll.hasVerticalScroller)
            XCTAssertEqual(dock.entries.frame.height,35*22)
            XCTAssertEqual(dock.entries.buttons.last?.frame.maxY,35*22)
            XCTAssertGreaterThan(dock.entries.frame.height,dock.scroll.contentSize.height)
            dock.update([a]) { _ in }; dock.fitDock(screens:[screen])
            XCTAssertFalse(dock.scroll.hasVerticalScroller); XCTAssertEqual(window.frame.size,NSSize(width:212,height:50))
            XCTAssertFalse(window.isVisible)
        }
    }
    @MainActor func testReferenceGeometryAndOffscreenDockAppearances() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Original application required") }
        let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
        for (address,opcode) in [(0xb9b64,0x388000c8),(0xb9c2c,0x1fdc0016),(0xb9c24,0x3860000a),(0xba710,0x1fc00016),(0xba788,0x38a00050),(0x9ac60,0x3803000a),(0x9ac74,0x3863fffd)] {
            XCTAssertEqual(try bytes.u32(address+0x1de0),opcode)
        }
        let appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared; style.configureAssets(appearances)
        defer { style.appearance = .recovery; style.configureAssets([]) }
        try withPreferences { preferences in
            let items = [owner("Chat — Example Server",preferences),owner("Files — /Software",preferences),owner("Users — Other Server",preferences)]
            for appearance in appearances {
                style.appearance = appearance
                let dock = ClassicDockWindow(preferences:preferences)
                dock.update(items) { _ in }; dock.chrome.layoutSubtreeIfNeeded()
                XCTAssertEqual(dock.chrome.bounds.size,NSSize(width:212,height:94))
                dock.entries.buttons[1].highlight(true)
                dock.entries.buttons[2].isEnabled = false
                for scale in [1,2] {
                    let bitmap = try HAPTextFieldTests().raster(dock.chrome,scale:scale)
                    for (row,slot) in [31,38,45].enumerated() {
                        XCTAssertEqual(try HAPWindowTests().color(bitmap,x:200*scale,y:(22+row*22+10)*scale),appearance.colors[slot],"\(appearance.name), row \(row), \(scale)x")
                    }
                    if let folder = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"] {
                        let root = URL(fileURLWithPath:folder,isDirectory:true)
                        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("\(appearance.name)-dock-\(scale)x.png"))
                    }
                }
                XCTAssertFalse(try XCTUnwrap(dock.window).isVisible)
            }
        }
    }
    @MainActor func testExternalSkinStatesAndFrameInsets() throws {
        let style = ClassicStyle.shared, helper = HAPArtworkTests()
        defer { style.appearance = .recovery }
        var skins = [UInt8](helper.skinSection())
        helper.put(0,64+9*4,in:&skins); helper.put(2112,64+33*4,in:&skins)
        style.appearance = ClassicAppearance(id:"dock-skin",name:"Dock skin",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test",artwork:try HAPArtwork(skins:Data(skins),icons:Data()))
        let raster = HAPWindowTests()
        for scale in [1,2] { for (pressed,enabled,expected): (Bool,Bool,UInt32) in [(false,true,0x0000ff),(true,true,0x262626),(false,false,0x2d2d2d)] {
            let bitmap = try raster.render(scale:scale,width:200,height:22) {
                HAPDockDrawing.button(NSRect(x:0,y:0,width:200,height:22),title:"",pressed:pressed,enabled:enabled)
            }
            XCTAssertEqual(try raster.color(bitmap,x:80*scale,y:10*scale),expected,"Missing state skins must use that state's palette.")
        } }
        style.appearance.artwork = try raster.syntheticSkins()
        try withPreferences { preferences in
            let dock = ClassicDockWindow(preferences:preferences)
            dock.update([owner("Files",preferences)]) { _ in }
            XCTAssertEqual(dock.window?.frame.size,NSSize(width:215,height:57))
            XCTAssertEqual(dock.chrome.content.frame,NSRect(x:7,y:26,width:200,height:22))
            XCTAssertTrue(dock.chrome.buttons.allSatisfy(\.isHidden))
            XCTAssertFalse(try XCTUnwrap(dock.window).isVisible)
        }
    }
}
