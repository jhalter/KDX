import AppKit
import XCTest
@testable import KDXClientUI

final class ClassicListSelectionTests: XCTestCase {
    @MainActor private func withList(_ body: (ClassicList,ClassicPreferences) throws -> Void) throws {
        _ = NSApplication.shared
        let suite = "KDX-selection-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
        let list = ClassicList(columns:["Name","Kind"],key:"files",preferences:preferences,kind:.files)
        list.frame = NSRect(x:0,y:0,width:400,height:240)
        list.table.allowsMultipleSelection = true
        list.rows = [ClassicRow(id:"a",values:["Alpha","keep"]),ClassicRow(id:"b",values:["Beta","other"]),ClassicRow(id:"c",values:["Gamma","keep"])]
        let owner = ClassicWindowController(title:"Selection test",key:"test",size:NSSize(width:420,height:280),preferences:preferences)
        owner.install(list)
        try body(list,preferences)
        XCTAssertFalse(try XCTUnwrap(owner.window).isVisible)
    }
    @MainActor private func selected(_ list: ClassicList) -> Set<String> {
        Set(list.table.selectedRowIndexes.compactMap { list.visible.indices.contains($0) ? list.visible[$0].id : nil })
    }
    @MainActor func testMultipleSelectionSurvivesSortingRefreshAndFiltering() throws {
        try withList { list,_ in
            list.table.selectRowIndexes(IndexSet([0,2]),byExtendingSelection:false)
            list.table.sortDescriptors = [NSSortDescriptor(key:"0",ascending:false)]
            XCTAssertEqual(selected(list),["a","c"])
            list.rows.insert(ClassicRow(id:"d",values:["Zebra","keep"]),at:0)
            XCTAssertEqual(selected(list),["a","c"],"A new row must not inherit an existing row's selection.")
            list.rows[1].values[0] = "Omega"
            XCTAssertEqual(selected(list),["a","c"],"Changing a selected file's sort position keeps its identity selected.")
            list.showFilter(); list.filter.stringValue = "keep"
            list.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:list.filter))
            XCTAssertEqual(selected(list),["a","c"])
            list.rows.removeAll { $0.id == "c" }
            XCTAssertEqual(selected(list),["a"])
            list.clearFilter()
            XCTAssertEqual(selected(list),["a"])
            list.rows.removeAll { $0.id == "a" }
            XCTAssertTrue(selected(list).isEmpty,"Removing the selected file must not select its former neighbor.")
        }
    }
    @MainActor func testThemeAndIconSizeUpdatesDoNotDispatchSelectionActions() throws {
        let style = ClassicStyle.shared, previous = style.appearance
        defer { style.appearance = previous }
        try withList { list,preferences in
            list.table.selectRowIndexes(IndexSet([0,2]),byExtendingSelection:false)
            var actions = [String?]()
            list.selectionChanged = { actions.append($0?.id) }
            for (index,small) in [false,true,false].enumerated() {
                var colors = (0..<221).map { UInt32($0)*0x010101 }
                colors[15] = index == 1 ? 0x123456 : 0xabcdef
                style.appearance = ClassicAppearance(id:String(index),name:"Test",colors:colors,source:"test")
                preferences.smallFileIcons = small; list.applyStyle()
                XCTAssertEqual(selected(list),["a","c"])
                XCTAssertEqual(list.table.backgroundColor,style.color(15))
                XCTAssertEqual(list.fileRowSize,small ? .compact : .normal)
            }
            XCTAssertTrue(actions.isEmpty,"Restyling must not reload tracker groups or switch message recipients.")
        }
    }
    @MainActor func testRefreshNotificationsNeverExposeAnUnselectedNeighbor() throws {
        try withList { list,_ in
            list.table.selectRowIndexes(IndexSet(integer:2),byExtendingSelection:false)
            var actions = [String?]()
            list.selectionChanged = { actions.append($0?.id) }
            list.rows = [list.rows[2],list.rows[0],list.rows[1]]
            XCTAssertEqual(selected(list),["c"])
            XCTAssertTrue(actions.isEmpty,"Moving the same selected item must not dispatch another selection action.")
            actions = []
            list.rows.removeAll { $0.id == "c" }
            XCTAssertTrue(selected(list).isEmpty)
            XCTAssertEqual(actions,[nil])
        }
    }
}
