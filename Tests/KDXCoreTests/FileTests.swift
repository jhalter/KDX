import XCTest
@testable import KDXCore

final class FileTests: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testConfinementAndAtomicUploads() throws {
        let root = try temporaryDirectory(), outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        let files = try SharedFiles(path: root.path)
        XCTAssertThrowsError(try files.openFile(["..", "secret"]))
        XCTAssertThrowsError(try files.openFile(["escape", "secret"]))
        XCTAssertThrowsError(try files.beginUpload(folder: [], name: "../escape"))
        XCTAssertTrue(try files.list([]).isEmpty)
        do {
            let pending = try files.beginUpload(folder: [], name: "hello.txt")
            try pending.handle.write(contentsOf: Data("hello".utf8)); try pending.commit()
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("hello.txt")), Data("hello".utf8))
        do {
            let collision = try files.beginUpload(folder: [], name: "hello.txt")
            try collision.handle.write(contentsOf: Data("overwrite".utf8))
            XCTAssertThrowsError(try collision.commit())
        }
        do { _ = try files.beginUpload(folder: [], name: "aborted.txt") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["escape", "hello.txt"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("hello.txt")), Data("hello".utf8))
    }
    @MainActor func testAuthenticatedTransferAttachmentAndFileIntegrity() async throws {
        let shared = try temporaryDirectory(), local = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: shared); try? FileManager.default.removeItem(at: local) }
        let bytes = Data((0..<131111).map { UInt8(truncatingIfNeeded: $0 &* 17) })
        try bytes.write(to: local.appendingPathComponent("upload.bin"))
        let table = ChallengeTable(testBytes: [UInt8](repeating: 11, count: 1739))
        var config = ServerConfiguration(); config.sharedFolder = shared.path
        config.accounts = [ServerAccount(login: "member", password: "pw")]
        let server = KDXServer(configuration: config), client = KDXClient()
        defer { client.disconnect(); server.stop() }
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await client.connect(wire: a, login: "member", password: "pw", nickname: "Member", table: table)
        client.setTransferFactory {
            let (clientWire, serverWire) = MemoryTransport.pair(); server.accept(wire: serverWire, table: table); return clientWire
        }
        try await client.listFiles(); XCTAssertTrue(client.files.isEmpty)
        try await client.upload(from: local.appendingPathComponent("upload.bin"))
        XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("upload.bin")), bytes)
        XCTAssertEqual(client.files.map(\.name), ["upload.bin"])
        let file = try XCTUnwrap(client.files.first)
        try await client.download(file, to: local.appendingPathComponent("download.bin"))
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("download.bin")), bytes)
        XCTAssertNil(client.transferStatus)
        XCTAssertEqual(server.users.count, 1, "Transfer attachments must not appear as users")
    }
}
