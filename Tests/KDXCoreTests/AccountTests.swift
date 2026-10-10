import XCTest
@testable import KDXCore

final class AccountTests: XCTestCase {
    @MainActor private func connect(_ client: KDXClient, server: KDXServer, login: String, password: String, table: ChallengeTable) async throws {
        let (a, b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await client.connect(wire: a, login: login, password: password, nickname: login, table: table)
    }
    @MainActor func testAccountLifecyclePersistencePasswordAndLivePrivileges() async throws {
        let table = ChallengeTable(testBytes: [UInt8](repeating: 9, count: 1739))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("server.json")
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true)]
        try config.save(to: file)
        let server = KDXServer(configuration: config, configurationURL: file), admin = KDXClient(), member = KDXClient(), reconnect = KDXClient()
        defer { admin.disconnect(); member.disconnect(); reconnect.disconnect(); server.stop() }
        try await connect(admin, server: server, login: "admin", password: "pw", table: table)
        try await admin.loadAccountClasses(); XCTAssertEqual(admin.accountClasses.map(\.id), [0,1,2])
        let rawClass = try await admin.request(type: 502, payload: [1])
        XCTAssertEqual(try AccountClass.decode(rawClass.payload, info: true).0, AccountClass.defaults[1])
        var record = RemoteAccount(login: "member", name: "A Member")
        try await admin.createAccount(record, password: "original")
        try await admin.loadAccounts(); XCTAssertEqual(admin.accounts.map(\.login), ["admin", "member"])
        let fetched = try await admin.account(login: "member")
        XCTAssertEqual(fetched.key, [1] + [UInt8](repeating: 0, count: 31), "Account info must not reveal the password-equivalent key")
        XCTAssertEqual(fetched.editor, "admin"); XCTAssertEqual(fetched.created, fetched.modified)
        try await connect(member, server: server, login: "member", password: "original", table: table)
        try await member.changePassword(to: "new-password")
        XCTAssertEqual(try ServerConfiguration.load(from: file).accounts.last?.key, AccountKey(password: "new-password").bytes)
        let pong = try await member.request(type: 108)
        XCTAssertEqual(pong.type, 109, "Password change must not change the current session cipher")
        do { try await connect(reconnect, server: server, login: "member", password: "original", table: table); XCTFail("Old password accepted") } catch { }
        try await connect(reconnect, server: server, login: "member", password: "new-password", table: table)
        reconnect.disconnect()
        record = try await admin.account(login: "member")
        record.login = "renamed"; record.name = "New Name"
        record.privilegeMask.set(71, true); record.privileges.set(71, false)
        try await admin.updateAccount(record, originalLogin: "member")
        do { try await member.postNews(subject: "Denied", body: "No longer allowed"); XCTFail("Revoked privilege retained") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        let saved = try ServerConfiguration.load(from: file)
        XCTAssertEqual(saved.accounts.last?.login, "renamed")
        XCTAssertEqual(saved.accounts.last?.key, AccountKey(password: "new-password").bytes, "Unchanged-password field must preserve the actual key")
        try await connect(reconnect, server: server, login: "renamed", password: "new-password", table: table)
        // Delete sends a 515 notification, not a success reply; the client uses a barrier.
        try await admin.deleteAccount(login: "renamed")
        XCTAssertEqual(try ServerConfiguration.load(from: file).accounts.map(\.login), ["admin"])
        for _ in 0..<50 where member.isConnected || reconnect.isConnected { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(member.isConnected); XCTAssertFalse(reconnect.isConnected)
        do { try await admin.deleteAccount(login: "admin"); XCTFail("Protected administrator deleted") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
    }
    @MainActor func testPrivilegeEscalationAndReadDenial() async throws {
        let table = ChallengeTable(testBytes: [UInt8](repeating: 5, count: 1739))
        var creator = ServerAccount(login: "creator", password: "pw")
        creator.privilegeMask = .enabled([50,51,52]); creator.privileges = .enabled([50,51,52])
        var config = ServerConfiguration(); config.accounts = [creator, ServerAccount(login: "member", password: "pw")]
        let server = KDXServer(configuration: config), client = KDXClient(), member = KDXClient()
        defer { client.disconnect(); member.disconnect(); server.stop() }
        try await connect(client, server: server, login: "creator", password: "pw", table: table)
        try await connect(member, server: server, login: "member", password: "pw", table: table)
        do { try await member.loadAccounts(); XCTFail("Member listed accounts") } catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        do { try await client.createAccount(RemoteAccount(login: "escalated", classID: 0), password: "pw"); XCTFail("Created administrator without privilege") } catch KDXError.remote(let code) { XCTAssertEqual(code, 0x640005) }
        try await client.createAccount(RemoteAccount(login: "allowed", classID: 1), password: "pw")
        var elevated = try await client.account(login: "allowed")
        elevated.privileges.set(0, true); elevated.privilegeMask.set(0, true)
        do { try await client.updateAccount(elevated, originalLogin: "allowed"); XCTFail("Escalated with account override") } catch KDXError.remote(let code) { XCTAssertEqual(code, 0x640005) }
        let unchanged = try await client.account(login: "allowed"); XCTAssertFalse(unchanged.privileges.contains(0))
        var denied = try await client.account(login: "member")
        denied.privilegeMask.set(30, true); denied.privileges.set(30, false)
        try await client.updateAccount(denied, originalLogin: "member")
        member.disconnect()
        try await connect(member, server: server, login: "member", password: "pw", table: table)
        XCTAssertTrue(member.isConnected, "An account denied chat must still be able to log in")
        XCTAssertNil(member.joinedRoom)
        try await member.loadNews()
    }
    @MainActor func testFailedPersistenceDoesNotApplyAccountMutation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("server.json")
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true)]
        let table = ChallengeTable(testBytes: [UInt8](repeating: 1, count: 1739))
        let server = KDXServer(configuration: config, configurationURL: file), client = KDXClient()
        defer { client.disconnect(); server.stop() }
        try await connect(client, server: server, login: "admin", password: "pw", table: table)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do { try await client.createAccount(RemoteAccount(login: "unsaved"), password: "pw"); XCTFail("Mutation acknowledged without saving") } catch { }
        try await client.loadAccounts(); XCTAssertEqual(client.accounts.map(\.login), ["admin"])
    }
    @MainActor func testDeletingOwnAccountHonorsConfirmationBeforeDisconnect() async throws {
        var account = ServerAccount(login: "self-delete", password: "pw")
        account.privilegeMask.set(52, true); account.privileges.set(52, true)
        var config = ServerConfiguration(); config.accounts = [account]
        let table = ChallengeTable(testBytes: [UInt8](repeating: 2, count: 1739))
        let server = KDXServer(configuration: config), client = KDXClient()
        defer { client.disconnect(); server.stop() }
        try await connect(client, server: server, login: account.login, password: "pw", table: table)
        try await client.deleteAccount(login: account.login)
        XCTAssertTrue(server.configuration.accounts.isEmpty)
    }
    func testConfigurationMigrationAndMalformedPrivilegeVectors() throws {
        let key = AccountKey(password: "pw").bytes
        let json: [String: Any] = ["name":"Legacy settings", "description":"", "port":10700, "allowGuests":true,
            "accounts":[["login":"admin", "isAdmin":true, "key":key]], "sharedFolder":"", "newsFile":""]
        let config = try JSONDecoder().decode(ServerConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(config.accounts[0].effective(in: config.accountClasses).contains(0))
        XCTAssertTrue(config.accounts[0].privilegeMask.contains(0))
        XCTAssertEqual(config.accounts[0].key, key)
        XCTAssertThrowsError(try JSONDecoder().decode(AccountPrivileges.self, from: Data("[255]".utf8)))
        XCTAssertThrowsError(try RemoteAccount.decode([0]))
        XCTAssertThrowsError(try AccountListEntry.decodeList([255,255,255,255]))
    }
    func testCapturedAccountPayloads() throws {
        for port in ["58284", "58290", "47988", "50184"] {
            let records = try capturedMessages("kdx-accounts-\(port)").filter { [507,510,511].contains($0.type) }
            let expectedType: UInt32 = port == "58284" ? 507 : (port == "47988" ? 511 : 510)
            XCTAssertEqual(records.filter { $0.type == expectedType }.count, 1, "Missing expected account record in \(port)")
            for message in records {
                let account = try RemoteAccount.decode(message.payload)
                var canonical = message.payload
                let end = 128 + [account.login, account.name, account.third, account.editor].reduce(0) { $0+$1.utf8.count }
                for i in end..<canonical.count { canonical[i] = 0 }
                XCTAssertEqual(try account.encode(), canonical)
                if message.type == 507 { XCTAssertEqual(account.login, "rs-test"); XCTAssertEqual(account.key, AccountKey(password: "rs-test-pw").bytes) }
                if message.type == 511 { XCTAssertEqual(account.editor, "rs-test"); XCTAssertEqual(account.login, "rs-test2"); XCTAssertEqual(account.key, [UInt8](repeating: 0, count: 32)) }
                if message.type == 510 { XCTAssertEqual(Array(account.key.dropFirst()), [UInt8](repeating: 0, count: 31)) }
            }
        }
        let passwordChange = try capturedMessages("kdx-accounts-58336", password: "rs-test-pw")
        XCTAssertEqual(passwordChange.first { $0.type == 550 }?.payload, AccountKey(password: "rs-test-pw2").bytes)
        XCTAssertTrue(try XCTUnwrap(passwordChange.first { $0.type == 551 }).isReply)
        let deletion = try capturedMessages("kdx-accounts-50188")
        XCTAssertEqual(deletion.first { $0.type == 515 }?.payload, Array("rs-test2".utf8))
        XCTAssertFalse(try XCTUnwrap(deletion.first { $0.type == 515 }).isReply)
    }
    func testCapturedClassesAndAccountLists() throws {
        var seen: Set<UInt32> = []
        for name in ["probe-50770", "probe-59006"] {
            for message in try capturedMessages(name) {
                switch message.type {
                case 506:
                    let classes = try AccountClass.decodeList(message.payload)
                    XCTAssertEqual(classes.count, 12)
                    XCTAssertEqual(Array(classes.prefix(3)).map(\.name), ["Administrator", "User", "Guest"])
                    XCTAssertEqual(try AccountClass.encodeList(classes), message.payload)
                    seen.insert(506)
                case 503:
                    let entry = try AccountClass.decode(message.payload, info: true).0
                    var canonical = message.payload
                    for at in (56 + entry.name.utf8.count)..<canonical.count { canonical[at] = 0 }
                    XCTAssertEqual(try entry.encode(info: true), canonical)
                    seen.insert(503)
                case 513:
                    let accounts = try AccountListEntry.decodeList(message.payload)
                    XCTAssertEqual(accounts.map(\.login), ["admin", "guest"])
                    XCTAssertEqual(try AccountListEntry.encodeList(accounts), message.payload)
                    seen.insert(513)
                default: break
                }
            }
        }
        XCTAssertEqual(seen, [503,506,513])
    }

}
