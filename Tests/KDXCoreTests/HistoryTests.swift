import XCTest
@testable import KDXCore

final class HistoryTests: XCTestCase {
    func testCapturedSnapshotsAndLiveUpdates() throws {
        for (name, count) in [("linux-chat-admin-37484", 18), ("linux-server-settings-45150", 5)] {
            let messages = try capturedMessages(name)
            let snapshot = try XCTUnwrap(messages.first { $0.type == 181 })
            let entries = try RemoteHistoryEntry.decodeList(snapshot.payload)
            XCTAssertEqual(entries.count, count)
            XCTAssertEqual(entries.first?.kind, 190)
            XCTAssertEqual(entries.last?.kind, 180)
            XCTAssertEqual(entries.last?.login, "admin")
            XCTAssertEqual(entries.last?.nickname, "kdx-lab-linux")
            XCTAssertEqual(try RemoteHistoryEntry.encodeList(entries), snapshot.payload)
            XCTAssertTrue(entries.allSatisfy { $0.date.timeIntervalSince1970 > 1_700_000_000 })
            if count == 18 {
                XCTAssertTrue(entries.contains { $0.kind == 200 && $0.detail == "Private 1" })
                XCTAssertTrue(entries.contains { $0.kind == 185 && $0.userID == 3 })
            } else {
                let updates = try messages.filter { $0.type == 183 }.map { message in
                    let (entry, used) = try RemoteHistoryEntry.decode(message.payload)
                    XCTAssertEqual(used, message.payload.count)
                    XCTAssertEqual(try entry.encode(), message.payload)
                    XCTAssertEqual(entry.userID, 2)
                    XCTAssertEqual(entry.address, "127.0.0.1:45150")
                    XCTAssertEqual(entry.login, "admin")
                    return entry
                }
                XCTAssertEqual(updates.map(\.kind), [170,172,170,172])
            }
        }
    }
    func testMalformedHistoryAndOpaqueHeader() throws {
        let snapshot = try XCTUnwrap(capturedMessages("linux-server-settings-45150").first { $0.type == 181 })
        XCTAssertThrowsError(try RemoteHistoryEntry.decodeList(Array(snapshot.payload.dropLast())))
        var invalid = snapshot.payload; invalid.put(UInt32.max, at: 4)
        XCTAssertThrowsError(try RemoteHistoryEntry.decodeList(invalid))
        invalid = snapshot.payload + [0]
        XCTAssertThrowsError(try RemoteHistoryEntry.decodeList(invalid))
        invalid = snapshot.payload; invalid[8+74] = 1
        XCTAssertThrowsError(try RemoteHistoryEntry.decodeList(invalid))
        var opaque = snapshot.payload; opaque[8+16] = 123
        XCTAssertEqual(try RemoteHistoryEntry.encodeList(RemoteHistoryEntry.decodeList(opaque)), opaque)
    }
    @MainActor private func connect(_ client: KDXClient, server: KDXServer, login: String, password: String = "pw", table: ChallengeTable) async throws {
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await client.connect(wire: a, login: login, password: password, nickname: login, table: table)
    }
    @MainActor private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    @MainActor func testLiveHistoryPermissionsPrivacyAndRejoin() async throws {
        var config = ServerConfiguration()
        config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true), ServerAccount(login: "member", password: "pw")]
        let table = ChallengeTable(testBytes: [UInt8](repeating: 7, count: 1739))
        let server = KDXServer(configuration: config), admin = KDXClient(), member = KDXClient(), bad = KDXClient()
        defer { admin.disconnect(); member.disconnect(); bad.disconnect(); server.stop() }
        try await connect(admin, server: server, login: "admin", table: table)
        try await admin.startHistory()
        XCTAssertEqual(admin.history.first?.kind, 190); XCTAssertEqual(admin.history.last?.kind, 180)
        XCTAssertEqual(admin.history.filter { $0.kind == 180 }.count, 1)
        try await connect(member, server: server, login: "member", table: table)
        try await eventually { admin.history.contains { $0.kind == 184 && $0.login == "member" } }
        do { try await member.startHistory(); XCTFail("Member read history") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        XCTAssertFalse(member.isViewingHistory); XCTAssertTrue(member.history.isEmpty)
        try await member.sendChat("private-chat-body-secret")
        try await member.changePassword(to: "password-secret")
        try await admin.sendBroadcast("broadcast-body-secret")
        _ = try await admin.request(type: 108)
        XCTAssertTrue(admin.history.contains { $0.kind == 550 && $0.login == "member" })
        XCTAssertTrue(admin.history.contains { $0.kind == 154 && $0.login == "admin" })
        XCTAssertTrue(admin.history.contains { $0.kind == 180 && $0.detail.contains("10014") })
        XCTAssertFalse(admin.history.contains { [$0.detail,$0.login,$0.nickname].joined().contains("secret") })
        do { try await connect(bad, server: server, login: "missing", password: "login-secret", table: table); XCTFail("Unknown login accepted") } catch { }
        try await eventually { admin.history.contains { $0.kind == 191 && $0.login == "missing" } }
        member.disconnect()
        try await eventually { admin.history.contains { $0.kind == 185 && $0.login == "member" } }
        try await admin.stopHistory()
        let stoppedCount = admin.history.count
        _ = try await admin.serverSettings(); _ = try await admin.request(type: 108)
        XCTAssertEqual(admin.history.count, stoppedCount)
        try await admin.startHistory()
        XCTAssertTrue(admin.history.contains { $0.kind == 182 })
        XCTAssertEqual(admin.history.filter { $0.kind == 170 }.count, 1)
        XCTAssertEqual(admin.history.filter { $0.kind == 180 && $0.login == "admin" }.count, 2)
    }
    @MainActor func testLiveRevocationAndRetention() async throws {
        var monitor = ServerAccount(login: "monitor", password: "pw")
        monitor.privilegeMask.set(63, true); monitor.privileges.set(63, true)
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true), monitor]
        let table = ChallengeTable(testBytes: [UInt8](repeating: 3, count: 1739))
        let server = KDXServer(configuration: config), admin = KDXClient(), viewer = KDXClient()
        defer { admin.disconnect(); viewer.disconnect(); server.stop() }
        try await connect(admin, server: server, login: "admin", table: table)
        try await connect(viewer, server: server, login: "monitor", table: table)
        try await viewer.startHistory()
        _ = try await admin.serverSettings()
        try await eventually { viewer.history.contains { $0.kind == 170 } }
        var edited = try await admin.account(login: "monitor")
        _ = try await admin.request(type: 108); _ = try await viewer.request(type: 108)
        let before = viewer.history.count
        edited.privileges.set(63, false)
        try await admin.updateAccount(edited, originalLogin: "monitor")
        _ = try await admin.serverSettings(); _ = try await admin.request(type: 108); _ = try await viewer.request(type: 108)
        XCTAssertEqual(viewer.history.count, before, "Revoked viewers must receive no further events")
        try await viewer.stopHistory()
        do { try await viewer.startHistory(); XCTFail("Revoked viewer rejoined") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        try await admin.startHistory()
        for _ in 0..<505 { _ = try await admin.serverSettings() }
        _ = try await admin.request(type: 108)
        XCTAssertEqual(admin.history.count, 500)
        XCTAssertTrue(admin.history.allSatisfy { $0.kind == 170 })
        try await admin.stopHistory(); try await admin.startHistory()
        XCTAssertEqual(admin.history.count, 500)
        XCTAssertEqual(Array(admin.history.suffix(2)).map(\.kind), [182,180])
    }
    @MainActor func testTransferEventsAttributeParentAndReportFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shared = folder.appendingPathComponent("shared"), local = folder.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = shared.appendingPathComponent("source.bin"), upload = local.appendingPathComponent("upload.bin")
        try Data(repeating: 123, count: 512).write(to: source)
        try Data(repeating: 45, count: 1024).write(to: upload)
        var config = ServerConfiguration(); config.sharedFolder = shared.path
        config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true)]
        let table = ChallengeTable(testBytes: [UInt8](repeating: 6, count: 1739))
        let server = KDXServer(configuration: config), client = KDXClient()
        defer { client.disconnect(); server.stop() }
        try await connect(client, server: server, login: "admin", table: table)
        client.setTransferFactory { let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table); return a }
        try await client.startHistory(); try await client.listFiles()
        let file = try XCTUnwrap(client.files.first)
        try await client.download(file, to: local.appendingPathComponent("download.bin"))
        try await client.upload(from: upload)
        try FileManager.default.removeItem(at: source)
        do { try await client.download(file, to: local.appendingPathComponent("missing.bin")); XCTFail("Missing file downloaded") } catch { }
        try await eventually { client.history.contains { $0.kind == 186 } }
        let events = client.history.filter { [UInt32(186),187,188,189].contains($0.kind) }
        XCTAssertEqual(events.map(\.kind), [188,189,186])
        XCTAssertEqual(events.map(\.userID), [UInt32](repeating: try XCTUnwrap(client.serverInfo?.userID), count: 3))
        XCTAssertTrue(events.allSatisfy { $0.login == "admin" })
        XCTAssertEqual(events[0].detail, "source.bin"); XCTAssertEqual(events[1].detail, "upload.bin")
        XCTAssertTrue(events[2].detail.contains("Error 0x")); XCTAssertTrue(events[2].detail.contains("source.bin"))
    }
    @MainActor func testClosingPendingHistoryAndReopening() async throws {
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true)]
        let table = ChallengeTable(testBytes: [UInt8](repeating: 8, count: 1739))
        let server = KDXServer(configuration: config), client = KDXClient()
        defer { client.disconnect(); server.stop() }
        try await connect(client, server: server, login: "admin", table: table)
        let old = Task { try await client.startHistory() }
        // startHistory sets the flag before sending its asynchronous request.
        while !client.isViewingHistory { await Task.yield() }
        let closing = Task { try await client.stopHistory() }
        while client.isViewingHistory { await Task.yield() }
        old.cancel()
        try await closing.value
        try await client.startHistory()
        _ = try? await old.value
        _ = try await client.serverSettings(); _ = try await client.request(type: 108)
        XCTAssertTrue(client.isViewingHistory)
        XCTAssertEqual(client.history.last?.kind, 170)
        XCTAssertEqual(client.history.filter { $0.kind == 170 }.count, 1)
    }

}
