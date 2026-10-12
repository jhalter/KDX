import AppKit
import XCTest
@testable import KDXClassicUI

final class ClassicColumnMenuTests: XCTestCase {
    @MainActor private func activate(_ menu: ClassicMenu, _ index: Int) throws {
        _ = NSApplication.shared
        menu.prepareForDisplay()
        XCTAssertTrue(try XCTUnwrap(menu.items[index].view as? ClassicMenuItemView).activate())
    }
    @MainActor private func table() -> (NSTableView,ClassicTableHeaderView) {
        let table = NSTableView(frame:NSRect(x:0,y:0,width:400,height:200))
        let header = ClassicTableHeaderView(frame:NSRect(x:0,y:0,width:400,height:23))
        table.headerView = header; table.allowsColumnReordering = true
        for id in ["a","b","c","d"] {
            let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id))
            column.title = id.uppercased(); column.width = 100; table.addTableColumn(column)
        }
        return (table,header)
    }

    @MainActor func testNativeMenuActionsPreserveListStateAndRestoreColumns() throws {
        let suite = "KDX-column-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite)); defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
        let list = ClassicList(columns:["Name","Size","Kind","Date"],key:"files",preferences:preferences)
        list.rows = [ClassicRow(id:"a",values:["Alpha","10","Text","1"]),ClassicRow(id:"b",values:["Beta","2","Text","2"])]
        list.table.sortDescriptors = [NSSortDescriptor(key:"1",ascending:true)]
        list.showFilter(); list.filter.stringValue = "text"
        list.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:list.filter))
        list.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        let header = try XCTUnwrap(list.table.headerView as? ClassicTableHeaderView)
        let size = list.table.tableColumns[1]; size.width = 162
        let kind = list.table.tableColumns[2]
        try activate(XCTUnwrap(header.reorderMenu(forColumn:2)),0)
        XCTAssertTrue(list.table.tableColumns[0] === kind)
        let first = try XCTUnwrap(header.reorderMenu(forColumn:0))
        XCTAssertEqual(first.items.map(\.isEnabled),[false,false,true,true])
        first.prepareForDisplay()
        XCTAssertFalse(try XCTUnwrap(first.items[0].view as? ClassicMenuItemView).activate())
        try activate(first,3)
        XCTAssertTrue(list.table.tableColumns[3] === kind)
        let last = try XCTUnwrap(header.reorderMenu(forColumn:3))
        XCTAssertEqual(last.items.map(\.isEnabled),[true,true,false,false])
        try activate(last,1); XCTAssertTrue(list.table.tableColumns[2] === kind)
        try activate(XCTUnwrap(header.reorderMenu(forColumn:2)),2)
        XCTAssertEqual(list.table.tableColumns.map(\.identifier.rawValue),["0","1","3","2"])
        XCTAssertEqual(list.visible.map(\.id),["b","a"]); XCTAssertEqual(list.selected?.id,"b")
        XCTAssertEqual(list.filterQuery,"text"); XCTAssertTrue(list.isFiltering)
        XCTAssertEqual(list.table.sortDescriptors.first?.key,"1")
        XCTAssertTrue(try XCTUnwrap(size.headerCell as? ClassicTableHeaderCell).sorted)
        XCTAssertEqual(size.width,162)
        XCTAssertEqual(defaults.array(forKey:"column-order.files") as? [String],["0","1","3","2"])
        let restored = ClassicList(columns:["Name","Size","Kind","Date"],key:"files",preferences:preferences)
        XCTAssertEqual(restored.table.tableColumns.map(\.identifier.rawValue),["0","1","3","2"])
        XCTAssertEqual(restored.table.tableColumns.first { $0.identifier.rawValue == "1" }?.width,162)
        XCTAssertEqual(restored.table.sortDescriptors.first?.key,"1")
    }

    @MainActor func testActionRetainsColumnIdentityAndRejectsStaleTargets() throws {
        let (first,header) = table(), (second,_) = table()
        let column = first.tableColumns[1]
        let menu = try XCTUnwrap(header.reorderMenu(forColumn:1))
        first.moveColumn(1,toColumn:0)
        try activate(menu,2)
        XCTAssertEqual(first.tableColumns.map(\.identifier.rawValue),["a","b","c","d"])
        XCTAssertEqual(second.tableColumns.map(\.identifier.rawValue),["a","b","c","d"])
        first.allowsColumnReordering = false
        try activate(menu,3)
        XCTAssertTrue(first.tableColumns[1] === column)
        XCTAssertNil(header.reorderMenu(forColumn:1))
        first.allowsColumnReordering = true
        column.isHidden = true; try activate(menu,3)
        XCTAssertTrue(first.tableColumns[1] === column)
        column.isHidden = false; first.removeTableColumn(column)
        let replacement = NSTableColumn(identifier:column.identifier); first.addTableColumn(replacement)
        let before = first.tableColumns
        try activate(menu,0)
        XCTAssertEqual(first.tableColumns,before,"A new column with the same identifier is not the clicked object.")
        XCTAssertNil(header.reorderMenu(forColumn:-1)); XCTAssertNil(header.reorderMenu(forColumn:10))
        first.isEnabled = false; XCTAssertNil(header.reorderMenu(forColumn:0))
    }

    @MainActor func testHiddenColumnsDelegateRestrictionsAndHeaderHitTesting() throws {
        let (table,header) = table()
        let left = table.tableColumns[0]; left.isHidden = true
        let menu = try XCTUnwrap(header.reorderMenu(forColumn:1))
        XCTAssertEqual(menu.items.map(\.isEnabled),[false,false,true,true])
        XCTAssertNil(header.reorderMenu(forColumn:0))
        try activate(XCTUnwrap(header.reorderMenu(forColumn:3)),0)
        XCTAssertEqual(table.tableColumns.map(\.identifier.rawValue),["a","d","b","c"])
        let restrictions = ColumnDelegate(); table.delegate = restrictions
        let blocked = try XCTUnwrap(header.reorderMenu(forColumn:1))
        XCTAssertEqual(blocked.items.map(\.isEnabled),[false,false,false,false])
        restrictions.allow = true
        let available = try XCTUnwrap(header.reorderMenu(forColumn:1))
        restrictions.allow = false
        try activate(available,3)
        XCTAssertEqual(table.tableColumns.map(\.identifier.rawValue),["a","d","b","c"],"Recheck the delegate when dispatching a previously available action.")
        table.delegate = nil; left.isHidden = false
        let rect = header.headerRect(ofColumn:2)
        let point = header.convert(NSPoint(x:rect.midX,y:rect.midY),to:nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with:.rightMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
        XCTAssertEqual(header.menu(for:event)?.title,"B")
        let outside = try XCTUnwrap(NSEvent.mouseEvent(with:.rightMouseDown,location:header.convert(NSPoint(x:-10,y:5),to:nil),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
        XCTAssertNil(header.menu(for:outside))
    }

    @MainActor func testOriginalCommandLabelsAndDispatchInstructions() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Set KDX_CLASSIC_REFERENCE for the original column menu.") }
        let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
        var offset = 0x108aa4
        let (table,header) = table()
        let menu = try XCTUnwrap(header.reorderMenu(forColumn:1))
        XCTAssertTrue(table.allowsColumnReordering)
        for item in menu.items {
            let length = Int(bytes.bytes[offset])
            XCTAssertEqual(item.title,String(data:try bytes.data(offset+1,length),encoding:.utf8))
            offset += length+1
        }
        for (address,instruction) in [(0x89a2c,0x83c28e9c),(0x89ba4,0x38800065),(0x89bc4,0x38800066),(0x89be0,0x38800067),(0x89bfc,0x38800068),
                                      (0x899cc,0x38a0f000),(0x899dc,0x38a0ffff),(0x899ec,0x38a00001),(0x899fc,0x38a01000)] {
            XCTAssertEqual(try bytes.u32(address+0x1de0),instruction)
        }
    }
}

@MainActor private final class ColumnDelegate: NSObject, NSTableViewDelegate {
    var allow = false
    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool { allow }
}
