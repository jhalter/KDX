import XCTest
@testable import KDXCore

final class IntegrationTests: XCTestCase {
    @MainActor func testTwoClientsAuthenticateChatPrivateMessageAndDisconnect() async throws {
        let table = ChallengeTable(testBytes: (0..<1739).map { UInt8(truncatingIfNeeded: $0) })
        var config = ServerConfiguration(); config.port = 0; config.allowGuests = false
        config.accounts = [ServerAccount(login: "alice", password: "test-alice", isAdmin: true), ServerAccount(login: "bob", password: "test-bob")]
        let server = KDXServer(configuration: config), alice = KDXClient(), bob = KDXClient()
        defer { alice.disconnect(); bob.disconnect(); server.stop() }
        let (aliceWire, serverAlice) = MemoryTransport.pair(), (bobWire, serverBob) = MemoryTransport.pair()
        server.accept(wire: serverAlice, table: table); server.accept(wire: serverBob, table: table)
        try await alice.connect(wire: aliceWire, login: "alice", password: "test-alice", nickname: "Alice", table: table)
        try await bob.connect(wire: bobWire, login: "bob", password: "test-bob", nickname: "Bob", table: table)
        XCTAssertEqual(server.users.count, 2)
        XCTAssertEqual(bob.users.count, 2)
        XCTAssertEqual(alice.serverInfo?.canModifySettings, true)
        try await alice.sendChat("Hello from Alice")
        try await eventually { bob.chat.contains { $0.text == "Hello from Alice" && $0.sender == "Alice" } }
        try await bob.sendPrivate(to: XCTUnwrap(alice.serverInfo?.userID), text: "Hello privately")
        try await eventually { alice.chat.contains { $0.text == "Hello privately" && $0.isPrivate } }
        bob.disconnect()
        try await eventually { alice.users.count == 1 && server.users.count == 1 }
        let pong = try await alice.request(type: 108)
        XCTAssertEqual(pong.type, 109)
        do { _ = try await alice.request(type: 9999); XCTFail("Unsupported request accepted") } catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10004) }
    }
    @MainActor func testIncorrectPasswordAndUnknownAccountAreRejected() async throws {
        let table = ChallengeTable(testBytes: [UInt8](repeating: 7, count: 1739))
        var config = ServerConfiguration(); config.port = 0; config.allowGuests = false
        config.accounts = [ServerAccount(login: "alice", password: "correct")]
        let server = KDXServer(configuration: config), client = KDXClient()
        defer { client.disconnect(); server.stop() }
        for (login, password) in [("alice", "wrong"), ("unknown", "correct")] {
            let (clientWire, serverWire) = MemoryTransport.pair()
            server.accept(wire: serverWire, table: table)
            do {
                try await client.connect(wire: clientWire, login: login, password: password, nickname: "Test", table: table)
                XCTFail("Invalid credentials accepted")
            } catch { XCTAssertFalse(client.isConnected) }
        }
        XCTAssertTrue(server.users.isEmpty)
    }
    @MainActor func testLiveTCP() async throws {
        guard ProcessInfo.processInfo.environment["KDX_TEST_TCP"] == "1" else {
            throw XCTSkip("Run KDX_TEST_TCP=1 scripts/test.sh outside a network-restricted sandbox.")
        }
        let table = ChallengeTable(testBytes: [UInt8](repeating: 7, count: 1739))
        var config = ServerConfiguration(); config.port = 0
        let server = KDXServer(), client = KDXClient()
        defer { client.disconnect(); server.stop() }
        try await server.start(configuration: config, table: table)
        try await client.connect(host: "127.0.0.1", port: XCTUnwrap(server.port), login: "", password: "", nickname: "Guest", table: table)
        try await client.sendChat("TCP works")
        try await eventually { client.chat.contains { $0.text == "TCP works" } }
        XCTAssertEqual(server.users.count, 1)
    }
    @MainActor private func eventually(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(3)
        while !predicate() && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate())
    }
}
