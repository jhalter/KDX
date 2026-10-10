import XCTest
@testable import KDXCore

final class AccountClassTests: XCTestCase {
    func testCapturedClassEdits() throws {
        let messages = try capturedMessages("linux-accounts-news-51382")
        let edits = messages.filter { $0.type == 504 }
        XCTAssertEqual(edits.count, 2)
        for (index, edit) in edits.enumerated() {
            let entry = try AccountClass.decode(edit.payload, info: true).0
            XCTAssertEqual(entry.id, 2); XCTAssertEqual(entry.name, "Guest")
            XCTAssertEqual(entry.privileges.contains(11), index == 1)
            XCTAssertEqual(edit.payload.count, 61)
            XCTAssertEqual(try entry.encode(info: true, padded: false), edit.payload)
            XCTAssertTrue(messages.contains { $0.type == 1 && $0.transaction == edit.transaction && $0.payload == UInt32(0).beBytes + UInt32(504).beBytes })
        }
    }
    @MainActor private func connect(_ client: KDXClient, server: KDXServer, login: String, table: ChallengeTable) async throws {
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await client.connect(wire: a, login: login, password: login.isEmpty ? "" : "pw", nickname: "Custom \(login)", table: table)
    }
    @MainActor func testPersistenceAndLiveMemberGuestOverrides() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("server.json")
        var config = ServerConfiguration()
        var special = ServerAccount(login: "special", password: "pw")
        special.privilegeMask = .enabled([30,60,71]); special.privileges = .enabled([30,60,71])
        config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true), ServerAccount(login: "member", password: "pw"), special]
        let server = KDXServer(configuration: config, configurationURL: file)
        let admin = KDXClient(), member = KDXClient(), overridden = KDXClient(), guest = KDXClient()
        let table = ChallengeTable(testBytes: [UInt8](repeating: 4, count: 1739))
        defer { admin.disconnect(); member.disconnect(); overridden.disconnect(); guest.disconnect(); server.stop() }
        for (client, login) in [(admin,"admin"), (member,"member"), (overridden,"special"), (guest,"")] {
            try await connect(client, server: server, login: login, table: table)
        }
        var entry = try await admin.accountClass(id: 1)
        entry.name = "Readers"
        for bit in [30,60,71] { entry.privileges.set(bit, false) }
        try await admin.updateAccountClass(entry)
        _ = try await member.request(type: 108)
        XCTAssertNil(member.joinedRoom); XCTAssertEqual(member.currentUser?.nickname, "member")
        XCTAssertEqual(overridden.joinedRoom, 1); XCTAssertEqual(overridden.currentUser?.nickname, "Custom special")
        do { try await member.postNews(subject: "Denied", body: "Class revoked"); XCTFail("Stale inherited permission") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        try await overridden.postNews(subject: "Allowed", body: "Explicit override")
        var guestClass = try await admin.accountClass(id: 2)
        guestClass.privileges.set(30, false); guestClass.privileges.set(60, false); guestClass.privileges.set(70, false)
        try await admin.updateAccountClass(guestClass)
        _ = try await guest.request(type: 108)
        XCTAssertNil(guest.joinedRoom); XCTAssertEqual(guest.currentUser?.nickname, "Guest")
        do { try await guest.loadNewsGroups(); XCTFail("Guest retained read privilege") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        let saved = try ServerConfiguration.load(from: file)
        XCTAssertEqual(saved.accountClasses.first { $0.id == 1 }?.name, "Readers")
        XCTAssertFalse(saved.accountClasses.first { $0.id == 1 }!.privileges.contains(71))
        let restarted = KDXServer(configuration: saved), reconnect = KDXClient()
        defer { reconnect.disconnect(); restarted.stop() }
        try await connect(reconnect, server: restarted, login: "member", table: table)
        XCTAssertNil(reconnect.joinedRoom)
        do { try await reconnect.postNews(subject: "Denied", body: "Still revoked"); XCTFail("Lost persisted restriction") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
    }
    @MainActor func testAuthorizationEscalationAndFailedSave() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("server.json")
        var editor = ServerAccount(login: "editor", password: "pw")
        editor.privilegeMask = .enabled([50,52]); editor.privileges = .enabled([50,52])
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true), editor]
        let server = KDXServer(configuration: config, configurationURL: file), admin = KDXClient(), client = KDXClient(), guest = KDXClient()
        defer { admin.disconnect(); client.disconnect(); guest.disconnect(); server.stop() }
        let table = ChallengeTable(testBytes: [UInt8](repeating: 4, count: 1739))
        for (client,login) in [(admin,"admin"), (client,"editor"), (guest,"")] { try await connect(client, server: server, login: login, table: table) }
        var entry = try await admin.accountClass(id: 2)
        do { try await guest.updateAccountClass(entry); XCTFail("Guest changed class") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        entry.privileges.set(0, true)
        do { try await client.updateAccountClass(entry); XCTFail("Editor granted administrator rights") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x640005) }
        entry.privileges.set(0, false); entry.name = "Visitors"
        try await client.updateAccountClass(entry)
        let fetched = try await admin.accountClass(id: 2); XCTAssertEqual(fetched.name, "Visitors")
        entry.id = 31
        do { try await admin.updateAccountClass(entry); XCTFail("Unknown class created") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10002) }
        entry.id = 2; entry.name = "Unsaved"; entry.privileges.set(30, false)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do { try await admin.updateAccountClass(entry); XCTFail("Unsaved class acknowledged") } catch { }
        let unchanged = try await admin.accountClass(id: 2)
        XCTAssertEqual(unchanged.name, "Visitors"); XCTAssertTrue(unchanged.privileges.contains(30)); XCTAssertEqual(guest.joinedRoom, 1)
    }
}
