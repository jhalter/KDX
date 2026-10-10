import XCTest
import Darwin
@testable import KDXCore

final class ResourceForkTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func nativeFork(_ file: URL) -> URL { URL(fileURLWithPath: file.path + "/..namedfork/rsrc") }
    private func writeNativeFork(_ bytes: Data, file: URL) throws {
        let fd = Darwin.open(nativeFork(file).path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        try handle.write(contentsOf: bytes)
    }
    private func bytes(_ count: Int, seed: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* seed) ^ ($0 >> 8)) }) }
    func testChunkedDescriptorAccessMatchesNativeResourceFork() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("classic")
        let data = bytes(137, seed: 7), resource = bytes(150019, seed: 19)
        try data.write(to: file); try writeNativeFork(resource, file: file)
        let handle = try FileHandle(forUpdating: file); defer { try? handle.close() }
        XCTAssertEqual(try ResourceFork.size(handle.fileDescriptor), UInt64(resource.count))
        XCTAssertEqual(try ResourceFork.read(handle.fileDescriptor, offset: 4096, count: 65536), resource.subdata(in: 4096..<69632))
        try ResourceFork.clear(handle.fileDescriptor)
        for offset in stride(from: 0, to: resource.count, by: 65536) {
            try ResourceFork.write(handle.fileDescriptor, offset: UInt64(offset), bytes: resource.subdata(in: offset..<min(offset+65536, resource.count)))
        }
        XCTAssertEqual(try Data(contentsOf: nativeFork(file)), resource)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    @MainActor func testBothForksUploadAndDownloadIncludingResourceOnlyFiles() async throws {
        let shared = try directory(), local = try directory()
        defer { try? FileManager.default.removeItem(at: shared); try? FileManager.default.removeItem(at: local) }
        let table = ChallengeTable(testBytes: [UInt8](repeating: 21, count: 1739))
        var config = ServerConfiguration(); config.sharedFolder = shared.path; config.accounts = [ServerAccount(login: "member", password: "pw")]
        let server = KDXServer(configuration: config), client = KDXClient()
        defer { client.disconnect(); server.stop() }
        try await connect(client, server: server, table: table)
        client.setTransferFactory {
            let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table); return a
        }
        for (index, sizes) in [(197321,147111),(0,70001)].enumerated() {
            let data = bytes(sizes.0, seed: 23), resource = bytes(sizes.1, seed: 31)
            let name = "classic-\(index)", source = local.appendingPathComponent("classic-\(index)")
            try data.write(to: source); try writeNativeFork(resource, file: source)
            try await client.upload(from: source)
            let uploaded = shared.appendingPathComponent(name)
            XCTAssertEqual(try Data(contentsOf: uploaded), data)
            XCTAssertEqual(try Data(contentsOf: nativeFork(uploaded)), resource)
            let listed = try XCTUnwrap(client.files.first { $0.name == name })
            let destination = local.appendingPathComponent("download-\(index)")
            try await client.download(listed, to: destination)
            XCTAssertEqual(try Data(contentsOf: destination), data)
            XCTAssertEqual(try Data(contentsOf: nativeFork(destination)), resource)
            XCTAssertEqual(client.transferProgress, 1)
        }
    }
    @MainActor func testResourceForkDownloadResumesFromSavedResourceOffset() async throws {
        let shared = try directory(), local = try directory()
        defer { try? FileManager.default.removeItem(at: shared); try? FileManager.default.removeItem(at: local) }
        let data = bytes(17, seed: 13), resource = bytes(160039, seed: 27)
        let source = shared.appendingPathComponent("classic"), destination = local.appendingPathComponent("download")
        try data.write(to: source); try writeNativeFork(resource, file: source)
        let table = ChallengeTable(testBytes: [UInt8](repeating: 22, count: 1739))
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
        let transfer = Task { try await client.download(file, to: destination) }
        try await eventually { gate?.isBlocked == true }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        client.cancelTransfer(); do { try await transfer.value; XCTFail("Canceled transfer completed") } catch {}
        var resumed: TransferGate?
        client.setTransferFactory {
            let (a,b) = MemoryTransport.endpoints(); let value = TransferGate(a); resumed = value
            server.accept(wire: WireConnection(transport: b), table: table); return WireConnection(transport: value)
        }
        try await client.download(file, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), data)
        XCTAssertEqual(try Data(contentsOf: nativeFork(destination)), resource)
        XCTAssertLessThan(try XCTUnwrap(resumed?.readByteCount), resource.count - 65536 + 1000)
    }
    @MainActor func testInterruptedResourceUploadRestartsResourceFork() async throws {
        let shared = try directory(), local = try directory()
        defer { try? FileManager.default.removeItem(at: shared); try? FileManager.default.removeItem(at: local) }
        let data = bytes(17, seed: 5), resource = bytes(140017, seed: 41)
        let source = local.appendingPathComponent("classic")
        try data.write(to: source); try writeNativeFork(resource, file: source)
        let table = ChallengeTable(testBytes: [UInt8](repeating: 23, count: 1739))
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
        client.cancelTransfer(); do { try await transfer.value; XCTFail("Canceled transfer completed") } catch {}
        _ = try await client.request(type: 108)
        var resumed: TransferGate?
        client.setTransferFactory {
            let (a,b) = MemoryTransport.endpoints(); let value = TransferGate(a); resumed = value
            server.accept(wire: WireConnection(transport: b), table: table); return WireConnection(transport: value)
        }
        try await client.upload(from: source)
        let uploaded = shared.appendingPathComponent("classic")
        XCTAssertEqual(try Data(contentsOf: uploaded), data)
        XCTAssertEqual(try Data(contentsOf: nativeFork(uploaded)), resource)
        XCTAssertGreaterThan(try XCTUnwrap(resumed?.writeByteCount), resource.count, "KDX uploads restart the resource fork")
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
