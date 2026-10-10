import XCTest
@testable import KDXCore

final class TrackerTests: XCTestCase {
    // Authored examples from the static layouts, not captured tracker traffic.
    private func bytes(_ hex: String) -> [UInt8] { hex.split(whereSeparator: \.isWhitespace).map { UInt8($0, radix: 16)! } }
    private var groups: [UInt8] {
        bytes("00 00 00 02 00 02 aa bb cc dd 03 04 4d 61 63 54 65 73 74 ee 00 00 11 22 33 44 02 00 c3 a9 ff ff")
    }
    private var servers: [UInt8] {
        // 28-byte header, six address bytes, name, description, then record padding.
        bytes("""
        00 00 00 01
        01 02 03 04 05 06 07 08 00 00 00 00 00 00 00 03
        00 0a 00 00 00 00 00 00 06 03 04 00
        c0 00 02 07 29 cc 4d 61 63 54 65 73 74 aa bb cc
        """)
    }
    func testStaticGroupLayoutAndNameRequest() throws {
        let list = try TrackerGroup.decodeList(groups)
        XCTAssertEqual(list.map(\.name), ["Mac", "é"])
        XCTAssertEqual(list.map(\.serverCount), [2,0]); XCTAssertEqual(list[0].description, "Test")
        XCTAssertEqual(list[0].serverListRequest(), bytes("00 00 03 00 4d 61 63"))
        XCTAssertEqual(list[1].serverListRequest(), bytes("00 00 02 00 c3 a9"))
        var raw = bytes("00 00 00 01 00 00 00 00 00 00 01 00 ff 00 00 00")
        XCTAssertEqual(try TrackerGroup.decodeList(raw)[0].serverListRequest(), bytes("00 00 01 00 ff"), "Keep the original group-name bytes for lookup")
        raw[10] = 255
        XCTAssertThrowsError(try TrackerGroup.decodeList(raw))
        XCTAssertEqual(try TrackerGroup.decodeList([0,0,0,0]), [])
    }
    func testStaticServerLayoutPaddingAndUnknownAddress() throws {
        let server = try XCTUnwrap(TrackerServer.decodeList(servers).first)
        XCTAssertEqual(server.name, "Mac"); XCTAssertEqual(server.description, "Test")
        XCTAssertEqual(server.host, "192.0.2.7"); XCTAssertEqual(server.port, 10700)
        XCTAssertTrue(server.isTracker)
        var ordinary = servers; ordinary[19] = 0
        XCTAssertFalse(try TrackerServer.decodeList(ordinary)[0].isTracker)
        XCTAssertEqual(Array(server.header.prefix(8)), bytes("01 02 03 04 05 06 07 08"))
        var two = servers; two[3] = 2; two += servers.dropFirst(4)
        XCTAssertEqual(try TrackerServer.decodeList(two).map(\.host), ["192.0.2.7", "192.0.2.7"])
        XCTAssertEqual(try TrackerServer.decodeList([]), []); XCTAssertEqual(try TrackerServer.decodeList([0,0,0,0]), [])
        var unknown = servers; unknown[28] = 5; unknown.remove(at: 37); unknown.removeLast(3)
        let unsupported = try XCTUnwrap(TrackerServer.decodeList(unknown).first)
        XCTAssertNil(unsupported.host); XCTAssertNil(unsupported.port)
        XCTAssertEqual(unsupported.name, "Mac")
    }
    func testMalformedListsAreRejected() throws {
        for end in 0..<groups.count { XCTAssertThrowsError(try TrackerGroup.decodeList(Array(groups.prefix(end)))) }
        for end in 1..<servers.count { XCTAssertThrowsError(try TrackerServer.decodeList(Array(servers.prefix(end)))) }
        for bad in [bytes("ff ff ff ff"), groups + [0], [UInt8](repeating: 0, count: 5)] {
            XCTAssertThrowsError(try TrackerGroup.decodeList(bad))
        }
        for bad in [bytes("ff ff ff ff"), servers + [0], [UInt8](repeating: 0, count: 5)] {
            XCTAssertThrowsError(try TrackerServer.decodeList(bad))
        }
        for offset in 28..<32 {
            var bad = servers; bad[offset] = 255
            XCTAssertThrowsError(try TrackerServer.decodeList(bad))
        }
    }
    @MainActor private func authenticate(_ wire: WireConnection, table: ChallengeTable) async throws {
        let client = try await wire.receiveHello()
        XCTAssertEqual(client.version, 0x10); XCTAssertEqual(client.name, [])
        var hello = Hello(server: true); hello.version = 0x30
        try await wire.write(hello.encode())
        let key = AccountKey(password: "")
        try Proof(wire: await wire.read(44)).verify(key: key, nonce: hello.nonce, response: table.response(hello.challenge))
        try await wire.write(Proof(key: key, nonce: client.nonce, response: table.response(client.challenge)).encode())
        wire.cipher = SessionCipher(key: key)
    }
    @MainActor func testAnonymousHandshakeAndCorrelatedListingRequests() async throws {
        let table = ChallengeTable(testBytes: [UInt8](repeating: 5, count: 1739))
        let group = try TrackerGroup.decodeList(groups)[0]
        for (type, payload, response) in [(UInt32(700), [], groups), (702, group.serverListRequest(), servers)] {
            let (client, tracker) = MemoryTransport.pair()
            defer { client.close(); tracker.close() }
            let peer = Task {
                try await authenticate(tracker, table: table)
                let request = try await tracker.receive()
                XCTAssertEqual(request.type, type, "Browsing must not send server identity opcode 100")
                XCTAssertFalse(request.isReply); XCTAssertEqual(request.payload, payload)
                try await tracker.send(type: type+1, payload: [], transaction: request.transaction &+ 1, reply: true)
                try await tracker.send(type: type+1, payload: [], transaction: request.transaction, reply: false)
                try await tracker.send(type: type+1, payload: response, transaction: request.transaction, reply: true)
            }
            let result = try await KDXTrackerClient.query(wire: client, type: type, replyType: type+1, payload: payload, table: table)
            XCTAssertEqual(result, response)
            try await peer.value
        }
    }
    @MainActor func testErrorsAndUnexpectedReplies() async throws {
        let table = ChallengeTable(testBytes: [UInt8](repeating: 6, count: 1739))
        for (type, payload) in [(UInt32(1), bytes("00 01 00 0c 00 00 02 be")), (701, [UInt8]()), (1, [0])] {
            let (client, tracker) = MemoryTransport.pair()
            defer { client.close(); tracker.close() }
            let peer = Task {
                try await authenticate(tracker, table: table)
                let request = try await tracker.receive()
                try await tracker.send(type: type, payload: payload, transaction: request.transaction, reply: true)
            }
            do {
                _ = try await KDXTrackerClient.query(wire: client, type: 702, replyType: 703, table: table)
                XCTFail("Invalid tracker reply accepted")
            } catch KDXError.remote(let code) { XCTAssertEqual(code, 0x1000c) }
            catch KDXError.invalid { }
            try await peer.value
        }
        let (client, server) = MemoryTransport.pair()
        defer { client.close(); server.close() }
        let peer = Task { _ = try await server.receiveHello(); try await server.write(Hello(server: true).encode()) }
        do {
            _ = try await KDXTrackerClient.query(wire: client, type: 700, replyType: 701, table: table)
            XCTFail("Ordinary server accepted as tracker")
        } catch KDXError.invalid(let message) { XCTAssertTrue(message.contains("service")) }
        try await peer.value
    }
    @MainActor func testCancellationDeadlineAndOversizedReply() async throws {
        let table = ChallengeTable(testBytes: [UInt8](repeating: 7, count: 1739))
        for mode in 0..<3 {
            let (client, tracker) = MemoryTransport.pair()
            defer { client.close(); tracker.close() }
            let received = expectation(description: "Request received")
            let peer = Task {
                try await authenticate(tracker, table: table)
                let request = try await tracker.receive()
                received.fulfill()
                if mode == 2 {
                    try await tracker.write(try XCTUnwrap(tracker.cipher).sealHeader(transaction: request.transaction, type: 701, reply: true, length: 0x100001))
                }
                do { _ = try await tracker.read(1); XCTFail("Query should close its connection") } catch { }
            }
            let query = Task { try await KDXTrackerClient.query(wire: client, type: 700, replyType: 701, table: table, timeout: mode == 1 ? .milliseconds(250) : .seconds(3)) }
            await fulfillment(of: [received], timeout: 2)
            if mode == 0 { query.cancel() }
            do { _ = try await query.value; XCTFail("Expected query to fail") } catch { }
            try await peer.value
        }
    }
}
