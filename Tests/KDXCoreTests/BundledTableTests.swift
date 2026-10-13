import Foundation
import XCTest
@testable import KDXCore

final class BundledTableTests: XCTestCase {
    func testBundledTableAndExplicitImportPrecedence() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_TEST_TABLE"] else {
            throw XCTSkip("Set KDX_TEST_TABLE to a verified challenge-table.bin")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let bundled = root.appendingPathComponent("bundled.bin"), stored = root.appendingPathComponent("stored.bin")
        let data = try Data(contentsOf:URL(fileURLWithPath:path))
        try data.write(to:bundled)
        let loaded = try KDXStorage.loadTable(stored:stored,bundled:bundled)
        XCTAssertEqual(loaded.bytes,Array(data))
        XCTAssertFalse(FileManager.default.fileExists(atPath:stored.path))
        try Data("damaged import".utf8).write(to:stored)
        XCTAssertThrowsError(try KDXStorage.loadTable(stored:stored,bundled:bundled))
        try data.write(to:stored)
        try Data("damaged bundle".utf8).write(to:bundled)
        XCTAssertEqual(try KDXStorage.loadTable(stored:stored,bundled:bundled).bytes,Array(data))
        XCTAssertEqual(try KDXStorage.loadTable(stored:stored,bundled:nil).bytes,Array(data))
        try FileManager.default.removeItem(at:stored)
        XCTAssertThrowsError(try KDXStorage.loadTable(stored:stored,bundled:bundled))
        XCTAssertThrowsError(try KDXStorage.loadTable(stored:stored,bundled:nil))
    }
}
