import XCTest
@testable import KDXCore

final class TrackerAdvertisementTests: XCTestCase {
    private func hex(_ value: String) -> [UInt8] {
        stride(from: 0, to: value.count, by: 2).map { at in
            let start = value.index(value.startIndex, offsetBy: at)
            return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
        }
    }
    private var sample: TrackerAdvertisement { TrackerAdvertisement(name: "Mac", description: "Test", port: 10700, userCount: 3, groups: ["Lab"]) }
    func testStaticDatagramVectorAndCRC() throws {
        // Authored independently in Python from the static wire layout, not a capture.
        let expected = hex("80ea2812e7779c9d73ee6edda4c492d7013557de94215081eda3a0fc8213381b5e104432e4a26825d4e86164b6fa5b1fc57b854663538389151b4058a985ffe3f8a44c4e3c7c66e128021a0c")
        XCTAssertEqual(try sample.encode(), expected)
        XCTAssertEqual(TrackerAdvertisement.crc(Array("123456789".utf8), seed: .max), 0x0376e6e7)
        var plain = TrackerAdvertisement.obfuscate(expected)
        XCTAssertEqual(plain.count, 76); XCTAssertEqual(plain.u32(0), 0x254b4458)
        XCTAssertEqual(plain.u16(4), 0x10); XCTAssertEqual(plain.u16(6), 0)
        XCTAssertEqual(plain.u32(24), 10700); XCTAssertEqual(plain.u16(36), 3)
        XCTAssertEqual(Array(plain[51..<62]), [0,0,3,4,0,3,0,0,0,0,0])
        XCTAssertEqual(plain.text(64..<74), "MacTestLab")
        let checksum = plain.u32(8); plain.put(UInt32(0xcad31ecc), at: 8)
        XCTAssertEqual(TrackerAdvertisement.crc(plain, seed: 0xdeadbeef), checksum)
        plain[64] ^= 1
        XCTAssertNotEqual(TrackerAdvertisement.crc(plain, seed: 0xdeadbeef), checksum)
        XCTAssertEqual(TrackerAdvertisement.obfuscate(TrackerAdvertisement.obfuscate([1,2,3,4,5])), [1,2,3,4,5])
    }
    func testLimitsAndConfigurationMigration() throws {
        var record = sample
        record.name = String(repeating: "é", count: 32); record.description = String(repeating: "d", count: 255)
        record.groups = (0..<6).map { String(repeating: String($0), count: 255) }
        let wire = try record.encode(), plain = TrackerAdvertisement.obfuscate(wire)
        XCTAssertEqual(plain[53], 64); XCTAssertEqual(plain[54], 255)
        XCTAssertEqual(Array(plain[56..<62]), [UInt8](repeating: 255, count: 6)); XCTAssertEqual(wire.count % 4, 0)
        record.name += "a"; XCTAssertThrowsError(try record.encode())
        record = sample; record.name = ""; XCTAssertThrowsError(try record.encode())
        record = sample; record.port = 0; XCTAssertThrowsError(try record.encode())
        record = sample; record.groups = [String](repeating: "g", count: 7); XCTAssertThrowsError(try record.encode())
        record = sample; record.groups = [String(repeating: "é", count: 128)]; XCTAssertThrowsError(try record.encode())
        var configuration = ServerConfiguration()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        json.removeValue(forKey: "tracker")
        let migrated = try JSONDecoder().decode(ServerConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(migrated.tracker.enabled); XCTAssertEqual(migrated.tracker.port, 10800)
        configuration.tracker.enabled = true
        XCTAssertThrowsError(try configuration.validate())
        configuration.tracker.host = "tracker.example"; configuration.tracker.groups = ["Lab"]
        configuration.tracker.advertisedPort = 10701
        try configuration.validate()
        XCTAssertEqual(try JSONDecoder().decode(ServerConfiguration.self, from: JSONEncoder().encode(configuration)), configuration)
        configuration.name = String(repeating: "a", count: 65); XCTAssertThrowsError(try configuration.validate())
        configuration.tracker.enabled = false; try configuration.validate()
    }
    @MainActor func testRetryFreshMetadataAndStop() async throws {
        var settings = TrackerAdvertisementSettings(); settings.enabled = true; settings.host = " tracker.example "; settings.groups = ["Lab"]
        var attempts = 0, reports = [String](), dates = [Date?](), packets = [[UInt8]](), users: UInt16 = 1
        let sentTwice = expectation(description: "retry then metadata update")
        let advertiser = TrackerAdvertiser(interval: .milliseconds(10)) { host, port, bytes in
            XCTAssertEqual(host, "tracker.example"); XCTAssertEqual(port, 10800)
            attempts += 1
            if attempts == 1 { throw KDXError.disconnected }
            packets.append(bytes)
        }
        advertiser.start(settings: settings, snapshot: { TrackerAdvertisement(name: "Mac", description: "", port: 10701, userCount: users, groups: settings.groups) }, report: { status, date in
            reports.append(status); dates.append(date)
            if packets.count == 1 { users = 2 }
            if packets.count == 2 { advertiser.stop(); sentTwice.fulfill() }
        })
        defer { advertiser.stop() }
        await fulfillment(of: [sentTwice], timeout: 2)
        XCTAssertEqual(attempts, 3); XCTAssertEqual(packets.map { TrackerAdvertisement.obfuscate($0).u16(36) }, [1,2])
        XCTAssertTrue(reports[0].contains("failed")); XCTAssertNil(dates[0]); XCTAssertNotNil(dates[1]); XCTAssertTrue(reports[1].contains("unconfirmed"))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(attempts, 3)
    }
    @MainActor func testDisabledRestartAndStaleSendCompletion() async throws {
        var settings = TrackerAdvertisementSettings(); settings.host = "tracker.example"
        var oldSend: CheckedContinuation<Void, Never>?, reports = [String](), attempts = 0
        let started = expectation(description: "old send started"), replacement = expectation(description: "replacement sent")
        let advertiser = TrackerAdvertiser(interval: .seconds(60)) { _, _, _ in
            attempts += 1
            if attempts == 1 { await withCheckedContinuation { oldSend = $0; started.fulfill() } }
        }
        defer { oldSend?.resume(); advertiser.stop() }
        advertiser.start(settings: settings, snapshot: { self.sample }, report: { _, _ in XCTFail("Disabled advertising sent a packet") })
        await Task.yield(); XCTAssertEqual(attempts, 0)
        settings.enabled = true
        advertiser.start(settings: settings, snapshot: { self.sample }, report: { _, _ in reports.append("old") })
        await fulfillment(of: [started], timeout: 2)
        advertiser.start(settings: settings, snapshot: { self.sample }, report: { _, _ in reports.append("new"); replacement.fulfill() })
        await fulfillment(of: [replacement], timeout: 2)
        oldSend?.resume(); oldSend = nil
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(reports, ["new"]); XCTAssertEqual(attempts, 2)
    }
}
