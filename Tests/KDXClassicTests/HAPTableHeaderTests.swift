import AppKit
import XCTest
@testable import KDXClassicUI

final class HAPTableHeaderTests: XCTestCase {
    @MainActor func testOriginalHeaderHeightInNativeListsAndReferenceCallers() throws {
        let suite = "KDX-header-height-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite)); defer { defaults.removePersistentDomain(forName:suite) }
        let list = ClassicList(columns:["Name","Size"],key:"height",preferences:ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults))
        list.frame = NSRect(x:0,y:0,width:400,height:220)
        list.layoutSubtreeIfNeeded(); list.scroll.tile()
        XCTAssertEqual(list.table.headerView?.frame.height,20)
        XCTAssertEqual(list.table.headerView?.superview?.frame.height,20)
        list.frame.size.width = 500; list.table.moveColumn(0,toColumn:1)
        list.applyStyle(); list.layoutSubtreeIfNeeded(); list.scroll.tile()
        XCTAssertEqual(list.table.headerView?.frame.height,20)
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Set KDX_CLASSIC_REFERENCE for original header geometry evidence.") }
        let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
        for (address,instruction) in [(0x87ed0,0x38000014),(0xab21c,0x38800014),(0xab224,0x38c00014),(0xab240,0x38600000),
                                      (0xac040,0x38800014),(0xac048,0x38c00014),(0x99108,0x38650003),(0x9910c,0x3804fffd),
                                      (0x99174,0x4bfc928d),(0x9d3b0,0x639c0010),(0x9d3fc,0x4bfc4e85),(0x623dc,0x38c10048),(0x623e0,0x38fb0028)] {
            XCTAssertEqual(try bytes.u32(address+0x1de0),instruction)
        }
    }

    @MainActor func testHeaderTitleGlyphsUsePaletteTruncationOrExistingBitmapClip() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Set KDX_CLASSIC_REFERENCE for header title glyph checks.") }
        let appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared, helper = HAPWindowTests(), previousFont = style.fontChoiceID
        defer { style.fontChoiceID = previousFont; style.configureAssets([]); style.appearance = .recovery }
        style.configureAssets(appearances); style.fontChoiceID = nil
        let data = try XCTUnwrap(appearances.compactMap(\.fonts).flatMap { $0 }.first { (try? HaxialFont(data:$0).name) == "Myoklonika" })
        let strike = try HaxialFont(data:data).strikes[0], letter = strike.glyphs[65]
        let ellipsis = try XCTUnwrap(strike.glyphs.first { $0.codepoint == 0x2026 })
        XCTAssertEqual(letter.advance,10); XCTAssertEqual(ellipsis.advance,14); XCTAssertEqual(strike.height,15)
        for appearance in appearances where ["Mach Lavender","Amber CRT"].contains(appearance.name) {
            for skin in [false,true] {
                var selectedAppearance = appearance
                if skin {
                    var bytes = [UInt8](HAPArtworkTests().skinSection())
                    for id in [134,135,136] { HAPArtworkTests().put(2112,64+id*4,in:&bytes) }
                    selectedAppearance.artwork = try HAPArtwork(skins:Data(bytes),icons:Data())
                }
                style.appearance = selectedAppearance
                for (selected,pressed,enabled,textSlot) in [(false,false,true,178),(true,false,true,182),(false,true,true,42),(false,false,false,49)] {
                    for scale in [1,2] {
                        let rect = NSRect(x:0,y:0,width:30,height:20)
                        let blank = try helper.render(scale:scale,width:30,height:20) {
                            HAPTableHeaderDrawing.draw(rect,title:"",selected:selected,pressed:pressed,enabled:enabled)
                        }
                        let bitmap = try helper.render(scale:scale,width:30,height:20) {
                            HAPTableHeaderDrawing.draw(rect,title:"AAAAA",selected:selected,pressed:pressed,enabled:enabled)
                        }
                        // Palette path fits exactly A (10) + ellipsis (14) into
                        // x=3…27. Bitmap path centers all five As at x=-10 and
                        // clips them to x=0…30, exposing three complete As.
                        for y in 0..<20 { for x in 0..<30 {
                            let set: Bool
                            if skin { set = letter.isSet(x:x%10-letter.x,y:y-2-letter.y) }
                            else { set = letter.isSet(x:x-3-letter.x,y:y-2-letter.y) || ellipsis.isSet(x:x-13-ellipsis.x,y:y-2-ellipsis.y) }
                            for sy in 0..<scale { for sx in 0..<scale {
                                let background = try helper.color(blank,x:x*scale+sx,y:y*scale+sy)
                                let expected = set ? (skin ? 0x123456 : appearance.colors[textSlot]) : background
                                XCTAssertEqual(try helper.color(bitmap,x:x*scale+sx,y:y*scale+sy),expected,"\(appearance.name), skin=\(skin), \(x),\(y), \(scale)x")
                            } }
                        } }
                    }
                }
                if skin { for scale in [1,2] {
                    let rect = NSRect(x:0,y:0,width:31,height:20)
                    let blank = try helper.render(scale:scale,width:45,height:20) {
                        NSRect(x:0,y:0,width:39,height:20).clip()
                        HAPTableHeaderDrawing.draw(rect,title:"",selected:false,pressed:false,enabled:true)
                    }
                    let bitmap = try helper.render(scale:scale,width:45,height:20) {
                        NSRect(x:0,y:0,width:39,height:20).clip()
                        HAPTableHeaderDrawing.draw(rect,title:"AAAAA",selected:false,pressed:false,enabled:true)
                    }
                    // (31 - 50) / 2 truncates toward zero to -9. The last A
                    // starts at 31, outside the header frame but within the
                    // existing graphics clip, as in the original glyph blitter.
                    for y in 0..<20 { for x in 0..<45 {
                        let set = x < 39 && letter.isSet(x:(x+9)%10-letter.x,y:y-2-letter.y)
                        for sy in 0..<scale { for sx in 0..<scale {
                            let expected = set ? 0x123456 : try helper.color(blank,x:x*scale+sx,y:y*scale+sy)
                            XCTAssertEqual(try helper.color(bitmap,x:x*scale+sx,y:y*scale+sy),expected)
                        } }
                    } }
                } }
            }
        }
    }

    @MainActor func testNativeHeaderPaintsUnusedTailAfterBitmapTitles() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.configureAssets([]); style.appearance = .recovery }
        var bytes = [UInt8](HAPArtworkTests().skinSection())
        HAPArtworkTests().put(2112,64+134*4,in:&bytes)
        style.appearance = ClassicAppearance(id:"overflow",name:"Overflow",colors:[UInt32](repeating:0,count:204),source:"test",artwork:try HAPArtwork(skins:Data(bytes),icons:Data()))
        let table = NSTableView(frame:NSRect(x:0,y:0,width:120,height:80))
        table.columnAutoresizingStyle = .noColumnAutoresizing; table.intercellSpacing = .zero
        let header = ClassicTableHeaderView(frame:NSRect(x:0,y:0,width:120,height:20)); table.headerView = header
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("0")); column.minWidth = 1; column.width = 30
        column.headerCell = ClassicTableHeaderCell(textCell:String(repeating:"A",count:20)); table.addTableColumn(column)
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:120,height:100))
        scroll.borderType = .noBorder; scroll.documentView = table
        scroll.layoutSubtreeIfNeeded(); scroll.tile(); table.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.bounds,NSRect(x:0,y:0,width:120,height:20))
        XCTAssertTrue(header.tableView === table)
        let end = header.headerRect(ofColumn:0).maxX
        let tail = NSRect(x:end,y:0,width:120-end,height:20)
        XCTAssertGreaterThan(tail.width,30)
        for scale in [1,2] {
            let actual = try helper.render(scale:scale,width:120,height:20) { header.draw(header.bounds) }
            let expected = try helper.render(scale:scale,width:120,height:20) { HAPTableHeaderDrawing.draw(tail,title:"",selected:false,pressed:false,enabled:true) }
            for y in 0..<20 { for x in Int(end)..<120 {
                XCTAssertEqual(try helper.color(actual,x:x*scale,y:y*scale),try helper.color(expected,x:x*scale,y:y*scale))
            } }
        }
    }

    @MainActor func testPartialHeaderRedrawMatchesFullCompositionWithOverflowAndHiddenColumns() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.configureAssets([]); style.appearance = .recovery }
        var bytes = [UInt8](HAPArtworkTests().skinSection())
        HAPArtworkTests().put(2112,64+134*4,in:&bytes)
        style.appearance = ClassicAppearance(id:"partial",name:"Partial",colors:[UInt32](repeating:0,count:204),source:"test",artwork:try HAPArtwork(skins:Data(bytes),icons:Data()))
        let table = NSTableView(frame:NSRect(x:0,y:0,width:120,height:80))
        table.columnAutoresizingStyle = .noColumnAutoresizing; table.intercellSpacing = .zero
        let header = ClassicTableHeaderView(frame:NSRect(x:0,y:0,width:120,height:20)); table.headerView = header
        for index in 0..<3 {
            let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier(String(index)))
            column.minWidth = 1; column.width = 30
            column.headerCell = ClassicTableHeaderCell(textCell:String(repeating:index == 1 ? "H" : "A",count:20))
            table.addTableColumn(column); column.isHidden = index == 1
        }
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:120,height:100))
        scroll.borderType = .noBorder; scroll.documentView = table
        scroll.layoutSubtreeIfNeeded(); scroll.tile(); table.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.bounds,NSRect(x:0,y:0,width:120,height:20))
        for scale in [1,2] {
            let full = try helper.render(scale:scale,width:120,height:20) { header.draw(header.bounds) }
            let partial = try helper.render(scale:scale,width:120,height:20) {
                // Deliberately repaint narrow strips in reverse order. Titles
                // originating outside a strip must still compose into it.
                for x in stride(from:110,through:0,by:-10) { header.draw(NSRect(x:x,y:0,width:10,height:20)) }
            }
            var mismatch: String?
            for y in 0..<(20*scale) { for x in 0..<(120*scale) {
                if mismatch == nil, try helper.color(full,x:x,y:y) != helper.color(partial,x:x,y:y) { mismatch = "Pixel \(x),\(y) at \(scale)x" }
            } }
            XCTAssertNil(mismatch)
        }
    }

    @MainActor func testOriginalListPaletteAndSelectionFocus() throws {
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery }
        style.appearance = ClassicAppearance(id:"list-colors",name:"List colors",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test")
        let helper = HAPWindowTests()
        let table = ClassicTableView(frame:NSRect(x:0,y:0,width:240,height:60))
        for (id,width) in [("0",80.0),("1",160.0)] {
            let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id)); column.width = width; table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key:"1",ascending:true)]
        let sorted = table.rect(ofColumn:1)
        for scale in [1,2] {
            for emphasized in [false,true] {
                let bitmap = try helper.render(scale:scale,width:240,height:60) {
                    table.drawBackground(inClipRect:NSRect(x:0,y:0,width:240,height:60))
                    HAPListDrawing.selection(NSRect(x:0,y:0,width:240,height:20),emphasized:emphasized)
                }
                for (x,y,slot) in [(10,40,15),(Int(sorted.midX),40,19),(1,1,17),(10,10,emphasized ? 17 : 15),(Int(sorted.midX),10,emphasized ? 17 : 19)] {
                    XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),UInt32(slot)*0x010101)
                }
            }
        }
        let row = ClassicTableRowView(frame:NSRect(x:0,y:0,width:240,height:20))
        let text = ClassicListTextField(labelWithString:"Selection"); text.frame = NSRect(x:4,y:0,width:180,height:20); row.addSubview(text)
        for (selected,emphasized,slot) in [(false,false,16),(true,true,18),(true,false,16)] {
            row.isSelected = selected; row.isEmphasized = emphasized
            _ = try helper.render(scale:1,width:240,height:20) { text.draw(text.bounds) }
            XCTAssertEqual(text.textColor,style.color(slot))
        }
    }
    @MainActor func testPaletteHeaderStatesAndBitmapOverride() throws {
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery }
        let colors = (0..<221).map { UInt32($0)*0x010101 }
        let helper = HAPWindowTests()
        for scale in [1,2] {
            for (selected,pressed,enabled,fill,outline,top,bottom) in [(false,false,true,176,174,175,177),(true,false,true,180,174,181,179),(true,true,true,38,41,36,40),(false,false,false,45,48,43,47)] {
                style.appearance = ClassicAppearance(id:"headers",name:"Headers",colors:colors,source:"test")
                let bitmap = try helper.render(scale:scale,width:100,height:23) { HAPTableHeaderDrawing.draw(NSRect(x:0,y:0,width:100,height:23),title:"",selected:selected,pressed:pressed,enabled:enabled) }
                for (x,y,slot) in [(50,10,fill),(0,0,outline),(50,1,top),(50,21,bottom)] {
                    XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),UInt32(slot)*0x010101)
                }
                var bytes = [UInt8](HAPArtworkTests().skinSection())
                let id = !enabled ? 136 : selected || pressed ? 135 : 134
                bytes.replaceSubrange((64+id*4)..<(68+id*4),with:bytes[100..<104])
                style.appearance.artwork = try HAPArtwork(skins:Data(bytes),icons:Data())
                let skinBitmap = try helper.render(scale:scale,width:100,height:23) { HAPTableHeaderDrawing.draw(NSRect(x:0,y:0,width:100,height:23),title:"",selected:selected,pressed:pressed,enabled:enabled) }
                XCTAssertEqual(try helper.color(skinBitmap,x:50*scale,y:10*scale),0x0000ff)
            }
        }
    }
    @MainActor func testNativeListSortingAndHeaderRenders() throws {
        let style = ClassicStyle.shared
        var appearances = [ClassicAppearance.recovery]
        if let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] {
            appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances.filter { ["Mach Lavender","Amber CRT"].contains($0.name) }
        }
        defer { style.appearance = .recovery; style.configureAssets([]) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let suite = "KDX-test-headers-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite)); defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = ClassicPreferences(root:root,defaults:defaults)
        for appearance in appearances {
            style.configureAssets([appearance]); style.appearance = appearance
            let list = ClassicList(columns:["Name","Size"],key:"headers-"+appearance.id,preferences:preferences)
            list.frame = NSRect(x:0,y:0,width:400,height:220)
            list.rows = [ClassicRow(id:"b",values:["Banana","2"]),ClassicRow(id:"a",values:["Apple","10"])]
            list.table.sortDescriptors = [NSSortDescriptor(key:"0",ascending:true)]
            XCTAssertEqual(list.visible.map(\.id),["a","b"])
            XCTAssertEqual((list.table.tableColumns[0].headerCell as? ClassicTableHeaderCell)?.sorted,true)
            XCTAssertEqual((list.table.tableColumns[1].headerCell as? ClassicTableHeaderCell)?.sorted,false)
            list.table.sortDescriptors = [NSSortDescriptor(key:"0",ascending:false)]
            XCTAssertEqual(list.visible.map(\.id),["b","a"])
            list.table.moveColumn(0,toColumn:1)
            XCTAssertEqual(list.table.tableColumns[1].identifier.rawValue,"0")
            XCTAssertEqual((list.table.tableColumns[1].headerCell as? ClassicTableHeaderCell)?.sorted,true)
            list.table.tableColumns[1].width = 160
            list.layoutSubtreeIfNeeded(); list.scroll.tile(); list.table.layoutSubtreeIfNeeded()
            list.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
            let selectedRow = try XCTUnwrap(list.table.rowView(atRow:0,makeIfNecessary:true) as? ClassicTableRowView)
            selectedRow.isEmphasized = true
            for scale in [1,2] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:400*scale,pixelsHigh:220*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                bitmap.size = list.bounds.size; list.cacheDisplay(in:list.bounds,to:bitmap)
                if let folder = ProcessInfo.processInfo.environment["KDX_CLASSIC_RENDER_DIR"] {
                    let url = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(appearance.name)-native-list-\(scale)x.png"))
                }
            }
        }
    }
}
