import XCTest
@testable import KDXCore

final class MultiRoomTests: XCTestCase {
    @MainActor private func connect(_ client: KDXClient, server: KDXServer, login: String, table: ChallengeTable) async throws {
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await client.connect(wire: a, login: login, password: "pw", nickname: login, table: table)
    }
    @MainActor private func synchronize(_ sender: KDXClient, _ receiver: KDXClient) async throws {
        _ = try await sender.request(type: 108); _ = try await receiver.request(type: 108)
    }
    private func configuration() -> ServerConfiguration {
        var config = ServerConfiguration()
        config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true), ServerAccount(login: "member", password: "pw")]
        var workshop = ChatRecord(name: "Workshop"); workshop.id = 2
        config.chats.append(workshop)
        return config
    }
    @MainActor func testMessagesTopicsAndMembersAcrossRooms() async throws {
        let table = ChallengeTable(testBytes: [UInt8](repeating: 2, count: 1739))
        let server = KDXServer(configuration: configuration()), admin = KDXClient(), member = KDXClient()
        defer { admin.disconnect(); member.disconnect(); server.stop() }
        try await connect(admin, server: server, login: "admin", table: table)
        try await connect(member, server: server, login: "member", table: table)
        try await admin.join(room: 2)
        XCTAssertEqual(Set(admin.joinedRooms.keys), [1,2])
        try await member.sendChat("Public while Workshop is selected")
        try await synchronize(member, admin)
        XCTAssertFalse(admin.chat.contains { $0.text.hasPrefix("Public") })
        XCTAssertEqual(admin.messages(in: 1).last?.text, "Public while Workshop is selected")
        XCTAssertEqual(admin.unreadRooms[1], 1)
        try await member.join(room: 2)
        try await member.sendChat("Workshop conversation")
        try await synchronize(member, admin)
        XCTAssertEqual(admin.chat.last?.text, "Workshop conversation")
        XCTAssertNil(admin.unreadRooms[2])
        XCTAssertEqual(admin.joinedRooms[1]?.members.count, 2)
        XCTAssertEqual(admin.joinedRooms[2]?.members.count, 2)
        try await admin.join(room: 1)
        XCTAssertNil(admin.unreadRooms[1])
        XCTAssertEqual(admin.chat.last?.text, "Public while Workshop is selected")
        try await admin.sendChat("Reply to background Workshop", room: 2)
        XCTAssertEqual(admin.joinedRoom, 1, "Sending to a captured room must not change selection")
        try await member.setTopic("Background topic")
        try await member.sendChat("Background Workshop message")
        try await member.sendPrivate(to: try XCTUnwrap(admin.currentUser?.id), text: "Direct message")
        try await synchronize(member, admin)
        XCTAssertEqual(admin.chatTopics[2]?.text, "Background topic")
        XCTAssertEqual(admin.unreadRooms[2], 2)
        XCTAssertEqual(admin.chat.last?.text, "Direct message")
        try await admin.join(room: 2)
        XCTAssertEqual(admin.chat.map(\.text), ["Workshop conversation", "Reply to background Workshop", "Background Workshop message", "Direct message"])
        XCTAssertNil(admin.unreadRooms[2])
        try await admin.sendPrivate(to: try XCTUnwrap(member.currentUser?.id), text: "Direct reply")
        try await admin.join(room: 1)
        XCTAssertEqual(admin.chat.map(\.text), ["Public while Workshop is selected", "Direct message", "Direct reply"])
        member.disconnect()
        for _ in 0..<100 where admin.users.count > 1 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(admin.joinedRooms[1]?.members.count, 1)
        XCTAssertEqual(admin.joinedRooms[2]?.members.count, 1)
        admin.disconnect()
        XCTAssertTrue(admin.joinedRooms.isEmpty); XCTAssertTrue(admin.chat.isEmpty)
        XCTAssertTrue(admin.messages(in: 1).isEmpty); XCTAssertTrue(admin.unreadRooms.isEmpty)
    }
    @MainActor func testBackgroundLeaveRevocationAndDeletionPreserveSelection() async throws {
        let table = ChallengeTable(testBytes: [UInt8](repeating: 3, count: 1739))
        let server = KDXServer(configuration: configuration()), admin = KDXClient(), member = KDXClient()
        defer { admin.disconnect(); member.disconnect(); server.stop() }
        try await connect(admin, server: server, login: "admin", table: table)
        try await connect(member, server: server, login: "member", table: table)
        try await admin.join(room: 2); try await member.join(room: 2); try await member.join(room: 1)
        try await admin.sendChat("Before leaving")
        try await synchronize(admin, member)
        try await member.leaveRoom(2)
        XCTAssertEqual(member.joinedRoom, 1); XCTAssertNil(member.joinedRooms[2]); XCTAssertNil(member.unreadRooms[2])
        try await admin.sendChat("After leaving")
        try await synchronize(admin, member)
        XCTAssertEqual(member.messages(in: 2).map(\.text), ["Before leaving"])
        XCTAssertEqual(admin.chatWindow?.members.count, 1)
        try await member.join(room: 2); try await member.join(room: 1)
        var room = try await admin.chatRecord(id: 2); room.joinClasses = 0x80000000
        try await admin.saveChat(room, creating: false)
        try await synchronize(admin, member)
        XCTAssertNil(member.joinedRooms[2]); XCTAssertEqual(member.joinedRoom, 1)
        do { try await member.join(room: 2); XCTFail("Revoked membership was cached") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        try await admin.join(room: 1)
        try await admin.deleteChat(id: 2)
        XCTAssertNil(admin.joinedRooms[2]); XCTAssertEqual(admin.joinedRoom, 1)
        XCTAssertFalse(admin.rooms.contains { $0.id == 2 })
    }
    @MainActor func testPrivateRoomsSurviveSwitchAndRefreshUntilExplicitLeave() async throws {
        let table = ChallengeTable(testBytes: [UInt8](repeating: 4, count: 1739))
        let server = KDXServer(configuration: configuration()), admin = KDXClient()
        defer { admin.disconnect(); server.stop() }
        try await connect(admin, server: server, login: "admin", table: table)
        try await admin.createPrivateChat(); let first = try XCTUnwrap(admin.chatWindow)
        try await admin.sendChat("First private room")
        try await admin.createPrivateChat(); let second = try XCTUnwrap(admin.chatWindow)
        try await admin.sendChat("Second private room")
        try await admin.join(room: 1); try await admin.refreshRooms()
        XCTAssertEqual(Set(admin.joinedRooms.keys), [1,first.id,second.id])
        XCTAssertTrue(admin.rooms.contains { $0.id == first.id }); XCTAssertTrue(admin.rooms.contains { $0.id == second.id })
        try await admin.join(room: first.id)
        XCTAssertEqual(admin.chat.last?.text, "First private room")
        try await admin.leaveRoom(second.id)
        XCTAssertEqual(admin.joinedRoom, first.id)
        XCTAssertFalse(admin.rooms.contains { $0.id == second.id })
        do { try await admin.join(room: second.id, key: second.key); XCTFail("Empty private room survived explicit leave") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x1000c) }
        try await admin.leaveRoom()
        XCTAssertNil(admin.joinedRoom); XCTAssertEqual(Set(admin.joinedRooms.keys), [1])
    }
}
