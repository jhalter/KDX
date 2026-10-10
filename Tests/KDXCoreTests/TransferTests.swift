import XCTest
import Darwin
@testable import KDXCore

@MainActor final class TransferGate: ByteTransport {
    let base: MemoryTransport
    let blockAfterLargeReads: Int?
    let blockAfterLargeWrites: Int?
    var delayClose = false
    private var waiter: CheckedContinuation<Void, Error>?
    private(set) var isBlocked = false
    private(set) var largeReadCount = 0
    private(set) var largeWriteCount = 0
    private(set) var readByteCount = 0
    var peerHost: String { base.peerHost }
    var endpointDescription: String { base.endpointDescription }
    init(_ base: MemoryTransport, blockAfterLargeReads: Int? = nil, blockAfterLargeWrites: Int? = nil) {
        self.base = base; self.blockAfterLargeReads = blockAfterLargeReads; self.blockAfterLargeWrites = blockAfterLargeWrites
    }
    func start() async throws { try await base.start() }
    func read(_ count: Int) async throws -> [UInt8] {
        if count >= 65536 {
            if largeReadCount == blockAfterLargeReads {
                isBlocked = true
                try await withCheckedThrowingContinuation { waiter = $0 }
            }
            largeReadCount += 1
        }
        let bytes = try await base.read(count); readByteCount += bytes.count; return bytes
    }
    func write(_ bytes: [UInt8]) async throws {
        if bytes.count >= 65536 {
            if largeWriteCount == blockAfterLargeWrites { isBlocked = true; try await withCheckedThrowingContinuation { waiter = $0 } }
            largeWriteCount += 1
        }
        try await base.write(bytes)
    }
    func releaseClose() { waiter?.resume(throwing: KDXError.disconnected); waiter = nil }
    func close() { if !delayClose { releaseClose() }; base.close() }
}

