import AppKit
import XCTest
@testable import KDXClassicUI
@testable import KDXCore

final class ClassicUsersTests: XCTestCase {
    @MainActor private final class HeadlessUsersWindow: ClassicUsersWindow {
        override func showError(_ error: Error) { XCTFail(error.localizedDescription) }
        override func showMessage(_ text: String, title: String = "KDX") { XCTFail("Unexpected dialog: \(title)") }
    }
    @MainActor private func preferences() throws -> (ClassicPreferences,() -> Void) {
        let suite = "KDX-users-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        return (ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults),{ defaults.removePersistentDomain(forName:suite) })
    }
    @MainActor func testTemplateGeometryAndInvitationExtension() throws {
        let (preferences,cleanup) = try preferences(); defer { cleanup() }
        let form = ClassicUsersForm(preferences:preferences); form.layoutSubtreeIfNeeded()
        XCTAssertEqual(form.bounds.size,NSSize(width:300,height:400))
        XCTAssertEqual(form.server.frame,NSRect(x:4,y:4,width:236,height:20))
        XCTAssertEqual(form.count.frame,NSRect(x:243,y:6,width:55,height:16))
        XCTAssertEqual(form.list.frame,NSRect(x:0,y:29,width:300,height:371))
        XCTAssertTrue(form.invitationPanel.isHidden)
        XCTAssertTrue(form.list.table.nextKeyView === form.server)
        if let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] {
            let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path))), base = 0xedea8
            XCTAssertEqual(form.bounds.size,try NSSize(width:bytes.u16(base+16),height:bytes.u16(base+18)))
            for (view,offset) in [(form.server as NSView,0xd4),(form.count,0x108),(form.list,0x13c)] {
                let x = try bytes.u16(base+offset+4), y = try bytes.u16(base+offset+6)
                XCTAssertEqual(view.frame,try NSRect(x:x,y:y,width:bytes.u16(base+offset+8)-x,height:bytes.u16(base+offset+10)-y))
            }
        }
        form.frame.size = NSSize(width:500,height:600); form.layoutSubtreeIfNeeded()
        XCTAssertEqual(form.server.frame,NSRect(x:4,y:4,width:436,height:20))
        XCTAssertEqual(form.count.frame.maxX,498)
        form.hasInvitations = true; form.layoutSubtreeIfNeeded()
        XCTAssertTrue(form.list.table.nextKeyView === form.invitations)
        XCTAssertTrue(form.invitations.nextKeyView === form.accept)
        XCTAssertEqual(form.list.frame.maxY,542); XCTAssertEqual(form.invitationPanel.frame,NSRect(x:0,y:542,width:500,height:58))
        for view in [form.invitations,form.accept,form.decline] { XCTAssertTrue(form.invitationPanel.bounds.contains(view.frame)) }
        form.hasInvitations = false; form.layoutSubtreeIfNeeded()
        XCTAssertEqual(form.list.frame.maxY,600)
        XCTAssertTrue(form.list.table.nextKeyView === form.server)
    }
    @MainActor func testExternalFrameInsetsKeepOriginalDefaultContentSize() throws {
        let style = ClassicStyle.shared; defer { style.appearance = .recovery }
        style.appearance = ClassicAppearance(id:"user-frame",name:"User frame",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test",artwork:try HAPWindowTests().syntheticSkins())
        let (preferences,cleanup) = try preferences(); defer { cleanup() }
        let controller = ClassicUsersWindow(session:ClassicSession(endpoint:ClassicEndpoint()),preferences:preferences)
        defer { controller.observation.stop() }
        controller.chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.window?.frame.size,NSSize(width:315,height:435))
        XCTAssertEqual(controller.form.bounds.size,NSSize(width:300,height:400))
        XCTAssertTrue(controller.window?.initialFirstResponder === controller.form.list.table)
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
    }
    @MainActor func testServerSelectorOpensCapturedServerWithoutChangingWindowSession() throws {
        let (preferences,cleanup) = try preferences(); defer { cleanup() }
        let a = ClassicSession(endpoint:ClassicEndpoint()), b = ClassicSession(endpoint:ClassicEndpoint())
        let window = ClassicUsersWindow(session:a,preferences:preferences)
        defer { window.observation.stop() }
        let choices = [ClassicUserServerChoice(id:a.id,title:"Same name — a.example"),ClassicUserServerChoice(id:b.id,title:"Same name — b.example")]
        window.serverChoices = { choices }; window.refresh()
        let originalItem = try XCTUnwrap(window.form.server.selectedItem)
        window.refresh(); XCTAssertTrue(window.form.server.selectedItem === originalItem,"Unchanged menus stay intact during observation updates.")
        var opened = [UUID](); window.openServer = { opened.append($0) }
        XCTAssertTrue(window.form.server.choose(try XCTUnwrap(window.form.server.item(at:1))))
        XCTAssertEqual(opened,[b.id]); XCTAssertTrue(window.session === a)
        XCTAssertEqual(window.form.server.selectedItem?.representedObject as? UUID,a.id)
        XCTAssertTrue(window.form.server.choose(originalItem)); XCTAssertEqual(opened,[b.id])
        XCTAssertFalse(try XCTUnwrap(window.window).isVisible)
    }
    @MainActor func testMessagesInvitationsAndClosingKeepSessionAndRoomIdentity() async throws {
        let (preferences,cleanup) = try preferences(); defer { cleanup() }
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login:"admin",password:"pw",isAdmin:true),ServerAccount(login:"member",password:"pw")]
        let server = KDXServer(configuration:config), a = ClassicSession(endpoint:ClassicEndpoint()), b = ClassicSession(endpoint:ClassicEndpoint())
        let table = ChallengeTable(testBytes:[UInt8](repeating:7,count:1739))
        defer { a.disconnect(); b.disconnect(); server.stop() }
        for (session,login) in [(a,"admin"),(b,"member")] {
            let (clientWire,serverWire) = ClassicMemoryTransport.pair(); server.accept(wire:serverWire,table:table)
            try await session.client.connect(wire:clientWire,login:login,password:"pw",nickname:login,table:table)
        }
        _ = try await a.client.request(type:115)
        let first = HeadlessUsersWindow(session:a,preferences:preferences), second = HeadlessUsersWindow(session:b,preferences:preferences)
        defer { first.observation.stop(); second.observation.stop() }
        let recipient = try XCTUnwrap(b.client.currentUser?.id)
        let row = try XCTUnwrap(first.form.list.visible.firstIndex { $0.id == String(recipient) })
        first.form.list.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        var messages = [UInt32](); first.messageUser = { messages.append($0) }; first.sendMessage()
        XCTAssertEqual(messages,[recipient])
        var opened: UInt32?; first.openRoom = { opened = $0 }; first.invite()
        a.client.selectRoom(1)
        for _ in 0..<1000 where opened == nil { try await Task.sleep(for:.milliseconds(2)) }
        let room = try XCTUnwrap(opened)
        _ = try await b.client.request(type:115)
        XCTAssertEqual(b.client.chatInvitations.first?.roomID,room)
        second.refresh(); second.form.layoutSubtreeIfNeeded()
        XCTAssertTrue(second.form.hasInvitations); XCTAssertTrue(second.form.accept.isEnabled)
        second.declineInvitation(); XCTAssertTrue(b.client.chatInvitations.isEmpty); XCTAssertFalse(second.form.hasInvitations)
        a.client.selectRoom(1)
        try await a.client.inviteToChat(users:[recipient],room:room); _ = try await b.client.request(type:115)
        second.refresh(); second.acceptInvitation()
        for _ in 0..<1000 where b.client.joinedRooms[room] == nil { try await Task.sleep(for:.milliseconds(2)) }
        XCTAssertNotNil(b.client.joinedRooms[room]); XCTAssertEqual(a.client.joinedRoom,1)
        a.privateMessages.reset(); first.sendMessage(); XCTAssertEqual(messages,[recipient],"A stale row from a previous connection cannot send a message.")
        first.refresh(); XCTAssertNil(first.form.list.selected)
        first.requestClose(); second.requestClose()
        XCTAssertTrue(a.client.isConnected); XCTAssertTrue(b.client.isConnected)
        XCTAssertNotNil(a.client.joinedRooms[room]); XCTAssertNotNil(b.client.joinedRooms[room])
    }
    @MainActor func testOffscreenUsersInOriginalAppearances() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Original appearances required") }
        let appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared; style.configureAssets(appearances)
        defer { style.appearance = .recovery; style.configureAssets([]) }
        let (preferences,cleanup) = try preferences(); defer { cleanup() }
        for appearance in appearances where ["Mach Lavender","Amber CRT"].contains(appearance.name) {
            style.appearance = appearance
            let form = ClassicUsersForm(preferences:preferences), chrome = ClassicChrome()
            form.server.addItem(withTitle:"Example Server"); form.count.stringValue = "3"
            form.list.rows = (1...3).map { ClassicRow(id:String($0),values:["User \($0)","Description",$0 == 3 ? "Away" : ""],userAdornment:ClassicUserAdornment(user:KDXUser(id:UInt32($0),nickname:"User \($0)"))) }
            chrome.title = "User List"; chrome.frame = NSRect(x:0,y:0,width:312,height:428); chrome.layoutSubtreeIfNeeded()
            form.frame = chrome.content.bounds; chrome.content.addSubview(form)
            for pending in [false,true] {
                form.hasInvitations = pending; form.invitations.addItem(withTitle:"Invitation to Private Chat")
                form.layoutSubtreeIfNeeded(); chrome.layoutSubtreeIfNeeded()
                for scale in [1,2] {
                    let bitmap = try HAPTextFieldTests().raster(chrome,scale:scale)
                    XCTAssertEqual(try HAPWindowTests().color(bitmap,x:302*scale,y:47*scale),appearance.colors[2])
                    if let folder = ProcessInfo.processInfo.environment["KDX_CLASSIC_RENDER_DIR"] {
                        let root = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("\(appearance.name)-users-\(pending ? "invitation" : "basic")-\(scale)x.png"))
                    }
                }
            }
        }
    }
}
