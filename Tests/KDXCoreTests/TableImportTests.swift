import XCTest
import CryptoKit
@testable import KDXCore

private final class ArchiveURLProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (Int, [String:String], Data) = (200, [:], Data())
        func set(_ status: Int, headers: [String:String] = [:], data: Data = Data()) { lock.withLock { value = (status, headers, data) } }
        func get() -> (Int, [String:String], Data) { lock.withLock { value } }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, data) = Self.state.get()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class TableImportTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ArchiveURLProtocol.self]
        return URLSession(configuration: config)
    }
    private func synthetic() throws -> [UInt8] {
        Array(try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "synthetic-table-import", withExtension: "zip", subdirectory: "Fixtures"))))
    }
    private func putLE(_ value: UInt32, in bytes: inout [UInt8], at: Int) {
        bytes.replaceSubrange(at..<at+4, with: value.leBytes)
    }
    func testStoredDeflatedAndEmptyEntriesStayInMemory() throws {
        let bytes = try synthetic(), archive = try TableArchive(data: Data(bytes))
        XCTAssertEqual(archive.entries.count, 3)
        XCTAssertEqual(try archive.contents(of: archive.entries[0]), Data("Synthetic ZIP import test; no Haxial content.".utf8))
        XCTAssertEqual(try archive.contents(of: archive.entries[1]), Data((0..<4096).map { UInt8($0 % 256) }))
        XCTAssertEqual(try archive.contents(of: archive.entries[2]), Data())
        XCTAssertThrowsError(try ChallengeTable(data: Data(bytes)), "Ordinary ZIP data must never become an authentication table")
        // ZIP comments may contain signature-like text; the complete EOCD length is authoritative.
        var commented = bytes; commented[bytes.count-2] = 8
        commented += [0x50,0x4b,0x05,0x06,1,2,3,4]
        XCTAssertEqual(try TableArchive(data: Data(commented)).entries.count, 3)
    }
    func testStreamedZIPDataDescriptorAndTotalExpansionBudget() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "synthetic-table-descriptor", withExtension: "zip", subdirectory: "Fixtures"))
        let streamed = try TableArchive(data: Data(contentsOf: url)), entry = try XCTUnwrap(streamed.entries.first)
        XCTAssertNotEqual(entry.flags & 8, 0)
        XCTAssertEqual(try streamed.contents(of: entry), Data(String(repeating: "streamed payload\n", count: 50).utf8))
        var bytes = try synthetic(), at = Int(bytes.le32(bytes.count-6))
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset+1]) << 8 }
        for _ in 0..<3 {
            let local = Int(bytes.le32(at+42))
            putLE(UInt32(TableArchive.fileLimit), in: &bytes, at: at+24)
            putLE(UInt32(TableArchive.fileLimit), in: &bytes, at: local+22)
            at += 46 + u16(at+28) + u16(at+30) + u16(at+32)
        }
        XCTAssertThrowsError(try TableArchive(data: Data(bytes))) { error in
            XCTAssertTrue(error.localizedDescription.contains("size limit"))
        }
    }
    func testRejectsCorruptionInvalidOffsetsAndExpansionLimits() throws {
        let bytes = try synthetic(), directory = Int(bytes.le32(bytes.count-6))
        for count in [0,4,21,bytes.count-1] { XCTAssertThrowsError(try TableArchive(data: Data(bytes.prefix(count)))) }
        var invalid = bytes; putLE(UInt32.max, in: &invalid, at: bytes.count-6)
        XCTAssertThrowsError(try TableArchive(data: Data(invalid)))
        invalid = bytes; invalid[bytes.count-18] = 1
        XCTAssertThrowsError(try TableArchive(data: Data(invalid)), "Split archives are unsupported")
        invalid = bytes; putLE(UInt32.max, in: &invalid, at: directory+42)
        XCTAssertThrowsError(try TableArchive(data: Data(invalid)))
        invalid = bytes; putLE(UInt32(TableArchive.fileLimit+1), in: &invalid, at: directory+24); putLE(UInt32(TableArchive.fileLimit+1), in: &invalid, at: 22)
        XCTAssertThrowsError(try TableArchive(data: Data(invalid)))
        let archive = try TableArchive(data: Data(bytes))
        invalid = bytes; invalid[archive.entries[0].packed.lowerBound] ^= 1
        let corrupt = try TableArchive(data: Data(invalid))
        XCTAssertThrowsError(try corrupt.contents(of: corrupt.entries[0]), "CRC must be checked before table scanning")
        invalid = bytes; invalid[archive.entries[1].packed.lowerBound] = 0xff
        let badDeflate = try TableArchive(data: Data(invalid))
        XCTAssertThrowsError(try badDeflate.contents(of: badDeflate.entries[1]))
        // Both size declarations agree, but stored data still has a different length.
        invalid = bytes; putLE(1, in: &invalid, at: 22); putLE(1, in: &invalid, at: directory+24)
        let badLength = try TableArchive(data: Data(invalid))
        XCTAssertThrowsError(try badLength.contents(of: badLength.entries[0]))
        invalid = bytes; invalid[6] |= 1; invalid[directory+8] |= 1
        let encrypted = try TableArchive(data: Data(invalid))
        XCTAssertNil(try encrypted.contents(of: encrypted.entries[0]))
    }
    func testBoundedFileReadAndInvalidRawTable() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(TableArchive.fileLimit+1)); try handle.close()
        XCTAssertThrowsError(try ChallengeTable(file: file)) { error in XCTAssertTrue(error.localizedDescription.contains("32 MiB")) }
        XCTAssertThrowsError(try ChallengeTable.verifiedDownload(Data()))
        XCTAssertThrowsError(try ChallengeTable(data: Data(repeating: 0, count: 1739)))
        XCTAssertThrowsError(try ChallengeTable(data: Data("This program including the following story".utf8)))
    }
    func testOriginalArchiveTableAndCapturedChallengeResponses() async throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_TEST_ARCHIVE"] else {
            throw XCTSkip("Set KDX_TEST_ARCHIVE to the original reference ZIP; it is not distributed with the tests.")
        }
        let url = URL(fileURLWithPath: path), data = try Data(contentsOf: url)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "8f50ef0cd4f82fc5b071340932c498a9df3556ed6cff6f23ecd6c36c43683583")
        let table = try ChallengeTable(file: url)
        let mock = session(); defer { mock.invalidateAndCancel() }
        ArchiveURLProtocol.state.set(200, headers: ["Content-Length": String(data.count)], data: data)
        let fetched = try await ChallengeTable.download(session: mock)
        XCTAssertEqual(fetched.bytes, table.bytes)
        if ProcessInfo.processInfo.environment["KDX_TEST_DOWNLOAD"] == "1" {
            let downloaded = try await ChallengeTable.download()
            XCTAssertEqual(downloaded.bytes, table.bytes)
        }
        XCTAssertEqual(try ChallengeTable.verifiedDownload(data).bytes, table.bytes)
        XCTAssertThrowsError(try ChallengeTable.verifiedDownload(data + Data([0])))
        XCTAssertEqual(table.bytes.count, 1739)
        let archive = try TableArchive(data: data)
        var programTable: ChallengeTable?
        for entry in archive.entries {
            if let program = try archive.contents(of: entry), let imported = try? ChallengeTable(data: program) { programTable = imported; break }
        }
        XCTAssertEqual(programTable?.bytes, table.bytes)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try table.save(to: destination)
        XCTAssertEqual(try ChallengeTable(file: destination).bytes, table.bytes)
        let decoy = Data("This program including the following story".utf8) + Data(repeating: 88, count: 1800)
        XCTAssertEqual(try ChallengeTable(data: decoy + Data(table.bytes)).bytes, table.bytes)
        var damaged = table.bytes; damaged[100] ^= 1
        XCTAssertThrowsError(try ChallengeTable(data: Data(damaged)))
        let client = try ProtocolTests().fixture("c2s"), server = try ProtocolTests().fixture("s2c")
        let clientHello = try Hello(wire: client), serverHello = try Hello(wire: server)
        for (wire, peer) in [(client,serverHello),(server,clientHello)] {
            let start = try Hello.length(wire), proof = try Proof(wire: Array(wire[start..<start+44]))
            XCTAssertEqual(try table.response(peer.challenge), proof.response)
            try proof.verify(key: AccountKey(password: "lab-only-pw!1"), nonce: peer.nonce, response: table.response(peer.challenge))
        }
    }
    func testPreCancelledDownloadDoesNotStart() async throws {
        let download = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ChallengeTable.download()
        }
        do { _ = try await download.value; XCTFail("Pre-cancelled download succeeded") }
        catch is CancellationError { }
    }

    func testDownloadRejectsHTTPErrorOversizedAndChangedResponses() async throws {
        let mock = session(); defer { mock.invalidateAndCancel() }
        ArchiveURLProtocol.state.set(404)
        do { _ = try await ChallengeTable.download(session: mock); XCTFail("HTTP error accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("could not be downloaded")) }
        ArchiveURLProtocol.state.set(200, headers: ["Content-Length": String(TableArchive.fileLimit+1)])
        do { _ = try await ChallengeTable.download(session: mock); XCTFail("Oversized response accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("32 MiB")) }
        ArchiveURLProtocol.state.set(200, data: Data("not the pinned archive".utf8))
        do { _ = try await ChallengeTable.download(session: mock); XCTFail("Changed archive accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("checksum")) }
    }

}
