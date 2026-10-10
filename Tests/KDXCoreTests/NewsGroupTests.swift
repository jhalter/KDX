import XCTest
@testable import KDXCore

final class NewsGroupTests: XCTestCase {
    func testCapturedAdministrationRecords() throws {
        let messages = try capturedMessages("linux-accounts-news-51382")
        for type: UInt32 in [600, 603, 604] {
            let message = try XCTUnwrap(messages.first { $0.type == type })
            let group = try NewsGroupInfo.decode(message.payload)
            XCTAssertEqual(try group.encode(), message.payload)
            XCTAssertEqual(group.readClasses, 0x80000000); XCTAssertEqual(group.postClasses, 0x80000000)
            XCTAssertEqual(group.id, type == 600 ? 0 : 2)
            XCTAssertEqual(group.name, type == 604 ? "Lab Group" : "test newsgroup")
            XCTAssertEqual(group.sizeLimitKiB, type == 604 ? 50 : 420)
            XCTAssertEqual(message.payload.count, type == 604 ? 91 : 82)
        }
        for type: UInt32 in [600, 601, 604] {
            XCTAssertTrue(messages.contains { $0.type == 1 && $0.payload == UInt32(0).beBytes + type.beBytes })
        }
        XCTAssertEqual(messages.first { $0.type == 601 }?.payload, UInt32(2).beBytes)
        for message in messages where message.type == 606 {
            XCTAssertEqual(try NewsGroup.encodeList(NewsGroup.decodeList(message.payload)), message.payload)
        }
    }
    func testStorageLimitsMigrationAndAtomicMutations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("news.json")
        struct OldSaved: Encodable { let nextID: UInt32; let posts: [NewsPost] }
        let old = NewsPost(id: 7, date: Date(), author: "A", login: "a", subject: "Old", body: "Existing post")
        try JSONEncoder().encode(OldSaved(nextID: 8, posts: [old])).write(to: file)
        let store = try NewsStore(url: file)
        XCTAssertEqual(store.posts.first?.id, 7)
        XCTAssertEqual(try store.add(author: "A", login: "a", subject: "New", body: "New post").id, 8)
        XCTAssertThrowsError(try store.delete(id: 7, login: "a", admin: false))
        var group = NewsGroupInfo(name: "Small"); group.sizeLimitKiB = 2
        group = try store.saveGroup(group, creating: true)
        for _ in 0..<3 { _ = try store.add(groupID: group.id, author: "A", login: "a", subject: "Budget", body: String(repeating: "x", count: 650)) }
        XCTAssertEqual(store.posts.filter { $0.groupID == group.id }.map(\.id), [2,3])
        group.sizeLimitKiB = 1; _ = try store.saveGroup(group, creating: false)
        XCTAssertEqual(store.posts.filter { $0.groupID == group.id }.map(\.id), [3])
        let restored = try NewsStore(url: file)
        XCTAssertEqual(try restored.group(group.id).sizeLimitKiB, 1)
        try restored.deleteGroup(group.id)
        let next = try restored.saveGroup(NewsGroupInfo(name: "Next"), creating: true)
        XCTAssertGreaterThan(next.id, group.id)
        XCTAssertEqual(restored.posts.map(\.groupID), [1,1])
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try restored.deleteGroup(1))
        XCTAssertEqual(restored.groups.count, 2); XCTAssertEqual(restored.posts.count, 2)
        XCTAssertThrowsError(try restored.saveGroup(NewsGroupInfo(name: "Unsaved"), creating: true))
        XCTAssertEqual(restored.groups.count, 2)
    }
    @MainActor func testGroupLifecycleAndClassPermissions() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var config = ServerConfiguration(); config.newsFile = file.path
        config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true), ServerAccount(login: "member", password: "pw")]
        let server = KDXServer(configuration: config), admin = KDXClient(), member = KDXClient()
        let table = ChallengeTable(testBytes: [UInt8](repeating: 3, count: 1739))
        defer { admin.disconnect(); member.disconnect(); server.stop() }
        for (client, login) in [(admin, "admin"), (member, "member")] {
            let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
            try await client.connect(wire: a, login: login, password: "pw", nickname: login, table: table)
        }
        var group = NewsGroupInfo(name: "Submissions"); group.readClasses = 0; group.postClasses = 0x40000000
        try await admin.saveNewsGroup(group, creating: true)
        let id = try XCTUnwrap(admin.newsGroups.first { $0.name == group.name }?.id)
        group = try await admin.newsGroup(id: id)
        XCTAssertEqual(group.postClasses, 0x40000000)
        try await member.loadNews(group: id); XCTAssertEqual(member.newsPermissions, 1)
        try await member.postNews(group: id, subject: "Private", body: "Submission")
        XCTAssertTrue(member.newsPosts.isEmpty)
        try await admin.loadNews(group: id); XCTAssertEqual(admin.newsPosts.count, 1)
        let post = try XCTUnwrap(admin.newsPosts.first)
        do { _ = try await member.request(type: 609, payload: id.beBytes + post.id.beBytes); XCTFail("Read denied group") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        do { try await member.saveNewsGroup(group, creating: false); XCTFail("Member edited group") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        group.name = "Published"; group.readClasses = .max; group.postClasses = 0
        try await admin.saveNewsGroup(group, creating: false)
        try await member.loadNews(group: id); XCTAssertEqual(member.newsPermissions, 4); XCTAssertEqual(member.newsPosts.count, 1)
        do { try await member.postNews(group: id, subject: "Denied", body: "No posting"); XCTFail("Ignored post mask") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        XCTAssertEqual(try NewsStore(url: file).group(id).name, "Published")
        try await admin.deleteNewsGroup(id: id)
        XCTAssertNil(admin.newsGroupID); XCTAssertTrue(admin.newsPosts.isEmpty)
        XCTAssertFalse(try NewsStore(url: file).groups.contains { $0.id == id })
    }
    @MainActor func testLargeNewsList() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = try NewsStore(url: file)
        var group = try store.group(1); group.sizeLimitKiB = 2048
        _ = try store.saveGroup(group, creating: false)
        for i in 0..<65 { _ = try store.add(author: "A", login: "a", subject: "Post \(i)", body: String(repeating: "x", count: 16384)) }
        var config = ServerConfiguration(); config.newsFile = file.path
        let server = KDXServer(configuration: config), client = KDXClient()
        defer { client.disconnect(); server.stop() }
        let table = ChallengeTable(testBytes: [UInt8](repeating: 3, count: 1739))
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await client.connect(wire: a, login: "", password: "", nickname: "Reader", table: table)
        try await client.loadNews()
        XCTAssertEqual(client.newsPosts.count, 65); XCTAssertEqual(client.newsPosts.first?.subject, "Post 64")
        XCTAssertTrue(client.newsPosts.allSatisfy { $0.body.count == 16384 })
    }
}
