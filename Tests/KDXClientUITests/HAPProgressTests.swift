import AppKit
import XCTest
@testable import KDXClientUI

final class HAPProgressTests: XCTestCase {
    private func artwork() throws -> HAPProgressArtwork {
        let digits = (0..<100).map { UInt8(1 << (7-($0/10)%6)) }
        return try HAPProgressArtwork(digits:Data(digits),complete:Data((0..<16).map { $0%2 == 0 ? 0x80 : 0 }),caps:Data((0..<40).map { [UInt8(0x12),0x34,0x56,0xbc][$0%4] }))
    }
    private func chrome(_ artwork: HAPProgressArtwork?) throws -> HAPChromeArtwork {
        var object: [String:Any] = [:]
        for (name,length) in [("close",98),("menu",224),("maximize",98),("minimize",98),("resize",153)] {
            object[name] = Data(repeating:0,count:length).base64EncodedString()
        }
        if let artwork { object["progress"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(artwork)) }
        let result = try JSONDecoder().decode(HAPChromeArtwork.self,from:JSONSerialization.data(withJSONObject:object))
        try result.validate(); return result
    }
    private func appearance(skins: HAPArtwork? = nil) throws -> ClassicAppearance {
        try ClassicAppearance(id:"progress",name:"Progress",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test",artwork:skins,chromeArtwork:chrome(artwork()))
    }
    private func skins(background: Bool = true, fill: Bool = true) throws -> HAPArtwork {
        let helper = HAPArtworkTests()
        var bytes = [UInt8](repeating:0,count:2112)
        for (id,height,color,placement) in [(95,18,0x102030,[0,0,0,0]),(96,6,0x50a070,[2,3,3,4])] {
            guard id == 95 ? background : fill else { continue }
            let at = bytes.count
            bytes += [UInt8](repeating:0,count:24+height*4)
            helper.put(at,64+id*4,in:&bytes)
            bytes[at+1] = 5; bytes[at+3] = UInt8(height); bytes[at+5] = 1
            bytes[at+12] = 1; bytes[at+14] = 1
            for (index,value) in placement.enumerated() { bytes[at+16+index] = UInt8(value) }
            helper.put(color,at+20,in:&bytes)
        }
        return try HAPArtwork(skins:Data(bytes),icons:Data())
    }

    func testRoundedProgressReservesCompletionAndBoundsInvalidValues() {
        for value in [Double.nan,.infinity,-.infinity,-1,0] {
            XCTAssertEqual(ClassicProgressValue(value).fraction,0)
            XCTAssertEqual(ClassicProgressValue(value).percent,0)
        }
        XCTAssertEqual(ClassicProgressValue(0.0049).percent,0)
        XCTAssertEqual(ClassicProgressValue(0.005).percent,1)
        XCTAssertEqual(ClassicProgressValue(0.5).percent,50)
        XCTAssertEqual(ClassicProgressValue(0.99999).percent,99)
        XCTAssertEqual(ClassicProgressValue(1).percent,100)
        XCTAssertEqual(ClassicProgressValue(2).percent,100)
        XCTAssertEqual(ClassicProgressValue(0.5).pixels(95),48)
        XCTAssertEqual(ClassicProgressValue(0.5).pixels(-5),0)
        XCTAssertEqual(ClassicProgressValue(1).pixels(95),95)
    }

    func testBoundedArtworkAndOldCatalogRecovery() throws {
        let art = try artwork()
        XCTAssertThrowsError(try HAPProgressArtwork(digits:Data(),complete:art.complete,caps:art.caps))
        XCTAssertThrowsError(try HAPProgressArtwork(digits:art.digits,complete:Data(repeating:0,count:17),caps:art.caps))
        XCTAssertThrowsError(try HAPProgressArtwork(digits:art.digits,complete:art.complete,caps:Data(repeating:0xdd,count:40)))
        XCTAssertNil(try chrome(nil).progress)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let library = AppearanceLibrary(root:root), good = try appearance()
        try library.install(AppearanceImport(appearances:[good],assets:[:]))
        XCTAssertEqual(library.load().last,good)
        var malformed = try JSONSerialization.jsonObject(with:JSONEncoder().encode(good)) as! [String:Any]
        var chrome = malformed["chromeArtwork"] as! [String:Any], progress = chrome["progress"] as! [String:Any]
        progress["caps"] = Data(repeating:0xff,count:40).base64EncodedString(); chrome["progress"] = progress; malformed["chromeArtwork"] = chrome
        let invalid = try JSONDecoder().decode(ClassicAppearance.self,from:JSONSerialization.data(withJSONObject:malformed))
        XCTAssertThrowsError(try library.install(AppearanceImport(appearances:[invalid],assets:[:])))
        XCTAssertEqual(library.load().last,good)
    }

    @MainActor func testPaletteGeometryGradientDigitsAndCapsAtBothScales() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        let theme = try appearance(); style.configureAssets([theme]); style.appearance = theme
        for fraction in [0.0,0.5,0.99999,1.0] { for scale in [1,2] {
            let value = ClassicProgressValue(fraction)
            let bitmap = try helper.render(scale:scale,width:100,height:20) {
                NSColor.magenta.setFill(); NSRect(x:0,y:0,width:100,height:20).fill()
                HAPProgressDrawing.draw(NSRect(x:0,y:0,width:100,height:20),value:value)
            }
            func check(_ x: Int, _ y: Int, _ slot: Int) throws {
                for sy in 0..<scale { for sx in 0..<scale {
                    XCTAssertEqual(try helper.color(bitmap,x:x*scale+sx,y:y*scale+sy),UInt32(slot)*0x010101,"\(fraction), (\(x),\(y))")
                } }
            }
            try check(0,3,3); try check(1,16,1); try check(1,4,126)
            XCTAssertEqual(try helper.color(bitmap,x:0,y:0),0xff00ff)
            if fraction == 0 {
                try check(16,5,125); try check(30,6,124); try check(30,14,123)
            } else {
                for row in 0..<10 { try check(30,5+row,113+row) }
            }
            if fraction == 0.5 {
                try check(16,5,113); try check(17,5,114)
                try check(54,5,115); try check(55,5,116)
                try check(60,5,125); try check(65,6,124); try check(65,14,123)
            }
            if fraction < 1 {
                for (left,digit) in [(2,value.percent/10),(9,value.percent%10)] {
                    for y in 5..<15 { for column in 0..<6 { try check(left+column,y,column == digit%6 ? 127 : 126) } }
                }
            } else {
                for y in 6..<14 { for column in 0..<9 { try check(4+column,y,column == 0 ? 127 : 126) } }
            }
        } }
    }

