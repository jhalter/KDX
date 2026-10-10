import Foundation
import Observation
@preconcurrency import Network

public struct ServerConfiguration: Codable, Equatable, Sendable {
    public var name = "My KDX Server"
    public var description = "Welcome to KDX"
    public var port: UInt16 = 10700
    public var allowGuests = true
    public var accounts: [ServerAccount] = []
    public var accountClasses: [AccountClass] = AccountClass.defaults
    public var chats: [ChatRecord] = [.publicChat]
    public var sharedFolder = ""
    public var newsFile = ""
    public init() {}
    private enum CodingKeys: String, CodingKey { case name, description, port, allowGuests, accounts, accountClasses, chats, sharedFolder, newsFile }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name); description = try c.decode(String.self, forKey: .description)
        port = try c.decode(UInt16.self, forKey: .port); allowGuests = try c.decode(Bool.self, forKey: .allowGuests)
        accounts = try c.decode([ServerAccount].self, forKey: .accounts)
        accountClasses = try c.decodeIfPresent([AccountClass].self, forKey: .accountClasses) ?? AccountClass.defaults
        chats = try c.decodeIfPresent([ChatRecord].self, forKey: .chats) ?? [.publicChat]
        sharedFolder = try c.decodeIfPresent(String.self, forKey: .sharedFolder) ?? ""
        newsFile = try c.decodeIfPresent(String.self, forKey: .newsFile) ?? ""
        try validate()
    }
    public func save(to url: URL) throws {
        try validate()
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func load(from url: URL) throws -> Self { try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
    func validate() throws {
        _ = try shortText(name); _ = try shortText(description)
        guard !name.isEmpty, Set(accounts.map(\.login)).count == accounts.count else { throw KDXError.invalid("Server name is required and account logins must be unique.") }
        guard accounts.count <= 4096, accountClasses.count <= 32,
              Set(accountClasses.map(\.id)).count == accountClasses.count,
              accountClasses.contains(where: { $0.id == 2 }) else { throw KDXError.invalid("Invalid account classes or account limit.") }
        guard chats.count <= 256, Set(chats.map(\.id)).count == chats.count, chats.contains(where: { $0.id == 1 }) else { throw KDXError.invalid("Invalid chat configuration.") }
        for chat in chats {
            guard chat.id != 0, !chat.name.isEmpty, chat.flags == 0, chat.key == 0 else { throw KDXError.invalid("Invalid chat configuration.") }
            _ = try chat.encode()
        }
        for entry in accountClasses { _ = try entry.encode(info: true) }
        for account in accounts {
            try ServerAccount.validateLogin(account.login)
            guard account.key.count == 32, account.unknown77.count == 3, accountClasses.contains(where: { $0.id == account.classID }) else { throw KDXError.invalid("Invalid account key or class.") }
            _ = try RemoteAccount.info(account).encode()
        }
    }
}
public struct ServerLog: Identifiable, Sendable {
    public let id = UUID(), date = Date()
    public let text: String
}

@Observable @MainActor public final class KDXServer {
    public private(set) var isRunning = false
    public private(set) var port: UInt16?
    public private(set) var users: [KDXUser] = []
    public private(set) var log: [ServerLog] = []
    public private(set) var lastError: String?
    private var listener: NWListener?
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var peers: [UUID: Peer] = [:]
    public private(set) var configuration = ServerConfiguration()
    private var configurationURL: URL?
    private var news = NewsStore()
    private var nextUser: UInt32 = 1
    private var chatTopics: [UInt32: ChatTopic] = [:]
    struct Peer {
        let wire: WireConnection
        var user: KDXUser?
        var account: ServerAccount?
        var sessionKey: [UInt8] = []
        var joined: Set<UInt32> = []
        var parent: UUID?
    }
    public init(configuration: ServerConfiguration = ServerConfiguration(), configurationURL: URL? = nil) { self.configuration = configuration; self.configurationURL = configurationURL }
    public func start(configuration: ServerConfiguration, table: ChallengeTable, configurationURL: URL? = nil) async throws {
        guard listener == nil else { throw KDXError.invalid("Server is already running.") }
        try configuration.validate()
        self.configuration = configuration; self.configurationURL = configurationURL; lastError = nil
        news = try NewsStore(url: configuration.newsFile.isEmpty ? nil : URL(fileURLWithPath: configuration.newsFile))
        let listener = try NWListener(using: .tcp, on: configuration.port == 0 ? .any : NWEndpoint.Port(rawValue: configuration.port)!)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] network in
            Task { @MainActor in
                guard let self, self.listener === listener else { network.cancel(); return }
                guard self.peers.count < 128 else { network.cancel(); return }
                self.accept(wire: WireConnection(network: network), table: table)
            }
        }
        try await withCheckedThrowingContinuation { continuation in
            startWaiter = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.port = listener.port?.rawValue; self.isRunning = true
                        self.record("Listening on port \(self.port ?? 0)")
                        self.startWaiter?.resume(); self.startWaiter = nil
                    case .failed(let error):
                        self.lastError = error.localizedDescription; self.startWaiter?.resume(throwing: error); self.startWaiter = nil; self.stop()
                    case .cancelled: self.stop()
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            Task { [weak self, weak listener] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, let listener, self.listener === listener, self.startWaiter != nil else { return }
                let error = KDXError.invalid("The server listener did not start in time.")
                self.startWaiter?.resume(throwing: error); self.startWaiter = nil
                self.lastError = error.localizedDescription; self.stop()
            }
        }
    }
    public func stop() {
        startWaiter?.resume(throwing: KDXError.disconnected); startWaiter = nil
        let old = listener; listener = nil; old?.cancel()
        for peer in peers.values { peer.wire.close() }; peers.removeAll()
        users = []; chatTopics = [:]; port = nil; isRunning = false; record("Server stopped")
    }
    public func disconnectUser(_ id: UInt32) { peers.values.first { $0.user?.id == id }?.wire.close() }
    private func record(_ text: String) { log.append(ServerLog(text: text)); if log.count > 500 { log.removeFirst() } }
    func accept(wire: WireConnection, table: ChallengeTable) {
        let id = UUID()
        peers[id] = Peer(wire: wire)
        Task { await self.serve(id: id, wire: wire, table: table) }
    }
    private func serve(id: UUID, wire: WireConnection, table: ChallengeTable) async {
        do {
            try await wire.start()
            wire.ioTimeout = .seconds(15)
            let timeout = Task { try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled { wire.close() } }
            do {
                let client = try await wire.receiveHello()
                let hello = Hello(server: true)
                try await wire.write(hello.encode())
                guard client.nonce != hello.nonce else { throw KDXError.authentication }
                let name = String(decoding: client.name, as: UTF8.self)
                let account = configuration.accounts.first { $0.login == (name.isEmpty ? "guest" : name) }
                let key: AccountKey
                if client.name.first == 0 {
                    guard client.name.count == 5,
                          let parent = peers.first(where: { $0.value.user?.id == client.name.u32(1) && $0.value.parent == nil }),
                          parent.value.wire.peerHost == wire.peerHost else { throw KDXError.authentication }
                    key = try AccountKey(bytes: parent.value.sessionKey)
                    peers[id]?.parent = parent.key; wire.ioTimeout = .seconds(30)
                } else if let account { key = try AccountKey(bytes: account.key) }
                else if configuration.allowGuests && (name.isEmpty || name == "guest") { key = AccountKey(password: "") }
                else { throw KDXError.authentication }
                try Proof(wire: await wire.read(44)).verify(key: key, nonce: hello.nonce, response: table.response(hello.challenge))
                try await wire.write(Proof(key: key, nonce: client.nonce, response: table.response(client.challenge)).encode())
                wire.cipher = SessionCipher(key: key)
                // Recheck after the network await: an administrator may have changed/deleted this account.
                if let account {
                    guard let current = configuration.accounts.first(where: { $0.login == account.login }), current.key == key.bytes else { throw KDXError.authentication }
                    var updated = current; updated.lastLogin = ServerAccount.now
                    var candidate = configuration
                    candidate.accounts[candidate.accounts.firstIndex(where: { $0.login == current.login })!] = updated
                    try commitConfiguration(candidate)
                    peers[id]?.account = updated
                }
                peers[id]?.sessionKey = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
            } catch { timeout.cancel(); throw error }
            timeout.cancel()
            while peers[id] != nil {
                let message = try await wire.receive(limit: 0x20000)
                guard peers[id]?.wire === wire else { break }
                guard !message.isReply else { throw KDXError.invalid("Unexpected client reply.") }
                do { try await handle(message, id: id, wire: wire) }
                catch {
                    let code: UInt32
                    if case KDXError.remote(let value) = error { code = value } else { code = 0x1000a }
                    try await wire.send(type: 1, payload: [code, message.type, 0, 0, 0, 0].flatMap(\.beBytes), transaction: message.transaction, reply: true)
                    if peers[id]?.parent != nil { throw error }
                }
            }
        } catch { if peers[id] != nil { record("Connection closed: \(error.localizedDescription)") } }
        wire.close()
        if let user = peers.removeValue(forKey: id)?.user {
            for peer in peers.values where peer.parent == id { peer.wire.close() }
            users.removeAll { $0.id == user.id }
            await broadcast(type: 104, payload: user.id.beBytes + [7,0,0,0])
            record("\(user.nickname) disconnected")
        }
    }
    private func handle(_ message: Message, id: UUID, wire: WireConnection) async throws {
        let b = message.payload, tx = message.transaction
        if let parentID = peers[id]?.parent {
            guard let parent = peers[parentID], parent.user != nil else { throw KDXError.authentication }
            try await handleTransfer(message, wire: wire, parent: parent)
            return
        }
        if message.type == 100 {
            var (user, _) = try KDXUser.decode(b)
            guard !user.nickname.isEmpty else { throw KDXError.remote(0x1000a) }
            wire.ioTimeout = nil
            let old = peers[id]?.user
            user.id = old?.id ?? nextUser
            if old == nil { nextUser = nextUser &+ 1; if nextUser == 0 { nextUser = 1 } }
            user.isAdmin = privileges(for: peers[id]).contains(0)
            if !privileges(for: peers[id]).contains(60) { user.nickname = peers[id]?.account?.name ?? "Guest" }
            peers[id]?.user = user; users.removeAll { $0.id == user.id }; users.append(user)
            if old == nil {
                let info = ServerInfo(name: configuration.name, description: configuration.description, userID: user.id, canModifySettings: privileges(for: peers[id]).contains(61), sessionKey: peers[id]?.sessionKey ?? [])
                try await wire.send(type: 105, payload: info.encode())
                try await wire.send(type: 101, payload: KDXUser.encodeList(users))
                record("\(user.nickname) connected")
            }
            await broadcast(type: old == nil ? 103 : 102, payload: try user.encode(), excluding: id)
            return
        }
        guard let user = peers[id]?.user else { throw KDXError.remote(0x10014) }
        if [UInt32(502), 505, 507, 508, 509, 511, 512, 550].contains(message.type) {
            try await handleAccounts(message, id: id, wire: wire)
            return
        }
        switch message.type {
        case 108: try await wire.send(type: 109, transaction: tx, reply: true)
        case 115:
            let address = Array(wire.endpointDescription.utf8.prefix(255))
            try await wire.send(type: 116, payload: [UInt8(address.count)] + address, transaction: tx, reply: true)
        case 605:
            try requirePrivilege(70, peer: peers[id])
            var group = [UInt8](repeating: 0, count: 24); group.put(UInt32(1), at: 8); group.put(UInt16(news.posts.count), at: 16)
            let name = Array("General".utf8); group[22] = UInt8(name.count)
            var payload = UInt32(1).beBytes + group + name; payload.pad(4)
            try await wire.send(type: 606, payload: payload, transaction: tx, reply: true)
        case 607:
            try requirePrivilege(70, peer: peers[id])
            try b.require(4); guard b.u32(0) == 1 else { throw KDXError.remote(0x1000c) }
            let access = privileges(for: peers[id])
            let permissions: UInt32 = 4 | (access.contains(71) ? 1 : 0) | (access.contains(72) ? 2 : 0)
            var payload = [UInt32(1), permissions, 0, UInt32(news.posts.count)].flatMap(\.beBytes)
            for post in news.posts { payload += try post.encode() }
            try await wire.send(type: 608, payload: payload, transaction: tx, reply: true)
        case 609:
            try requirePrivilege(70, peer: peers[id])
            try b.require(8)
            guard b.u32(0) == 1, let post = news.posts.first(where: { $0.id == b.u32(4) }) else { throw KDXError.remote(0x1000c) }
            try await wire.send(type: 610, payload: post.encode(), transaction: tx, reply: true)
        case 611:
            try requirePrivilege(71, peer: peers[id])
            let login = peers[id]?.account?.login ?? "guest"
            try b.require(16); let subjectLength = Int(b[14]), bodyLength = Int(b.u16(12)); try b.require(16+subjectLength+bodyLength)
            guard b.u32(0) == 1 else { throw KDXError.remote(0x1000c) }
            let post = try news.add(author: user.nickname, login: login, subject: b.text(16..<16+subjectLength), body: b.text(16+subjectLength..<16+subjectLength+bodyLength))
            await broadcast(type: 613, payload: [UInt32(1), post.id, UInt32(news.posts.count)].flatMap(\.beBytes))
        case 612:
            try requirePrivilege(70, peer: peers[id])
            let login = peers[id]?.account?.login ?? "guest"
            try b.require(8); guard b.u32(0) == 1 else { throw KDXError.remote(0x1000c) }
            try news.delete(id: b.u32(4), login: login, admin: privileges(for: peers[id]).contains(72) || privileges(for: peers[id]).contains(0))
            await broadcast(type: 614, payload: [UInt32(1), b.u32(4), UInt32(news.posts.count)].flatMap(\.beBytes))
        case 400:
            let files = try SharedFiles(path: configuration.sharedFolder).list(RemotePath(wire: b).names)
            try await wire.send(type: 401, payload: RemoteFile.encodeList(files), transaction: tx, reply: true)
        case 201...220:
            try await handleChat(message, id: id, wire: wire)
        case 300:
            try requirePrivilege(32, peer: peers[id])
            try b.require(17); guard b.count <= 4112 else { throw KDXError.remote(0x1000a) }
            guard let recipient = peers.values.first(where: { $0.user?.id == b.u32(0) }) else { throw KDXError.remote(0x1000c) }
            var payload = b; payload.put(user.id, at: 0); try await recipient.wire.send(type: 301, payload: payload)
        default: throw KDXError.remote(0x10004)
        }
    }
    private func handleTransfer(_ message: Message, wire: WireConnection, parent: Peer) async throws {
        let b = message.payload, tx = message.transaction
        let files = try SharedFiles(path: configuration.sharedFolder)
        switch message.type {
        case 400:
            try await wire.send(type: 401, payload: RemoteFile.encodeList(files.list(RemotePath(wire: b).names)), transaction: tx, reply: true)
        case 412:
            try requirePrivilege(10, peer: parent)
            try b.require(24)
            guard b[23] == 0, b.u64(8) == 0 else { throw KDXError.remote(0x10004) }
            let path = try RemotePath(wire: Array(b.dropFirst(24)))
            let (handle, size) = try files.openFile(path.names)
            defer { try? handle.close() }
            let offset = min(size, b.u64(0) & ~UInt64(4095))
            guard size - offset <= UInt32.max else { throw KDXError.invalid("File is too large for a KDX transfer.") }
            let name = try shortText(path.names.last ?? "")
            var info = [UInt8](repeating: 0, count: 76)
            info.put(size, at: 0); info.put(UInt32(1), at: 48); info[72] = UInt8(name.count); info += name
            try await wire.send(type: 413, payload: info, transaction: tx, reply: true)
            try handle.seek(toOffset: offset)
            try await wire.sendFile(type: 414, length: UInt32(size-offset), source: handle, transaction: tx, reply: true)
            try await wire.sendFile(type: 414, length: 0, source: nil)
            record("Downloaded \(path.names.joined(separator: "/"))")
        case 415:
            try requirePrivilege(11, peer: parent)
            try b.require(76)
            guard b[23] == 0, b.u64(8) == 0, b.u64(0) <= UInt32.max else { throw KDXError.remote(0x10004) }
            let stringsEnd = 76 + (72..<76).reduce(0) { $0 + Int(b[$1]) }
            let pathLength = Int(b.u16(70)); try b.require(stringsEnd + pathLength)
            guard stringsEnd + pathLength == b.count else { throw KDXError.remote(0x1000a) }
            let name = b.text(76..<76+Int(b[72]))
            let folder = try RemotePath(wire: Array(b[stringsEnd..<stringsEnd+pathLength]))
            let upload = try files.beginUpload(folder: folder.names, name: name)
            var reply = [UInt8](repeating: 0, count: 24); reply.put(UInt64.max, at: 8)
            try await wire.send(type: 416, payload: reply, transaction: tx, reply: true)
            let length = try await wire.receiveFile(type: 417, sink: upload.handle, maximum: b.u64(0))
            guard length == b.u64(0) else { throw KDXError.invalid("Upload size did not match its metadata.") }
            _ = try await wire.receiveFile(type: 417, sink: nil, maximum: 0)
            try upload.commit()
            try await wire.send(type: 418)
            record("Uploaded \(name)")
        default: throw KDXError.remote(0x10004)
        }
    }
    private func broadcast(type: UInt32, payload: [UInt8], excluding: UUID? = nil, room: UInt32? = nil) async {
        let recipients = peers.filter { $0.key != excluding && $0.value.user != nil && (room == nil || $0.value.joined.contains(room!)) }.map(\.value.wire)
        for wire in recipients { do { try await wire.send(type: type, payload: payload) } catch { wire.close() } }
    }
}

