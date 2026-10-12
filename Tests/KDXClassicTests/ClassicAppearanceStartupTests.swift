import AppKit
import XCTest
@testable import KDXClassicUI

final class ClassicAppearanceStartupTests: XCTestCase {
    @MainActor private func withApplication(_ body: (ClassicApplication) throws -> Void) throws {
        _ = NSApplication.shared
        let suite = "KDX-appearance-startup-"+UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {
            defaults.removePersistentDomain(forName:suite)
            try? FileManager.default.removeItem(at:root)
            ClassicStyle.shared.appearance = .recovery; ClassicStyle.shared.configureAssets([])
        }
        let app = ClassicApplication(applicationName:"KDX Client",preferences:ClassicPreferences(root:root,defaults:defaults))
        try body(app)
        XCTAssertTrue(app.windows.isEmpty); XCTAssertTrue(app.utilityWindows.isEmpty)
        XCTAssertNil(app.bar,"Loading settings must not show a desktop window.")
    }
    @MainActor func testMissingAndCorruptCatalogRequireSetup() throws {
        try withApplication { app in
            XCTAssertTrue(app.loadAppearanceSettings())
            XCTAssertEqual(ClassicStyle.shared.appearance,.recovery)
            try FileManager.default.createDirectory(at:app.library.root,withIntermediateDirectories:true)
            try Data("corrupt".utf8).write(to:app.library.root.appendingPathComponent("catalog.json"))
            app.preferences.appearanceID = "missing"
            XCTAssertTrue(app.loadAppearanceSettings())
            XCTAssertEqual(ClassicStyle.shared.appearance,.recovery)
            XCTAssertEqual(try Data(contentsOf:app.library.root.appendingPathComponent("catalog.json")),Data("corrupt".utf8))
        }
    }
    @MainActor func testStandaloneHAPRestoresWithoutAnApplicationImport() throws {
        try withApplication { app in
            let imported = try AppearanceDecoder.hap(AppearanceTests().hap(),name:"Standalone")
            try app.library.install(imported)
            for saved in [nil,"missing",imported.appearances[0].id] as [String?] {
                app.preferences.appearanceID = saved
                XCTAssertFalse(app.loadAppearanceSettings())
                XCTAssertEqual(ClassicStyle.shared.appearance,imported.appearances[0],"An installed theme must not silently fall back to Recovery when its preference is missing.")
            }
            app.preferences.appearanceID = "recovery"
            XCTAssertFalse(app.loadAppearanceSettings(),"An intentional recovery selection does not mean the assets are missing.")
            XCTAssertEqual(ClassicStyle.shared.appearance,.recovery)
        }
    }
    @MainActor func testOriginalCatalogDefaultsToMachLavenderAndRestoresChoice() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Original application required") }
        try withApplication { app in
            let imported = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path))
            try app.library.install(imported)
            XCTAssertFalse(app.loadAppearanceSettings())
            XCTAssertEqual(ClassicStyle.shared.appearance.name,"Mach Lavender")
            XCTAssertEqual(ClassicStyle.shared.fontChoices.count,5)
            let amber = try XCTUnwrap(app.appearances.first { $0.name == "Amber CRT" })
            app.preferences.appearanceID = amber.id
            let font = try XCTUnwrap(ClassicStyle.shared.fontChoices.last)
            app.preferences.defaults.set(font.id,forKey:"font")
            XCTAssertFalse(app.loadAppearanceSettings())
            XCTAssertEqual(ClassicStyle.shared.appearance,amber)
            XCTAssertEqual(ClassicStyle.shared.fontChoiceID,font.id)
        }
    }
}
