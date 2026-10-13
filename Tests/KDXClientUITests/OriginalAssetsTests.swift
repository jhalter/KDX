import Foundation
import XCTest
@testable import KDXClientUI
import KDXCore

final class OriginalAssetsTests: XCTestCase {
    func testInvalidArchivePreservesGeneratedAssets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let archive = root.appendingPathComponent("bad.7z"), output = root.appendingPathComponent("output")
        try Data("not the original archive".utf8).write(to:archive)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let sentinel = output.appendingPathComponent("OriginalAppearances.json")
        try Data("keep me".utf8).write(to:sentinel)
        XCTAssertThrowsError(try ClassicOriginalAssets.export(from:archive,to:output))
        XCTAssertEqual(try Data(contentsOf:sentinel),Data("keep me".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:output.path),["OriginalAppearances.json"])
    }

    func testOriginalArchiveExportsCompleteAssets() async throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_ORIGINAL_ARCHIVE"] else {
            throw XCTSkip("Set KDX_ORIGINAL_ARCHIVE to KDX_1.6_OSX_intel.7z")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:output) }
        try ClassicOriginalAssets.export(from:URL(fileURLWithPath:path),to:output)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:output.path)),
                       ["OriginalAppearances.json","OriginalServerAppearances.json","challenge-table.bin"])
        let client = try ClassicBundledAppearances.load(from:output.appendingPathComponent("OriginalAppearances.json"))
        let server = try ClassicBundledAppearances.load(from:output.appendingPathComponent("OriginalServerAppearances.json"))
        XCTAssertEqual(client.count,16); XCTAssertEqual(server.count,16)
        XCTAssertNotNil(client.first?.chromeArtwork?.banner)
        XCTAssertNotNil(client.first?.chromeArtwork?.progress)
        XCTAssertNotNil(client.first?.chromeArtwork?.wonderLight)
        XCTAssertNil(server.first?.chromeArtwork?.banner)
        let table = output.appendingPathComponent("challenge-table.bin")
        XCTAssertEqual(try Data(contentsOf:table).count,1739)
        _ = try ChallengeTable(file:table) // Includes the independent protocol table digest check.
        if let native = ProcessInfo.processInfo.environment["KDX_REFERENCE"] {
            let original = try await ClassicAssetImporter.load(URL(fileURLWithPath:native))
            XCTAssertEqual(client,original.appearances,"All client assets must remain identical to the native PowerPC reference")
        }
    }

    func testUnknownWindowsClientIsRejected() {
        XCTAssertThrowsError(try AppearanceDecoder.application(Data("MZunknown revision".utf8)))
    }
}
