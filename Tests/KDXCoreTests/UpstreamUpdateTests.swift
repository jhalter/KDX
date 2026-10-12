import XCTest
@testable import KDXCore

final class UpstreamUpdateTests: XCTestCase {
    func testCapturedMonitorTransfers() throws {
        let messages = try capturedMessages("linux-catalog-volumes-58160")
        let replies = messages.filter { $0.type == 143 }; XCTAssertEqual(replies.count, 24)
        var transfers = 0
        for reply in replies {
            let entries = try MonitoredConnection.decodeList(reply.payload)
            var canonical = reply.payload, at = 0
            for entry in entries {
                let end = at+104+[entry.nickname,entry.login,entry.accountClassName,entry.address].reduce(0) { $0+$1.utf8.count }+(try entry.path.encode().count)
                let next = (end+3) & ~3; for offset in end..<next { canonical[offset] = 0 }; at = next
                if entry.transferID != 0 {
                    transfers += 1; XCTAssertEqual(entry.path.names, ["speed.bin"]); XCTAssertEqual(entry.totalBytes, 0x200000)
                    XCTAssertEqual(entry.state, 412); XCTAssertEqual(entry.speedLimit, 0x5000); XCTAssertGreaterThan(entry.rate, 0)
                }
            }
            XCTAssertEqual(try MonitoredConnection.encodeList(entries), canonical)
        }
        XCTAssertEqual(transfers, 20)
    }
    func testCapturedUTF8AndRawFilenames() throws {
        let messages = try capturedMessages("linux-text-encoding-40504")
        let lists = try messages.filter { $0.type == 401 }.flatMap { try RemoteFile.decodeList($0.payload) }
        let raw = Array("caf".utf8)+[UInt8(0x8e)]+Array(".txt".utf8)
        let file = try XCTUnwrap(lists.first { $0.nameBytes == raw })
        let utf8 = try XCTUnwrap(lists.first { $0.name == "café.txt" })
        XCTAssertNotEqual(file.id, utf8.id)
        let path = RemotePath(["lab-utf8"]).appending(file)
        XCTAssertEqual(try RemotePath(wire: path.encode()).components.last, raw)
        XCTAssertThrowsError(try path.localNames())
        let identity = DownloadIdentity(server: "s", account: "a", path: path.names, destination: "x", rawPath: path.components)
        let replaced = DownloadIdentity(server: "s", account: "a", path: path.names, destination: "x")
        XCTAssertNotEqual(try identity.digest(), try replaced.digest())
        let chat = try XCTUnwrap(messages.first { $0.type == 207 })
        XCTAssertEqual(chat.payload.text(12..<chat.payload.count), "café ’ — 日本 😀")
        XCTAssertTrue(messages.filter { $0.type == 102 }.contains { (try? KDXUser.decode($0.payload).0.nickname) == "Zoë-日本" })
    }
    func testCapturedTrackerListsGreetingAndRegistration() throws {
        let messages = try capturedMessages("linux-tracker-60698", password: "")
        let groups = try TrackerGroup.decodeList(XCTUnwrap(messages.first { $0.type == 701 }).payload)
        XCTAssertEqual(groups.count, 8); XCTAssertEqual(groups.first { $0.name == "General" }?.serverCount, 1)
        let replies = messages.filter { $0.type == 703 }
        XCTAssertEqual(try TrackerServer.decodeList(replies[0].payload).first?.name, "Lab Server")
        XCTAssertTrue(try TrackerServer.decodeList(replies[1].payload).isEmpty)
        let greeting = try capturedMessages("linux-tracker-43808", password: "").first { $0.type == 107 }
        XCTAssertEqual(greeting?.payload.text(4..<(greeting?.payload.count ?? 4)), "Tracker greeting")
        let url = try XCTUnwrap(Bundle.module.url(forResource: "linux-tracker-registration", withExtension: "bin", subdirectory: "Fixtures"))
        let packet = Array(try Data(contentsOf: url)); var plain = TrackerAdvertisement.obfuscate(packet)
        let checksum = plain.u32(8); plain.put(UInt32(0xcad31ecc), at: 8)
        XCTAssertEqual(TrackerAdvertisement.crc(plain, seed: 0xdeadbeef), checksum)
        XCTAssertEqual(plain.u32(24), 10700); XCTAssertEqual(plain.u16(36), 1)
        XCTAssertEqual(plain[52], 9); XCTAssertEqual(plain.text(64..<73), "trk-login")
    }
    func testCapturedFileOperationsAndAccessRecords() throws {
        let messages = try capturedMessages("linux-files-59246")
        for message in messages {
            switch message.type {
            case 402: XCTAssertEqual(try CreateFolderRequest.decode(message.payload).encode(), message.payload)
            case 403,407: XCTAssertEqual(try MoveItemsRequest.decode(message.payload).encode(), message.payload)
            case 405: XCTAssertEqual(try TrashItemsRequest.decode(message.payload).encode(), message.payload)
            case 411: XCTAssertEqual(try SetFileInfoRequest.decode(message.payload).encode(), message.payload)
            default: break
            }
        }
        for stem in ["linux-accounts-folder-access-55746","linux-folder-access-guest-54824"] {
            for message in try capturedMessages(stem) where [UInt32(1100),1104,1105].contains(message.type) {
                let item = try FolderAccess.decode(message.payload)
                var canonical = message.payload
                let end = 184+[item.name,item.owner,item.description,item.currentName].reduce(0) { $0+$1.utf8.count }
                for index in end..<canonical.count { canonical[index] = 0 }
                XCTAssertEqual(try item.encode(), canonical)
                if message.type == 1105, item.classRules[2] == 0x8000 { XCTAssertTrue(item.permits(0, classID: 2, login: "guest", folderOwner: nil)); XCTAssertFalse(item.permits(1, classID: 2, login: "guest", folderOwner: nil)) }
            }
        }
        let catalog = try capturedMessages("linux-catalog-volumes-58160")
        let volume = try XCTUnwrap(catalog.first { $0.type == 422 })
        XCTAssertEqual(try VolumeInformation.decode(volume.payload).encode(), volume.payload)
        let search = try XCTUnwrap(catalog.first { $0.type == 453 })
        XCTAssertEqual(try FileSearchResult.encodeList(FileSearchResult.decodeList(search.payload)), search.payload)
    }
    func testLoginMigrationAndClassFields() throws {
        var config = ServerConfiguration(); config.accounts = [ServerAccount(login: "user", password: "pw")]
        for index in config.accountClasses.indices { config.accountClasses[index].privileges.set(4, false) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]); object.removeValue(forKey: "accessVersion")
        let old = try JSONSerialization.data(withJSONObject: object)
        let migrated = try JSONDecoder().decode(ServerConfiguration.self, from: old)
        XCTAssertTrue(migrated.accountClasses.allSatisfy { $0.privileges.contains(4) })
        let modern = try JSONDecoder().decode(ServerConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertFalse(modern.accountClasses[0].privileges.contains(4))
        var entry = AccountClass(id: 1, name: "Test"); entry.floodLimit = 20; entry.second = "Extra"; entry.editor = "admin"; entry.extra26 = [12,34]
        XCTAssertEqual(try AccountClass.decode(entry.encode(info: true), info: true).0, entry)
        XCTAssertEqual(try JSONDecoder().decode(AccountClass.self, from: JSONEncoder().encode(entry)), entry)
        var info = ServerInfo(name: "Test", description: "", userID: 1, canModifySettings: false, sessionKey: [UInt8](repeating: 0, count: 32)); info.transferPort = 12345
        XCTAssertEqual(try ServerInfo.decode(info.encode()).transferPort, 12345)
    }
    func testFloodWindows() {
        var window = RequestFloodWindow()
        for count in 1...29 {
            let expected: RequestFloodWindow.Action = count == 20 ? .warning : count == 24 ? .finalWarning : count == 29 ? .ban : .none
            XCTAssertEqual(window.record(limit: 20, now: Double(count)*0.3), expected)
        }
        XCTAssertEqual(window.record(limit: 20, now: 122), .none)
        XCTAssertEqual(window.record(limit: 0, now: 123), .none)
        var accepts = ConnectionFloodWindow(started: 0)
        for _ in 0..<30 { XCTAssertTrue(accepts.accept(now: 1)) }
        XCTAssertFalse(accepts.accept(now: 2)); XCTAssertFalse(accepts.accept(now: 3601)); XCTAssertTrue(accepts.accept(now: 3602))
    }
}
