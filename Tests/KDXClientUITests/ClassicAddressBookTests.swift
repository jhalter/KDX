import AppKit
import XCTest
@testable import KDXClientUI

final class ClassicAddressBookTests: XCTestCase {
    @MainActor private class HeadlessBook: ClassicAddressBookWindow {
        var errors: [Error] = []
        override func showError(_ error: Error) { errors.append(error) }
    }
    @MainActor private func withPreferences(_ body: (ClassicPreferences) throws -> Void) throws {
        _ = NSApplication.shared
        let suite = "KDX-address-book-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        try body(ClassicPreferences(root:root,defaults:defaults))
    }
    private func endpoint(_ host: String) -> ClassicEndpoint {
        var value = ClassicEndpoint(); value.name = "Same name"; value.host = host; return value
    }
    @MainActor func testOriginalGeometryAndImportedInsets() throws {
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery }
        if let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] {
            let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
            for (address,opcode) in [(0xaa8c,0x3900010e),(0xaa94,0x380000c8),(0xab58,0x3900010e),(0xab5c,0x380000c8),(0xaaf4,0x38800064),(0xaaf8,0x38a00050)] {
                XCTAssertEqual(try bytes.u32(address+0x1de0),opcode)
            }
        }
        for external in [false,true] {
            style.appearance = external ? ClassicAppearance(id:"frame",name:"Frame",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test",artwork:try HAPWindowTests().syntheticSkins()) : .recovery
            try withPreferences { preferences in
                let book = HeadlessBook(preferences:preferences)
                book.chrome.layoutSubtreeIfNeeded()
                XCTAssertEqual(book.list.frame,NSRect(x:0,y:0,width:270,height:200))
                XCTAssertEqual(book.window?.frame.size,NSSize(width:external ? 285 : 282,height:external ? 235 : 228))
                XCTAssertEqual(book.window?.minSize,NSSize(width:external ? 115 : 112,height:external ? 115 : 108))
                XCTAssertTrue(book.window?.initialFirstResponder === book.list.table)
                XCTAssertFalse(try XCTUnwrap(book.window).isVisible)
                XCTAssertTrue(book.errors.isEmpty)
            }
        }
    }
    @MainActor func testActionsSelectionIdentityAndConcurrentEditorSaves() throws {
        try withPreferences { preferences in
            let a = endpoint("a.example"), b = endpoint("b.example")
            try preferences.save(endpoints:[a,b])
            let book = HeadlessBook(preferences:preferences)
            let menu = try XCTUnwrap(book.list.table.menu)
            XCTAssertEqual(menu.items.map(\.title),["New…","Edit…","Connect…","Delete"])
            XCTAssertFalse(menu.items[1].isEnabled)
            var edited: ClassicEndpoint?, connected: ClassicEndpoint?
            book.editEndpoint = { edited = $0 }; book.connectEndpoint = { connected = $0 }
            book.list.table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
            XCTAssertTrue(menu.items[1].isEnabled)
            menu.performActionForItem(at:1); menu.performActionForItem(at:2)
            XCTAssertEqual(edited,b); XCTAssertEqual(connected,b)
            let other = HeadlessBook(preferences:preferences)
            var renamed = a; renamed.name = "Changed elsewhere"
            try other.save(renamed)
            var updated = b; updated.login = "member"
            try book.save(updated)
            XCTAssertEqual(try preferences.endpoints(),[renamed,updated])
            XCTAssertEqual(book.selectedEndpoint,updated)
            book.deleteSelected()
            XCTAssertEqual(try preferences.endpoints(),[renamed])
            XCTAssertNil(book.selectedEndpoint); XCTAssertFalse(menu.items[2].isEnabled)
            other.reload(); XCTAssertEqual(other.endpoints,[renamed])
            XCTAssertTrue(book.errors.isEmpty); XCTAssertTrue(other.errors.isEmpty)
        }
    }
    @MainActor func testFailedWritesPreserveBookAndControllerReleases() throws {
        try withPreferences { preferences in
            let a = endpoint("a.example")
            try preferences.save(endpoints:[a])
            weak var released: ClassicAddressBookWindow?
            try autoreleasepool {
                let book = HeadlessBook(preferences:preferences); released = book
                book.list.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
                try Data("corrupt".utf8).write(to:preferences.root.appendingPathComponent("address-book.json"))
                XCTAssertThrowsError(try book.save(endpoint("new.example")))
                XCTAssertEqual(book.endpoints,[a])
                book.deleteSelected(); XCTAssertEqual(book.errors.count,1)
                XCTAssertEqual(book.endpoints,[a])
                XCTAssertEqual(try Data(contentsOf:preferences.root.appendingPathComponent("address-book.json")),Data("corrupt".utf8))
                book.requestClose()
            }
            XCTAssertNil(released,"Menu actions and list callbacks must not retain a closed book.")
        }
    }
    @MainActor func testReferenceThemesRenderAtBothScalesAndKeepSavedSize() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Original application required") }
        let appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared; style.configureAssets(appearances)
        defer { style.appearance = .recovery; style.configureAssets([]) }
        try withPreferences { preferences in
            try preferences.save(endpoints:[endpoint("alpha.example"),endpoint("beta.example")])
            for appearance in appearances where ["Mach Lavender","Amber CRT"].contains(appearance.name) {
                style.appearance = appearance
                let book = HeadlessBook(preferences:preferences)
                book.chrome.layoutSubtreeIfNeeded()
                book.list.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
                for scale in [1,2] {
                    let bitmap = try HAPTextFieldTests().raster(book.chrome,scale:scale)
                    XCTAssertEqual(bitmap.pixelsWide,282*scale); XCTAssertEqual(bitmap.pixelsHigh,228*scale)
                    if let folder = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"] {
                        let root = URL(fileURLWithPath:folder,isDirectory:true)
                        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("\(appearance.name)-address-book-\(scale)x.png"))
                    }
                }
                XCTAssertFalse(try XCTUnwrap(book.window).isVisible)
            }
            preferences.save(frame:NSRect(x:100,y:100,width:640,height:380),key:"address-book")
            let saved = preferences.frame(key:"address-book",fallback:.zero,screens:[NSRect(x:0,y:0,width:1000,height:800)])
            XCTAssertEqual(saved.size,NSSize(width:640,height:380))
            let expected = preferences.frame(key:"address-book",fallback:NSRect(x:140,y:200,width:282,height:228),screens:NSScreen.screens.map(\.visibleFrame))
            let restored = HeadlessBook(preferences:preferences)
            XCTAssertEqual(restored.window?.frame.size,expected.size)
        }
    }
}
