import AppKit
import KDXCore
import XCTest
@testable import KDXClassicUI

@MainActor private final class UserListSurface: ClassicSurface {
    override func draw(_ dirtyRect: NSRect) { HAPListDrawing.background(bounds,sortedColumn:nil) }
}

final class ClassicUserIconTests: XCTestCase {
    private func encoded(type: UInt8 = 1, palette: [UInt32] = [0x010305,0x07090b,0x0d0f11,0x131517]) -> [UInt8] {
        var bytes: [UInt8] = [type,UInt8(palette.count-1)]
        for rgb in palette { bytes += [UInt8((rgb >> 16)&255),UInt8((rgb >> 8)&255),UInt8(rgb&255)] }
        let pixels: [UInt8] = (0..<1024).map { position in
            let x = position%32, y = position/32
            let index = x%2 + (y%2)*2
            return UInt8(index%palette.count)
        }
        if type <= 2 { for i in stride(from:0,to:1024,by:2) { bytes.append(pixels[i] << 4 | pixels[i+1]) } }
        else { bytes += pixels }
        return bytes
    }

    func testAllEncodingsAndOriginalReductionOrder() throws {
        for type in UInt8(1)...4 {
            let icon = try XCTUnwrap(ClassicUserIcon(encoded(type:type)))
            XCTAssertEqual(Array(icon.indices.prefix(4)),[0,1,0,1])
            XCTAssertEqual(Array(icon.indices[32..<36]),[2,3,2,3])
            let full = icon.bitmap(small:false), small = icon.bitmap(small:true)
            XCTAssertEqual(full.width,32); XCTAssertEqual(full.rgba.count,4096)
            XCTAssertEqual(Array(full.rgba.prefix(8)),[1,3,5,255,7,9,11,255])
            XCTAssertEqual(small.width,16); XCTAssertEqual(small.rgba.count,1024)
            XCTAssertEqual(Array(small.rgba.prefix(4)),[10,12,14,255])
            // Tint each odd component with zero, floor, THEN reduce. Reversing
            // those operations would incorrectly produce [5,6,7].
            XCTAssertEqual(Array(icon.bitmap(small:true,selection:0).rgba.prefix(4)),[4,5,6,255])
        }
    }

    func testMalformedIconsAndBoundedTrailingData() throws {
        let valid = encoded()
        for length in 0..<valid.count { XCTAssertNil(ClassicUserIcon(Array(valid.prefix(length)))) }
        for type: UInt8 in [0,5,255] { var invalid = valid; invalid[0] = type; XCTAssertNil(ClassicUserIcon(invalid)) }
        for type: UInt8 in [1,2,3,4] {
            var invalid = encoded(type:type); invalid[14] = 255
            XCTAssertNil(ClassicUserIcon(invalid),"Every index must fit the declared palette.")
        }
        XCTAssertNotNil(ClassicUserIcon(valid+[UInt8](repeating:0,count:1800-valid.count)))
        XCTAssertNil(ClassicUserIcon(valid+[UInt8](repeating:0,count:1801-valid.count)))
        // An 8-bit palette can use all 256 entries; four-bit files can declare
        // more than 16 entries even though their pixels only address the first 16.
        let palette = (0..<256).flatMap { [UInt8($0),UInt8($0),UInt8($0)] }
        XCTAssertNotNil(ClassicUserIcon([3,255]+palette+[UInt8](repeating:255,count:1024)))
        XCTAssertNotNil(ClassicUserIcon([1,255]+palette+[UInt8](repeating:255,count:512)))
    }