// Account operations persist a validated candidate before updating live state.
extension KDXServer {
    private func privileges(for peer: Peer?) -> AccountPrivileges {
        peer?.account?.effective(in: configuration.accountClasses)
            ?? configuration.accountClasses.first { $0.id == 2 }?.privileges ?? AccountPrivileges()
    }
    private func requirePrivilege(_ bit: Int, peer: Peer?) throws {
        guard privileges(for: peer).contains(bit) else { throw KDXError.remote(0x10014) }
    }
    private func commitConfiguration(_ candidate: ServerConfiguration) throws {
        try candidate.validate()
        if let configurationURL { try candidate.save(to: configurationURL) }
        configuration = candidate
    }
    private func validateGrant(_ account: ServerAccount, requester: Peer?) throws {
        let granted = account.effective(in: configuration.accountClasses), allowed = privileges(for: requester)
        if allowed.contains(0) { return }
        for bit in 0..<128 where granted.contains(bit) && !allowed.contains(bit) {
            if bit == 3 || bit == 36 || (bit == 23 && allowed.contains(24)) { continue }
            throw KDXError.remote(0x640005)
        }
    }
    private func handleAccounts(_ message: Message, id: UUID, wire: WireConnection) async throws {
        let b = message.payload, tx = message.transaction
        let requester = peers[id]
        switch message.type {
        case 505:
            let permissions = privileges(for: requester)
            guard [27,37,50,73].contains(where: permissions.contains) else { throw KDXError.remote(0x10014) }
            try await wire.send(type: 506, payload: AccountClass.encodeList(configuration.accountClasses), transaction: tx, reply: true)
        case 502:
            try requirePrivilege(50, peer: requester)
            guard b.count == 1, let entry = configuration.accountClasses.first(where: { $0.id == b[0] }) else { throw KDXError.remote(0x10002) }
            try await wire.send(type: 503, payload: entry.encode(info: true), transaction: tx, reply: true)
        case 512:
            try requirePrivilege(50, peer: requester)
            let entries = configuration.accounts.map { account in
                AccountListEntry(login: account.login, name: account.name, classID: account.classID, created: account.created, lastLogin: account.lastLogin, unknown1b: account.effective(in: configuration.accountClasses).contains(0) ? 1 : 0)
            }
            try await wire.send(type: 513, payload: AccountListEntry.encodeList(entries), transaction: tx, reply: true)
        case 509:
            try requirePrivilege(50, peer: requester)
            guard let login = String(bytes: b, encoding: .utf8), let account = configuration.accounts.first(where: { $0.login == login }) else { throw KDXError.remote(0x1000c) }
            try await wire.send(type: 510, payload: RemoteAccount.info(account).encode(), transaction: tx, reply: true)
        case 507, 511:
            let creating = message.type == 507
            try requirePrivilege(creating ? 51 : 52, peer: requester)
            let record = try RemoteAccount.decode(b)
            try ServerAccount.validateLogin(record.login)
            guard configuration.accountClasses.contains(where: { $0.id == record.classID }) else { throw KDXError.remote(0x10002) }
            let existing = configuration.accounts.firstIndex { $0.login == record.editor }
            if !creating && existing == nil { throw KDXError.remote(0x1000c) }
            if configuration.accounts.contains(where: { $0.login == record.login && (creating || $0.login != record.editor) }) { throw KDXError.remote(0x1000d) }
            var account = creating ? ServerAccount(login: record.login, password: "") : configuration.accounts[existing!]
            if account.privilegeMask.contains(54) && account.privileges.contains(54) && !privileges(for: requester).contains(0) { throw KDXError.remote(0x10014) }
            account.apply(record, editor: requester?.account?.login ?? "guest", creating: creating)
            try validateGrant(account, requester: requester)
            var candidate = configuration
            if creating { candidate.accounts.append(account) } else { candidate.accounts[existing!] = account }
            try commitConfiguration(candidate)
            // Keep authenticated sessions' ciphers, but apply the new identity and rights immediately.
            let changed = creating ? [] : peers.keys.filter { peers[$0]?.account?.login == record.editor }
            var departures: [(UInt32, UInt32, WireConnection)] = []
            for peerID in changed {
                let oldRooms = peers[peerID]?.joined ?? []
                peers[peerID]?.account = account
                let effective = account.effective(in: configuration.accountClasses)
                if !effective.contains(30) { peers[peerID]?.joined = [] }
                else { peers[peerID]?.joined = Set(oldRooms.filter { room in
                    configuration.chats.first { $0.id == room }.map { ChatRecord.permits($0.joinClasses, classID: account.classID) } ?? false
                }) }
                if let peer = peers[peerID], let userID = peer.user?.id {
                    for roomID in oldRooms.subtracting(peer.joined) { departures.append((roomID, userID, peer.wire)) }
                }
                for attached in peers.values where attached.parent == peerID { attached.wire.close() }
                if var user = peers[peerID]?.user {
                    user.isAdmin = effective.contains(0)
                    if !effective.contains(60) { user.nickname = account.name }
                    peers[peerID]?.user = user
                    if let index = users.firstIndex(where: { $0.id == user.id }) { users[index] = user }
                }
            }
            try await wire.send(type: 1, payload: [UInt32(0), message.type].flatMap(\.beBytes), transaction: tx, reply: true)
            for (roomID, userID, departingWire) in departures { await notifyDeparture(roomID: roomID, userID: userID, wire: departingWire) }
            for peerID in changed {
                if let peer = peers[peerID], let user = peer.user {
                    await broadcast(type: 102, payload: try user.encode())
                    let info = ServerInfo(name: configuration.name, description: configuration.description, userID: user.id, canModifySettings: privileges(for: peer).contains(61), sessionKey: peer.sessionKey)
                    _ = try? await peer.wire.send(type: 105, payload: info.encode())
                }
            }
            recordLogAccount(creating ? "Created" : "Updated", login: account.login)
        case 508:
            try requirePrivilege(52, peer: requester)
            guard let login = String(bytes: b, encoding: .utf8), let account = configuration.accounts.first(where: { $0.login == login }) else { throw KDXError.remote(0x1000c) }
            if (account.privilegeMask.contains(0) && account.privileges.contains(0)) || (account.privilegeMask.contains(54) && account.privileges.contains(54) && !privileges(for: requester).contains(0)) { throw KDXError.remote(0x10014) }
            var candidate = configuration; candidate.accounts.removeAll { $0.login == login }; try commitConfiguration(candidate)
            try await wire.send(type: 515, payload: b)
            for peer in peers.values where peer.account?.login == login { peer.wire.close() }
            recordLogAccount("Deleted", login: login)
        case 550:
            try requirePrivilege(53, peer: requester)
            guard b.count == 32, let login = requester?.account?.login,
                  let index = configuration.accounts.firstIndex(where: { $0.login == login }) else { throw KDXError.remote(0x10014) }
            var candidate = configuration; candidate.accounts[index].key = b; candidate.accounts[index].modified = ServerAccount.now
            try commitConfiguration(candidate)
            for peerID in peers.keys where peers[peerID]?.account?.login == login { peers[peerID]?.account = candidate.accounts[index] }
            try await wire.send(type: 551, transaction: tx, reply: true)
        default: throw KDXError.remote(0x10004)
        }
    }
    private func recordLogAccount(_ action: String, login: String) { record("\(action) account \(login)") }
}

