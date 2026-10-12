import AppKit
import KDXCore
import XCTest
@testable import KDXClientUI

final class HAPUserRowTests: XCTestCase {
    private func user(gradient: Bool) -> KDXUser {
        var user = KDXUser(id:17,nickname:"Profile",info:"Description")
        user.colors = [0x10,0x20,0x30,0xd0,0xe0,0xf0]
        user.badge = 0x88; user.server15 = 0x66; user.server16 = 0x44
        user.flags = gradient ? 4 : 0
        return user
    }
    @MainActor private func configureStyle() {
        var colors = (0..<221).map { UInt32($0)*0x010101 }
        colors[17] = 0x204060; colors[18] = 0xe0a020
        ClassicStyle.shared.appearance = ClassicAppearance(id:"user-rows",name:"User Rows",colors:colors,source:"test")
    }

    func testWireColorMappingGradientFlagAndModernDefaults() {
        let profile = ClassicUserAdornment(user:user(gradient:true))
        XCTAssertEqual(profile.foreground,0x102030); XCTAssertEqual(profile.background,0xd0e0f0)
        XCTAssertEqual(profile.classColor,0x886644); XCTAssertTrue(profile.gradient)
        var model = user(gradient:false); model.flags = 0xfb
        XCTAssertFalse(ClassicUserAdornment(user:model).gradient,"Only bit 2 enables the gradient.")
        for colors: [UInt8] in [[],[1,2,3],[0,0,0,0,0,0]] {
            model.colors = colors
            XCTAssertNil(ClassicUserAdornment(user:model).foreground)
            XCTAssertNil(ClassicUserAdornment(user:model).background)
        }
        model.colors = [5,5,5,5,5,5]
        XCTAssertEqual(ClassicUserAdornment(user:model).foreground,0x050505,"Equal nonzero colors are not silently changed.")
        XCTAssertEqual(ClassicUserAdornment(user:model).background,0x050505)
    }

    func testIntegerGradientUsesOriginalRoundingAndExclusiveEndpoint() {
        let ascending: [UInt32] = [0,42,85,127,170,212]
        let descending: [UInt32] = [255,213,170,128,85,43]
        for i in 0..<6 {
            XCTAssertEqual(HAPUserRowDrawing.gradientColor(start:0,end:0xffffff,offset:i,width:6),ascending[i]*0x010101)
            XCTAssertEqual(HAPUserRowDrawing.gradientColor(start:0xffffff,end:0,offset:i,width:6),descending[i]*0x010101)
        }
        XCTAssertEqual(HAPUserRowDrawing.gradientColor(start:0x123456,end:0xabcdef,offset:0,width:1),0x123456)
        XCTAssertEqual(HAPUserRowDrawing.gradientColor(start:0x123456,end:0xabcdef,offset:3,width:0),0x123456)
    }

    @MainActor func testBackgroundPixelsAndClippedRedrawKeepGradientPhase() throws {
        configureStyle(); defer { ClassicStyle.shared.appearance = .recovery }
        let helper = HAPWindowTests(), rect = NSRect(x:0,y:0,width:126,height:19)
        for gradient in [false,true] { for active in [false,true] { for scale in [1,2] {
            let profile = ClassicUserAdornment(user:user(gradient:gradient))
            let base: UInt32 = active ? 0x204060 : 0xd0e0f0, end: UInt32 = active ? 0xe0a020 : 0x102030
            let bitmap = try helper.render(scale:scale,width:126,height:19) {
                HAPUserRowDrawing.background(rect,profile:profile,selected:active,emphasized:true,dirtyRect:rect)
            }
            XCTAssertEqual(try helper.color(bitmap,x:29*scale,y:9*scale),base)
            XCTAssertEqual(try helper.color(bitmap,x:30*scale,y:9*scale),base)
            // At x=78, half of the 96-pixel gradient has elapsed.
            XCTAssertEqual(try helper.color(bitmap,x:78*scale,y:9*scale),gradient ? active ? 0x807040 : 0x708090 : base)
            XCTAssertEqual(try helper.color(bitmap,x:125*scale,y:9*scale),gradient ? HAPUserRowDrawing.gradientColor(start:base,end:end,offset:95,width:96) : base)
            let clipped = try helper.render(scale:scale,width:126,height:19) {
                HAPUserRowDrawing.background(rect,profile:profile,selected:active,emphasized:true,dirtyRect:NSRect(x:60,y:5,width:30,height:8))
            }
            for x in 60..<90 { XCTAssertEqual(try helper.color(clipped,x:x*scale,y:9*scale),try helper.color(bitmap,x:x*scale,y:9*scale)) }
            XCTAssertEqual(try helper.color(clipped,x:59*scale,y:9*scale),0xffffff)
            XCTAssertEqual(try helper.color(clipped,x:90*scale,y:9*scale),0xffffff)
        } } }
        for width in [1,6,29,30] {
            let bitmap = try helper.render(scale:1,width:width,height:19) {
                let bounds = NSRect(x:0,y:0,width:width,height:19)
                HAPUserRowDrawing.background(bounds,profile:ClassicUserAdornment(user:user(gradient:true)),selected:false,emphasized:true,dirtyRect:bounds)
            }
            XCTAssertEqual(try helper.color(bitmap,x:width-1,y:9),0xd0e0f0)
        }
    }

