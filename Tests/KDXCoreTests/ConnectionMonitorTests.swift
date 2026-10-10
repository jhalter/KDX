import XCTest
@testable import KDXCore

@MainActor private final class MonitorReplyGate: ByteTransport {
    let base: MemoryTransport
    var holdReply = false
    private(set) var waiting = false
    private var waiter: CheckedContinuation<Void, Error>?
    var endpointDescription: String { base.endpointDescription }
    var peerHost: String { base.peerHost }
    init(_ base: MemoryTransport) { self.base = base }
    func start() async throws { try await base.start() }
    func read(_ count: Int) async throws -> [UInt8] { try await base.read(count) }
    func readSome(maximum: Int) async throws -> [UInt8] { try await base.readSome(maximum: maximum) }
    func write(_ bytes: [UInt8]) async throws {
        if holdReply && bytes.count > 100 {
            holdReply = false; waiting = true
            try await withCheckedThrowingContinuation { waiter = $0 }
        }
        try await base.write(bytes)
    }
    func release() { waiting = false; waiter?.resume(); waiter = nil }
    func close() { waiter?.resume(throwing: KDXError.disconnected); waiter = nil; waiting = false; base.close() }
}

final class ConnectionMonitorTests: XCTestCase {
    func testCapturedConnectionSnapshotAndMalformedRecords() throws {
        let messages = try capturedMessages("probe-50984")
        for type: UInt32 in [140,141,142] { XCTAssertEqual(messages.first { $0.type == type }?.payload, []) }
        let payload = try XCTUnwrap(messages.first { $0.type == 143 }?.payload)
        let entries = try MonitoredConnection.decodeList(payload)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.userID, 8); XCTAssertEqual(entry.nickname, "probe")
        XCTAssertEqual(entry.login, "admin"); XCTAssertEqual(entry.accountName, "Administrator")
        XCTAssertEqual(entry.address, "127.0.0.1:50984")
        XCTAssertEqual(entry.loginTime, 0x3a36cb6db33); XCTAssertEqual(entry.lastActivity, 0x3a36cb6e662)
        var canonical = payload
        let end = 104 + [entry.nickname,entry.login,entry.accountName,entry.address].reduce(0) { $0 + $1.utf8.count }
        for at in end..<canonical.count { canonical[at] = 0 }
        XCTAssertEqual(try MonitoredConnection.encodeList(entries), canonical, "Captured padding contains uninitialized bytes")
        var opaque = canonical; opaque[32] = 91; opaque[100] = 93
        XCTAssertEqual(try MonitoredConnection.encodeList(MonitoredConnection.decodeList(opaque)), opaque)
        XCTAssertEqual(try MonitoredConnection.decodeList(canonical + canonical).count, 2)
        XCTAssertTrue(try MonitoredConnection.decodeList([]).isEmpty)
        for count in [1,103,payload.count-1] { XCTAssertThrowsError(try MonitoredConnection.decodeList(Array(payload.prefix(count)))) }
        var invalid = payload; invalid[99] = 255
        XCTAssertThrowsError(try MonitoredConnection.decodeList(invalid))
    }
    @discardableResult @MainActor private func connect(_ client: KDXClient, server: KDXServer, login: String, table: ChallengeTable) async throws -> WireConnection {
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await client.connect(wire: a, login: login, password: login.isEmpty ? "" : "pw", nickname: login.isEmpty ? "Guest" : login, table: table)
        return a
    }
    @MainActor func testSessionListingPermissionsActivityAndClose() async throws {
        var config = ServerConfiguration()
        config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true), ServerAccount(login: "member", password: "pw")]
        let table = ChallengeTable(testBytes: [UInt8](repeating: 5, count: 1739))
        let server = KDXServer(configuration: config), admin = KDXClient(), member = KDXClient(), guest = KDXClient()
        defer { admin.disconnect(); member.disconnect(); guest.disconnect(); server.stop() }
        for (client,login) in [(admin,"admin"),(member,"member"),(guest,"")] { try await connect(client, server: server, login: login, table: table) }
        do { _ = try await admin.request(type: 142); XCTFail("Unopened monitor accepted") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10003) }
        let initial = try await admin.connectionMonitor()
        XCTAssertEqual(initial.map(\.login), ["admin","member","guest"])
        XCTAssertEqual(initial.map(\.userID), server.users.map(\.id).sorted())
        XCTAssertTrue(initial.allSatisfy { $0.address == "127.0.0.1:12345" && $0.connectedAt != nil })
        do { _ = try await admin.request(type: 142); XCTFail("Fetch left monitor open") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10003) }
        do { _ = try await guest.connectionMonitor(); XCTFail("Guest read monitor") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        let before = try XCTUnwrap(initial.first { $0.login == "member" })
        try await Task.sleep(for: .milliseconds(5)); try await member.sendChat("Activity")
        let updated = try await admin.connectionMonitor()
        let after = try XCTUnwrap(updated.first { $0.login == "member" })
        XCTAssertEqual(before.loginTime, after.loginTime); XCTAssertGreaterThan(after.lastActivity, before.lastActivity)
        _ = try await member.request(type: 108)
        let afterPing = try await admin.connectionMonitor()
        XCTAssertEqual(afterPing.first { $0.login == "member" }?.lastActivity, after.lastActivity)
        guest.disconnect()
        for _ in 0..<100 where server.users.count > 2 { try await Task.sleep(for: .milliseconds(5)) }
        let remaining = try await member.connectionMonitor()
        XCTAssertEqual(remaining.count, 2, "Default members have user-information privilege")
        XCTAssertFalse(remaining.contains { $0.login == "guest" })
    }
    @MainActor func testPrivilegeRevocationInvalidatesOpenMonitor() async throws {
        var config = ServerConfiguration()
        config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true), ServerAccount(login: "member", password: "pw")]
        let table = ChallengeTable(testBytes: [UInt8](repeating: 6, count: 1739))
        let server = KDXServer(configuration: config), admin = KDXClient(), member = KDXClient()
        defer { admin.disconnect(); member.disconnect(); server.stop() }
        try await connect(admin, server: server, login: "admin", table: table)
        let memberWire = try await connect(member, server: server, login: "member", table: table)
        // Open/close have no success reply; use a raw send followed by a barrier.
        try await memberWire.send(type: 140)
        _ = try await member.request(type: 108)
        let snapshot = try await member.request(type: 142); XCTAssertEqual(snapshot.type, 143)
        var account = try await admin.account(login: "member")
        account.privilegeMask.set(40, true); account.privileges.set(40, false)
        try await admin.updateAccount(account, originalLogin: "member")
        do { _ = try await member.request(type: 142); XCTFail("Revoked access remained") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        account.privileges.set(40, true); try await admin.updateAccount(account, originalLogin: "member")
        do { _ = try await member.request(type: 142); XCTFail("Old monitor survived revocation") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10003) }
        let reopened = try await member.connectionMonitor(); XCTAssertEqual(reopened.count, 2)
    }
    @MainActor func testCancelledRefreshClosesMonitorAndPreservesCipher() async throws {
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true)]
        let table = ChallengeTable(testBytes: [UInt8](repeating: 7, count: 1739))
        let server = KDXServer(configuration: config), client = KDXClient()
        let (a,b) = MemoryTransport.endpoints(), gate = MonitorReplyGate(b)
        let clientWire = WireConnection(transport: a)
        server.accept(wire: WireConnection(transport: gate), table: table)
        defer { client.disconnect(); server.stop() }
        try await client.connect(wire: clientWire, login: "admin", password: "pw", nickname: "admin", table: table)
        gate.holdReply = true
        let pending = Task { try await client.connectionMonitor() }
        for _ in 0..<100 where !gate.waiting { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(gate.waiting)
        do { _ = try await client.connectionMonitor(); XCTFail("Concurrent refresh accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already refreshing")) }
        pending.cancel(); gate.release()
        do { _ = try await pending.value; XCTFail("Cancelled refresh succeeded") } catch is CancellationError { }
        do { _ = try await client.request(type: 142); XCTFail("Cancelled refresh left monitor open") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10003) }
        let cancelledSend = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clientWire.send(type: 108)
        }
        do { _ = try await cancelledSend.value; XCTFail("Pre-cancelled send succeeded") } catch is CancellationError { }
        let pong = try await client.request(type: 108)
        XCTAssertEqual(pong.type, 109, "Cancellation must not advance the outbound cipher without sending bytes")
        let reopened = try await client.connectionMonitor(); XCTAssertEqual(reopened.count, 1)
    }

}
