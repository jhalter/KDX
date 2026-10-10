import XCTest
@testable import KDXCore

final class ChatTests: XCTestCase {
    func testCapturedChatRecordsWindowsTopicsAndLists() throws {
        let messages = try capturedMessages("probe-35844")
        let windowBytes = try XCTUnwrap(messages.first { $0.type == 203 }?.payload)
        let window = try ChatWindow.decode(windowBytes)
        XCTAssertEqual(window.name, "Public Chat"); XCTAssertEqual(window.members, [3])
        XCTAssertEqual(try window.encode(), windowBytes)
        let topicBytes = try XCTUnwrap(messages.first { $0.type == 210 }?.payload)
        let topic = try ChatTopic.decode(topicBytes)
        XCTAssertEqual(topic.text, "\0\0\0\0H"); XCTAssertEqual(topic.nickname, "probe"); XCTAssertEqual(topic.userID, 3)
        XCTAssertEqual(try topic.encode(), topicBytes)
        let recordBytes = try XCTUnwrap(messages.first { $0.type == 219 }?.payload)
        let record = try ChatRecord.decode(recordBytes)
        XCTAssertEqual(record.description, "For all users"); XCTAssertEqual(record.joinClasses, .max)
        XCTAssertEqual(try record.encode(), recordBytes)
        let listBytes = try XCTUnwrap(capturedMessages("probe-50770").first { $0.type == 215 }?.payload)
        let list = try ChatRoom.list(listBytes)
        XCTAssertEqual(list.map(\.name), ["Public Chat", "Voice Chat", "Admin Lounge"]); XCTAssertEqual(list[1].flags, 2)
        XCTAssertEqual(try ChatRoom.encodeList(list), listBytes)
        for bytes in [windowBytes, recordBytes, topicBytes] {
            for length in [0, 3, 10] {
                let truncated = Array(bytes.prefix(length))
                XCTAssertThrowsError(try ChatWindow.decode(truncated)); XCTAssertThrowsError(try ChatRecord.decode(truncated)); XCTAssertThrowsError(try ChatTopic.decode(truncated))
            }
        }
    }
    @MainActor func testRoomLifecycleMembershipIsolationTopicsAndPersistence() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: settings) }
        let table = ChallengeTable(testBytes: [UInt8](repeating: 7, count: 1739))
        var config = ServerConfiguration(); config.allowGuests = false
        config.accounts = [ServerAccount(login: "admin", password: "a", isAdmin: true), ServerAccount(login: "bob", password: "b")]
        let server = KDXServer(configuration: config, configurationURL: settings), admin = KDXClient(), bob = KDXClient()
        defer { admin.disconnect(); bob.disconnect(); server.stop() }
        try await connect(admin, server: server, login: "admin", password: "a", table: table)
        try await connect(bob, server: server, login: "bob", password: "b", table: table)
        try await eventually { admin.chatWindow?.members.count == 2 }
        let created = ChatRecord(name: "Workshop", description: "Project discussion")
        try await admin.saveChat(created, creating: true)
        let room = try XCTUnwrap(admin.rooms.first { $0.name == created.name })
        XCTAssertNotEqual(room.id, 0); XCTAssertNotEqual(room.id, 1)
        XCTAssertEqual(try ServerConfiguration.load(from: settings).chats.count, 2)
        try await admin.join(room: room.id)
        try await eventually { bob.chatWindow?.members.count == 1 }
        try await admin.sendChat("Only workshop members receive this")
        XCTAssertTrue(admin.chat.contains { $0.text == "Only workshop members receive this" })
        XCTAssertFalse(bob.chat.contains { $0.text == "Only workshop members receive this" })
        try await admin.setTopic("Release planning")
        try await bob.join(room: room.id)
        try await eventually { bob.chatTopics[room.id]?.text == "Release planning" && admin.chatWindow?.members.count == 2 }
        try await bob.setTopic("Ready for review")
        try await eventually { admin.chatTopics[room.id]?.nickname == "bob" }
        var edited = try await admin.chatRecord(id: room.id)
        edited.description = "Updated description"
        try await admin.saveChat(edited, creating: false)
        XCTAssertEqual(try ServerConfiguration.load(from: settings).chats.last?.description, edited.description)
        try await admin.deleteChat(id: room.id)
        try await eventually { admin.joinedRoom == nil && bob.joinedRoom == nil }
        XCTAssertEqual(try ServerConfiguration.load(from: settings).chats.map(\.id), [1])
        try await admin.join(room: 1)
        try await bob.join(room: 1)
        bob.disconnect()
        try await eventually { admin.chatWindow?.members.count == 1 }
        try await admin.leaveRoom()
        XCTAssertNil(admin.chatWindow)
    }
    @MainActor func testRoomClassPolicyAndLiveRevocation() async throws {
        let table = ChallengeTable(testBytes: [UInt8](repeating: 9, count: 1739))
        var config = ServerConfiguration(); config.allowGuests = false
        config.accounts = [ServerAccount(login: "admin", password: "a", isAdmin: true), ServerAccount(login: "bob", password: "b")]
        let server = KDXServer(configuration: config), admin = KDXClient(), bob = KDXClient()
        defer { admin.disconnect(); bob.disconnect(); server.stop() }
        try await connect(admin, server: server, login: "admin", password: "a", table: table)
        try await connect(bob, server: server, login: "bob", password: "b", table: table)
        await denied { try await bob.saveChat(ChatRecord(name: "Denied"), creating: true) }
        await denied { _ = try await bob.chatRecord(id: 1) }
        await denied { try await bob.deleteChat(id: 1) }
        var room = ChatRecord(name: "Read only"); room.sendClasses = 0x80000000; room.topicClasses = 0x80000000
        try await admin.saveChat(room, creating: true)
        let id = try XCTUnwrap(admin.rooms.first { $0.name == room.name }?.id)
        try await admin.join(room: id); try await bob.join(room: id)
        await denied { try await bob.sendChat("Not allowed") }
        await denied { try await bob.setTopic("Not allowed") }
        room.id = id; room.joinClasses = 0x80000000
        try await admin.saveChat(room, creating: false)
        try await eventually { bob.joinedRoom == nil && admin.chatWindow?.members.count == 1 }
        await denied { try await bob.join(room: id) }
        try await bob.join(room: 1)
        var account = try await admin.account(login: "bob")
        account.privilegeMask.set(30, true); account.privileges.set(30, false)
        try await admin.updateAccount(account, originalLogin: "bob")
        try await eventually { bob.joinedRoom == nil }
        await denied { try await bob.join(room: 1) }
        XCTAssertTrue(bob.isConnected)
        await denied { try await admin.deleteChat(id: 1) }
    }
    @MainActor func testRoomSaveFailureLeavesRoomsAndMembershipUnchanged() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: settings) }
        let table = ChallengeTable(testBytes: [UInt8](repeating: 7, count: 1739))
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "admin", password: "a", isAdmin: true)]
        let server = KDXServer(configuration: config, configurationURL: settings), admin = KDXClient()
        defer { admin.disconnect(); server.stop() }
        try await connect(admin, server: server, login: "admin", password: "a", table: table)
        try FileManager.default.removeItem(at: settings); try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: false)
        do { try await admin.saveChat(ChatRecord(name: "Unsaved"), creating: true); XCTFail("Save should fail") } catch {}
        XCTAssertEqual(server.configuration.chats.map(\.id), [1]); XCTAssertEqual(admin.joinedRoom, 1)
    }
    @MainActor private func connect(_ client: KDXClient, server: KDXServer, login: String, password: String, table: ChallengeTable) async throws {
        let (clientWire, serverWire) = MemoryTransport.pair(); server.accept(wire: serverWire, table: table)
        try await client.connect(wire: clientWire, login: login, password: password, nickname: login, table: table)
    }
    @MainActor private func denied(_ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected access denied") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        catch { XCTFail("Unexpected error: \(error)") }
    }
    @MainActor private func eventually(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(3)
        while !predicate() && Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
}
