import XCTest
@testable import KDXCore

final class FileOperationTests: XCTestCase {
    @MainActor private func connect(_ client: KDXClient, server: KDXServer, table: ChallengeTable, login: String = "admin") async throws {
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await client.connect(wire: a, login: login, password: login.isEmpty ? "" : "pw", nickname: login.isEmpty ? "Guest" : login, table: table)
        client.setTransferFactory { let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table); return a }
    }
    @MainActor func testFileLifecycleCatalogAndFolderPolicy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        var config = ServerConfiguration(); config.sharedFolder = root.path
        config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true)]
        let server = KDXServer(configuration: config), admin = KDXClient(), guest = KDXClient()
        let table = ChallengeTable(testBytes: [UInt8](repeating: 5, count: 1739))
        defer { admin.disconnect(); guest.disconnect(); server.stop() }
        try await connect(admin, server: server, table: table); try await connect(guest, server: server, table: table, login: "")
        var item = FolderAccess(name: "Private"); item.classRules[0] = 0xfffe
        try await admin.saveFolderAccess(item, creating: true)
        try await admin.createFolder(name: "Secret", at: RemotePath([]), access: "Private")
        try Data("secret".utf8).write(to: root.appendingPathComponent("Secret [Private]/secret.txt"))
        let guestFiles = try await guest.files(at: [])
        XCTAssertFalse(guestFiles.contains { $0.name.contains("Secret") })
        do { _ = try await guest.files(at: ["Secret [Private]"]); XCTFail("Guest listed denied folder") } catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        let secretFiles = try await admin.files(at: ["Secret [Private]"])
        let secret = try XCTUnwrap(secretFiles.first)
        do { try await guest.download(secret, at: ["Secret [Private]"], to: root.appendingPathComponent("stolen.txt")); XCTFail("Guest downloaded denied file") } catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
        try await admin.createFolder(name: "Destination", at: RemotePath([]))
        try Data("public".utf8).write(to: root.appendingPathComponent("public.txt"))
        let publicFiles = try await admin.files(at: [])
        var file = try XCTUnwrap(publicFiles.first { $0.name == "public.txt" })
        try await admin.renameFile(file, at: RemotePath([]), to: "renamed.txt")
        let renamedFiles = try await admin.files(at: [])
        file = try XCTUnwrap(renamedFiles.first { $0.name == "renamed.txt" })
        try await admin.moveFiles([file], from: RemotePath([]), to: RemotePath(["Destination"]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Destination/renamed.txt")), Data("public".utf8))
        try await admin.generateCatalog()
        for _ in 0..<200 where admin.catalogProgress?.complete != true { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(admin.catalogProgress?.complete, true)
        let found = try await admin.searchFiles("secret"), hidden = try await guest.searchFiles("secret")
        XCTAssertEqual(found.count, 2); XCTAssertTrue(hidden.isEmpty)
        let renamed = try await guest.searchFiles("renamed"); XCTAssertEqual(renamed.first?.path.names, ["Destination","renamed.txt"])
        try await admin.trashFiles([file], at: RemotePath(["Destination"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Destination/renamed.txt").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".kdx-trash").path).count, 1)
        try await admin.emptyTrash(); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".kdx-trash").path).isEmpty)
        switch try await admin.itemInformation(path: RemotePath([])) { case .volume(let volume): XCTAssertGreaterThan(volume.totalSize, 0); XCTAssertEqual(volume.flagsMask, 0); default: XCTFail("Expected volume") }
        item = try await admin.folderAccess(name: "Private"); item.currentName = item.name; item.classRules[2] = 0xe000
        try await admin.saveFolderAccess(item, creating: false)
        let allowed = try await guest.files(at: ["Secret [Private]"]); XCTAssertEqual(allowed.count, 1)
        try await admin.deleteFolderAccess(name: "Private")
        let accessItems = try await admin.folderAccessList(); XCTAssertFalse(accessItems.contains { $0.name == "Private" })
        do { try await guest.createFolder(name: "denied", at: RemotePath([])); XCTFail("Guest created folder") } catch KDXError.remote(let code) { XCTAssertEqual(code, 0x10014) }
    }
    func testFilesystemMutationsStayConfinedAndDoNotOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent("a")); try Data([2]).write(to: root.appendingPathComponent("b"))
        let files = try SharedFiles(path: root.path)
        XCTAssertThrowsError(try files.rename(["a"], to: "b"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("b")), Data([2]))
        XCTAssertThrowsError(try files.createFolder(parent: [], name: "../outside"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root)
        XCTAssertThrowsError(try files.rename(["link"], to: "renamed"))
        XCTAssertThrowsError(try files.move(source: [], destination: ["link"], names: ["a"]))
        try files.createFolder(parent: [], name: "dir")
        XCTAssertThrowsError(try files.move(source: [], destination: ["dir"], names: ["dir"]))
        try files.trash(folder: [], names: ["dir"]); try files.emptyTrash()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
    }
    @MainActor func testLoginDenialAndLiveRevocation() async throws {
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true),ServerAccount(login: "member", password: "pw")]
        config.accounts[1].privilegeMask.set(4,true); config.accounts[1].privileges.set(4,false)
        config.accountClasses[2].privileges.set(4,false)
        let server = KDXServer(configuration: config), admin = KDXClient(), denied = KDXClient()
        let table = ChallengeTable(testBytes: [UInt8](repeating: 4, count: 1739))
        defer { admin.disconnect(); denied.disconnect(); server.stop() }
        for login in ["member",""] { do { try await connect(denied, server: server, table: table, login: login); XCTFail("Disabled login accepted") } catch {} }
        try await connect(admin, server: server, table: table)
        var account = try await admin.account(login: "member"); account.privileges.set(4,true)
        try await admin.updateAccount(account, originalLogin: "member")
        try await connect(denied, server: server, table: table, login: "member")
        account.privileges.set(4,false); try await admin.updateAccount(account, originalLogin: "member")
        for _ in 0..<100 where denied.isConnected { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(denied.isConnected)
    }
    func testNewsArchivalPersistsAndRollsBackOnFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("news.json"), store = try NewsStore(url: root.appendingPathComponent("news.json"))
        var group = try store.group(1); group.sizeLimitKiB = 1; _ = try store.saveGroup(group, creating: false)
        XCTAssertEqual(try store.group(1).sizeLimitKiB, 4)
        for _ in 0..<3 { _ = try store.add(author: "A", login: "a", subject: "post", body: String(repeating: "x", count: 3000)) }
        XCTAssertEqual(store.posts.map(\.id), [3]); XCTAssertEqual(store.archives.flatMap(\.posts).map(\.id), [1,2])
        let restored = try NewsStore(url: url); XCTAssertEqual(restored.archives.flatMap(\.posts).map(\.id), [1,2])
        try FileManager.default.removeItem(at: url); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try restored.add(author: "A", login: "a", subject: "failure", body: String(repeating: "x", count: 3000)))
        XCTAssertEqual(restored.posts.map(\.id), [3]); XCTAssertEqual(restored.archives.flatMap(\.posts).map(\.id), [1,2])
    }
}

