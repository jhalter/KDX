import XCTest
@testable import KDXCore

final class ModerationTests: XCTestCase {
    func testCapturedModerationMessages() throws {
        let messages = try capturedMessages("linux-chat-admin-37484")
        let outgoing = try XCTUnwrap(messages.first { $0.type == 154 })
        let broadcast = try BroadcastMessage.decode(outgoing.payload, received: false)
        XCTAssertEqual(broadcast.text, "test broadcast")
        XCTAssertEqual(try broadcast.encode(received: false), outgoing.payload)
        for message in messages + (try capturedMessages("linux-chat-admin-37478")) where message.type == 155 {
            let received = try BroadcastMessage.decode(message.payload, received: true)
            XCTAssertEqual(received.senderID, 2); XCTAssertEqual(received.text, broadcast.text)
            XCTAssertEqual(try received.encode(received: true), message.payload)
        }
        let disconnect = try XCTUnwrap(messages.first { $0.type == 150 })
        let request = try DisconnectRequest.decode(disconnect.payload)
        XCTAssertEqual(request.userID, 2); XCTAssertEqual(request.banSeconds, 0); XCTAssertEqual(request.reason, "test")
        XCTAssertEqual(try request.encode(), disconnect.payload)
        let response = try XCTUnwrap(messages.first { $0.type == 151 })
        let notice = try DisconnectNotice.decode(response.payload)
        XCTAssertEqual(notice.senderID, request.userID, "The capture disconnects the sender's own session")
        XCTAssertEqual(notice.sender, "kdx-lab-linux"); XCTAssertEqual(notice.reason, "test")
        XCTAssertEqual(try notice.encode(), response.payload)
        var marked = broadcast; marked.options = 0x1234
        XCTAssertEqual(try BroadcastMessage.decode(marked.encode(received: true), received: true).options, 0x1234)
        XCTAssertThrowsError(try BroadcastMessage(text: String(repeating: "x", count: 2049)).encode(received: false))
        XCTAssertThrowsError(try DisconnectRequest(userID: 1, reason: String(repeating: "x", count: 256)).encode())
        XCTAssertThrowsError(try DisconnectRequest(userID: 1, banSeconds: 0x80001).encode())
    }
    @MainActor private func connect(_ client: KDXClient, server: KDXServer, login: String, table: ChallengeTable) async throws {
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await client.connect(wire: a, login: login, password: login.isEmpty ? "" : "pw", nickname: login.isEmpty ? "Guest" : login, table: table)
    }
    @MainActor func testBroadcastReachesAllRoomsWithPermissionChecks() async throws {
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true), ServerAccount(login: "member", password: "pw")]
        let server = KDXServer(configuration: config), admin = KDXClient(), member = KDXClient(), guest = KDXClient()
        defer { admin.disconnect(); member.disconnect(); guest.disconnect(); server.stop() }
        let table = ChallengeTable(testBytes: [UInt8](repeating: 4, count: 1739))
        for (client,login) in [(admin,"admin"), (member,"member"), (guest,"")] { try await connect(client, server: server, login: login, table: table) }
        try await admin.createPrivateChat()
        try await member.leaveRoom()
        do { try await guest.sendBroadcast("Denied"); XCTFail("Guest broadcast") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        try await admin.sendBroadcast("Server announcement: こんにちは")
        for client in [admin,member,guest] {
            _ = try await client.request(type: 108)
            XCTAssertEqual(client.broadcasts.count, 1)
            XCTAssertEqual(client.broadcasts.first?.text, "Server announcement: こんにちは")
            XCTAssertEqual(client.broadcasts.first?.sender, "admin")
            XCTAssertTrue(client.chat.isEmpty, "Broadcast history is independent of the active room")
        }
        guest.disconnect()
        try await connect(guest, server: server, login: "", table: table)
        XCTAssertTrue(guest.broadcasts.isEmpty, "New connections must not show another session's broadcasts")
    }
    @MainActor func testDisconnectReasonQuietModeProtectionAndSelfConfirmation() async throws {
        var adminAccount = ServerAccount(login: "admin", password: "pw", isAdmin: true)
        adminAccount.privilegeMask.set(43, true); adminAccount.privileges.set(43, true)
        var protected = ServerAccount(login: "protected", password: "pw")
        protected.privilegeMask.set(42, true); protected.privileges.set(42, true)
        var config = ServerConfiguration(); config.accounts = [adminAccount, protected, ServerAccount(login: "member", password: "pw")]
        let server = KDXServer(configuration: config), admin = KDXClient(), member = KDXClient(), immune = KDXClient()
        defer { admin.disconnect(); member.disconnect(); immune.disconnect(); server.stop() }
        let table = ChallengeTable(testBytes: [UInt8](repeating: 8, count: 1739))
        for (client,login) in [(admin,"admin"), (member,"member"), (immune,"protected")] { try await connect(client, server: server, login: login, table: table) }
        let adminID = try XCTUnwrap(admin.currentUser?.id), targetID = try XCTUnwrap(member.currentUser?.id)
        do { try await member.disconnectUser(id: adminID); XCTFail("Member disconnected administrator") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        do { try await admin.disconnectUser(id: immune.currentUser!.id); XCTFail("Disconnected protected user") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        do { try await admin.disconnectUser(id: UInt32.max); XCTFail("Disconnected missing user") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x1000c) }
        do { _ = try await admin.request(type: 150, payload: DisconnectRequest(userID: targetID, banSeconds: 60).encode()); XCTFail("Claimed unsupported ban") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10004) }
        try await admin.disconnectUser(id: targetID, reason: "Maintenance")
        for _ in 0..<50 where member.isConnected { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(member.isConnected)
        XCTAssertEqual(member.disconnectNotice?.reason, "Maintenance")
        XCTAssertEqual(member.disconnectNotice?.sender, "admin")
        XCTAssertEqual(member.lastError, "Disconnected by admin: Maintenance")
        try await connect(member, server: server, login: "member", table: table)
        XCTAssertNil(member.disconnectNotice)
        try await admin.disconnectUser(id: member.currentUser!.id, quietly: true)
        for _ in 0..<50 where member.isConnected { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(member.isConnected); XCTAssertNil(member.disconnectNotice)
        XCTAssertTrue(immune.isConnected)
        try await admin.disconnectUser(id: adminID, reason: "Signing off")
        XCTAssertFalse(admin.isConnected); XCTAssertEqual(admin.disconnectNotice?.reason, "Signing off")
    }
}