    @MainActor func testNativeRowBackgroundTextAndInactiveOutline() throws {
        _ = NSApplication.shared
        configureStyle(); defer { ClassicStyle.shared.appearance = .recovery }
        let suite = "KDX-profile-rows-"+UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let list = ClassicList(columns:["Name","Description"],key:"profile",preferences:ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults))
        var model = user(gradient:false)
        model.icon = [1,0,255,255,255]+[UInt8](repeating:0,count:512)
        list.rows = [ClassicRow(id:"17",values:[model.nickname,model.info],userAdornment:ClassicUserAdornment(user:model))]
        let row = try XCTUnwrap(list.tableView(list.table,rowViewForRow:0) as? ClassicTableRowView)
        row.frame = NSRect(x:0,y:0,width:300,height:19)
        let cell = try XCTUnwrap(list.tableView(list.table,viewFor:list.table.tableColumns[0],row:0) as? ClassicUserCell)
        let info = try XCTUnwrap(list.tableView(list.table,viewFor:list.table.tableColumns[1],row:0) as? ClassicListTextField)
        cell.frame = NSRect(x:0,y:0,width:180,height:19); info.frame = NSRect(x:180,y:0,width:120,height:19)
        row.addSubview(cell); row.addSubview(info); row.layoutSubtreeIfNeeded()
        let helper = HAPWindowTests()
        for (selected,emphasized) in [(false,true),(true,true),(true,false)] {
            row.isSelected = selected; row.isEmphasized = emphasized
            for scale in [1,2] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:300*scale,pixelsHigh:19*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                bitmap.size = row.bounds.size; row.cacheDisplay(in:row.bounds,to:bitmap)
                XCTAssertEqual(HAPUserRowDrawing.rgb(try XCTUnwrap(info.textColor)),selected && emphasized ? 0xe0a020 : 0x102030)
                XCTAssertEqual(info.textColor,cell.text.textColor)
                XCTAssertEqual(try helper.color(bitmap,x:200*scale,y:18*scale),selected ? 0x204060 : 0xd0e0f0)
                XCTAssertEqual(try helper.color(bitmap,x:250*scale,y:9*scale),selected && emphasized ? 0x204060 : 0xd0e0f0)
                XCTAssertEqual(try helper.color(bitmap,x:5*scale,y:18*scale),selected && emphasized ? 0x204060 : 0x886644)
                XCTAssertEqual(try helper.color(bitmap,x:6*scale,y:18*scale),selected ? 0x204060 : 0xd0e0f0)
                XCTAssertEqual(try helper.color(bitmap,x:14*scale,y:scale),selected ? emphasized ? 0x8f9faf : 0x204060 : 0xffffff,"Inactive outline must cover the icon's first scanline.")
                XCTAssertEqual(try helper.color(bitmap,x:14*scale,y:2*scale),selected && emphasized ? 0x8f9faf : 0xffffff)
            }
        }
    }

    @MainActor func testReferenceProfileRowRenders() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Set KDX_REFERENCE to render imported themes.") }
        let imported = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)), style = ClassicStyle.shared
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for appearance in imported.appearances.filter({ ["Mach Lavender","Amber CRT"].contains($0.name) }) {
            style.configureAssets([appearance]); style.appearance = appearance
            let surface = ClassicSurface(frame:NSRect(x:0,y:0,width:320,height:120))
            for index in 0..<6 {
                var model = user(gradient:index >= 3); model.nickname = ["Normal","Selected","Inactive"][index%3]+(index >= 3 ? " gradient" : " solid")
                let row = ClassicTableRowView(frame:NSRect(x:0,y:index*20,width:320,height:19))
                row.userAdornment = ClassicUserAdornment(user:model); row.isSelected = index%3 != 0; row.isEmphasized = index%3 != 2
                let text = ClassicListTextField(labelWithString:model.nickname); text.font = style.font
                let cell = ClassicUserCell(text:text,adornment:ClassicUserAdornment(user:model)); cell.frame = row.bounds
                row.addSubview(cell); surface.addSubview(row); cell.layoutSubtreeIfNeeded()
            }
            for scale in [1,2] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:320*scale,pixelsHigh:120*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                bitmap.size = surface.bounds.size; surface.cacheDisplay(in:surface.bounds,to:bitmap)
                if let folder = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"] {
                    let url = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(appearance.name)-user-profiles-\(scale)x.png"))
                }
            }
        }
    }
}
