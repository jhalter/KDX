import AppKit
import XCTest
@testable import KDXClientUI

final class ClassicBundledAppearancesTests: XCTestCase {
    private func reference() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Original application required") }
        return URL(fileURLWithPath:path)
    }
    func testExportRoundTripAndFailedReplacement() async throws {
        let source = try reference()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let catalog = root.appendingPathComponent("OriginalAppearances.json")
        try await ClassicBundledAppearances.export(from:source,to:catalog)
        let decoded = try ClassicBundledAppearances.load(from:catalog)
        XCTAssertEqual(decoded.count,16)
        XCTAssertTrue(decoded.allSatisfy { $0.fonts?.count == 4 && $0.chromeArtwork != nil && $0.artwork != nil })
        let saved = try Data(contentsOf:catalog)
        let invalid = root.appendingPathComponent("invalid.hap")
        try Data("invalid".utf8).write(to:invalid)
        do { try await ClassicBundledAppearances.export(from:invalid,to:catalog); XCTFail("Invalid source must fail") }
        catch { }
        XCTAssertEqual(try Data(contentsOf:catalog),saved)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:root.path)),["OriginalAppearances.json","invalid.hap"],"Export only the decoded catalog, not source archives, executables or intermediate assets.")
    }
    func testIncompleteCorruptAndOversizedCatalogsAreRejected() throws {
        let appearances = try ClassicAssetImporter.loadSync(reference()).appearances
        XCTAssertThrowsError(try ClassicBundledAppearances.decode(JSONEncoder().encode(Array(appearances.dropLast()))))
        var incomplete = appearances; incomplete[0].fonts = nil
        XCTAssertThrowsError(try ClassicBundledAppearances.decode(JSONEncoder().encode(incomplete)))
        XCTAssertThrowsError(try ClassicBundledAppearances.decode(Data("corrupt".utf8)))
        XCTAssertThrowsError(try ClassicBundledAppearances.decode(Data(repeating:0,count:4_000_000)))
    }
    @MainActor func testFreshInstallUsesAllBundledThemesAndMachLavenderWithoutWritingUserAssets() throws {
        _ = NSApplication.shared
        let appearances = try ClassicAssetImporter.loadSync(reference()).appearances
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let catalog = root.appendingPathComponent("OriginalAppearances.json")
        try JSONEncoder().encode(appearances).write(to:catalog)
        let suite = "KDX-bundled-startup-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        let preferences = ClassicPreferences(root:root.appendingPathComponent("UserData"),defaults:defaults)
        defer {
            defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root)
            ClassicStyle.shared.appearance = .recovery; ClassicStyle.shared.configureAssets([])
        }
        let app = ClassicApplication(applicationName:"KDX Client",preferences:preferences,bundledAppearancesURL:catalog)
        XCTAssertFalse(app.loadAppearanceSettings())
        XCTAssertEqual(app.appearances.count,17)
        XCTAssertEqual(ClassicStyle.shared.appearance.name,"Mach Lavender")
        XCTAssertEqual(ClassicStyle.shared.fontChoices.count,5)
        XCTAssertNotNil(ClassicStyle.shared.artwork?.icon(84,small:true))
        XCTAssertFalse(FileManager.default.fileExists(atPath:preferences.root.path),"Bundled themes must work before any Application Support import.")
        let amber = try XCTUnwrap(app.appearances.first { $0.name == "Amber CRT" })
        preferences.appearanceID = amber.id
        XCTAssertFalse(app.loadAppearanceSettings()); XCTAssertEqual(ClassicStyle.shared.appearance,amber)
        let custom = try AppearanceDecoder.hap(AppearanceTests().hap(),name:"Custom")
        try app.library.install(custom)
        preferences.appearanceID = custom.appearances[0].id
        XCTAssertFalse(app.loadAppearanceSettings()); XCTAssertEqual(app.appearances.count,18)
        XCTAssertEqual(ClassicStyle.shared.appearance,custom.appearances[0])
        XCTAssertNotNil(ClassicStyle.shared.artwork?.icon(84,small:true),"Custom themes retain bundled original icon fallback.")
        try Data("corrupt".utf8).write(to:app.library.root.appendingPathComponent("catalog.json"))
        XCTAssertFalse(app.loadAppearanceSettings()); XCTAssertEqual(app.appearances.count,17)
        XCTAssertEqual(ClassicStyle.shared.appearance.name,"Mach Lavender")
        XCTAssertTrue(app.windows.isEmpty); XCTAssertTrue(app.utilityWindows.isEmpty); XCTAssertNil(app.bar)
    }
    func testLocalCatalogCanReplaceBundledEntryWithoutDuplicates() throws {
        let originals = try ClassicAssetImporter.loadSync(reference()).appearances
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let library = AppearanceLibrary(root:root)
        try library.install(AppearanceImport(appearances:[originals[0]],assets:[:]))
        let merged = library.load(bundled:originals)
        XCTAssertEqual(merged.count,17); XCTAssertEqual(Set(merged.map(\.id)).count,17)
        XCTAssertEqual(library.load().count,2,"Read-only bundle assets must not be copied into user storage by an unrelated import.")
    }
}
