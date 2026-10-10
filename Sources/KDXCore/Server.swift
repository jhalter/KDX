import Foundation
import Observation
@preconcurrency import Network

public struct ServerAccount: Codable, Identifiable, Sendable {
    public var id: String { login }
    public let login: String
    public var isAdmin: Bool
    var key: [UInt8]
    public init(login: String, password: String, isAdmin: Bool = false) {
        self.login = login; self.isAdmin = isAdmin; key = AccountKey(password: password).bytes
    }
}
public struct ServerConfiguration: Codable, Sendable {
    public var name = "My KDX Server"
    public var description = "Welcome to KDX"
    public var port: UInt16 = 10700
    public var allowGuests = true
    public var accounts: [ServerAccount] = []
    public var sharedFolder = ""
    public var newsFile = ""
    public init() {}
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
        for account in accounts {
            guard !account.login.isEmpty, account.login.utf8.count <= 31, !account.login.utf8.contains(0), account.key.count == 32 else { throw KDXError.invalid("Invalid account. Logins must contain 1–31 UTF-8 bytes.") }
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
    private var configuration = ServerConfiguration()
    private var news = NewsStore()
    private var nextUser: UInt32 = 1
    private struct Peer {
        let wire: WireConnection
        var user: KDXUser?
        var account: ServerAccount?
        var sessionKey: [UInt8] = []
        var joined = false
        var parent: UUID?
    }
    public init(configuration: ServerConfiguration = ServerConfiguration()) { self.configuration = configuration }
    public func start(configuration: ServerConfiguration, table: ChallengeTable) async throws {
        guard listener == nil else { throw KDXError.invalid("Server is already running.") }
        try configuration.validate()
        self.configuration = configuration; lastError = nil
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
        }
    }
    public func stop() {
        startWaiter?.resume(throwing: KDXError.disconnected); startWaiter = nil
        let old = listener; listener = nil; old?.cancel()
        for peer in peers.values { peer.wire.close() }; peers.removeAll()
        users = []; port = nil; isRunning = false; record("Server stopped")
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
                    peers[id]?.parent = parent.key
                } else if let account { key = try AccountKey(bytes: account.key) }
                else if configuration.allowGuests && (name.isEmpty || name == "guest") { key = AccountKey(password: "") }
                else { throw KDXError.authentication }
                try Proof(wire: await wire.read(44)).verify(key: key, nonce: hello.nonce, response: table.response(hello.challenge))
                try await wire.write(Proof(key: key, nonce: client.nonce, response: table.response(client.challenge)).encode())
                wire.cipher = SessionCipher(key: key)
                peers[id]?.account = account
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
            let old = peers[id]?.user
            user.id = old?.id ?? nextUser
            if old == nil { nextUser = nextUser &+ 1; if nextUser == 0 { nextUser = 1 } }
            user.isAdmin = peers[id]?.account?.isAdmin ?? false
            peers[id]?.user = user; users.removeAll { $0.id == user.id }; users.append(user)
            if old == nil {
                let info = ServerInfo(name: configuration.name, description: configuration.description, userID: user.id, canModifySettings: user.isAdmin, sessionKey: peers[id]?.sessionKey ?? [])
                try await wire.send(type: 105, payload: info.encode())
                try await wire.send(type: 101, payload: KDXUser.encodeList(users))
                record("\(user.nickname) connected")
            }
            await broadcast(type: old == nil ? 103 : 102, payload: try user.encode(), excluding: id)
            return
        }
        guard let user = peers[id]?.user else { throw KDXError.remote(0x10014) }
        switch message.type {
        case 108: try await wire.send(type: 109, transaction: tx, reply: true)
        case 115:
            let address = Array(wire.endpointDescription.utf8.prefix(255))
            try await wire.send(type: 116, payload: [UInt8(address.count)] + address, transaction: tx, reply: true)
        case 605:
            var group = [UInt8](repeating: 0, count: 24); group.put(UInt32(1), at: 8); group.put(UInt16(news.posts.count), at: 16)
            let name = Array("General".utf8); group[22] = UInt8(name.count)
            var payload = UInt32(1).beBytes + group + name; payload.pad(4)
            try await wire.send(type: 606, payload: payload, transaction: tx, reply: true)
        case 607:
            try b.require(4); guard b.u32(0) == 1 else { throw KDXError.remote(0x1000c) }
            let permissions: UInt32 = 4 | (peers[id]?.account != nil ? 1 : 0) | (user.isAdmin ? 2 : 0)
            var payload = [UInt32(1), permissions, 0, UInt32(news.posts.count)].flatMap(\.beBytes)
            for post in news.posts { payload += try post.encode() }
            try await wire.send(type: 608, payload: payload, transaction: tx, reply: true)
        case 609:
            try b.require(8)
            guard b.u32(0) == 1, let post = news.posts.first(where: { $0.id == b.u32(4) }) else { throw KDXError.remote(0x1000c) }
            try await wire.send(type: 610, payload: post.encode(), transaction: tx, reply: true)
        case 611:
            guard let account = peers[id]?.account else { throw KDXError.remote(0x10014) }
            try b.require(16); let subjectLength = Int(b[14]), bodyLength = Int(b.u16(12)); try b.require(16+subjectLength+bodyLength)
            guard b.u32(0) == 1 else { throw KDXError.remote(0x1000c) }
            let post = try news.add(author: user.nickname, login: account.login, subject: b.text(16..<16+subjectLength), body: b.text(16+subjectLength..<16+subjectLength+bodyLength))
            await broadcast(type: 613, payload: [UInt32(1), post.id, UInt32(news.posts.count)].flatMap(\.beBytes))
        case 612:
            guard let account = peers[id]?.account else { throw KDXError.remote(0x10014) }
            try b.require(8); guard b.u32(0) == 1 else { throw KDXError.remote(0x1000c) }
            try news.delete(id: b.u32(4), login: account.login, admin: account.isAdmin)
            await broadcast(type: 614, payload: [UInt32(1), b.u32(4), UInt32(news.posts.count)].flatMap(\.beBytes))
        case 400:
            let files = try SharedFiles(path: configuration.sharedFolder).list(RemotePath(wire: b).names)
            try await wire.send(type: 401, payload: RemoteFile.encodeList(files), transaction: tx, reply: true)
        case 214:
            let name = Array("Public Chat".utf8), description = Array("Everyone is welcome".utf8)
            var entry = [UInt8](repeating: 0, count: 20)
            entry.put(UInt32(1), at: 0); entry.put(UInt16(peers.values.filter(\.joined).count), at: 16)
            entry[18] = UInt8(name.count); entry[19] = UInt8(description.count)
            var payload = UInt32(1).beBytes + entry + name + description; payload.pad(4)
            try await wire.send(type: 215, payload: payload, transaction: tx, reply: true)
        case 202:
            try b.require(8); guard b.u32(0) == 1 else { throw KDXError.remote(0x1000c) }
            peers[id]?.joined = true
            let members = peers.values.filter(\.joined).compactMap { $0.user?.id }, name = Array("Public Chat".utf8)
            var payload = [UInt8](repeating: 0, count: 36)
            payload.put(UInt32(1), at: 8); payload.put(UInt16(members.count), at: 22); payload[32] = UInt8(name.count)
            payload += members.flatMap(\.beBytes); payload += name
            try await wire.send(type: 203, payload: payload, transaction: tx, reply: true)
            await broadcast(type: 205, payload: UInt32(1).beBytes + user.id.beBytes + [0,0,0,0], excluding: id, joinedOnly: true)
        case 204:
            try b.require(4); guard b.u32(0) == 1 else { throw KDXError.remote(0x1000c) }
            peers[id]?.joined = false
            await broadcast(type: 206, payload: UInt32(1).beBytes + user.id.beBytes + [1,0,0,0], excluding: id, joinedOnly: true)
        case 207:
            try b.require(13)
            guard peers[id]?.joined == true, b.u32(0) == 1 else { throw KDXError.remote(0x10014) }
            guard b.count <= 4108 else { throw KDXError.remote(0x1000a) }
            var text = b; text.put(user.id, at: 4)
            await broadcast(type: 208, payload: text, joinedOnly: true)
        case 300:
            try b.require(17); guard b.count <= 4112 else { throw KDXError.remote(0x1000a) }
            guard let recipient = peers.values.first(where: { $0.user?.id == b.u32(0) }) else { throw KDXError.remote(0x1000c) }
            var payload = b; payload.put(user.id, at: 0); try await recipient.wire.send(type: 301, payload: payload)
        default: throw KDXError.remote(0x10006)
        }
    }
    private func handleTransfer(_ message: Message, wire: WireConnection, parent: Peer) async throws {
        let b = message.payload, tx = message.transaction
        let files = try SharedFiles(path: configuration.sharedFolder)
        switch message.type {
        case 400:
            try await wire.send(type: 401, payload: RemoteFile.encodeList(files.list(RemotePath(wire: b).names)), transaction: tx, reply: true)
        case 412:
            try b.require(24)
            guard b[23] == 0, b.u64(8) == 0 else { throw KDXError.remote(0x10006) }
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
            // Anonymous guests may browse and download, but cannot upload.
            guard parent.account != nil else { throw KDXError.remote(0x10014) }
            try b.require(76)
            guard b[23] == 0, b.u64(8) == 0, b.u64(0) <= UInt32.max else { throw KDXError.remote(0x10006) }
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
        default: throw KDXError.remote(0x10006)
        }
    }
    private func broadcast(type: UInt32, payload: [UInt8], excluding: UUID? = nil, joinedOnly: Bool = false) async {
        let recipients = peers.filter { $0.key != excluding && $0.value.user != nil && (!joinedOnly || $0.value.joined) }.map(\.value.wire)
        for wire in recipients { do { try await wire.send(type: type, payload: payload) } catch { wire.close() } }
    }
}
