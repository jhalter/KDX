import XCTest
@testable import KDXCore

final class ChatPolicyTests: XCTestCase {
    func testCapturedAutomaticJoinAndClassToggle() throws {
        let messages = try capturedMessages("linux-chat-rooms-60398")
        XCTAssertEqual(messages.first { $0.type == 213 }?.payload, [])
        XCTAssertFalse(try XCTUnwrap(messages.first { $0.type == 213 }).isReply)
        XCTAssertEqual(messages.first { $0.type == 202 }?.payload, UInt32(1).beBytes + UInt32(0).beBytes)
        XCTAssertEqual(messages.filter { [UInt32(101),105,107,106,213].contains($0.type) }.map(\.type), [101,105,107,106,213])
        let administration = try capturedMessages("linux-chat-rooms-43718")
        let edits = try administration.filter { $0.type == 504 }.map { try AccountClass.decode($0.payload, info: true).0 }
        XCTAssertEqual(edits.map { $0.privileges.contains(36) }, [true,false])
        for message in administration where [217,219,220].contains(message.type) {
            XCTAssertEqual(try ChatRecord.decode(message.payload).encode(), message.payload)
        }
    }
    func testChatTextLimitsUseUTF8ByteCounts() throws {
        var room = ChatRecord(name: String(repeating: "a", count: 63), description: String(repeating: "b", count: 127))
        room.third = String(repeating: "c", count: 127); room.fourth = String(repeating: "d", count: 63)
        _ = try room.encode()
        for field in 0..<4 {
            var invalid = room
            switch field { case 0: invalid.name += "x"; case 1: invalid.description += "x"; case 2: invalid.third += "x"; default: invalid.fourth += "x" }
            XCTAssertThrowsError(try invalid.encode())
        }
        room.name = String(repeating: "é", count: 32)
        XCTAssertThrowsError(try room.encode())
    }
    @MainActor private func connect(_ client: KDXClient, server: KDXServer, login: String, table: ChallengeTable, autoJoin: Bool = true) async throws -> WireConnection {
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await client.connect(wire: a, login: login, password: "pw", nickname: login, autoJoinPublicChat: autoJoin, table: table)
        return b
    }
    @MainActor private func denied(_ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected permission denial") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        catch { XCTFail("Unexpected error: \(error)") }
    }
    @MainActor func testOverrideBypassesClassMasksButNotActionPrivilegesOrPrivateKeys() async throws {
        var override = ServerAccount(login: "override", password: "pw")
        override.privilegeMask.set(0, true); override.privileges.set(0, true)
        var config = ServerConfiguration()
        config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true), override, ServerAccount(login: "member", password: "pw")]
        var room = ChatRecord(name: "Restricted"); room.id = 2; room.joinClasses = 0; room.sendClasses = 0; room.topicClasses = 0
        config.chats.append(room)
        let table = ChallengeTable(testBytes: [UInt8](repeating: 2, count: 1739))
        let server = KDXServer(configuration: config), admin = KDXClient(), elevated = KDXClient(), member = KDXClient()
        defer { admin.disconnect(); elevated.disconnect(); member.disconnect(); server.stop() }
        for (client,login) in [(admin,"admin"),(elevated,"override"),(member,"member")] { _ = try await connect(client, server: server, login: login, table: table) }
        await denied { try await member.join(room: 2) }
        try await elevated.join(room: 2); try await elevated.sendChat("Override send"); try await elevated.setTopic("Override topic")
        XCTAssertEqual(elevated.chat.last?.text, "Override send"); XCTAssertEqual(elevated.chatTopics[2]?.text, "Override topic")
        room.description = "Edited while restricted"; try await admin.saveChat(room, creating: false)
        _ = try await elevated.request(type: 108)
        XCTAssertNotNil(elevated.joinedRooms[2], "Room edits must preserve override memberships")
        var accountClass = try await admin.accountClass(id: 1); accountClass.name = "Updated Member"
        try await admin.updateAccountClass(accountClass); _ = try await elevated.request(type: 108)
        XCTAssertNotNil(elevated.joinedRooms[2], "Class edits must preserve override memberships")
        var account = try await admin.account(login: "override")
        account.privilegeMask.set(31, true); account.privileges.set(31, false)
        try await admin.updateAccount(account, originalLogin: "override")
        await denied { try await elevated.sendChat("Global send permission still applies") }
        try await admin.createPrivateChat(); let privateRoom = try XCTUnwrap(admin.chatWindow)
        await denied { try await elevated.join(room: privateRoom.id) }
        account.privileges.set(0, false); try await admin.updateAccount(account, originalLogin: "override")
        _ = try await elevated.request(type: 108)
        XCTAssertNil(elevated.joinedRooms[2]); XCTAssertNotNil(elevated.joinedRooms[1])
        await denied { try await elevated.join(room: 2) }
        account.privilegeMask.set(30, true); account.privileges.set(30, false); account.privileges.set(0, true)
        try await admin.updateAccount(account, originalLogin: "override")
        await denied { try await elevated.join(room: 2) }
        await denied { try await elevated.refreshRooms() }
    }
    @MainActor func testPreferenceServerRequestAndDeniedChatLogin() async throws {
        var required = ServerAccount(login: "required", password: "pw")
        required.privilegeMask.set(36, true); required.privileges.set(36, true)
        var deniedAccount = ServerAccount(login: "denied", password: "pw")
        deniedAccount.privilegeMask = .enabled([30,36]); deniedAccount.privileges = .enabled([36])
        var config = ServerConfiguration(); config.accounts = [required, deniedAccount, ServerAccount(login: "optional", password: "pw")]
        let table = ChallengeTable(testBytes: [UInt8](repeating: 3, count: 1739))
        let server = KDXServer(configuration: config), client = KDXClient()
        defer { client.disconnect(); server.stop() }
        _ = try await connect(client, server: server, login: "optional", table: table, autoJoin: false)
        XCTAssertTrue(client.joinedRooms.isEmpty); XCTAssertFalse(client.rooms.isEmpty)
        client.disconnect()
        _ = try await connect(client, server: server, login: "required", table: table, autoJoin: false)
        for _ in 0..<100 where client.joinedRoom != 1 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(client.joinedRoom, 1); XCTAssertNil(client.lastError)
        client.disconnect()
        _ = try await connect(client, server: server, login: "denied", table: table, autoJoin: false)
        XCTAssertTrue(client.isConnected); XCTAssertTrue(client.joinedRooms.isEmpty); XCTAssertTrue(client.rooms.isEmpty)
        await denied { try await client.refreshRooms() }
        XCTAssertNil(client.lastError)
    }
    @MainActor func testLateServerRequestSelectsPublicWithoutLeavingOtherRoomsOrDuplicatingJoin() async throws {
        var room = ChatRecord(name: "Second"); room.id = 2
        var config = ServerConfiguration(); config.chats.append(room)
        config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true)]
        let table = ChallengeTable(testBytes: [UInt8](repeating: 4, count: 1739))
        let server = KDXServer(configuration: config), client = KDXClient()
        defer { client.disconnect(); server.stop() }
        let serverWire = try await connect(client, server: server, login: "admin", table: table, autoJoin: false)
        try await client.startHistory()
        try await client.join(room: 2)
        try await serverWire.send(type: 213)
        for _ in 0..<100 where client.joinedRoom != 1 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(Set(client.joinedRooms.keys), [1,2])
        _ = try await client.request(type: 108)
        let count = client.history.filter { $0.kind == 202 }.count
        try await client.join(room: 2)
        try await serverWire.send(type: 213, payload: [1,2,3,4])
        for _ in 0..<100 where client.joinedRoom != 1 { try await Task.sleep(for: .milliseconds(5)) }
        _ = try await client.request(type: 108)
        XCTAssertEqual(client.joinedRoom, 1); XCTAssertNil(client.lastError)
        XCTAssertEqual(client.history.filter { $0.kind == 202 }.count, count, "Already-open Public Chat should be selected locally")
    }
}
