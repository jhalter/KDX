import AppKit
import XCTest
@testable import KDXClassicUI

final class HAPBannerTests: XCTestCase {
    private func artwork() throws -> HAPBannerArtwork {
        let palette = (0..<200).flatMap { [UInt8(0),UInt8($0),UInt8(199-$0),UInt8($0/2)] }
        return try HAPBannerArtwork(palette:Data(palette),pixels:Data((0..<6080).map { UInt8($0%200) }))
    }
    private func chrome(_ banner: HAPBannerArtwork?) throws -> HAPChromeArtwork {
        var object: [String:Any] = [:]
        for (name,length) in [("close",98),("menu",224),("maximize",98),("minimize",98),("resize",153)] {
            object[name] = Data(repeating:0,count:length).base64EncodedString()
        }
        if let banner { object["banner"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(banner)) }
        return try JSONDecoder().decode(HAPChromeArtwork.self,from:JSONSerialization.data(withJSONObject:object))
    }
    func testValidationCatalogRoundTripAndOldCatalog() throws {
        let banner = try artwork()
        for size in [0,799,801] {
            XCTAssertThrowsError(try HAPBannerArtwork(palette:Data(repeating:0,count:size),pixels:banner.pixels))
        }
        for size in [0,6079,6081] {
            XCTAssertThrowsError(try HAPBannerArtwork(palette:banner.palette,pixels:Data(repeating:0,count:size)))
        }
        var badPalette = banner.palette; badPalette[0] = 1
        XCTAssertThrowsError(try HAPBannerArtwork(palette:badPalette,pixels:banner.pixels))
        var badPixels = banner.pixels; badPixels[6079] = 200
        XCTAssertThrowsError(try HAPBannerArtwork(palette:banner.palette,pixels:badPixels))
        let old = try chrome(nil); try old.validate(); XCTAssertNil(old.banner)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let library = AppearanceLibrary(root:root)
        var appearance = ClassicAppearance(id:"banner-test",name:"Banner",colors:[UInt32](repeating:0,count:204),source:"test")
        appearance.chromeArtwork = try chrome(banner)
        try library.install(AppearanceImport(appearances:[appearance],assets:[:]))
        XCTAssertEqual(library.load().last?.chromeArtwork?.banner,banner)
        // Codable can construct invalid data; installation must validate it before replacing a working catalog.
        let invalid = try JSONDecoder().decode(HAPBannerArtwork.self,from:JSONSerialization.data(withJSONObject:["palette":badPalette.base64EncodedString(),"pixels":banner.pixels.base64EncodedString()]))
        appearance.chromeArtwork = try chrome(invalid)
        XCTAssertThrowsError(try library.install(AppearanceImport(appearances:[appearance],assets:[:])))
        XCTAssertEqual(library.load().last?.chromeArtwork?.banner,banner)
    }
    @MainActor func testConnectionSelectionRefreshesStatusWithoutCrossSessionErrors() throws {
        _ = NSApplication.shared
        let app = ClassicApplication()
        var firstEndpoint = ClassicEndpoint(); firstEndpoint.name = "First server"
        var secondEndpoint = ClassicEndpoint(); secondEndpoint.name = "Second server"
        let first = ClassicSession(endpoint:firstEndpoint), second = ClassicSession(endpoint:secondEndpoint)
        first.error = "First connection failed"
        app.sessions = [first.id:first,second.id:second]; app.selectedSession = first.id
        app.sessionPicker.target = app; app.sessionPicker.action = #selector(ClassicApplication.pickSession)
        app.refreshBar()
        XCTAssertEqual(app.status.stringValue,first.error)
        XCTAssertTrue(app.sessionPicker.toolTip?.contains("First connection failed") == true)
        let item = try XCTUnwrap(app.sessionPicker.itemArray.first { $0.representedObject as? UUID == second.id })
        XCTAssertTrue(app.sessionPicker.choose(item))
        XCTAssertEqual(app.selectedSession,second.id)
        XCTAssertEqual(app.status.stringValue,second.client.state)
        XCTAssertTrue(app.sessionPicker.toolTip?.contains("Second server") == true)
        XCTAssertFalse(app.sessionPicker.toolTip?.contains("First connection failed") == true)
        XCTAssertEqual(app.sessionPicker.accessibilityValue() as? String,"Second server — \(second.client.state)")
        first.error = "Background failure"; app.refreshBar()
        XCTAssertEqual(app.status.stringValue,second.client.state)
        XCTAssertTrue(app.windows.isEmpty); XCTAssertTrue(app.utilityWindows.isEmpty)
    }
    @MainActor func testNativeSizeCenteringClippingAndOpaquePixels() throws {
        let banner = try artwork(), image = try banner.bitmap(), helper = HAPWindowTests()
        XCTAssertEqual(HAPBannerDrawing.imageRect(image,in:NSRect(x:-2,y:-2,width:153,height:41)),NSRect(x:-1,y:-1,width:152,height:40))
        for bounds in [NSRect(x:3,y:5,width:156,height:44), NSRect(x:3,y:5,width:147,height:35)] {
            let rect = HAPBannerDrawing.imageRect(image,in:bounds)
            for scale in [1,2] {
                let bitmap = try helper.render(scale:scale,width:166,height:54) {
                    NSColor.magenta.setFill(); NSRect(x:0,y:0,width:166,height:54).fill()
                    HAPBannerDrawing.draw(image,in:bounds)
                }
                for y in 0..<54 { for x in 0..<166 {
                    let point = NSPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)
                    var expected: UInt32 = 0xff00ff
                    if bounds.contains(point) && rect.contains(point) {
                        let index = banner.pixels[(y-Int(rect.minY))*152+x-Int(rect.minX)]
                        expected = UInt32(index)<<16 | UInt32(199-index)<<8 | UInt32(index/2)
                    }
                    for sy in 0..<scale { for sx in 0..<scale {
                        XCTAssertEqual(try helper.color(bitmap,x:x*scale+sx,y:y*scale+sy),expected)
                    } }
                } }
            }
        }
    }
    @MainActor func testBannerKeepsSelectionAndRecoveryAcrossThemes() throws {
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery; style.configureAssets([]) }
        var imported = ClassicAppearance.recovery
        imported.chromeArtwork = try chrome(artwork())
        style.configureAssets([imported]); style.appearance = imported
        let picker = ClassicPopUpButton("Connection"), status = classicLabel("Ready")
        picker.addItems(withTitles:["First server","Second server"])
        let buttons = ClassicBarAction.allCases.map { action in ClassicButton(action.title,height:action.rect(compact:false).height) {} }
        let view = ClassicButtonBarView(compact:false,picker:picker,status:status,buttons:buttons)
        view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(picker.banner); XCTAssertTrue(status.isHidden)
        XCTAssertEqual(view.convert(picker.bounds,from:picker),NSRect(x:0,y:0,width:152,height:40))
        XCTAssertTrue(picker.choose(try XCTUnwrap(picker.item(at:1))))
        XCTAssertEqual(picker.accessibilityValue() as? String,"Second server")
        picker.isEnabled = false
        XCTAssertFalse(picker.choose(try XCTUnwrap(picker.item(at:0))))
        XCTAssertEqual(picker.indexOfSelectedItem,1)
        // External themes share the imported original artwork; removing it restores setup controls.
        style.appearance = .recovery; view.applyStyle(); XCTAssertNotNil(picker.banner)
        style.configureAssets([]); view.applyStyle(); view.layoutSubtreeIfNeeded()
        XCTAssertNil(picker.banner); XCTAssertFalse(status.isHidden)
        XCTAssertEqual(view.convert(picker.bounds,from:picker),NSRect(x:4,y:2,width:144,height:20))
        XCTAssertEqual(picker.indexOfSelectedItem,1)
    }
}
