import AppKit
import XCTest
@testable import KDXClassicUI

final class ClassicCommandsMenuTests: XCTestCase {
    @MainActor func testConnectionActionsCaptureIdentityAndRespectState() throws {
        _ = NSApplication.shared
        let a = UUID(), b = UUID(), tracker = UUID()
        let connections = [
            ClassicCommandConnection(id:a,title:"Same name",address:"a.invalid:10700",connected:true,connecting:false),
            ClassicCommandConnection(id:b,title:"Same name",address:"b.invalid:10701",connected:false,connecting:false)
        ]
        var commands = [ClassicCommand]()
        let menu = ClassicCommandsMenu.make(connections:connections,trackers:[ClassicCommandTracker(id:tracker,title:"Directory",address:"directory.invalid:10800")],selected:a,compact:true) { commands.append($0) }
        XCTAssertEqual((menu.item(withTitle:"Connect…")?.representedObject as? ClassicMenuAction)?.iconID,84)
        XCTAssertEqual((menu.item(withTitle:"Address Book")?.representedObject as? ClassicMenuAction)?.iconID,78)
        let first = try XCTUnwrap(menu.item(withTitle:"Same name — a.invalid:10700"))
        let second = try XCTUnwrap(menu.item(withTitle:"Same name — b.invalid:10701"))
        XCTAssertEqual(first.state,.on); XCTAssertEqual(second.state,.off)
        XCTAssertEqual(menu.item(withTitle:"Small Button Bar")?.state,.on)
        let firstMenu = try XCTUnwrap(first.submenu as? ClassicMenu)
        let secondMenu = try XCTUnwrap(second.submenu as? ClassicMenu)
        firstMenu.prepareForDisplay(); secondMenu.prepareForDisplay()
        for action in ClassicServerCommand.allCases {
            let row = try XCTUnwrap(firstMenu.item(withTitle:action.rawValue))
            let view = try XCTUnwrap(row.view as? ClassicMenuItemView)
            let enabled = action != .reconnect
            XCTAssertEqual(row.isEnabled,enabled)
            XCTAssertEqual(view.activate(),enabled)
            if enabled { XCTAssertEqual(commands.last,.server(a,action)) }
        }
        let beforeDisabled = commands.count
        for action in [ClassicServerCommand.rooms,.files,.profile,.away,.disconnect] {
            let row = try XCTUnwrap(secondMenu.item(withTitle:action.rawValue))
            XCTAssertFalse(row.isEnabled)
            XCTAssertFalse(try XCTUnwrap(row.view as? ClassicMenuItemView).activate())
        }
        XCTAssertEqual(commands.count,beforeDisabled)
        for action in [ClassicServerCommand.select,.users,.transfers,.reconnect] {
            let view = try XCTUnwrap(secondMenu.item(withTitle:action.rawValue)?.view as? ClassicMenuItemView)
            XCTAssertTrue(view.activate()); XCTAssertEqual(commands.last,.server(b,action))
        }
        let trackerMenu = try XCTUnwrap(menu.item(withTitle:"Tracker — Directory")?.submenu as? ClassicMenu)
        trackerMenu.prepareForDisplay()
        for action in ClassicTrackerCommand.allCases {
            let view = try XCTUnwrap(trackerMenu.item(withTitle:action.rawValue)?.view as? ClassicMenuItemView)
            XCTAssertTrue(view.activate()); XCTAssertEqual(commands.last,.tracker(tracker,action))
        }
    }

    @MainActor func testDispatcherRevalidatesMissingAndDisconnectedTargets() throws {
        _ = NSApplication.shared
        let app = ClassicApplication(), a = ClassicSession(endpoint:ClassicEndpoint()), b = ClassicSession(endpoint:ClassicEndpoint())
        app.sessions = [a.id:a,b.id:b]; app.selectedSession = b.id
        // This menu was built while the peer was connected; it is now offline.
        let stale = ClassicCommandsMenu.make(connections:[ClassicCommandConnection(id:a.id,title:"Peer",address:"a.invalid",connected:true,connecting:false)],trackers:[],selected:b.id,compact:false) { app.performCommand($0) }
        let submenu = try XCTUnwrap(stale.item(withTitle:"Peer")?.submenu as? ClassicMenu)
        submenu.prepareForDisplay()
        let files = try XCTUnwrap(submenu.item(withTitle:ClassicServerCommand.files.rawValue)?.view as? ClassicMenuItemView)
        XCTAssertTrue(files.activate())
        XCTAssertTrue(app.windows.isEmpty,"Disconnected target is rejected before opening a file window.")
        XCTAssertEqual(app.selectedSession,b.id)
        let select = try XCTUnwrap(submenu.item(withTitle:ClassicServerCommand.select.rawValue)?.view as? ClassicMenuItemView)
        XCTAssertTrue(select.activate()); XCTAssertEqual(app.selectedSession,a.id)
        app.sessions.removeValue(forKey:a.id); app.selectedSession = b.id
        XCTAssertTrue(select.activate()); XCTAssertEqual(app.selectedSession,b.id,"Removed targets cannot select another session.")
        app.performCommand(.tracker(UUID(),.refresh))
        XCTAssertTrue(app.utilityWindows.isEmpty,"Closed tracker IDs cannot reopen or query another tracker.")
    }

    @MainActor func testConnectingAndEmptyMenus() throws {
        _ = NSApplication.shared
        for action in ClassicServerCommand.allCases {
            XCTAssertEqual(action.isEnabled(connected:false,connecting:true),[.select,.users,.transfers,.disconnect].contains(action))
        }
        var commands = [ClassicCommand]()
        let menu = ClassicCommandsMenu.make(connections:[],trackers:[],selected:nil,compact:false) { commands.append($0) }
        menu.prepareForDisplay()
        for (title,command) in [("Connect…",ClassicCommand.connect),("Address Book",.addressBook),("Appearances…",.appearances),("Small Button Bar",.smallButtonBar)] {
            XCTAssertTrue(try XCTUnwrap(menu.item(withTitle:title)?.view as? ClassicMenuItemView).activate())
            XCTAssertEqual(commands.last,command)
        }
        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count,1)
        XCTAssertFalse(menu.items.contains { $0.submenu != nil })
    }
}
