import AppKit
import XCTest
@testable import KDXClassicUI

final class ClassicFileIconTests: XCTestCase {
    private func atlas(small: Int = 16, large: Int? = 32, palette: [Int] = [0x123456,0xabcdef], transparent: Int = 0) throws -> HAPArtwork {
        var bytes = [UInt8](repeating:0,count:3072)
        let helper = HAPArtworkTests()
        for (slot,size) in [small,large].enumerated() {
            guard let size else { continue }
            let offset = bytes.count, stride = ((size+31)/32)*4
            bytes += [UInt8](repeating:0,count:8+8+stride*size)
            helper.put(offset,17*16+slot*4,in:&bytes)
            bytes[offset+1] = UInt8(size); bytes[offset+3] = UInt8(size)
            bytes[offset+4] = 1; bytes[offset+5] = 1; bytes[offset+6] = 1; bytes[offset+7] = UInt8(transparent)
            helper.put(palette[0],offset+8,in:&bytes); helper.put(palette[1],offset+12,in:&bytes)
            // Alternating columns exercise keyed transparency and native pixel sizing.
            for y in 0..<size { for x in 0..<stride { bytes[offset+16+y*stride+x] = 0x55 } }
        }
        return try HAPArtwork(skins:Data(),icons:Data(bytes))
    }

    func testUnknownKindsAndDirectoryFallback() {
        for kind in ["image/unknown","IMAGE/PNG","image/png ","exttype/png","photo.png",""] {
            XCTAssertEqual(ClassicFileKind.iconID(kind),17)
            XCTAssertEqual(ClassicFileKind.iconID(kind,isDirectory:true),40)
        }
        XCTAssertEqual(ClassicFileKind.iconID("folder/dropbox",isDirectory:true),44)
        XCTAssertEqual(ClassicFileKind.iconID("folder/uploads",isDirectory:true),43)
        XCTAssertEqual(ClassicFileKind.iconID("alias/folder"),40)
        XCTAssertEqual(ClassicFileKind.iconID("data",isDirectory:true),17,"Recognized kinds take precedence over the modern directory fallback.")
    }

    func testSelectionTransparencyAndExactMonochromePalette() throws {
        let bitmap = try XCTUnwrap(atlas().decode().icon(17,small:true))
        let selected = bitmap.tintedIcon(tint:0x204060,text:0)
        XCTAssertEqual(Array(selected.rgba.prefix(8)),[0x19,0x3a,0x5b,0,0x65,0x86,0xa7,255])
        let white = bitmap.tintedIcon(tint:0xffffff,text:0)
        XCTAssertEqual(Array(white.rgba.prefix(4)),[0x89,0x9a,0xab,0],"White uses the original upward-rounded lookup, not the general average.")
        for transparent in [0,1] {
            let template = try XCTUnwrap(atlas(palette:[0xffffff,0],transparent:transparent).decode().icon(17,small:true))
            XCTAssertTrue(template.monochromeIconTemplate)
            for selection: UInt32? in [nil,0x204060] {
                XCTAssertEqual(Array(template.tintedIcon(tint:selection,text:0x13579b).rgba.prefix(8)),[0x13,0x57,0x9b,0,0x13,0x57,0x9b,255])
            }
        }
        let reversed = try XCTUnwrap(atlas(palette:[0,0xffffff]).decode().icon(17,small:true))
        XCTAssertFalse(reversed.monochromeIconTemplate,"The actual palette identity matters; black/white pixel content alone is insufficient.")
    }

