import AppKit
import XCTest
@testable import KDXClassicUI

final class ClassicWindowRestorationTests: XCTestCase {
    @MainActor func testUnavailableAndChangedDisplaysPreserveOrConstrainSavedFrames() {
        let saved = NSRect(x:-1100,y:160,width:600,height:400)
        let fallback = NSRect(x:140,y:200,width:600,height:400)
        XCTAssertEqual(ClassicPreferences.constrain(saved,to:[],fallback:fallback),saved)
        XCTAssertEqual(ClassicPreferences.constrain(.zero,to:[],fallback:fallback),fallback)
        let remainingDisplay = NSRect(x:0,y:0,width:1440,height:900)
        let moved = ClassicPreferences.constrain(saved,to:[remainingDisplay],fallback:fallback)
        XCTAssertTrue(remainingDisplay.contains(moved))
        XCTAssertEqual(moved.size,saved.size)
        XCTAssertEqual(moved.minY,saved.minY)
    }

    @MainActor func testMovedWindowsRestoreWithFreshPreferencesAndControllers() throws {
        _ = NSApplication.shared
        let previous = ClassicStyle.shared.appearance
        ClassicStyle.shared.appearance = .recovery
        defer { ClassicStyle.shared.appearance = previous }
        let suite = "KDX-window-restoration-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let screen = NSScreen.screens.first?.visibleFrame ?? NSRect(x:0,y:0,width:1440,height:900)
        let factories: [(ClassicPreferences) -> ClassicWindowController] = [
            { ClassicButtonBarWindow(title:"KDX",compact:false,preferences:$0) },
            { ClassicButtonBarWindow(title:"KDX",compact:true,preferences:$0) },
            { ClassicConnectWindow(endpoint:.defaultTracker,saving:false,preferences:$0) },
            { ClassicWindowController(title:"Tracker",key:"tracker",size:NSSize(width:780,height:480),preferences:$0) }
        ]
        for create in factories {
            let first = create(ClassicPreferences(defaults:defaults))
            let window = try XCTUnwrap(first.window)
            let moved = NSRect(x:screen.minX+40,y:screen.maxY-window.frame.height-70,width:window.frame.width,height:window.frame.height)
            window.setFrame(moved,display:false)
            first.windowDidMove(Notification(name:NSWindow.didMoveNotification,object:window))
            let key = first.persistenceKey
            XCTAssertEqual(defaults.string(forKey:"frame."+key),NSStringFromRect(moved))
            XCTAssertFalse(window.isVisible)
            window.close()

            let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName:suite))
            let reopened = create(ClassicPreferences(defaults:reopenedDefaults))
            let restored = try XCTUnwrap(reopened.window)
            XCTAssertEqual(restored.frame,moved,"Restore position and size for \(key)")
            XCTAssertFalse(reopened.shouldCascadeWindows,"AppKit must not offset an explicitly restored frame")
            reopened.applyStyle()
            XCTAssertEqual(restored.frame,moved,"Applying the same theme must not move \(key)")
            XCTAssertFalse(restored.isVisible)
            restored.close()
        }
    }
}
