import XCTest
@testable import KDXCore

final class NewsTests: XCTestCase {
    func testPersistenceAndOwnership() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = try NewsStore(url: file)
        let post = try store.add(author: "Alice", login: "alice", subject: "Welcome", body: "Hello, community!")
        let restored = try NewsStore(url: file)
        XCTAssertEqual(restored.posts.first?.subject, "Welcome")
        XCTAssertThrowsError(try restored.delete(id: post.id, login: "bob", admin: false))
        try restored.delete(id: post.id, login: "alice", admin: false)
        let empty = try NewsStore(url: file)
        XCTAssertTrue(empty.posts.isEmpty)
        let later = try empty.add(author: "Alice", login: "alice", subject: "Later", body: "New post")
        XCTAssertGreaterThan(later.id, post.id, "Deleted post IDs must never be reused after restart")
    }
    @MainActor func testPostingReadingDeletingAndGuestDenial() async throws {
        let table = ChallengeTable(testBytes: [UInt8](repeating: 3, count: 1739))
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "alice", password: "pw")]
        let server = KDXServer(configuration: config), alice = KDXClient(), guest = KDXClient()
        defer { alice.disconnect(); guest.disconnect(); server.stop() }
        let (a,b) = MemoryTransport.pair(), (c,d) = MemoryTransport.pair()
        server.accept(wire: b, table: table); server.accept(wire: d, table: table)
        try await alice.connect(wire: a, login: "alice", password: "pw", nickname: "Alice", table: table)
        try await guest.connect(wire: c, login: "", password: "", nickname: "Guest", table: table)
        try await alice.loadNewsGroups(); XCTAssertEqual(alice.newsGroups.first?.name, "General")
        try await alice.postNews(subject: "Welcome", body: "Unicode works: こんにちは")
        try await guest.loadNews(); XCTAssertEqual(guest.newsPosts.first?.body, "Unicode works: こんにちは")
        XCTAssertEqual(guest.newsPermissions, 4)
        do { try await guest.postNews(subject: "Denied", body: "No permission"); XCTFail("Guest posted") } catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        let post = try XCTUnwrap(alice.newsPosts.first)
        try await alice.deleteNews(post); XCTAssertTrue(alice.newsPosts.isEmpty)
    }
}