    @MainActor func testUserCellSelectionGeometryAndMalformedFallback() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery }
        style.appearance = ClassicAppearance(id:"user-test",name:"User Test",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test")
        var user = KDXUser(id:42,nickname:"Example")
        user.badge = 0x12; user.server15 = 0x34; user.server16 = 0x56; user.icon = encoded()
        for malformed in [false,true] {
            if malformed { user.icon = [1,255] }
            let row = ClassicTableRowView(frame:NSRect(x:0,y:0,width:180,height:19))
            let text = ClassicListTextField(labelWithString:user.nickname)
            let cell = ClassicUserCell(text:text,adornment:ClassicUserAdornment(user:user))
            row.addSubview(cell); cell.frame = row.bounds; cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(cell.text.stringValue,"Example")
            XCTAssertEqual(cell.text.frame.minX,34)
            XCTAssertEqual(cell.text.accessibilityHelp(),"Class color #123456")
            for (selected,emphasized) in [(false,true),(true,true),(true,false)] {
                row.isSelected = selected; row.isEmphasized = emphasized
                for scale in [1,2] {
                    let bitmap = try helper.render(scale:scale,width:180,height:19) { cell.draw(cell.bounds) }
                    for x in 0..<6 { XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:9*scale),selected && emphasized ? 0x111111 : 0x123456) }
                    XCTAssertEqual(try helper.color(bitmap,x:6*scale,y:9*scale),0xffffff)
                    XCTAssertEqual(try helper.color(bitmap,x:14*scale,y:scale),malformed ? 0xffffff : selected && emphasized ? 0x0d0e0f : 0x0a0c0e)
                    XCTAssertEqual(try helper.color(bitmap,x:30*scale,y:scale),0xffffff)
                }
            }
        }
    }

    @MainActor func testNativeListPreservesIdentityAndAdornmentOnSortAndFilter() throws {
        _ = NSApplication.shared
        let suite = "KDX-user-list-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let list = ClassicList(columns:["Name","Description"],key:"users",preferences:ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults))
        var user = KDXUser(id:42,nickname:"Zebra",info:"Remote user"); user.icon = encoded()
        let expected = ClassicUserAdornment(user:user)
        list.rows = [ClassicRow(id:"42",values:[user.nickname,user.info],userAdornment:expected),ClassicRow(id:"11",values:["Alpha","Other"])]
        list.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        list.table.sortDescriptors = [NSSortDescriptor(key:"0",ascending:true)]
        XCTAssertEqual(list.selected?.id,"42")
        list.showFilter(); list.filter.stringValue = "remote"
        list.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:list.filter))
        XCTAssertEqual(list.visible.map(\.id),["42"])
        let cell = try XCTUnwrap(list.tableView(list.table,viewFor:list.table.tableColumns[0],row:0) as? ClassicUserCell)
        XCTAssertEqual(cell.adornment,expected)
        XCTAssertTrue(list.tableView(list.table,viewFor:list.table.tableColumns[1],row:0) is ClassicListTextField)
        user.server15 = 33
        list.rows = [ClassicRow(id:"42",values:[user.nickname,user.info],userAdornment:ClassicUserAdornment(user:user))]
        XCTAssertEqual(list.selected?.id,"42"); XCTAssertNotEqual(list.visible[0].userAdornment,expected)
    }

    @MainActor func testReferenceIconInImportedAppearances() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Set KDX_CLASSIC_REFERENCE for the read-only original icon fixture.") }
        let source = try Data(contentsOf:URL(fileURLWithPath:path))
        // Validate the supported original revision before accessing this static asset.
        let imported = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path))
        XCTAssertEqual(AppearanceDecoder.digest(source),"fb3876cd557c3a077f5cd3dbf1b0546d95de8cee7fb56f276b94aa6275fbca18")
        guard source.count >= 0xefe34+529 else { return XCTFail("Reference icon absent") }
        let bytes = Array(source[0xefe34..<0xefe34+529]), icon = try XCTUnwrap(ClassicUserIcon(bytes))
        XCTAssertEqual(icon.palette,[0xff79ca,0,0xff0099,0xffffff,0x0099ff])
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for appearance in imported.appearances.filter({ ["Mach Lavender","Amber CRT"].contains($0.name) }) {
            style.configureAssets([appearance]); style.appearance = appearance
            let surface = UserListSurface(frame:NSRect(x:0,y:0,width:240,height:76))
            for index in 0..<3 {
                var user = KDXUser(nickname:["Original user icon","Selected user","Inactive selection"][index]); user.icon = bytes
                user.badge = 0x44; user.server15 = 0x88; user.server16 = 0xcc
                let row = ClassicTableRowView(frame:NSRect(x:0,y:index*25,width:240,height:19))
                row.userAdornment = ClassicUserAdornment(user:user)
                row.isSelected = index > 0; row.isEmphasized = index == 1
                let text = ClassicListTextField(labelWithString:user.nickname); text.font = style.font
                let cell = ClassicUserCell(text:text,adornment:ClassicUserAdornment(user:user)); cell.frame = row.bounds
                row.addSubview(cell); surface.addSubview(row); cell.layoutSubtreeIfNeeded()
            }
            for scale in [1,2] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:240*scale,pixelsHigh:76*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                bitmap.size = surface.bounds.size; surface.cacheDisplay(in:surface.bounds,to:bitmap)
                if let folder = ProcessInfo.processInfo.environment["KDX_CLASSIC_RENDER_DIR"] {
                    let url = URL(fileURLWithPath:folder,isDirectory:true)
                    try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(appearance.name)-user-icons-\(scale)x.png"))
                }
            }
        }
    }
}
