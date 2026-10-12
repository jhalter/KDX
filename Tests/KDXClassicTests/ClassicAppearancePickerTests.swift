import AppKit
import XCTest
@testable import KDXClassicUI

final class ClassicAppearancePickerTests: XCTestCase {
    @MainActor private func withApplication(_ body: (ClassicApplication) throws -> Void) throws {
        _ = NSApplication.shared
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Original application required") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let catalog = root.appendingPathComponent("OriginalAppearances.json")
        try JSONEncoder().encode(ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances).write(to:catalog)
        let suite = "KDX-appearance-picker-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        let preferences = ClassicPreferences(root:root.appendingPathComponent("UserData"),defaults:defaults)
        defer {
            defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root)
            ClassicStyle.shared.appearance = .recovery; ClassicStyle.shared.configureAssets([])
        }
        let app = ClassicApplication(applicationName:"KDX Client",preferences:preferences,bundledAppearancesURL:catalog)
        XCTAssertFalse(app.loadAppearanceSettings())
        app.bar = ClassicWindowController(title:"Bar",key:"bar",size:NSSize(width:300,height:200),preferences:preferences)
        try body(app)
        XCTAssertFalse(try XCTUnwrap(app.bar.window).isVisible)
        for controller in app.utilityWindows.values { XCTAssertFalse(try XCTUnwrap(controller.window).isVisible) }
    }
    @MainActor private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views($0) } }
    @MainActor private func button(_ title: String, in controller: ClassicWindowController) throws -> ClassicButton {
        try XCTUnwrap(views(controller.chrome).compactMap { $0 as? ClassicButton }.first { $0.title == title })
    }
    @MainActor private func picker(_ title: String, in controller: ClassicWindowController) throws -> ClassicPopUpButton {
        try XCTUnwrap(views(controller.chrome).compactMap { $0 as? ClassicPopUpButton }.first { $0.accessibilityLabel() == title })
    }
    @MainActor func testApplySaveCancelAndRestartRestoreRealPickerSelections() throws {
        try withApplication { app in
            let window = app.makeAppearanceWindow(); app.utilityWindows["appearances"] = window
            let themes = try picker("Appearance",in:window), fonts = try picker("Font",in:window)
            XCTAssertEqual(themes.numberOfItems,17); XCTAssertEqual(fonts.numberOfItems,6)
            XCTAssertEqual(themes.titleOfSelectedItem,"Mach Lavender")
            XCTAssertTrue(fonts.isEnabled)
            let amber = try XCTUnwrap(themes.item(withTitle:"Amber CRT"))
            XCTAssertTrue(themes.choose(amber))
            XCTAssertEqual(ClassicStyle.shared.appearance.name,"Mach Lavender","Selection remains staged until Apply or Save.")
            let fontItem = try XCTUnwrap(fonts.item(at:fonts.numberOfItems-1))
            XCTAssertTrue(fonts.choose(fontItem))
            try button("Apply",in:window).performClick(nil)
            XCTAssertEqual(ClassicStyle.shared.appearance.name,"Amber CRT")
            XCTAssertEqual(app.preferences.appearanceID,amber.representedObject as? String)
            XCTAssertEqual(app.preferences.defaults.string(forKey:"font"),fontItem.representedObject as? String)
            let blue = try XCTUnwrap(themes.item(withTitle:"Blue Jeans"))
            XCTAssertTrue(themes.choose(blue))
            try button("Cancel",in:window).performClick(nil)
            XCTAssertEqual(ClassicStyle.shared.appearance.name,"Amber CRT")
            XCTAssertFalse(app.loadAppearanceSettings())
            XCTAssertEqual(ClassicStyle.shared.appearance.name,"Amber CRT")
            let reopened = app.makeAppearanceWindow(); app.utilityWindows["appearances"] = reopened
            let reopenedPicker = try picker("Appearance",in:reopened)
            XCTAssertEqual(reopenedPicker.titleOfSelectedItem,"Amber CRT")
            XCTAssertTrue(reopenedPicker.choose(try XCTUnwrap(reopenedPicker.item(withTitle:"Blue Jeans"))))
            try button("Save",in:reopened).performClick(nil)
            XCTAssertFalse(app.loadAppearanceSettings()); XCTAssertEqual(ClassicStyle.shared.appearance.name,"Blue Jeans")
        }
    }
    @MainActor func testPickerOffscreenAcrossBundledThemes() throws {
        try withApplication { app in
            let window = app.makeAppearanceWindow(); app.utilityWindows["appearances"] = window
            let themes = try picker("Appearance",in:window), apply = try button("Apply",in:window)
            for name in ["Mach Lavender","Amber CRT","The Dream Scheme (Green)"] {
                XCTAssertTrue(themes.choose(try XCTUnwrap(themes.item(withTitle:name))))
                apply.performClick(nil); window.chrome.layoutSubtreeIfNeeded()
                let content = window.chrome.content
                for control in views(content).filter({ $0 is ClassicPopUpButton || $0 is ClassicButton || $0 is ClassicCheckbox }) {
                    let frame = control.convert(control.bounds,to:content)
                    XCTAssertTrue(content.bounds.contains(frame),"\(name): \(control) must fit the Appearance window")
                }
                for scale in [1,2] {
                    let bitmap = try HAPTextFieldTests().raster(window.chrome,scale:scale)
                    if let folder = ProcessInfo.processInfo.environment["KDX_CLASSIC_RENDER_DIR"] {
                        let root = URL(fileURLWithPath:folder,isDirectory:true)
                        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("\(name)-appearance-picker-\(scale)x.png"))
                    }
                }
            }
        }
    }
}
