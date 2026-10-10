import XCTest
@testable import KDXCore

@MainActor private final class StalledTransport: ByteTransport {
    let endpointDescription = "test:10700", peerHost = "test"
    var stallsStart = false, stallsWrite = false
    private(set) var closed = false
    private(set) var isWaiting = false
    private var readWaiter: CheckedContinuation<[UInt8], Error>?
    private var voidWaiter: CheckedContinuation<Void, Error>?
    func start() async throws { if stallsStart { try await suspend() } }
    func read(_ count: Int) async throws -> [UInt8] {
        guard !closed else { throw KDXError.disconnected }
        return try await withCheckedThrowingContinuation { readWaiter = $0; isWaiting = true }
    }
    func write(_ bytes: [UInt8]) async throws { if stallsWrite { try await suspend() } }
    private func suspend() async throws {
        guard !closed else { throw KDXError.disconnected }
        try await withCheckedThrowingContinuation { voidWaiter = $0; isWaiting = true }
    }
    func close() {
        guard !closed else { return }; closed = true
        readWaiter?.resume(throwing: KDXError.disconnected); readWaiter = nil
        voidWaiter?.resume(throwing: KDXError.disconnected); voidWaiter = nil; isWaiting = false
    }
}

final class LifecycleTests: XCTestCase {
    @MainActor func testStalledReadAndStartTimeoutsCloseTransport() async throws {
        for startup in [false, true] {
            let transport = StalledTransport(); transport.stallsStart = startup
            let wire = WireConnection(transport: transport); wire.ioTimeout = .milliseconds(20); wire.handshakeTimeout = .milliseconds(20)
            do {
                if startup { try await wire.start() } else { _ = try await wire.read(16) }
                XCTFail("Stalled I/O completed without timeout")
            } catch { XCTAssertTrue(error.localizedDescription.contains("stopped responding")) }
            XCTAssertTrue(transport.closed)
        }
    }
    @MainActor func testCancelBlockedWriteAndHandshake() async throws {
        let writer = StalledTransport(); writer.stallsWrite = true
        let wire = WireConnection(transport: writer)
        let writing = Task { try await wire.write([1,2,3]) }
        try await eventually { writer.isWaiting }
        writing.cancel()
        do { try await writing.value; XCTFail("Cancelled write succeeded") } catch is CancellationError { }
        XCTAssertTrue(writer.closed)
        let transport = StalledTransport(), client = KDXClient()
        let connect = Task { try await client.connect(wire: WireConnection(transport: transport), login: "", password: "", nickname: "Guest", table: ChallengeTable(testBytes: [UInt8](repeating: 1, count: 1739))) }
        try await eventually { transport.isWaiting }
        connect.cancel()
        do { try await connect.value; XCTFail("Cancelled handshake succeeded") } catch is CancellationError { }
        XCTAssertTrue(transport.closed); XCTAssertFalse(client.isConnecting); XCTAssertFalse(client.isConnected)
    }
    @MainActor func testReplacingPendingConnectionCannotClearNewSession() async throws {
        let transport = StalledTransport(), client = KDXClient(), server = KDXServer()
        let table = ChallengeTable(testBytes: [UInt8](repeating: 1, count: 1739))
        defer { client.disconnect(); server.stop() }
        let old = Task { try await client.connect(wire: WireConnection(transport: transport), login: "", password: "", nickname: "Old", table: table) }
        try await eventually { transport.isWaiting }
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await client.connect(wire: a, login: "", password: "", nickname: "New", table: table)
        do { try await old.value; XCTFail("Old connection unexpectedly succeeded") } catch { }
        XCTAssertTrue(client.isConnected); XCTAssertEqual(client.users.first?.nickname, "New")
        XCTAssertNil(client.lastError)
    }
    @MainActor func testRequestCancellationAndTimeoutLeaveSessionUsable() async throws {
        let server = KDXServer(), client = KDXClient()
        let table = ChallengeTable(testBytes: [UInt8](repeating: 1, count: 1739))
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        defer { client.disconnect(); server.stop() }
        try await client.connect(wire: a, login: "", password: "", nickname: "Guest", table: table)
        // 207 deliberately has no success reply, making it a controlled pending request.
        let payload = UInt32(1).beBytes + [UInt8](repeating: 0, count: 8) + Array("pending".utf8)
        let pending = Task { try await client.request(type: 207, payload: payload) }
        try await eventually { client.chat.contains { $0.text == "pending" } }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled request succeeded") } catch is CancellationError { }
        client.requestTimeout = .milliseconds(20)
        do { _ = try await client.request(type: 207, payload: payload); XCTFail("Missing reply did not time out") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not reply")) }
        let pong = try await client.request(type: 108); XCTAssertEqual(pong.type, 109)
        XCTAssertTrue(client.isConnected)
    }
    @MainActor private func eventually(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate())
    }
}