extension KDXServer {
    private func requireChatAccess(_ bit: Int, mask: UInt32, peer: Peer?) throws {
        try requirePrivilege(bit, peer: peer)
        guard ChatRecord.permits(mask, classID: peer?.account?.classID ?? 2) else { throw KDXError.remote(0x10014) }
    }
    private func chatRecord(_ roomID: UInt32) throws -> ChatRecord {
        guard let room = configuration.chats.first(where: { $0.id == roomID }) else { throw KDXError.remote(0x1000c) }
        return room
    }
    private func handleChat(_ message: Message, id: UUID, wire: WireConnection) async throws {
        let b = message.payload, tx = message.transaction
        guard let peer = peers[id], let user = peer.user else { throw KDXError.disconnected }
        switch message.type {
        case 214:
            let rooms = configuration.chats.map { room in
                ChatRoom(id: room.id, key: room.key, name: room.name, description: room.description,
                         memberCount: peers.values.filter { $0.joined.contains(room.id) }.count, flags: room.flags)
            }
            try await wire.send(type: 215, payload: ChatRoom.encodeList(rooms), transaction: tx, reply: true)
        case 202:
            try b.require(8); let room = try chatRecord(b.u32(0))
            try requireChatAccess(30, mask: room.joinClasses, peer: peer)
            guard room.flags & 1 == 0 || room.key == b.u32(4) else { throw KDXError.remote(0x10014) }
            let wasMember = peer.joined.contains(room.id)
            peers[id]?.joined.insert(room.id)
            let members = peers.values.filter { $0.joined.contains(room.id) }.compactMap { $0.user?.id }.sorted()
            let window = ChatWindow(id: room.id, key: room.key, flags: room.flags, members: members, strings: ["", "", room.name, "", ""])
            try await wire.send(type: 203, payload: window.encode(), transaction: tx, reply: true)
            if let topic = chatTopics[room.id] { try await wire.send(type: 210, payload: topic.encode()) }
            if !wasMember { await broadcast(type: 205, payload: room.id.beBytes + user.id.beBytes + [0,0,0,0], excluding: id, room: room.id) }
        case 204:
            try b.require(4); let room = try chatRecord(b.u32(0))
            if peers[id]?.joined.remove(room.id) != nil {
                await broadcast(type: 206, payload: room.id.beBytes + user.id.beBytes + [1,0,0,0], excluding: id, room: room.id)
            }
        case 207:
            try b.require(13); let room = try chatRecord(b.u32(0))
            try requireChatAccess(31, mask: room.sendClasses, peer: peer)
            guard peer.joined.contains(room.id) else { throw KDXError.remote(0x10014) }
            guard b.count <= 4108 else { throw KDXError.remote(0x1000a) }
            var text = b; text.put(user.id, at: 4)
            await broadcast(type: 208, payload: text, room: room.id)
        case 209:
            try b.require(12); let room = try chatRecord(b.u32(0))
            try requireChatAccess(35, mask: room.topicClasses, peer: peer)
            guard peer.joined.contains(room.id) else { throw KDXError.remote(0x10014) }
            let end = 12 + Int(b[10]); try b.require(end)
            let topic = ChatTopic(time: ServerAccount.now, roomID: room.id, userID: user.id, text: b.text(12..<end), nickname: user.nickname)
            chatTopics[room.id] = topic
            await broadcast(type: 210, payload: try topic.encode(), room: room.id)
        case 218:
            try requirePrivilege(37, peer: peer); try b.require(4)
            try await wire.send(type: 219, payload: chatRecord(b.u32(0)).encode(), transaction: tx, reply: true)
        case 217, 220:
            try requirePrivilege(37, peer: peer)
            var room = try ChatRecord.decode(b)
            // Voice and private-room management need additional protocol support.
            guard room.flags == 0, room.key == 0 else { throw KDXError.remote(0x10004) }
            guard !room.name.isEmpty else { throw KDXError.remote(0x1000a) }
            var candidate = configuration
            if message.type == 217 {
                repeat { room.id = UInt32.random(in: 4...UInt32.max) } while candidate.chats.contains(where: { $0.id == room.id })
                candidate.chats.append(room)
            } else {
                guard let index = candidate.chats.firstIndex(where: { $0.id == room.id }) else { throw KDXError.remote(0x1000c) }
                candidate.chats[index] = room
            }
            try commitConfiguration(candidate)
            let removed = removeDisallowedMembers(room)
            try await wire.send(type: 1, payload: [UInt32(0), message.type].flatMap(\.beBytes), transaction: tx, reply: true)
            for (departed, departingWire) in removed { await notifyDeparture(roomID: room.id, userID: departed, wire: departingWire) }
            record("\(message.type == 217 ? "Created" : "Updated") chat \(room.name)")
        case 201:
            try requirePrivilege(37, peer: peer); try b.require(4)
            let room = try chatRecord(b.u32(0))
            guard room.id != 1 else { throw KDXError.remote(0x10014) }
            var candidate = configuration; candidate.chats.removeAll { $0.id == room.id }; try commitConfiguration(candidate)
            let members = peers.values.filter { $0.joined.contains(room.id) }.map(\.wire)
            for peerID in peers.keys { peers[peerID]?.joined.remove(room.id) }
            chatTopics.removeValue(forKey: room.id)
            for member in members { do { try await member.send(type: 221, payload: room.id.beBytes + user.id.beBytes) } catch { member.close() } }
            try await wire.send(type: 1, payload: [UInt32(0), message.type].flatMap(\.beBytes), transaction: tx, reply: true)
            record("Deleted chat \(room.name)")
        default: throw KDXError.remote(0x10004)
        }
    }
    // Apply all membership changes before any await, so concurrent messages see the new policy.
    private func removeDisallowedMembers(_ room: ChatRecord) -> [(UInt32, WireConnection)] {
        var removed: [(UInt32, WireConnection)] = []
        for peerID in peers.keys {
            guard let peer = peers[peerID], let user = peer.user, peer.joined.contains(room.id),
                  !ChatRecord.permits(room.joinClasses, classID: peer.account?.classID ?? 2) else { continue }
            peers[peerID]?.joined.remove(room.id); removed.append((user.id, peer.wire))
        }
        return removed
    }
    private func notifyDeparture(roomID: UInt32, userID: UInt32, wire: WireConnection) async {
        let payload = roomID.beBytes + userID.beBytes + [1,0,0,0]
        await broadcast(type: 206, payload: payload, room: roomID)
        _ = try? await wire.send(type: 206, payload: payload)
    }
}
