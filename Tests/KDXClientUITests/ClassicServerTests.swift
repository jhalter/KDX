import AppKit
import XCTest
@testable import KDXClientUI
@testable import KDXCore

final class ClassicServerTests: XCTestCase {
    private func reference() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["KDX_SERVER_REFERENCE"] else { throw XCTSkip("Set KDX_SERVER_REFERENCE to the original server app or executable") }
        return URL(fileURLWithPath:path)
    }
    private func source() throws -> Data {
        let url = try reference()
        return try Data(contentsOf:url.pathExtension == "app" ? url.appendingPathComponent(ClassicServerReference.executablePath) : url)
    }
    @MainActor private func fixture() throws -> (ClassicServerModel,ClassicPreferences,URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kdx-server-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName:root.lastPathComponent))
        let preferences = ClassicPreferences(root:root,defaults:defaults)
        let model = ClassicServerModel(configurationURL:root.appendingPathComponent("server.json"),tableLoader:{ ChallengeTable(testBytes:[UInt8](repeating:7,count:1739)) })
        model.load(); return (model,preferences,root)
    }
    func testReferenceCatalogAndCorruptInput() throws {
        let raw = try source(), appearances = try ClassicServerReference.decode(raw)
        XCTAssertEqual(appearances.count,16)
        let loaded = try ClassicBundledAppearances.decode(JSONEncoder().encode(appearances))
        XCTAssertEqual(loaded,appearances)
        let theme = try XCTUnwrap(appearances.first { $0.name == "Mach Lavender" })
        XCTAssertEqual(theme.fonts?.count,4)
        XCTAssertEqual(AppearanceDecoder.digest(try XCTUnwrap(theme.artwork?.icons)),AppearanceDecoder.referenceIconAtlasSHA256)
        XCTAssertEqual(theme.chromeArtwork?.close,raw.subdata(in:0x84618..<0x8467a))
        XCTAssertEqual(theme.fonts?.first,raw.subdata(in:0x8ce58..<0x90a88))
        var damaged = raw; damaged[0x7da6c] ^= 1
        XCTAssertThrowsError(try ClassicServerReference.decode(damaged))
        XCTAssertThrowsError(try ClassicServerReference.decode(raw.dropLast()))
    }
    @MainActor func testLocalControlsAgainstOriginalTemplate() throws {
        _ = NSApplication.shared
        let b = try AssetBytes(source()), base = 0x7da6c
        let form = ClassicServerLocalForm(configuration:ServerConfiguration())
        XCTAssertEqual(form.bounds.size,NSSize(width:try b.u16(base+16),height:try b.u16(base+18)))
        for (control,offset) in [(form.login,0x114),(form.password,0x180),(form.confirmation,0x1f0),(form.port,0x280),(form.alternate,0x2ec),(form.transfer,0x3d0),(form.save,0x314),(form.cancel,0x34c)] as [(NSView,Int)] {
            let x = try b.u16(base+offset+4), y = try b.u16(base+offset+6)
            let right = try b.u16(base+offset+8), bottom = try b.u16(base+offset+10)
            XCTAssertEqual(control.frame,NSRect(x:x,y:y,width:right-x,height:bottom-y))
            XCTAssertTrue(form.bounds.contains(control.frame))
        }
        XCTAssertFalse(form.alternate.isEnabled); XCTAssertFalse(form.transfer.isEnabled)
        form.password.stringValue = "secret"; form.confirmation.stringValue = "secret"; form.clearPasswords()
        XCTAssertEqual(form.password.stringValue,""); XCTAssertEqual(form.confirmation.stringValue,"")
        // Original main-window constructor x86 0x401000 (file 0x400).
        XCTAssertEqual(Array(b.bytes[0x41a..<0x41e]),[0x26,0x02,0x00,0x00])
        XCTAssertEqual(Array(b.bytes[0x421..<0x425]),[0xf0,0x00,0x00,0x00])
        XCTAssertEqual(ClassicServerConsole.referenceSize,NSSize(width:550,height:240))
    }
    @MainActor func testAdminCredentialsPreserveAccountMetadataAndValidate() throws {
        var config = ServerConfiguration()
        var admin = ServerAccount(login:"old",password:"secret",isAdmin:true); admin.name = "Owner"; admin.third = "metadata"
        config.accounts = [admin,ServerAccount(login:"member",password:"member")]
        let unchanged = try ClassicServerModel.localSettings(config,login:"renamed",password:"",confirmation:"",port:"12345")
        XCTAssertEqual(unchanged.accounts[0].key,admin.key); XCTAssertEqual(unchanged.accounts[0].third,"metadata")
        XCTAssertEqual(unchanged.accounts[0].privileges,admin.privileges); XCTAssertEqual(unchanged.port,12345)
        let updated = try ClassicServerModel.localSettings(config,login:"old",password:"new",confirmation:"new",port:"10700")
        XCTAssertEqual(updated.accounts[0].key,AccountKey(password:"new").bytes)
        for (login,password,confirm,port) in [("","x","x","10700"),("member","x","x","10700"),("admin","x","y","10700"),("admin","x","x","0"),("admin","x","x","65536"),("a\nb","x","x","10700")] {
            XCTAssertThrowsError(try ClassicServerModel.localSettings(config,login:login,password:password,confirmation:confirm,port:port))
        }
        XCTAssertThrowsError(try ClassicServerModel.localSettings(ServerConfiguration(),login:"admin",password:"",confirmation:"",port:"10700"))
        let created = try ClassicServerModel.localSettings(ServerConfiguration(),login:"admin",password:"secret",confirmation:"secret",port:"65535")
        XCTAssertTrue(created.accounts[0].effective(in:created.accountClasses).contains(0))
    }
    @MainActor func testPersistenceAndStaleDraftProtection() throws {
        let (model,prefs,root) = try fixture()
        defer { model.shutdown(); prefs.defaults.removePersistentDomain(forName:root.lastPathComponent); try? FileManager.default.removeItem(at:root) }
        let base = model.configuration
        var next = base; next.name = "Saved server"; next.accounts = [ServerAccount(login:"admin",password:"secret",isAdmin:true)]
        try model.save(next,replacing:base)
        let url = root.appendingPathComponent("server.json"), stored = try ServerConfiguration.load(from:url)
        XCTAssertEqual(stored,model.configuration); XCTAssertEqual(stored.name,"Saved server")
        XCTAssertEqual(stored.newsFile,root.appendingPathComponent("news.json").path)
        XCTAssertFalse(try String(contentsOf:url,encoding:.utf8).contains("secret"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        XCTAssertThrowsError(try model.save(base,replacing:base))
        XCTAssertEqual(try ServerConfiguration.load(from:url),stored)
    }
    @MainActor func testInvalidExistingSettingsAreNotOverwritten() throws {
        let (model,prefs,root) = try fixture()
        defer { model.shutdown(); prefs.defaults.removePersistentDomain(forName:root.lastPathComponent); try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("server.json"), damaged = Data("not json".utf8)
        try damaged.write(to:url); model.load()
        XCTAssertFalse(model.editable); XCTAssertNotNil(model.configurationError)
        XCTAssertThrowsError(try model.save(ServerConfiguration(),replacing:model.configuration))
        model.start(); XCTAssertFalse(model.starting); XCTAssertEqual(try Data(contentsOf:url),damaged)
    }
    @MainActor func testImmediateStopCancelsPendingStart() async throws {
        let (model,prefs,root) = try fixture()
        defer { model.shutdown(); prefs.defaults.removePersistentDomain(forName:root.lastPathComponent); try? FileManager.default.removeItem(at:root) }
        var draft = model.configuration; draft.name = "Keep this configuration"
        try model.save(draft,replacing:model.configuration)
        model.start(); XCTAssertTrue(model.starting); XCTAssertFalse(model.editable)
        model.stop()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(model.starting); XCTAssertFalse(model.server.isRunning); XCTAssertTrue(model.editable)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.configuration.name,"Keep this configuration")
    }
    @MainActor func testDownloadCancellationAndRetry() async throws {
        let (_,prefs,root) = try fixture()
        defer { prefs.defaults.removePersistentDomain(forName:root.lastPathComponent); try? FileManager.default.removeItem(at:root) }
        var attempts = 0, ready = false
        let model = ClassicServerModel(configurationURL:root.appendingPathComponent("server.json"),tableLoader:{
            guard ready else { throw KDXError.invalid("Missing table") }
            return ChallengeTable(testBytes:[UInt8](repeating:7,count:1739))
        },tableDownloader:{
            attempts += 1
            if attempts == 1 { try await Task.sleep(for:.seconds(30)) }
            try Task.checkCancellation(); ready = true
        })
        defer { model.shutdown() }
        model.load(); XCTAssertFalse(model.tableReady)
        model.downloadTable()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(model.downloading); XCTAssertEqual(attempts,1)
        model.downloadTable(); XCTAssertEqual(attempts,1)
        model.cancelDownload()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(model.downloading); XCTAssertFalse(model.tableReady); XCTAssertNil(model.error)
        model.downloadTable()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(attempts,2); XCTAssertTrue(model.tableReady); XCTAssertFalse(model.downloading)
    }
    @MainActor func testSettingsAndTrackerControlsSaveThroughTheModel() throws {
        _ = NSApplication.shared
        let (model,prefs,root) = try fixture()
        defer { model.shutdown(); prefs.defaults.removePersistentDomain(forName:root.lastPathComponent); try? FileManager.default.removeItem(at:root) }
        let app = ClassicServerApplication(model:model,preferences:prefs)
        func views(_ root: NSView) -> [NSView] { [root]+root.subviews.flatMap(views) }
        let settings = app.makeSettingsWindow()
        let controls = views(settings.chrome.content)
        let fields = controls.compactMap { $0 as? ClassicTextField }
        try XCTUnwrap(fields.first { $0.accessibilityLabel() == "Name:" }).stringValue = "Edited server"
        try XCTUnwrap(fields.first { $0.accessibilityLabel() == "Description:" }).stringValue = "Description"
        try XCTUnwrap(fields.first { $0.accessibilityLabel() == "Download limit:" }).stringValue = "123456"
        try XCTUnwrap(fields.first { $0.accessibilityLabel() == "Shared folder:" }).stringValue = root.path
        let checks = controls.compactMap { $0 as? ClassicCheckbox }
        try XCTUnwrap(checks.first { $0.title == "Guest access allowed" }).state = .off
        try XCTUnwrap(checks.first { $0.title == "Show greeting on login" }).state = .on
        try XCTUnwrap(controls.compactMap { $0 as? ClassicServerEditor }.first).text.string = "Welcome!"
        try XCTUnwrap(controls.compactMap { $0 as? ClassicButton }.first { $0.title == "Save" }).performClick(nil)
        XCTAssertEqual(model.configuration.name,"Edited server"); XCTAssertEqual(model.configuration.description,"Description")
        XCTAssertEqual(model.configuration.downloadLimit,123456); XCTAssertEqual(model.configuration.sharedFolder,root.path)
        XCTAssertFalse(model.configuration.allowGuests); XCTAssertTrue(model.configuration.greetingEnabled); XCTAssertEqual(model.configuration.greeting,"Welcome!")
        let tracker = app.makeTrackerWindow(), trackerControls = views(tracker.chrome.content)
        let trackerFields = trackerControls.compactMap { $0 as? ClassicTextField }
        try XCTUnwrap(trackerFields.first { $0.accessibilityLabel() == "Tracker address:" }).stringValue = "tracker.example"
        try XCTUnwrap(trackerFields.first { $0.accessibilityLabel() == "UDP port:" }).stringValue = "10801"
        try XCTUnwrap(trackerFields.first { $0.accessibilityLabel() == "Advertised port:" }).stringValue = "10701"
        try XCTUnwrap(trackerControls.compactMap { $0 as? ClassicCheckbox }.first).state = .on
        try XCTUnwrap(trackerControls.compactMap { $0 as? ClassicServerEditor }.first).text.string = "General\nSoftware"
        try XCTUnwrap(trackerControls.compactMap { $0 as? ClassicButton }.first { $0.title == "Save" }).performClick(nil)
        XCTAssertEqual(model.configuration.tracker.host,"tracker.example"); XCTAssertTrue(model.configuration.tracker.enabled)
        XCTAssertEqual(model.configuration.tracker.port,10801); XCTAssertEqual(model.configuration.tracker.advertisedPort,10701)
        XCTAssertEqual(model.configuration.tracker.groups,["General","Software"])
        XCTAssertEqual(model.configuration.name,"Edited server")
    }
    @MainActor func testOffscreenWindowsAndMenuKeepOriginalConsoleStructure() throws {
        _ = NSApplication.shared
        let (model,prefs,root) = try fixture()
        defer { model.shutdown(); prefs.defaults.removePersistentDomain(forName:root.lastPathComponent); try? FileManager.default.removeItem(at:root); ClassicStyle.shared.appearance = .recovery; ClassicStyle.shared.configureAssets([]) }
        let catalog = root.appendingPathComponent("catalog.json")
        try ClassicServerReference.export(from:reference(),to:catalog)
        let app = ClassicServerApplication(model:model,preferences:prefs,bundledAppearancesURL:catalog)
        app.loadAppearanceSettings()
        XCTAssertEqual(ClassicStyle.shared.appearance.name,"Mach Lavender")
        let menu = app.makeServerMenu()
        XCTAssertEqual(Array(menu.items.prefix(6)).map(\.title),["Copy Address To Clipboard","Show Info","Settings","About","","Exit Server"])
        let console = ClassicServerConsole(preferences:prefs)
        console.chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(console.chrome.content.bounds.size,ClassicServerConsole.referenceSize)
        XCTAssertTrue(console.scroll.documentView === console.transcript)
        console.update(model); XCTAssertTrue(console.transcript.string.contains("Server stopped"))
        let local = ClassicServerLocalWindow(model:model,preferences:prefs)
        let accounts = ClassicServerAccountsWindow(model:model,preferences:prefs)
        let users = ClassicServerUsersWindow(model:model,preferences:prefs)
        let forms = [app.makeSettingsWindow(),app.makeTrackerWindow(),app.makeChallengeTableWindow(),app.makeAppearancesWindow(),accounts]
        for c in [console,local,users]+forms {
            c.chrome.layoutSubtreeIfNeeded()
            XCTAssertFalse(try XCTUnwrap(c.window).isVisible,"Headless tests never present a window")
            XCTAssertGreaterThan(c.chrome.content.bounds.width,0)
            XCTAssertFalse(c.chrome.content.hasAmbiguousLayout)
            func inspect(_ view: NSView) {
                if view is NSControl, !view.isHidden {
                    XCTAssertGreaterThan(view.frame.width,0,"\(c.title): \(type(of:view))")
                    XCTAssertGreaterThan(view.frame.height,0,"\(c.title): \(type(of:view))")
                    if let parent = view.superview, !(parent is NSTableView), !(parent is NSClipView) {
                        // AppKit's text fields extend two pixels beyond their alignment rectangle.
                        let alignment = view.alignmentRect(forFrame:view.frame)
                        XCTAssertGreaterThanOrEqual(alignment.minX,-1,"\(c.title): \(type(of:view))")
                        XCTAssertLessThanOrEqual(alignment.maxX,parent.bounds.width+1,"\(c.title): \(type(of:view)) \(alignment) in \(parent.bounds)")
                    }
                }
                for child in view.subviews { inspect(child) }
            }
            inspect(c.chrome.content)
        }
        accounts.login.stringValue = "member"; accounts.password.stringValue = "pw"; accounts.add.performClick(nil)
        XCTAssertEqual(accounts.list.rows.map(\.id),["member"])
        XCTAssertEqual(accounts.password.stringValue,"")
        XCTAssertTrue(model.configuration.accounts.isEmpty,"A draft is not saved until Save")
        accounts.save.performClick(nil); XCTAssertEqual(model.configuration.accounts.map(\.login),["member"])
        // Clean up observations without showing, closing, or activating any windows.
        for c in [console,local,users]+forms { c.observation.stop() }
    }
}
