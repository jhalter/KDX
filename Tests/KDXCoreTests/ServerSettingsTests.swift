import XCTest
@testable import KDXCore

final class ServerSettingsTests: XCTestCase {
    func testCapturedSettingsAndSectionRelocation() throws {
        let messages = try capturedMessages("linux-server-settings-45150")
        let records = messages.filter { $0.type == 171 || $0.type == 172 }
        XCTAssertEqual(records.count, 4)
        for message in records {
            let settings = try RemoteServerSettings(wire: message.payload)
            XCTAssertEqual(try settings.encode(), message.payload)
            XCTAssertEqual(settings.name, message.payload.count == 216 ? "New Server" : "Lab Server")
            XCTAssertEqual(settings.downloadLimit, message.payload.count == 216 ? 0 : 20480)
        }
        let captured = try XCTUnwrap(records.first { $0.payload.count == 764 })
        var edited = try RemoteServerSettings(wire: captured.payload)
        let icon = edited.icon
        edited.name = "A much longer server name"; edited.greeting = "Different greeting\nこんにちは"; edited.greetingEnabled = true; edited.downloadLimit = 0
        let decoded = try RemoteServerSettings(wire: edited.encode())
        XCTAssertEqual(decoded.name, edited.name); XCTAssertEqual(decoded.greeting, edited.greeting)
        XCTAssertEqual(decoded.icon, icon); XCTAssertTrue(decoded.greetingEnabled); XCTAssertEqual(decoded.downloadLimit, 0)
        var extended = captured.payload
        extended.put(UInt32(extended.count), at: 20); extended.put(UInt32(3), at: 24); extended += [0xaa,0xbb,0xcc]
        extended.put(UInt32(0x01020304), at: Int(extended.u32(36)))
        var opaque = try RemoteServerSettings(wire: extended); opaque.name = "Relocated"
        let relocated = try opaque.encode(), unknownAt = Int(relocated.u32(20)), greetingAt = Int(relocated.u32(36))
        XCTAssertEqual(Array(relocated[unknownAt..<unknownAt+3]), [0xaa,0xbb,0xcc])
        XCTAssertEqual(relocated.u32(greetingAt), 0x01020304)
        var invalid = captured.payload; invalid.put(UInt32(1), at: 12)
        XCTAssertThrowsError(try RemoteServerSettings(wire: invalid))
        invalid = captured.payload; invalid.put(UInt32.max, at: 40)
        XCTAssertThrowsError(try RemoteServerSettings(wire: invalid))
        XCTAssertTrue(messages.filter { $0.type == 173 }.allSatisfy { $0.payload.isEmpty })
    }
    @MainActor private func connect(_ client: KDXClient, server: KDXServer, login: String, table: ChallengeTable) async throws {
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await client.connect(wire: a, login: login, password: login.isEmpty ? "" : "pw", nickname: login.isEmpty ? "Guest" : login, table: table)
    }
    @MainActor func testPersistenceGreetingPermissionsAndIconRetention() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("server.json")
        var hidden = ServerAccount(login: "hidden", password: "pw")
        hidden.privilegeMask.set(62, true); hidden.privileges.set(62, true)
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true), hidden]
        let table = ChallengeTable(testBytes: [UInt8](repeating: 8, count: 1739))
        let server = KDXServer(configuration: config, configurationURL: file), admin = KDXClient(), guest = KDXClient()
        defer { admin.disconnect(); guest.disconnect(); server.stop() }
        try await connect(admin, server: server, login: "admin", table: table)
        try await connect(guest, server: server, login: "", table: table)
        try await guest.loadGreeting(); XCTAssertEqual(guest.greeting, "(No greeting.)")
        do { _ = try await guest.serverSettings(); XCTFail("Guest read settings") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        var settings = try await admin.serverSettings()
        settings.name = "New Name"; settings.greeting = "Welcome!"; settings.icon = [1,2,3,4]
        do { try await guest.updateServerSettings(settings); XCTFail("Guest edited settings") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        try await admin.updateServerSettings(settings)
        try await guest.loadGreeting(); XCTAssertEqual(guest.greeting, "(Greeting disabled.)")
        XCTAssertEqual(guest.serverInfo?.name, "New Name")
        settings.greetingEnabled = true; settings.icon = []
        try await admin.updateServerSettings(settings)
        let reread = try await admin.serverSettings(); XCTAssertEqual(reread.icon, [1,2,3,4])
        let saved = try ServerConfiguration.load(from: file)
        XCTAssertEqual(saved.name, "New Name"); XCTAssertTrue(saved.greetingEnabled)
        let restart = KDXServer(configuration: saved), next = KDXClient()
        defer { next.disconnect(); restart.stop() }
        try await connect(next, server: restart, login: "", table: table)
        XCTAssertEqual(next.greeting, "Welcome!"); XCTAssertEqual(next.serverIcon, [1,2,3,4])
        next.disconnect()
        try await connect(next, server: restart, login: "hidden", table: table)
        XCTAssertNil(next.greeting, "Privilege 62 suppresses automatic greeting delivery")
        try await next.loadGreeting(); XCTAssertEqual(next.greeting, "Welcome!")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        settings.name = "Unsaved"
        do { try await admin.updateServerSettings(settings); XCTFail("Unsaved mutation acknowledged") } catch { }
        XCTAssertEqual(server.configuration.name, "New Name")
    }
    @MainActor func testSharedLimiterAndProgressBasedReadTimeout() async throws {
        let limiter = DownloadLimiter(); limiter.setRate(40960)
        let start = ContinuousClock.now
        let first = Task { for _ in 0..<10 { try await limiter.acquire(4096) } }
        let second = Task { for _ in 0..<10 { try await limiter.acquire(4096) } }
        try await first.value; try await second.value
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(1700), "Both senders must share one budget")
        limiter.setRate(1)
        let cancelled = Task { try await limiter.acquire(1024) }
        await Task.yield(); cancelled.cancel()
        do { try await cancelled.value; XCTFail("Limiter ignored cancellation") } catch { }
        var closed = false
        let waiting = Task { try await limiter.acquire(1024, isClosed: { closed }) }
        await Task.yield(); closed = true
        do { try await waiting.value; XCTFail("Closed connection kept waiting for bandwidth") } catch { }
        limiter.setRate(0); try await limiter.acquire(65536)
        let (input, output) = MemoryTransport.endpoints()
        let wire = WireConnection(transport: input); wire.ioTimeout = .milliseconds(300)
        defer { wire.close() }
        let sender = Task {
            for _ in 0..<4 { try await Task.sleep(for: .milliseconds(100)); try await output.write([1,2,3]) }
        }
        let bytes = try await wire.read(12)
        try await sender.value
        XCTAssertEqual(bytes, [1,2,3,1,2,3,1,2,3,1,2,3])
    }
    @MainActor func testLimitedDownloadAndNotification() async throws {
        let shared = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shared); try? FileManager.default.removeItem(at: local) }
        let bytes = Data(repeating: 123, count: 32768)
        try bytes.write(to: shared.appendingPathComponent("limited.bin"))
        var config = ServerConfiguration(); config.sharedFolder = shared.path; config.downloadLimit = 16384
        let server = KDXServer(configuration: config), client = KDXClient()
        defer { client.disconnect(); server.stop() }
        let table = ChallengeTable(testBytes: [UInt8](repeating: 4, count: 1739))
        try await connect(client, server: server, login: "", table: table)
        client.setTransferFactory { let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table); return a }
        try await client.listFiles()
        let file = try XCTUnwrap(client.files.first), destination = local.appendingPathComponent("download.bin")
        let start = ContinuousClock.now
        try await client.download(file, to: destination)
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(1700))
        XCTAssertEqual(client.serverDownloadLimit, 16384)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }
}