    @MainActor func testSkinsUseNativeHeightPlacementAndPartialFallback() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for (background,fill) in [(true,true),(true,false),(false,true)] {
            let theme = try appearance(skins:skins(background:background,fill:fill))
            style.configureAssets([theme]); style.appearance = theme
            for fraction in [0.0,0.5,1.0] { for scale in [1,2] {
                let bitmap = try helper.render(scale:scale,width:100,height:20) {
                    NSColor.magenta.setFill(); NSRect(x:0,y:0,width:100,height:20).fill()
                    HAPProgressDrawing.draw(NSRect(x:0,y:0,width:100,height:20),value:ClassicProgressValue(fraction))
                }
                if background && fill {
                    XCTAssertEqual(try helper.color(bitmap,x:0,y:1*scale),0x102030)
                    XCTAssertEqual(try helper.color(bitmap,x:2*scale,y:4*scale),fraction == 0 ? 0x102030 : 0x50a070)
                    XCTAssertEqual(try helper.color(bitmap,x:49*scale,y:9*scale),fraction == 0 ? 0x102030 : 0x50a070)
                    XCTAssertEqual(try helper.color(bitmap,x:50*scale,y:4*scale),fraction == 1 ? 0x50a070 : 0x102030)
                    XCTAssertEqual(try helper.color(bitmap,x:2*scale,y:10*scale),0x102030,"Fill keeps its native six-pixel height.")
                } else {
                    XCTAssertEqual(try helper.color(bitmap,x:0,y:3*scale),0x030303,"Either missing skin selects the palette path.")
                    XCTAssertEqual(try helper.color(bitmap,x:50*scale,y:1*scale),background ? 0x102030 : 0xff00ff,"The original paints a supplied background before discovering a missing fill.")
                }
            } }
        }
    }

    @MainActor func testTransferCellAccessibilityFilteringAndUpdates() throws {
        _ = NSApplication.shared
        let suite = "KDX-progress-"+UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let list = ClassicList(columns:["File","Direction","Remote Folder","Status","Progress"],key:"progress",preferences:ClassicPreferences(defaults:defaults),kind:.transfers)
        list.rows = [ClassicRow(id:"transfer",values:["File","Download","/Folder","Active","50%"],progress:0.5)]
        list.showFilter(); list.filter.stringValue = "File"
        list.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:list.filter))
        list.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        let progressColumn = list.table.tableColumns[4]
        list.table.moveColumn(4,toColumn:0)
        for fraction in [0.5,0.99999,1] {
            list.rows = [ClassicRow(id:"transfer",values:["File","Download","/Folder","Active","\(ClassicProgressValue(fraction).percent)%"],progress:fraction)]
            let cell = try XCTUnwrap(list.tableView(list.table,viewFor:progressColumn,row:0) as? ClassicProgressView)
            XCTAssertEqual(cell.accessibilityRole(),.progressIndicator)
            XCTAssertEqual(cell.accessibilityValue() as? Int,ClassicProgressValue(fraction).percent)
            XCTAssertEqual(cell.accessibilityMinValue() as? Int,0); XCTAssertEqual(cell.accessibilityMaxValue() as? Int,100)
            XCTAssertEqual(cell.toolTip,"\(ClassicProgressValue(fraction).percent)%")
            XCTAssertEqual(list.selected?.id,"transfer"); XCTAssertEqual(list.filterQuery,"File")
        }
    }

    @MainActor func testOriginalProgressArtworkAndAppearancesRender() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Set KDX_REFERENCE for original progress artwork checks.") }
        let imported = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)), data = try Data(contentsOf:URL(fileURLWithPath:path))
        let art = try XCTUnwrap(imported.appearances.first?.chromeArtwork?.progress)
        XCTAssertEqual(art.digits,data[0x1091ac..<0x109210]); XCTAssertEqual(art.complete,data[0x109210..<0x109220]); XCTAssertEqual(art.caps,data[0x109248..<0x109270])
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for appearance in imported.appearances.filter({ ["Mach Lavender","Amber CRT"].contains($0.name) }) {
            style.configureAssets([appearance]); style.appearance = appearance
            for scale in [1,2] {
                let bitmap = try helper.render(scale:scale,width:220,height:160) {
                    style.color(15).setFill(); NSRect(x:0,y:0,width:220,height:160).fill()
                    for (index,fraction) in [0.0,0.01,0.05,0.25,0.5,0.75,0.9999,1].enumerated() {
                        HAPProgressDrawing.draw(NSRect(x:0,y:index*20,width:220,height:20),value:ClassicProgressValue(fraction))
                    }
                }
                // Every source digit pixel in the 50-percent row is imported, not native text.
                for (left,digit) in [(2,5),(9,0)] { for row in 0..<10 { for column in 0..<6 {
                    let set = art.digits[digit*10+row] & (1 << (7-column)) != 0
                    XCTAssertEqual(try helper.color(bitmap,x:(left+column)*scale,y:(85+row)*scale),appearance.colors[set ? 127 : 126])
                } } }
                if let folder = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"] {
                    let url = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(appearance.name)-progress-\(scale)x.png"))
                }
            }
        }
    }
}
