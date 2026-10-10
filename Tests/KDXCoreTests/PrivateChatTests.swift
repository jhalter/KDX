import XCTest
@testable import KDXCore

final class PrivateChatTests: XCTestCase {
    func testCapturedPrivateChat() throws {
        let creator = try capturedMessages("linux-chat-admin-37484")
        XCTAssertEqual(creator.first { $0.type == 200 }?.payload, [])
        let response = try XCTUnwrap(creator.first { $0.type == 216 })
        let room = try ChatWindow.decode(response.payload)
        XCTAssertTrue(response.isReply)
        XCTAssertEqual(room.id, 0xb06d05e6); XCTAssertEqual(room.key, 0x4ca93520)
        XCTAssertEqual(room.members, [2]); XCTAssertEqual(room.name, "Private 1")
        XCTAssertEqual(room.flags, 0, "Private creation does not set the window private flag in this capture")
        XCTAssertEqual(try room.encode(), response.payload)
        let requests = creator.filter { $0.type == 211 }
        XCTAssertEqual(requests.count, 2)
        for (index, message) in requests.enumerated() {
            let request = try ChatInviteRequest.decode(message.payload)
            XCTAssertEqual(request.roomID, room.id); XCTAssertEqual(request.users, index == 0 ? [1] : [1,4])
            XCTAssertEqual(try request.encode(), message.payload)
        }
        let invitations = try capturedMessages("linux-chat-admin-37478").filter { $0.type == 212 }
        XCTAssertEqual(invitations.count, 2)
        for message in invitations {
            let invitation = try ChatInvitation.decode(message.payload)
            XCTAssertEqual(invitation.roomID, room.id); XCTAssertEqual(invitation.key, room.key)
            XCTAssertEqual(invitation.inviterID, 2); XCTAssertEqual(invitation.name, "Private 1")
            XCTAssertEqual(try invitation.encode(), message.payload)
        }
    }
    @MainActor private func connect(_ client: KDXClient, server: KDXServer, login: String, table: ChallengeTable) async throws {
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await client.connect(wire: a, login: login, password: login.isEmpty ? "" : "pw", nickname: login.isEmpty ? "Guest" : login, table: table)
    }
    @MainActor func testInviteJoinIsolationAndLastLeaveDeletion() async throws {
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true), ServerAccount(login: "member", password: "pw")]
        let server = KDXServer(configuration: config), admin = KDXClient(), member = KDXClient(), outsider = KDXClient()
        defer { admin.disconnect(); member.disconnect(); outsider.disconnect(); server.stop() }
        let table = ChallengeTable(testBytes: [UInt8](repeating: 5, count: 1739))
        for (client,login) in [(admin,"admin"), (member,"member"), (outsider,"")] { try await connect(client, server: server, login: login, table: table) }
        try await admin.createPrivateChat()
        let window = try XCTUnwrap(admin.chatWindow)
        XCTAssertEqual(window.members.count, 1); XCTAssertNotEqual(window.key, 0)
        try await outsider.refreshRooms(); XCTAssertFalse(outsider.rooms.contains { $0.id == window.id })
        do { try await outsider.join(room: window.id); XCTFail("Joined without private key") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        do { _ = try await outsider.request(type: 211, payload: ChatInviteRequest(roomID: window.id, users: [member.currentUser!.id]).encode()); XCTFail("Nonmember invited") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        try await admin.inviteToChat(users: [try XCTUnwrap(member.currentUser?.id)])
        _ = try await member.request(type: 108)
        let invitation = try XCTUnwrap(member.chatInvitations.first)
        XCTAssertEqual(invitation.key, window.key)
        XCTAssertTrue(outsider.chatInvitations.isEmpty)
        try await member.acceptInvitation(invitation)
        XCTAssertTrue(member.chatInvitations.isEmpty); XCTAssertEqual(member.joinedRoom, window.id)
        try await member.sendChat("Only room members")
        _ = try await admin.request(type: 108)
        XCTAssertEqual(admin.chat.last?.text, "Only room members"); XCTAssertTrue(outsider.chat.isEmpty)
        try await admin.join(room: 1)
        XCTAssertFalse(admin.rooms.contains { $0.id == window.id })
        try await member.sendChat("Still here")
        try await member.leaveRoom()
        do { try await admin.join(room: window.id, key: window.key); XCTFail("Empty private room survived") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x1000c) }
        XCTAssertTrue(server.configuration.chats.allSatisfy { $0.id != window.id })
    }
    @MainActor func testCreateLimitPrivilegeAndDisconnectCleanup() async throws {
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "member", password: "pw")]
        let server = KDXServer(configuration: config), member = KDXClient(), guest = KDXClient()
        defer { member.disconnect(); guest.disconnect(); server.stop() }
        let table = ChallengeTable(testBytes: [UInt8](repeating: 6, count: 1739))
        try await connect(member, server: server, login: "member", table: table)
        try await connect(guest, server: server, login: "", table: table)
        do { try await guest.createPrivateChat(); XCTFail("Guest created room") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        var rooms = [ChatWindow]()
        // Direct requests keep multiple server memberships, like a multiwindow legacy client.
        for _ in 0..<10 { let reply = try await member.request(type: 200); rooms.append(try ChatWindow.decode(reply.payload)) }
        XCTAssertEqual(Set(rooms.map(\.id)).count, 10)
        do { _ = try await member.request(type: 200); XCTFail("Created eleventh private room") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x1000a) }
        member.disconnect()
        for _ in 0..<50 where server.users.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        for room in rooms {
            do { try await guest.join(room: room.id, key: room.key); XCTFail("Disconnected owner's empty room survived") }
            catch KDXError.remote(let code) { XCTAssertEqual(code, 0x1000c) }
        }
    }
    @MainActor func testRevokedMembershipDeletesPrivateRoomAndDeclineDoesNotJoin() async throws {
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true), ServerAccount(login: "member", password: "pw")]
        let server = KDXServer(configuration: config), admin = KDXClient(), member = KDXClient()
        defer { admin.disconnect(); member.disconnect(); server.stop() }
        let table = ChallengeTable(testBytes: [UInt8](repeating: 7, count: 1739))
        try await connect(admin, server: server, login: "admin", table: table)
        try await connect(member, server: server, login: "member", table: table)
        try await member.createPrivateChat()
        let room = try XCTUnwrap(member.chatWindow)
        try await member.inviteToChat(users: [admin.currentUser!.id])
        _ = try await admin.request(type: 108)
        let invitation = try XCTUnwrap(admin.chatInvitations.first)
        admin.dismissInvitation(invitation); XCTAssertEqual(admin.joinedRoom, 1)
        var accountClass = try await admin.accountClass(id: 1); accountClass.privileges.set(30, false)
        try await admin.updateAccountClass(accountClass)
        _ = try await member.request(type: 108)
        XCTAssertNil(member.joinedRoom)
        do { try await admin.join(room: room.id, key: room.key); XCTFail("Revoked member retained private room") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x1000c) }
        XCTAssertThrowsError(try ChatInviteRequest(roomID: 1, users: Array(repeating: 1, count: 21)).encode())
    }
}