@MainActor private final class PortAdvertiserTransport: ByteTransport {
    let base: MemoryTransport
    let cipher = SessionCipher(key: AccountKey(password: "pw"))
    var peerHost: String { base.peerHost }
    var endpointDescription: String { base.endpointDescription }
    init(_ base: MemoryTransport) { self.base = base }
    func start() async throws { try await base.start() }
    func read(_ count: Int) async throws -> [UInt8] { try await base.read(count) }
    func readSome(maximum: Int) async throws -> [UInt8] { try await base.readSome(maximum: maximum) }
    func write(_ bytes: [UInt8]) async throws {
        if bytes.count >= 16, let header = try? cipher.header(Array(bytes.prefix(16)), limit: 0x100000), header.type == 105 {
            var message = try cipher.open(header, payload: Array(bytes.dropFirst(16))); message.payload.put(UInt32(12000), at: 32)
            try await base.write(cipher.seal(message))
        } else { try await base.write(bytes) }
    }
    func close() { base.close() }
}
extension FileOperationTests {
    @MainActor func testAdvertisedTransferPortAndLiveMonitorProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 7, count: 180000).write(to: root.appendingPathComponent("large.bin"))
        var config = ServerConfiguration(); config.sharedFolder = root.path; config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true)]
        let server = KDXServer(configuration: config), client = KDXClient(), observer = KDXClient()
        let table = ChallengeTable(testBytes: [UInt8](repeating: 9, count: 1739))
        defer { client.disconnect(); observer.disconnect(); server.stop() }
        var ports = [UInt16](), gate: TransferGate?
        client.networkFactory = { _, port in
            ports.append(port)
            let (a,b) = MemoryTransport.endpoints()
            if port == 10700 { server.accept(wire: WireConnection(transport: PortAdvertiserTransport(b)), table: table) }
            else { let blocked = TransferGate(b, blockAfterLargeWrites: 1); gate = blocked; server.accept(wire: WireConnection(transport: blocked), table: table) }
            return WireConnection(transport: a)
        }
        try await client.connect(host: "test.invalid", port: 10700, login: "admin", password: "pw", nickname: "reader", table: table)
        try await connect(observer, server: server, table: table)
        let listing = try await client.files(at: []), file = try XCTUnwrap(listing.first)
        let task = Task { try await client.download(file, at: [], to: root.appendingPathComponent("copy.bin")) }
        for _ in 0..<200 where gate?.isBlocked != true { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(ports, [10700,12000]); XCTAssertEqual(gate?.isBlocked, true)
        let snapshot = try await observer.connectionMonitor(), transfer = try XCTUnwrap(snapshot.first { $0.transferID != 0 })
        XCTAssertEqual(transfer.path.names, ["large.bin"]); XCTAssertEqual(transfer.bytesDone, 65536); XCTAssertEqual(transfer.totalBytes, 180000)
        XCTAssertEqual(transfer.accountClassName, "Administrator"); XCTAssertEqual(transfer.state, 412)
        client.cancelTransfer(); gate?.close() // Release the synthetic blocked write as a transport failure.
        do { try await task.value; XCTFail("Cancelled transfer succeeded") } catch {}
        for _ in 0..<100 {
            let remaining = try await observer.connectionMonitor()
            if !remaining.contains(where: { $0.transferID != 0 }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Transfer remained in monitor after cancellation")
    }
    @MainActor func testFloodWarningsAndDisconnect() async throws {
        var config = ServerConfiguration(); config.accountClasses[2].floodLimit = 20
        let server = KDXServer(configuration: config), client = KDXClient()
        let table = ChallengeTable(testBytes: [UInt8](repeating: 8, count: 1739))
        defer { client.disconnect(); server.stop() }
        let (a,b) = MemoryTransport.pair(); server.accept(wire: b, table: table)
        try await client.connect(wire: a, login: "", password: "", nickname: "guest", autoJoinPublicChat: false, table: table)
        var replies = 0
        do { for _ in 0..<30 { _ = try await client.request(type: 115); replies += 1 } } catch {}
        XCTAssertLessThan(replies, 30)
        XCTAssertEqual(client.broadcasts.count, 2)
        XCTAssertTrue(client.broadcasts.first?.text.hasPrefix("WARNING:") == true)
        XCTAssertTrue(client.broadcasts.last?.text.hasPrefix("Final warning:") == true)
    }
}

extension FileOperationTests {
    @MainActor func testAccessPersistenceFailureDoesNotApplyRules() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "admin", password: "pw", isAdmin: true)]
        let server = KDXServer(configuration: config, configurationURL: url), admin = KDXClient()
        let table = ChallengeTable(testBytes: [UInt8](repeating: 2, count: 1739))
        defer { admin.disconnect(); server.stop() }
        try await connect(admin, server: server, table: table)
        var item = try await admin.folderAccess(name: "[Default]"); item.currentName = item.name; item.classRules[2] = 0
        try FileManager.default.removeItem(at: url); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        do { try await admin.saveFolderAccess(item, creating: false); XCTFail("Failed save acknowledged") } catch {}
        let unchanged = try await admin.folderAccess(name: "[Default]")
        XCTAssertEqual(unchanged.classRules[2], 0xfffe)
    }
}
