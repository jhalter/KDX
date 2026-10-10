import XCTest
@testable import KDXCore

final class FileInformationTests: XCTestCase {
    func testCapturedFileInformationAndLists() throws {
        let messages = try capturedMessages("probe-54328")
        let payload = try XCTUnwrap(messages.first { $0.type == 410 }?.payload)
        let info = try RemoteFileInformation.decode(payload)
        XCTAssertEqual(info.name, "Uploads [UL]"); XCTAssertEqual(info.kind, "folder")
        XCTAssertTrue(info.isDirectory); XCTAssertEqual(try info.encode(), payload)
        XCTAssertEqual(info.header.u32(0), 0x39); XCTAssertEqual(info.header.u32(4), 0xbf)
        let request = try XCTUnwrap(messages.first { $0.type == 409 }?.payload)
        XCTAssertEqual(try RemotePath(wire: request).names, ["Uploads [UL]"])
        var seen = 0
        for message in messages where message.type == 401 {
            let files = try RemoteFile.decodeList(message.payload)
            var normalized = message.payload, at = 4
            for file in files {
                let end = at + 56 + file.name.utf8.count + file.kind.utf8.count
                let padded = min((end + 3) & ~3, normalized.count)
                // Legacy list padding is uninitialized; the reference encoder zeroes it too.
                normalized.replaceSubrange(end..<padded, with: repeatElement(UInt8(0), count: padded-end)); at = padded
            }
            XCTAssertEqual(try RemoteFile.encodeList(files), normalized)
            seen += 1
        }
        XCTAssertGreaterThan(seen, 0)
    }
    func testDescriptorConfinementAndMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.bin"), folder = root.appendingPathComponent("Folder")
        try Data([1,2,3]).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let modified = Date(timeIntervalSince1970: 1_600_000_000.125)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: file)
        let store = try SharedFiles(path: root.path), details = try store.information(["sample.bin"])
        XCTAssertEqual(details.size, 3); XCTAssertEqual(details.kind, "exttype/bin")
        XCTAssertEqual(try XCTUnwrap(details.modified).timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNotNil(details.created)
        XCTAssertTrue(try store.information(["Folder"]).isDirectory)
        XCTAssertTrue(try store.information([]).isDirectory)
        for path in [["escape"], ["..", "sample.bin"], [".kdx-downloads"], ["missing"]] { XCTAssertThrowsError(try store.information(path)) }
        let entry = try XCTUnwrap(store.list([]).first { $0.name == "sample.bin" })
        XCTAssertEqual(entry.kind, details.kind); XCTAssertEqual(entry.created, details.created)
        XCTAssertEqual(entry.modified, details.modified)
    }
    @MainActor func testFileInformationRoundTripAndPermissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("Contents".utf8).write(to: root.appendingPathComponent("hello.txt"))
        var config = ServerConfiguration(); config.sharedFolder = root.path
        config.accounts = [ServerAccount(login: "member", password: "pw")]
        let server = KDXServer(configuration: config), member = KDXClient(), guest = KDXClient()
        defer { member.disconnect(); guest.disconnect(); server.stop() }
        let table = ChallengeTable(testBytes: [UInt8](repeating: 9, count: 1739))
        for (client,login) in [(member,"member"), (guest,"")] {
            let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
            try await client.connect(wire: a, login: login, password: login.isEmpty ? "" : "pw", nickname: login.isEmpty ? "Guest" : login, table: table)
        }
        let details = try await member.fileInformation(path: ["hello.txt"])
        XCTAssertEqual(details.name, "hello.txt"); XCTAssertEqual(details.kind, "exttype/txt"); XCTAssertEqual(details.size, 8)
        XCTAssertNotNil(details.created); XCTAssertNotNil(details.modified)
        try await member.listFiles()
        XCTAssertEqual(member.files.first?.kind, details.kind)
        XCTAssertEqual(member.files.first?.created, details.created)
        do { _ = try await guest.fileInformation(path: ["hello.txt"]); XCTFail("Guest read denied attributes") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        do { _ = try await member.fileInformation(path: ["..", "hello.txt"]); XCTFail("Traversal accepted") } catch { }
    }
}
