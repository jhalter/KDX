import AppKit
import KDXCore
import XCTest
@testable import KDXClassicUI

final class ClassicUserRowSizeTests: XCTestCase {
    private func profile() -> ClassicUserAdornment {
        var user = KDXUser(nickname:"Native user")
        user.icon = [1,1,0,0,0,255,255,255]+[UInt8](repeating:0x01,count:512)
        user.colors = [0x10,0x20,0x30,0xd0,0xe0,0xf0]
        user.badge = 0x88; user.server15 = 0x66; user.server16 = 0x44; user.flags = 4
        return ClassicUserAdornment(user:user)
    }

    @MainActor func testSizePreferenceRestoresAndPreservesFilteredSelection() throws {
        _ = NSApplication.shared
        let suite = "KDX-row-size-tests-"+UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
        XCTAssertTrue(preferences.smallUserIcons,"Retain existing compact lists when no preference is saved.")
        let list = ClassicList(columns:["Name","Description"],key:"users",preferences:preferences,kind:.users)
        list.frame = NSRect(x:0,y:0,width:400,height:200); list.table.allowsMultipleSelection = true
        list.rows = (0..<4).map { ClassicRow(id:String($0),values:["User \($0)",$0 == 3 ? "Other" : "Matching"],userAdornment:profile()) }
        list.showFilter(); list.filter.stringValue = "matching"
        list.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:list.filter))
        list.table.selectRowIndexes(IndexSet([0,2]),byExtendingSelection:false)
        let files = ClassicList(columns:["Name"],key:"files",preferences:preferences)
        for small in [false,true,false] {
            preferences.smallUserIcons = small; list.applyStyle(); files.applyStyle()
            let size: ClassicUserRowSize = small ? .compact : .normal
            XCTAssertEqual(list.userRowSize,size); XCTAssertEqual(list.table.rowHeight,small ? 19 : 33)
            XCTAssertEqual(list.scroll.lineScroll,list.table.rowHeight+list.table.intercellSpacing.height)
            XCTAssertEqual(files.table.rowHeight,19,"User-icon size must not change file or tracker rows.")
            XCTAssertEqual(list.filterQuery,"matching"); XCTAssertTrue(list.isFiltering)
            XCTAssertEqual(list.visible.map(\.id),["0","1","2"])
            XCTAssertEqual(list.table.selectedRowIndexes,IndexSet([0,2]))
            let row = try XCTUnwrap(list.tableView(list.table,rowViewForRow:0) as? ClassicTableRowView)
            let cell = try XCTUnwrap(list.tableView(list.table,viewFor:list.table.tableColumns[0],row:0) as? ClassicUserCell)
            XCTAssertEqual(row.userRowSize,size); XCTAssertEqual(cell.rowSize,size)
        }
        let restored = ClassicPreferences(root:preferences.root,defaults:try XCTUnwrap(UserDefaults(suiteName:suite)))
        XCTAssertFalse(restored.smallUserIcons)
        let chat = ClassicList(columns:["Name"],key:"chat-users",preferences:restored,kind:.users)
        XCTAssertEqual(chat.table.rowHeight,33,"New chat panes must use the saved preference even before users arrive.")
    }

    @MainActor func testNormalAndCompactArtworkGeometryAtBothScales() throws {
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery }
        var colors = (0..<221).map { UInt32($0)*0x010101 }; colors[17] = 0x204060; colors[18] = 0xe0a020
        style.appearance = ClassicAppearance(id:"sizes",name:"Sizes",colors:colors,source:"test")
        let helper = HAPWindowTests(), adornment = profile()
        for size: ClassicUserRowSize in [.compact,.normal] {
            let row = ClassicTableRowView(frame:NSRect(x:0,y:0,width:250,height:size.rowHeight))
            row.userAdornment = adornment; row.userRowSize = size
            let text = ClassicListTextField(labelWithString:"User")
            let cell = ClassicUserCell(text:text,adornment:adornment,rowSize:size)
            cell.frame = row.bounds; row.addSubview(cell); cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(cell.text.frame.minX,size == .compact ? 34 : 52)
            XCTAssertEqual(size.iconRect,size == .compact ? NSRect(x:14,y:1,width:16,height:16) : NSRect(x:16,y:0,width:32,height:32))
            for (selected,emphasized) in [(false,true),(true,true),(true,false)] { for scale in [1,2] {
                row.isSelected = selected; row.isEmphasized = emphasized
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:250*scale,pixelsHigh:Int(size.rowHeight)*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                bitmap.size = row.bounds.size; row.cacheDisplay(in:row.bounds,to:bitmap)
                let active = selected && emphasized
                let x = Int(size.iconRect.minX), y = Int(size.iconRect.minY)+4
                let first: UInt32 = size.small ? active ? 0x4f5f6f : 0x7f7f7f : active ? 0x102030 : 0
                let second: UInt32 = size.small ? first : active ? 0x8f9faf : 0xffffff
                for sy in 0..<scale { for sx in 0..<scale {
                    XCTAssertEqual(try helper.color(bitmap,x:x*scale+sx,y:y*scale+sy),first)
                    XCTAssertEqual(try helper.color(bitmap,x:(x+1)*scale+sx,y:y*scale+sy),second)
                } }
                XCTAssertEqual(try helper.color(bitmap,x:(Int(size.classWidth)-1)*scale,y:8*scale),active ? 0x204060 : 0x886644)
                if selected && !emphasized {
                    for top in 0..<Int(size.outlineWidth) { XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:top*scale),0x204060) }
                    XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:Int(size.outlineWidth)*scale),size.small ? 0x7f7f7f : 0)
                }
                let base: UInt32 = active ? 0x204060 : 0xd0e0f0
                XCTAssertEqual(try helper.color(bitmap,x:size.gradientOrigin*scale,y:8*scale),base)
            } }
        }
    }

    @MainActor func testBothSizesRenderWithOriginalIconAndAppearances() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Set KDX_CLASSIC_REFERENCE for original icon/theme rendering.") }
        let imported = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path))
        let data = try Data(contentsOf:URL(fileURLWithPath:path))
        guard AppearanceDecoder.digest(data) == "fb3876cd557c3a077f5cd3dbf1b0546d95de8cee7fb56f276b94aa6275fbca18" else { return XCTFail("Unexpected original revision") }
        let icon = Array(data[0xefe34..<0xefe34+529]), style = ClassicStyle.shared
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for appearance in imported.appearances.filter({ ["Mach Lavender","Amber CRT"].contains($0.name) }) {
            style.configureAssets([appearance]); style.appearance = appearance
            let surface = ClassicSurface(frame:NSRect(x:0,y:0,width:320,height:174))
            var top: CGFloat = 0
            for size: ClassicUserRowSize in [.compact,.normal] { for state in 0..<3 {
                var user = KDXUser(nickname:(size.small ? "Small" : "Normal")+[" icon"," selected"," inactive"][state]); user.icon = icon
                user.colors = [0x10,0x20,0x30,0xd0,0xe0,0xf0]; user.badge = 0x44; user.server15 = 0x88; user.server16 = 0xcc
                let adornment = ClassicUserAdornment(user:user)
                let row = ClassicTableRowView(frame:NSRect(x:0,y:top,width:320,height:size.rowHeight))
                row.userAdornment = adornment; row.userRowSize = size; row.isSelected = state > 0; row.isEmphasized = state != 2
                let text = ClassicListTextField(labelWithString:user.nickname); text.font = style.font
                let cell = ClassicUserCell(text:text,adornment:adornment,rowSize:size); cell.frame = row.bounds
                row.addSubview(cell); surface.addSubview(row); cell.layoutSubtreeIfNeeded(); top += size.rowHeight+3
            } }
            for scale in [1,2] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:320*scale,pixelsHigh:174*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                bitmap.size = surface.bounds.size; surface.cacheDisplay(in:surface.bounds,to:bitmap)
                if let folder = ProcessInfo.processInfo.environment["KDX_CLASSIC_RENDER_DIR"] {
                    let url = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(appearance.name)-user-sizes-\(scale)x.png"))
                }
            }
        }
    }
}
