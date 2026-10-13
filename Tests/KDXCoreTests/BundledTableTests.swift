import Foundation
import XCTest
@testable import KDXCore

final class BundledTableTests: XCTestCase {
    func testMissingBundledDataReportsInstallationError() {
        XCTAssertThrowsError(try KDXStorage.loadTable(bundled:nil)) { error in
            XCTAssertEqual(error.localizedDescription,"This installation is missing required authentication data. Reinstall the app.")
        }
    }

    func testDamagedOrUnreadableBundledDataReportsInstallationError() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:file) }
        let message = "This installation's authentication data is damaged or unreadable. Reinstall the app."
        XCTAssertThrowsError(try KDXStorage.loadTable(bundled:file)) { error in
            XCTAssertEqual(error.localizedDescription,message)
        }
        try Data("damaged data".utf8).write(to:file)
        XCTAssertThrowsError(try KDXStorage.loadTable(bundled:file)) { error in
            XCTAssertEqual(error.localizedDescription,message)
        }
    }

    func testVerifiedBundledDataLoadsAutomatically() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_TEST_TABLE"] else {
            throw XCTSkip("Set KDX_TEST_TABLE to a verified challenge-table.bin")
        }
        let bundled = URL(fileURLWithPath:path)
        let data = try Data(contentsOf:bundled)
        XCTAssertEqual(try KDXStorage.loadTable(bundled:bundled).bytes,Array(data))
    }
}
