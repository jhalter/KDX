import AppKit
import XCTest
@testable import KDXClientUI

final class ClassicListScrollingTests: XCTestCase {
    @MainActor func testRealTableScrollbarsMoveBothAxes() throws {
        _ = NSApplication.shared
        let oldAppearance = ClassicStyle.shared.appearance
        ClassicStyle.shared.appearance = .recovery
        defer { ClassicStyle.shared.appearance = oldAppearance }
        let suite = "KDX-scrolling-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let list = ClassicList(columns:["Server","Description","Address"],key:"scroll-test",preferences:ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:320,height:240),styleMask:.borderless,backing:.buffered,defer:true)
        window.isReleasedWhenClosed = false; window.contentView = list
        defer { window.contentView = nil; window.close() }
        list.rows = (0..<100).map { ClassicRow(id:String($0),values:["Server \($0)","Description \($0)","127.0.0.1:10700"]) }
        list.layoutSubtreeIfNeeded(); list.scroll.tile()
        list.table.tableColumns[0].width = 400
        list.table.tile(); list.scroll.reflectScrolledClipView(list.scroll.contentView)
        for horizontal in [false,true] {
            let scroller = try XCTUnwrap((horizontal ? list.scroll.horizontalScroller : list.scroll.verticalScroller) as? ClassicScroller)
            func origin() -> CGFloat { horizontal ? list.scroll.contentView.bounds.minX : list.scroll.contentView.bounds.minY }
            let start = origin()
            scroller.activate(.increment)
            XCTAssertGreaterThan(origin(),start)
            let layout = scroller.geometry
            scroller.moveKnob(to:horizontal ? layout.track.maxX-layout.knob.width : layout.track.maxY-layout.knob.height)
            XCTAssertGreaterThan(origin(),start+100)
            scroller.moveKnob(to:-100)
            XCTAssertEqual(origin(),start,accuracy:0.01)
        }
        list.rows = Array(list.rows.prefix(2))
        list.table.tableColumns[0].width = 100
        list.table.tableColumns[1].width = 60
        list.table.tableColumns[2].width = 60
        list.layoutSubtreeIfNeeded(); list.table.tile(); list.scroll.tile()
        list.scroll.reflectScrolledClipView(list.scroll.contentView)
        for scroller in [list.scroll.verticalScroller,list.scroll.horizontalScroller].compactMap({ $0 }) {
            XCTAssertFalse(scroller.isEnabled)
            let themed = try XCTUnwrap(scroller as? ClassicScroller)
            XCTAssertEqual(themed.geometry.knob,themed.geometry.track,"A disabled bar must not advertise a stale scroll range")
        }
        XCTAssertFalse(window.isVisible)
    }
}
