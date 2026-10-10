import XCTest
@testable import KDXCore

/// Explicit opt-in probes for independent peers; never run against a default public endpoint.
final class LiveInteropTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private func table() throws -> ChallengeTable {
        if let path = environment["KDX_TEST_TABLE"] ?? environment["KDX_TEST_ARCHIVE"] {
            return try ChallengeTable(file: URL(fileURLWithPath: path))
        }
        return try KDXStorage.loadTable()
    }
    private func port(_ key: String, default fallback: UInt16) throws -> UInt16 {
        guard let text = environment[key] else { return fallback }
        guard let value = UInt16(text), value > 0 else { throw KDXError.invalid("Invalid \(key).") }
        return value
    }
    @MainActor func testOriginalTrackerBrowsing() async throws {
        guard let host = environment["KDX_TEST_TRACKER_HOST"], !host.isEmpty else {
            throw XCTSkip("Set KDX_TEST_TRACKER_HOST to an authorized independent tracker for live verification.")
        }
        let client = KDXTrackerClient(host: host, port: try port("KDX_TEST_TRACKER_PORT", default: 10800))
        let table = try table(), groups = try await client.groups(table: table)
        // A known group can be selected when the first group is empty.
        let group: TrackerGroup
        if let name = environment["KDX_TEST_TRACKER_GROUP"] {
            group = try XCTUnwrap(groups.first { $0.name == name }, "Requested tracker group was not listed")
        } else {
            group = try XCTUnwrap(groups.first, "Choose a tracker with a group to verify both listing commands")
        }
        let servers = try await client.servers(in: group, table: table)
        XCTAssertTrue(servers.allSatisfy { $0.address.count == 6 }, "Tracker returned an address format that still needs decoding")
        // Counts may change between queries; do not assert snapshot equality.
    }
    @MainActor func testOriginalServerLogin() async throws {
        guard let host = environment["KDX_TEST_SERVER_HOST"], !host.isEmpty else {
            throw XCTSkip("Set KDX_TEST_SERVER_HOST to an authorized independent server for live verification.")
        }
        let client = KDXClient()
        defer { client.disconnect() }
        try await client.connect(host: host, port: port("KDX_TEST_SERVER_PORT", default: 10700),
                                 login: environment["KDX_TEST_SERVER_LOGIN"] ?? "",
                                 password: environment["KDX_TEST_SERVER_PASSWORD"] ?? "",
                                 nickname: "macOS KDX Interop", autoJoinPublicChat: false, table: table())
        XCTAssertTrue(client.isConnected)
        XCTAssertNotNil(client.serverInfo)
        // No messages, account changes, or file mutations are sent by this probe.
    }
}
