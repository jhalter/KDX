import AppKit
import XCTest
@testable import KDXClientUI

final class ClassicListFilterTests: XCTestCase {
    @MainActor private func withList(_ run: (ClassicList) throws -> Void) throws {
        let suite = "KDX-filter-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
        let list = ClassicList(columns:["Name","Phone"],key:"filter",preferences:preferences)
        list.frame = NSRect(x:0,y:0,width:360,height:200)
        list.rows = [ClassicRow(id:"jane",values:["Jane Smith","6234 5234"]),ClassicRow(id:"john",values:["John Smith","6234 5234"]),ClassicRow(id:"clark",values:["Clark Kent","5234 1231"])]
        try run(list)
    }
    @MainActor private func change(_ list: ClassicList, to text: String, editor: NSTextView? = nil) {
        list.showFilter(); list.filter.stringValue = text
        list.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:list.filter,userInfo:editor.map { ["NSFieldEditor":$0] }))
    }
    private func key(_ text: String, ignoring: String? = nil, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:text,charactersIgnoringModifiers:ignoring ?? text,isARepeat:false,keyCode:code))
    }

    @MainActor func testFilterAppearsBelowListAndRestoresViewport() throws {
        try withList { list in
            list.layoutSubtreeIfNeeded()
            let frame = try XCTUnwrap(list.scroll.superview)
            XCTAssertFalse(list.isFiltering); XCTAssertTrue(list.filter.isHidden)
            XCTAssertEqual(frame.frame,list.bounds)
            list.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
            change(list,to:"SMITH")
            list.layoutSubtreeIfNeeded()
            XCTAssertTrue(list.isFiltering)
            XCTAssertEqual(list.visible.map(\.id),["jane","john"])
            XCTAssertEqual(list.selected?.id,"jane")
            XCTAssertEqual(list.filter.frame.minY,0)
            XCTAssertEqual(frame.frame.minY,list.filter.frame.maxY+6)
            XCTAssertEqual(frame.frame.maxY,list.bounds.maxY)
            XCTAssertEqual(frame.frame.height+list.filter.frame.height+6,list.bounds.height)
            change(list,to:"")
            list.layoutSubtreeIfNeeded()
            XCTAssertFalse(list.isFiltering); XCTAssertEqual(list.visible.count,3)
            XCTAssertEqual(frame.frame,list.bounds)
            XCTAssertEqual(list.selected?.id,"jane")
        }
    }

    @MainActor func testCommittedQuerySurvivesMarkedTextAndRowRefresh() throws {
        try withList { list in
            change(list,to:"smith")
            let cell = try XCTUnwrap(list.filter.cell as? ClassicTextFieldCell)
            let editor = try XCTUnwrap(cell.fieldEditor(for:list.filter))
            editor.setMarkedText("かな",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            change(list,to:"かな",editor:editor)
            XCTAssertEqual(list.filterQuery,"smith")
            list.rows.append(ClassicRow(id:"kana",values:["かな","1234"]))
            XCTAssertEqual(list.visible.map(\.id),["jane","john"],"A server refresh must not apply uncommitted IME text.")
            XCTAssertFalse(list.control(list.filter,textView:editor,doCommandBy:#selector(NSResponder.cancelOperation(_:))))
            XCTAssertTrue(list.isFiltering)
            editor.unmarkText()
            list.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:list.filter,userInfo:["NSFieldEditor":editor]))
            XCTAssertEqual(list.filterQuery,"かな"); XCTAssertEqual(list.visible.map(\.id),["kana"])
            XCTAssertTrue(list.control(list.filter,textView:editor,doCommandBy:#selector(NSResponder.cancelOperation(_:))))
            XCTAssertFalse(list.isFiltering); XCTAssertEqual(list.visible.count,4)
        }
    }

    @MainActor func testFilterKeysPreserveNativeInputAndCommandPriority() throws {
        let table = ClassicTableView()
        var received: NSEvent?
        table.beginFiltering = { received = $0; return true }
        for event in [try key("s"),try key("",ignoring:"e",flags:.option),try key("👩🏽‍💻")] {
            let accepted = ClassicTableView.startsFilter(event)
            XCTAssertTrue(accepted,"Text event: \(String(describing:event.charactersIgnoringModifiers))")
            if accepted { table.keyDown(with:event); XCTAssertTrue(received === event) }
        }
        for event in [try key("f",flags:.command),try key("f",flags:.control),try key("\r",code:36),try key("\u{1b}",code:53),try key("\u{f701}",code:125),try key("")] {
            XCTAssertFalse(ClassicTableView.startsFilter(event))
        }
        try withList { list in
            var stops = 0
            list.table.command = { _ in stops += 1; return true }
            change(list,to:"smith")
            let escape = try key("\u{1b}",code:53)
            list.table.keyDown(with:escape)
            XCTAssertFalse(list.isFiltering); XCTAssertEqual(stops,0)
            list.table.keyDown(with:escape); XCTAssertEqual(stops,1,"After dismissing the filter, the transfer list's Escape action remains available.")
        }
    }

    @MainActor func testFilterSelectionCommandsAndIndependentLists() throws {
        try withList { first in try withList { second in
            first.table.selectRowIndexes(IndexSet(integer:2),byExtendingSelection:false)
            change(first,to:"smith")
            XCTAssertNil(first.selected,"Do not retarget a selected row to a different item after filtering.")
            XCTAssertEqual(second.visible.count,3); XCTAssertFalse(second.isFiltering)
            let editor = NSTextView()
            XCTAssertTrue(first.control(first.filter,textView:editor,doCommandBy:#selector(NSResponder.moveDown(_:))))
            XCTAssertEqual(first.selected?.id,"jane")
            XCTAssertTrue(first.control(first.filter,textView:editor,doCommandBy:#selector(NSResponder.moveDown(_:))))
            XCTAssertEqual(first.selected?.id,"john")
            XCTAssertTrue(first.control(first.filter,textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:))))
            XCTAssertEqual(first.selected?.id,"john"); XCTAssertTrue(first.isFiltering)
            change(second,to:"kent"); first.clearFilter()
            XCTAssertEqual(first.visible.count,3); XCTAssertEqual(second.visible.map(\.id),["clark"])
        } }
    }

    @MainActor func testReferenceFilteredListRenders() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Provide the original application for list filter theme renders") }
        let appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared, oldFont = style.fontChoiceID
        defer { style.fontChoiceID = oldFont; style.appearance = .recovery; style.configureAssets([]) }
        style.configureAssets(appearances); style.fontChoiceID = nil
        for appearance in appearances where ["Mach Lavender","Amber CRT"].contains(appearance.name) {
            style.appearance = appearance
            try withList { list in
                let surface = ClassicSurface(frame:NSRect(x:0,y:0,width:380,height:220))
                list.translatesAutoresizingMaskIntoConstraints = true
                list.frame = NSRect(x:10,y:10,width:360,height:200); surface.addSubview(list)
                list.table.sortDescriptors = [NSSortDescriptor(key:"0",ascending:true)]
                change(list,to:"smith"); list.layoutSubtreeIfNeeded(); list.scroll.tile(); list.table.layoutSubtreeIfNeeded()
                for scale in [1,2] {
                    let bitmap = try HAPTextFieldTests().raster(surface,scale:scale)
                    let vertical = try XCTUnwrap(list.scroll.verticalScroller), horizontal = try XCTUnwrap(list.scroll.horizontalScroller)
                    let corner = list.scroll.convert(NSPoint(x:vertical.frame.midX,y:horizontal.frame.midY),to:surface)
                    XCTAssertEqual(try HAPWindowTests().color(bitmap,x:Int(corner.x)*scale,y:Int(corner.y)*scale),appearance.colors[2])
                    if let directory = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"] {
                        let folder = URL(fileURLWithPath:directory,isDirectory:true); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent("\(appearance.name)-filtered-list-\(scale)x.png"))
                    }
                }
            }
        }
    }
}