    @MainActor func testPreferencesAreIndependentAndRetainSelectionAndFilter() throws {
        _ = NSApplication.shared
        let suite = "KDX-file-size-"+UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
        XCTAssertTrue(preferences.smallFileIcons)
        preferences.smallUserIcons = false
        let files = ClassicList(columns:["Name","Kind"],key:"files",preferences:preferences,kind:.files)
        let users = ClassicList(columns:["Name"],key:"users",preferences:preferences,kind:.users)
        let plain = ClassicList(columns:["Name"],key:"tracker",preferences:preferences)
        files.table.allowsMultipleSelection = true
        files.rows = (0..<4).map { ClassicRow(id:String($0),values:["File \($0)",$0 == 3 ? "Other" : "Match"],iconID:17) }
        files.showFilter(); files.filter.stringValue = "match"
        files.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:files.filter))
        files.table.selectRowIndexes(IndexSet([0,2]),byExtendingSelection:false)
        for small in [false,true,false] {
            preferences.smallFileIcons = small; files.applyStyle(); users.applyStyle(); plain.applyStyle()
            XCTAssertEqual(files.table.rowHeight,small ? 18 : 34)
            XCTAssertEqual(files.scroll.lineScroll,files.table.rowHeight+files.table.intercellSpacing.height)
            XCTAssertEqual(files.filterQuery,"match"); XCTAssertEqual(files.visible.count,3)
            XCTAssertEqual(files.table.selectedRowIndexes,IndexSet([0,2]))
            XCTAssertEqual(users.table.rowHeight,33); XCTAssertEqual(plain.table.rowHeight,19)
            let cell = try XCTUnwrap(files.tableView(files.table,viewFor:files.table.tableColumns[0],row:0) as? ClassicFileCell)
            XCTAssertEqual(cell.rowSize.small,small)
        }
        let restored = ClassicPreferences(root:preferences.root,defaults:try XCTUnwrap(UserDefaults(suiteName:suite)))
        XCTAssertFalse(restored.smallFileIcons)
        XCTAssertEqual(ClassicList(columns:["Folders"],key:"folders",preferences:restored,kind:.files).table.rowHeight,34)
    }

    @MainActor func testNativeSizeFallbackAndSelectionPixelsAtBothScales() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for (small,large) in [(16,32),(10,Optional<Int>.none)] {
            let artwork = try atlas(small:small,large:large)
            var colors = [UInt32](repeating:0,count:221); colors[17] = 0x204060; colors[18] = 0xffffff
            let appearance = ClassicAppearance(id:"file-test",name:"Files",colors:colors,source:"test",artwork:artwork)
            style.configureAssets([appearance]); style.appearance = appearance
            for size: ClassicFileRowSize in [.compact,.normal] {
                let row = ClassicTableRowView(frame:NSRect(x:0,y:0,width:180,height:size.rowHeight))
                let cell = ClassicFileCell(text:ClassicListTextField(labelWithString:"File"),iconID:17,rowSize:size)
                cell.frame = row.bounds; row.addSubview(cell); cell.layoutSubtreeIfNeeded()
                XCTAssertEqual(cell.text.frame.minX,size.iconColumnWidth+4)
                let width = size.small ? small : large ?? small
                let rect = size.iconRect(try XCTUnwrap(artwork.decode().icon(17,small:size.small)))
                XCTAssertEqual(rect.width,CGFloat(width)); XCTAssertEqual(rect.minX,CGFloat((Int(size.iconColumnWidth)-width)/2))
                for (selected,emphasized) in [(false,true),(true,true),(true,false)] { for scale in [1,2] {
                    row.isSelected = selected; row.isEmphasized = emphasized
                    // Draw the actual cell into a known background. No window or desktop capture.
                    let bitmap = try helper.render(scale:scale,width:180,height:Int(size.rowHeight)) {
                        NSColor.black.setFill(); row.bounds.fill(); cell.draw(cell.bounds)
                    }
                    let x = Int(rect.minX), y = Int(rect.midY)
                    for sy in 0..<scale { for sx in 0..<scale {
                        XCTAssertEqual(try helper.color(bitmap,x:x*scale+sx,y:y*scale+sy),0)
                        XCTAssertEqual(try helper.color(bitmap,x:(x+1)*scale+sx,y:y*scale+sy),selected && emphasized ? 0x6586a7 : 0xabcdef)
                        XCTAssertEqual(try helper.color(bitmap,x:(x+width)*scale+sx,y:y*scale+sy),0,"A small fallback must not be enlarged.")
                    } }
                } }
            }
        }
    }

    @MainActor func testOriginalKindTableAndImportedFileRows() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Set KDX_CLASSIC_REFERENCE for original kind-table and artwork checks.") }
        let data = try Data(contentsOf:URL(fileURLWithPath:path))
        guard AppearanceDecoder.digest(data) == "fb3876cd557c3a077f5cd3dbf1b0546d95de8cee7fb56f276b94aa6275fbca18" else { return XCTFail("Unexpected reference revision") }
        for component in 0..<256 { XCTAssertEqual(Int(data[0xf89d8+component]),component/2+128) }
        var kinds: [(String,Int)] = []
        for index in 0..<54 {
            let offset = 0x114c48+index*60
            let kind = try XCTUnwrap(String(data:data[offset+1..<offset+1+Int(data[offset])],encoding:.utf8))
            let icon = Int(data[offset+42])*256+Int(data[offset+43])
            XCTAssertEqual(ClassicFileKind.iconID(kind),icon,kind); kinds.append((kind,icon))
        }
        let imported = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)), style = ClassicStyle.shared
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for appearance in imported.appearances.filter({ ["Mach Lavender","Amber CRT"].contains($0.name) }) {
            style.configureAssets([appearance]); style.appearance = appearance
            let surface = ClassicSurface(frame:NSRect(x:0,y:0,width:720,height:54*35))
            for size: ClassicFileRowSize in [.compact,.normal] { for (index,entry) in kinds.enumerated() {
                let row = ClassicTableRowView(frame:NSRect(x:size.small ? 0 : 360,y:CGFloat(index)*35,width:358,height:size.rowHeight))
                row.isSelected = index%3 != 0; row.isEmphasized = index%3 != 2
                let text = ClassicListTextField(labelWithString:entry.0); text.font = style.font
                let cell = ClassicFileCell(text:text,iconID:entry.1,rowSize:size); cell.frame = row.bounds
                row.addSubview(cell); surface.addSubview(row); cell.layoutSubtreeIfNeeded()
                if entry.1 == 12 { XCTAssertNil(style.artwork?.icon(entry.1,small:size.small),"The original library icon slot is empty.") }
                else { XCTAssertNotNil(style.artwork?.icon(entry.1,small:size.small),entry.0) }
            } }
            for scale in [1,2] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:720*scale,pixelsHigh:54*35*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                bitmap.size = surface.bounds.size; surface.cacheDisplay(in:surface.bounds,to:bitmap)
                if let folder = ProcessInfo.processInfo.environment["KDX_CLASSIC_RENDER_DIR"] {
                    let url = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(appearance.name)-file-icons-\(scale)x.png"))
                }
            }
        }
    }
}
