import XCTest
@testable import KDXCore

final class UserTests: XCTestCase {
    func testCapturedIdentityUserListAndDetailedInfo() throws {
        let first = try capturedMessages("first-connect")
        let identityBytes = try XCTUnwrap(first.first { $0.type == 100 }?.payload)
        let (identity, count) = try KDXUser.decode(identityBytes)
        XCTAssertEqual(identity.nickname, "kdx@gitbran.ch"); XCTAssertEqual(count, identityBytes.count)
        XCTAssertEqual(identity.voicePort, 10600); XCTAssertFalse(identity.icon.isEmpty)
        XCTAssertEqual(try identity.encode(), identityBytes)
        let listBytes = try XCTUnwrap(first.first { $0.type == 101 }?.payload)
        XCTAssertEqual(try KDXUser.encodeList(KDXUser.list(listBytes)), listBytes)
        let probe = try capturedMessages("probe-50984")
        let infoBytes = try XCTUnwrap(probe.first { $0.type == 153 }?.payload)
        let info = try UserInformation.decode(infoBytes)
        XCTAssertEqual(info.address, "127.0.0.1:50984"); XCTAssertEqual(info.nickname, "probe"); XCTAssertEqual(info.login, "admin")
        XCTAssertEqual(info.name3f, "Administrator"); XCTAssertEqual(try info.encode(), infoBytes)
    }
    @MainActor func testIdentityAndStatusBroadcastToSelfAndOtherUsers() async throws {
        let table = ChallengeTable(testBytes: [UInt8](repeating: 24, count: 1739))
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true), ServerAccount(login: "member", password: "pw")]
        let server = KDXServer(configuration: config), admin = KDXClient(), member = KDXClient()
        defer { admin.disconnect(); member.disconnect(); server.stop() }
        _ = try await connect(admin, server: server, login: "admin", table: table)
        let wire = try await connect(member, server: server, login: "member", table: table)
        let memberID = try XCTUnwrap(member.serverInfo?.userID)
        try await member.updateProfile(nickname: "New Name", info: "About\r\n\tme")
        XCTAssertEqual(member.currentUser?.nickname, "New Name"); XCTAssertEqual(member.currentUser?.info, "Aboutme")
        try await eventually { admin.users.first { $0.id == memberID }?.nickname == "New Name" }
        try await member.setStatus(1)
        XCTAssertEqual(member.currentUser?.status, 1)
        try await eventually { admin.users.first { $0.id == memberID }?.status == 1 }
        try await member.setStatus(0)
        XCTAssertEqual(member.currentUser?.status, 0)
        try await eventually { admin.users.first { $0.id == memberID }?.status == 0 }
        var forged = KDXUser(id: 99999, nickname: "Still a member", isAdmin: true)
        forged.flags = 255; forged.server15 = 255; forged.server16 = 255; forged.extra = [1,2,3]
        forged.colors = [1,2,3,4,5,6]; forged.icon = [1,2,3]
        try await wire.send(type: 100, payload: forged.encode())
        _ = try await member.request(type: 108)
        try await eventually { member.currentUser?.nickname == "Still a member" }
        XCTAssertEqual(member.currentUser?.id, memberID); XCTAssertEqual(member.currentUser?.isAdmin, false)
        XCTAssertEqual(member.currentUser?.server15, 0); XCTAssertEqual(member.currentUser?.server16, 0)
        XCTAssertEqual(member.currentUser?.flags, 4); XCTAssertEqual(member.currentUser?.extra, [])
        XCTAssertEqual(member.currentUser?.colors, forged.colors); XCTAssertEqual(member.currentUser?.icon, forged.icon)
        let details = try await admin.userInformation(id: memberID)
        XCTAssertEqual(details.login, "member"); XCTAssertEqual(details.nickname, "Still a member")
        XCTAssertLessThan(abs(try XCTUnwrap(details.connectedAt).timeIntervalSinceNow), 10)
        XCTAssertEqual(server.users.count, 2)
    }
    @MainActor func testNicknameRestrictionAndUserInfoPermissions() async throws {
        let table = ChallengeTable(testBytes: [UInt8](repeating: 25, count: 1739))
        var restricted = ServerAccount(login: "member", password: "pw"); restricted.name = "Account Name"
        restricted.privilegeMask.set(60, true); restricted.privileges.set(60, false)
        var config = ServerConfiguration(); config.accounts = [restricted]
        let server = KDXServer(configuration: config), member = KDXClient(), guest = KDXClient()
        defer { member.disconnect(); guest.disconnect(); server.stop() }
        _ = try await connect(member, server: server, login: "member", table: table)
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await guest.connect(wire: a, login: "", password: "", nickname: "Guest", table: table)
        try await member.updateProfile(nickname: "Forbidden name", info: "My profile")
        XCTAssertEqual(member.currentUser?.nickname, "Account Name"); XCTAssertEqual(member.currentUser?.info, "My profile")
        do { _ = try await guest.userInformation(id: XCTUnwrap(member.serverInfo?.userID)); XCTFail("Guest read privileged info") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        do { _ = try await member.userInformation(id: UInt32.max); XCTFail("Unknown user exists") }
        catch KDXError.remote(let code) { XCTAssertEqual(code, 0x1000c) }
        XCTAssertThrowsError(try KDXUser(nickname: "Test", info: String(repeating: "x", count: 128)).encode())
        var invalid = KDXUser(nickname: "Test"); invalid.icon = [UInt8](repeating: 0, count: 0x709)
        XCTAssertThrowsError(try invalid.encode())
        XCTAssertEqual(member.currentUser?.nickname, "Account Name")
    }
    @MainActor func testProfileAppearanceBroadcastAndCompatibleTextUpdate() async throws {
        let table = ChallengeTable(testBytes:[UInt8](repeating:26,count:1739))
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login:"member",password:"pw")]
        let server = KDXServer(configuration:config), member = KDXClient(), observer = KDXClient()
        defer { member.disconnect(); observer.disconnect(); server.stop() }
        _ = try await connect(member,server:server,login:"member",table:table)
        _ = try await connect(observer,server:server,login:"member",table:table)
        let id = try XCTUnwrap(member.currentUser?.id), colors: [UInt8] = [12,34,56,78,90,123]
        let icon: [UInt8] = [1,0,255,127,0]+[UInt8](repeating:0,count:512)
        try await member.updateProfile(nickname:"With appearance",info:"About",colors:colors,icon:icon,gradient:true)
        _ = try await observer.request(type:115)
        let remote = try XCTUnwrap(observer.users.first { $0.id == id })
        XCTAssertEqual(remote.colors,colors); XCTAssertEqual(remote.icon,icon); XCTAssertEqual(remote.flags,4)
        XCTAssertFalse(remote.isAdmin); XCTAssertEqual(remote.server15,0); XCTAssertEqual(remote.server16,0)
        try await member.updateProfile(nickname:"Text only",info:"New description")
        XCTAssertEqual(member.currentUser?.colors,colors); XCTAssertEqual(member.currentUser?.icon,icon); XCTAssertEqual(member.currentUser?.flags,4)
        for (badColors,badIcon) in [(Array(colors.dropLast()),icon),(colors,[UInt8](repeating:0,count:0x709))] {
            do {
                try await member.updateProfile(nickname:"Invalid",info:"",colors:badColors,icon:badIcon,gradient:false)
                XCTFail("Invalid appearance must fail before transmission")
            } catch {}
            XCTAssertEqual(member.currentUser?.nickname,"Text only")
            XCTAssertTrue(member.isConnected)
        }
        try await member.updateProfile(nickname:"Cleared",info:"",colors:[0,0,0,0,0,0],icon:[],gradient:false)
        XCTAssertEqual(member.currentUser?.icon,[]); XCTAssertEqual(member.currentUser?.flags,0)
    }
    @MainActor private func connect(_ client: KDXClient, server: KDXServer, login: String, table: ChallengeTable) async throws -> WireConnection {
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await client.connect(wire: a, login: login, password: "pw", nickname: login, table: table); return a
    }
    @MainActor private func eventually(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(3)
        while !predicate() && Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
}
