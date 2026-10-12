import XCTest
@testable import KDXCore

final class ClassicIsolationTests: XCTestCase {
    @MainActor func testIndependentListingsAndExplicitTransferFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for folder in [root,local,root.appendingPathComponent("a"),root.appendingPathComponent("b")] { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true) }
        defer { try? FileManager.default.removeItem(at:root); try? FileManager.default.removeItem(at:local) }
        try Data("alpha".utf8).write(to:root.appendingPathComponent("a/same.txt")); try Data("beta".utf8).write(to:root.appendingPathComponent("b/same.txt"))
        var config = ServerConfiguration(); config.sharedFolder = root.path; config.accounts = [ServerAccount(login:"member",password:"pw")]
        let table = ChallengeTable(testBytes:[UInt8](repeating:7,count:1739)), server = KDXServer(configuration:config), client = KDXClient()
        defer { client.disconnect(); server.stop() }
        let (a,b) = MemoryTransport.pair(); server.accept(wire:b,table:table)
        try await client.connect(wire:a,login:"member",password:"pw",nickname:"member",table:table)
        client.setTransferFactory { let (a,b) = MemoryTransport.pair(); server.accept(wire:b,table:table); return a }
        try await client.listFiles(path:["b"])
        async let first = client.files(at:["a"])
        async let second = client.files(at:["b"])
        let (alpha,beta) = try await (first,second)
        XCTAssertEqual(alpha.first?.size,5); XCTAssertEqual(beta.first?.size,4)
        XCTAssertEqual(client.filePath,["b"]); XCTAssertEqual(client.files.first?.size,4)
        try await client.download(try XCTUnwrap(alpha.first),at:["a"],to:local.appendingPathComponent("download"))
        XCTAssertEqual(try Data(contentsOf:local.appendingPathComponent("download")),Data("alpha".utf8))
        try Data("uploaded".utf8).write(to:local.appendingPathComponent("upload"))
        try await client.upload(from:local.appendingPathComponent("upload"),to:["a"])
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("a/upload")),Data("uploaded".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("b/upload").path)); XCTAssertEqual(client.filePath,["b"])
    }
    @MainActor func testBackgroundTopicInvitationAndReadSelection() async throws {
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login:"admin",password:"pw",isAdmin:true),ServerAccount(login:"member",password:"pw")]
        var workshop = ChatRecord(name:"Workshop"); workshop.id = 2; config.chats.append(workshop)
        let table = ChallengeTable(testBytes:[UInt8](repeating:8,count:1739)), server = KDXServer(configuration:config), admin = KDXClient(), member = KDXClient()
        defer { admin.disconnect(); member.disconnect(); server.stop() }
        for (client,login) in [(admin,"admin"),(member,"member")] {
            let (a,b) = MemoryTransport.pair(); server.accept(wire:b,table:table)
            try await client.connect(wire:a,login:login,password:"pw",nickname:login,table:table)
        }
        try await admin.join(room:2); admin.selectRoom(1)
        try await admin.setTopic("Bound to workshop",room:2)
        XCTAssertEqual(admin.joinedRoom,1); XCTAssertEqual(admin.chatTopics[2]?.text,"Bound to workshop")
        let created = try await admin.createPrivateChatWindow(), room = created.id
        XCTAssertEqual(admin.joinedRooms[room],created)
        admin.selectRoom(1)
        try await admin.inviteToChat(users:[try XCTUnwrap(member.currentUser?.id)],room:room)
        _ = try await member.request(type:115)
        XCTAssertEqual(member.chatInvitations.first?.roomID,room); XCTAssertEqual(admin.joinedRoom,1)
        try await member.sendChat("Unread public"); admin.selectRoom(nil)
        _ = try await admin.request(type:115)
        admin.markRoomRead(1); XCTAssertNil(admin.unreadRooms[1]); XCTAssertNil(admin.joinedRoom)
        try await admin.leaveRoom(room); XCTAssertTrue(admin.isConnected); XCTAssertNotNil(admin.joinedRooms[1])
    }
}