final class TransferTests: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func testCapturedDownloadMetadataAndAlignedOffsets() throws {
        var complete = [UInt8]()
        for (parent, transfer, offset, length) in [("33068", "33082", 0, 70000), ("53514", "53518", 5000, 65904), ("56346", "56352", 70000, 0)] {
            let parentMessages = try capturedMessages("probe-" + parent)
            let info = try XCTUnwrap(parentMessages.first { $0.type == 105 })
            let messages = try capturedMessages("probe-" + transfer, key: AccountKey(bytes: Array(info.payload.prefix(32))))
            let requestBytes = try XCTUnwrap(messages.first { $0.type == 412 }?.payload)
            let request = try DownloadRequest(wire: requestBytes)
            XCTAssertEqual(request.dataOffset, UInt64(offset)); XCTAssertEqual(try request.encode(), requestBytes)
            let replyBytes = try XCTUnwrap(messages.first { $0.type == 413 }?.payload)
            let details = try DownloadInfo(wire: replyBytes)
            XCTAssertEqual(details.dataSize, 70000); XCTAssertEqual(details.strings[0], "probe-dl.bin")
            XCTAssertEqual(try details.encode(), replyBytes)
            let forks = messages.filter { $0.type == 414 }
            XCTAssertEqual(forks.count, 2); XCTAssertEqual(forks[0].payload.count, length); XCTAssertTrue(forks[1].payload.isEmpty)
            if offset == 0 { complete = forks[0].payload }
            else { XCTAssertEqual(forks[0].payload, Array(complete.dropFirst(Int(request.alignedOffset(size: details.dataSize))))) }
        }
        // The reference's timestamp example is consistent with its October 2026 capture.
        let sample = KDXTime.decode(0x3a36c4895ba)
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: sample), 2026)
        XCTAssertEqual(KDXTime.encode(sample), 0x3a36c4895ba)
        XCTAssertEqual(KDXTime.decode(KDXTime.encode(Date(timeIntervalSince1970: 1700000000))), Date(timeIntervalSince1970: 1700000000))
    }
    func testCheckpointLockingConfinementAndChangedFileRejection() throws {
        let local = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: local) }
        let destination = local.appendingPathComponent("download.bin")
        let identity = DownloadIdentity(server: "test", account: "member", path: ["file"], destination: "download.bin")
        var info = DownloadInfo(dataSize: 100000, name: "file"); info.modified = KDXTime.encode(Date())
        do {
            let partial = try PartialDownload(destination: destination, identity: identity)
            try partial.prepare(info); try partial.handle.write(contentsOf: Data(repeating: 3, count: 5001))
            XCTAssertThrowsError(try PartialDownload(destination: destination, identity: identity), "A simultaneous writer must not open the checkpoint")
        }
        do {
            let partial = try PartialDownload(destination: destination, identity: identity)
            XCTAssertEqual(partial.offset, 4096)
            var changed = info; changed.modified += 1
            XCTAssertThrowsError(try partial.prepare(changed))
        }
        do { let fresh = try PartialDownload(destination: destination, identity: identity); XCTAssertEqual(fresh.offset, 0); fresh.discard() }
        let folder = local.appendingPathComponent(".kdx-downloads")
        let stem = try identity.digest()
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(stem + ".part"), withDestinationURL: local.appendingPathComponent("outside"))
        XCTAssertThrowsError(try PartialDownload(destination: destination, identity: identity))
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("outside").path))
        try FileManager.default.removeItem(at: folder)
        let outside = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        XCTAssertThrowsError(try PartialDownload(destination: destination, identity: identity))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    @MainActor func testCancelledDownloadResumesAfterReconnectWithoutPublishingPartialFile() async throws {
        let shared = try temporaryDirectory(), local = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: shared); try? FileManager.default.removeItem(at: local) }
        let bytes = Data((0..<200003).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let source = shared.appendingPathComponent("source.bin"), destination = local.appendingPathComponent("download.bin")
        try bytes.write(to: source)
        let modified = Date(timeIntervalSince1970: 1700000000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
        let table = ChallengeTable(testBytes: [UInt8](repeating: 11, count: 1739))
        var config = ServerConfiguration(); config.sharedFolder = shared.path; config.accounts = [ServerAccount(login: "member", password: "pw")]
        let server = KDXServer(configuration: config), client = KDXClient()
        defer { client.disconnect(); server.stop() }
        try await connect(client, server: server, table: table)
        var gate: TransferGate?
        client.setTransferFactory {
            let (a,b) = MemoryTransport.endpoints(); let value = TransferGate(a, blockAfterLargeReads: 1); gate = value
            server.accept(wire: WireConnection(transport: b), table: table); return WireConnection(transport: value)
        }
        try await client.listFiles(); let file = try XCTUnwrap(client.files.first)
        let interrupted = Task { try await client.download(file, to: destination) }
        try await eventually { gate?.isBlocked == true }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertGreaterThan(client.transferProgress, 0)
        client.cancelTransfer()
        do { try await interrupted.value; XCTFail("Cancelled download completed") } catch {}
        XCTAssertNil(client.transferStatus); XCTAssertTrue(client.isConnected)
        client.disconnect(); try await connect(client, server: server, table: table)
        var resumed: TransferGate?
        client.setTransferFactory {
            let (a,b) = MemoryTransport.endpoints(); let value = TransferGate(a); resumed = value
            server.accept(wire: WireConnection(transport: b), table: table); return WireConnection(transport: value)
        }
        try await client.download(file, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertLessThan(try XCTUnwrap(resumed?.readByteCount), bytes.count - 65536 + 1000, "The resumed connection must skip the saved first chunk")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date, modified)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: local.appendingPathComponent(".kdx-downloads").path).isEmpty)
        do { try await client.download(file, to: destination); XCTFail("Existing destination overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }
    @MainActor func testOldTransferCleanupCannotClearNewTransferAfterReconnect() async throws {
        let shared = try temporaryDirectory(), local = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: shared); try? FileManager.default.removeItem(at: local) }
        try Data(repeating: 5, count: 131111).write(to: shared.appendingPathComponent("source.bin"))
        let table = ChallengeTable(testBytes: [UInt8](repeating: 12, count: 1739))
        var config = ServerConfiguration(); config.sharedFolder = shared.path; config.accounts = [ServerAccount(login: "member", password: "pw")]
        let server = KDXServer(configuration: config), client = KDXClient()
        defer { client.disconnect(); server.stop() }
        try await connect(client, server: server, table: table)
        var oldGate: TransferGate?
        client.setTransferFactory {
            let (a,b) = MemoryTransport.endpoints(); let value = TransferGate(a, blockAfterLargeReads: 1); value.delayClose = true; oldGate = value
            server.accept(wire: WireConnection(transport: b), table: table); return WireConnection(transport: value)
        }
        try await client.listFiles(); let file = try XCTUnwrap(client.files.first)
        let old = Task { try await client.download(file, to: local.appendingPathComponent("old.bin")) }
        try await eventually { oldGate?.isBlocked == true }
        client.disconnect(); try await connect(client, server: server, table: table)
        var newGate: TransferGate?
        client.setTransferFactory {
            let (a,b) = MemoryTransport.endpoints(); let value = TransferGate(a, blockAfterLargeReads: 1); newGate = value
            server.accept(wire: WireConnection(transport: b), table: table); return WireConnection(transport: value)
        }
        let current = Task { try await client.download(file, to: local.appendingPathComponent("new.bin")) }
        try await eventually { newGate?.isBlocked == true }
        let progress = client.transferProgress
        oldGate?.releaseClose()
        do { try await old.value; XCTFail("Old download completed") } catch {}
        XCTAssertNotNil(client.transferStatus); XCTAssertEqual(client.transferProgress, progress); XCTAssertTrue(client.isConnected)
        current.cancel()
        do { try await current.value; XCTFail("Cancelled download completed") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertNil(client.transferStatus); XCTAssertTrue(client.isConnected)
    }
    @MainActor func testCancelledUploadRemovesPartialServerFileAndLeavesSessionUsable() async throws {
        let shared = try temporaryDirectory(), local = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: shared); try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source.bin"); try Data(repeating: 9, count: 131111).write(to: source)
        let table = ChallengeTable(testBytes: [UInt8](repeating: 13, count: 1739))
        var config = ServerConfiguration(); config.sharedFolder = shared.path; config.accounts = [ServerAccount(login: "member", password: "pw")]
        let server = KDXServer(configuration: config), client = KDXClient()
        defer { client.disconnect(); server.stop() }
        try await connect(client, server: server, table: table)
        var gate: TransferGate?
        client.setTransferFactory {
            let (a,b) = MemoryTransport.endpoints(); let value = TransferGate(a, blockAfterLargeWrites: 1); gate = value
            server.accept(wire: WireConnection(transport: b), table: table); return WireConnection(transport: value)
        }
        let transfer = Task { try await client.upload(from: source) }
        try await eventually { gate?.isBlocked == true }
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("source.bin").path))
        client.cancelTransfer()
        do { try await transfer.value; XCTFail("Cancelled upload completed") } catch {}
        try await eventually { (try? FileManager.default.contentsOfDirectory(atPath: shared.path).isEmpty) == true }
        let pong = try await client.request(type: 108)
        XCTAssertEqual(pong.type, 109); XCTAssertNil(client.transferStatus)
    }
    @MainActor private func connect(_ client: KDXClient, server: KDXServer, table: ChallengeTable) async throws {
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await client.connect(wire: a, login: "member", password: "pw", nickname: "Member", table: table)
    }
    @MainActor private func eventually(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(4)
        while !predicate() && Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
}
