import Foundation
import Observation
@preconcurrency import Network

public struct ServerConfiguration: Codable, Equatable, Sendable {
    public var name = "My KDX Server"
    public var description = "Welcome to KDX"
    public var greeting = ""
    public var greetingEnabled = false
    public var downloadLimit: UInt32 = 0
    var settingsBlob: [UInt8]?
    public var port: UInt16 = 10700
    public var allowGuests = true
    public var accounts: [ServerAccount] = []
    public var accountClasses: [AccountClass] = AccountClass.defaults
    public var chats: [ChatRecord] = [.publicChat]
    public var sharedFolder = ""
    public var newsFile = ""
    public init() {}
    private enum CodingKeys: String, CodingKey { case name, description, greeting, greetingEnabled, downloadLimit, settingsBlob, port, allowGuests, accounts, accountClasses, chats, sharedFolder, newsFile }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name); description = try c.decode(String.self, forKey: .description)
        greeting = try c.decodeIfPresent(String.self, forKey: .greeting) ?? ""
        greetingEnabled = try c.decodeIfPresent(Bool.self, forKey: .greetingEnabled) ?? false
        downloadLimit = try c.decodeIfPresent(UInt32.self, forKey: .downloadLimit) ?? 0
        settingsBlob = try c.decodeIfPresent([UInt8].self, forKey: .settingsBlob)
        port = try c.decode(UInt16.self, forKey: .port); allowGuests = try c.decode(Bool.self, forKey: .allowGuests)
        accounts = try c.decode([ServerAccount].self, forKey: .accounts)
        accountClasses = try c.decodeIfPresent([AccountClass].self, forKey: .accountClasses) ?? AccountClass.defaults
        chats = try c.decodeIfPresent([ChatRecord].self, forKey: .chats) ?? [.publicChat]
        sharedFolder = try c.decodeIfPresent(String.self, forKey: .sharedFolder) ?? ""
        newsFile = try c.decodeIfPresent(String.self, forKey: .newsFile) ?? ""
        try validate()
    }
    func remoteSettings() throws -> RemoteServerSettings {
        var settings = try settingsBlob.map { try RemoteServerSettings(wire: $0) } ?? RemoteServerSettings(name: name)
        settings.name = name; settings.greeting = greeting; settings.greetingEnabled = greetingEnabled; settings.downloadLimit = downloadLimit
        return settings
    }
    public func save(to url: URL) throws {
        try validate()
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func load(from url: URL) throws -> Self { try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
    func validate() throws {
        _ = try remoteSettings().encode()
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
    private var newsLoaded = false
    private var privateChats: [UInt32: (room: ChatRecord, owner: UInt32)] = [:]
    private var activeDownloads: Set<ObjectIdentifier> = []
    private let downloadLimiter = DownloadLimiter()
    private var nextInvitation: UInt32 = 1
    private var history: [(sequence: UInt64, entry: RemoteHistoryEntry)] = []
    private var historySequence: UInt64 = 0
    private var nextUser: UInt32 = 1
    private var chatTopics: [UInt32: ChatTopic] = [:]
    struct Peer {
        let wire: WireConnection
        var user: KDXUser?
        var loginTime: UInt64 = 0
        var lastActivity: UInt64 = 0
        var account: ServerAccount?
        var sessionKey: [UInt8] = []
        var joined: Set<UInt32> = []
        var loginAttempt: String?
        var monitoringConnections = false
        var historyJoined = false
        var historySending = false
        var historyCursor: UInt64 = 0
        var parent: UUID?
    }
    public init(configuration: ServerConfiguration = ServerConfiguration(), configurationURL: URL? = nil) { self.configuration = configuration; self.configurationURL = configurationURL }
    public func start(configuration: ServerConfiguration, table: ChallengeTable, configurationURL: URL? = nil) async throws {
        guard listener == nil else { throw KDXError.invalid("Server is already running.") }
        try configuration.validate()
        self.configuration = configuration; self.configurationURL = configurationURL; lastError = nil
        news = try NewsStore(url: configuration.newsFile.isEmpty ? nil : URL(fileURLWithPath: configuration.newsFile)); newsLoaded = true
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
                        self.appendHistory(kind: 190)
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
        users = []; chatTopics = [:]; privateChats = [:]; nextInvitation = 1; newsLoaded = false; port = nil; isRunning = false; record("Server stopped")
    }
    public func disconnectUser(_ id: UInt32) { peers.values.first { $0.user?.id == id }?.wire.close() }
    private func record(_ text: String) { log.append(ServerLog(text: text)); if log.count > 500 { log.removeFirst() } }
    func accept(wire: WireConnection, table: ChallengeTable) {
        if !newsLoaded {
            do { news = try NewsStore(url: configuration.newsFile.isEmpty ? nil : URL(fileURLWithPath: configuration.newsFile)); newsLoaded = true }
            catch { lastError = error.localizedDescription; wire.close(); return }
        }
        if downloadLimiter.rate != configuration.downloadLimit { downloadLimiter.setRate(configuration.downloadLimit) }
        if history.isEmpty { appendHistory(kind: 190) }
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
                if client.name.first != 0 { peers[id]?.loginAttempt = name.isEmpty ? "guest" : name }
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
                let actor = peers[id]?.parent.flatMap { peers[$0] } ?? peers[id]
                let detail = historyDetail(message)
                do {
                    try await handle(message, id: id, wire: wire)
                    if ![UInt32(100),108,115,140,141,142,180,207,300,412,415].contains(message.type) { appendHistory(kind: message.type, peer: actor, detail: detail) }
                }
                catch {
                    let code: UInt32
                    if case KDXError.remote(let value) = error { code = value } else { code = 0x1000a }
                    appendHistory(kind: message.type == 412 ? 186 : message.type == 415 ? 187 : message.type, peer: actor, detail: "Error 0x" + String(code, radix: 16) + (detail.isEmpty ? "" : " · " + detail))
                    try await wire.send(type: 1, payload: [code, message.type, 0, 0, 0, 0].flatMap(\.beBytes), transaction: message.transaction, reply: true)
                    if peers[id]?.parent != nil { throw error }
                }
                await publishHistory()
            }
        } catch {
            if let peer = peers[id] {
                if peer.user == nil, peer.parent == nil, peer.loginAttempt != nil { appendHistory(kind: 191, peer: peer) }
                record("Connection closed: \(error.localizedDescription)")
            }
        }
        wire.close()
        let departed = peers.removeValue(forKey: id)
        if let user = departed?.user {
            appendHistory(kind: 185, peer: departed, detail: departed?.wire.endpointDescription ?? "")
            for peer in peers.values where peer.parent == id { peer.wire.close() }
            users.removeAll { $0.id == user.id }
            removeEmptyPrivateChats()
            await broadcast(type: 104, payload: user.id.beBytes + [7,0,0,0])
            record("\(user.nickname) disconnected")
        }
        await publishHistory()
    }
    private func handle(_ message: Message, id: UUID, wire: WireConnection) async throws {
        let b = message.payload, tx = message.transaction
        if let parentID = peers[id]?.parent {
            guard let parent = peers[parentID], parent.user != nil else { throw KDXError.authentication }
            try await handleTransfer(message, wire: wire, parent: parent)
            return
        }
        if message.type != 108 { peers[id]?.lastActivity = ServerAccount.now }
        if message.type == 100 {
            var (user, _) = try KDXUser.decode(b)
            guard !user.nickname.isEmpty else { throw KDXError.remote(0x1000a) }
            wire.ioTimeout = nil
            let old = peers[id]?.user
            user.id = old?.id ?? nextUser
            if old == nil { nextUser = nextUser &+ 1; if nextUser == 0 { nextUser = 1 } }
            user.isAdmin = privileges(for: peers[id]).contains(0)
            user.server15 = 0; user.server16 = 0; user.flags &= 4; user.extra = []
            user.info.unicodeScalars.removeAll { $0.value == 13 || $0.value == 10 || $0.value == 9 }
            if !privileges(for: peers[id]).contains(60) { user.nickname = peers[id]?.account?.name ?? "Guest" }
            peers[id]?.user = user; users.removeAll { $0.id == user.id }; users.append(user)
            if old == nil {
                peers[id]?.loginTime = ServerAccount.now
                let info = ServerInfo(name: configuration.name, description: configuration.description, userID: user.id, canModifySettings: privileges(for: peers[id]).contains(61), sessionKey: peers[id]?.sessionKey ?? [])
                try await wire.send(type: 105, payload: info.encode())
                if configuration.greetingEnabled && !configuration.greeting.isEmpty && !privileges(for: peers[id]).contains(62) { try await wire.send(type: 107, payload: [0,0,0,0] + Array(configuration.greeting.utf8)) }
                let icon = try configuration.remoteSettings().icon
                if !icon.isEmpty { try await wire.send(type: 106, payload: icon) }
                try await wire.send(type: 101, payload: KDXUser.encodeList(users))
                appendHistory(kind: 184, peer: peers[id])
                record("\(user.nickname) connected")
            } else { appendHistory(kind: 100, peer: peers[id]) }
            await broadcast(type: old == nil ? 103 : 102, payload: try user.encode(), excluding: old == nil ? id : nil)
            return
        }
        guard let user = peers[id]?.user else { throw KDXError.remote(0x10014) }
        if [UInt32(502), 504, 505, 507, 508, 509, 511, 512, 550].contains(message.type) {
            try await handleAccounts(message, id: id, wire: wire)
            return
        }
        switch message.type {
        case 110:
            try b.require(4)
            if user.status != b[0] {
                var updated = user; updated.status = b[0]; peers[id]?.user = updated
                if let index = users.firstIndex(where: { $0.id == user.id }) { users[index] = updated }
                await broadcast(type: 111, payload: user.id.beBytes + [b[0],0,0,0])
            }
        case 140:
            try requirePrivilege(40, peer: peers[id]); peers[id]?.monitoringConnections = true
        case 141:
            peers[id]?.monitoringConnections = false
        case 142:
            try requirePrivilege(40, peer: peers[id])
            guard peers[id]?.monitoringConnections == true else { throw KDXError.remote(0x10003) }
            let entries = peers.values.compactMap { peer -> MonitoredConnection? in
                guard let user = peer.user else { return nil }
                return MonitoredConnection(userID: user.id, nickname: user.nickname, login: peer.account?.login ?? "guest",
                                           accountName: peer.account?.name ?? "Guest", address: peer.wire.endpointDescription,
                                           loginTime: peer.loginTime, lastActivity: peer.lastActivity)
            }.sorted { $0.userID < $1.userID }
            try await wire.send(type: 143, payload: MonitoredConnection.encodeList(entries), transaction: tx, reply: true)
        case 180:
            try requirePrivilege(63, peer: peers[id])
            appendHistory(kind: 180, peer: peers[id])
            peers[id]?.historyJoined = false
            let snapshot = history.map(\.entry), cursor = historySequence
            try await wire.send(type: 181, payload: RemoteHistoryEntry.encodeList(snapshot), transaction: tx, reply: true)
            peers[id]?.historyCursor = cursor; peers[id]?.historyJoined = true
        case 182:
            peers[id]?.historyJoined = false
        case 112:
            let text = configuration.greeting.isEmpty ? "(No greeting.)" : configuration.greetingEnabled ? configuration.greeting : "(Greeting disabled.)"
            try await wire.send(type: 107, payload: [0,0,0,0] + Array(text.utf8))
        case 170:
            try requirePrivilege(61, peer: peers[id])
            try await wire.send(type: 171, payload: configuration.remoteSettings().encode(), transaction: tx, reply: true)
        case 172:
            try requirePrivilege(61, peer: peers[id])
            var settings = try RemoteServerSettings(wire: b)
            if settings.icon.isEmpty { settings.icon = try configuration.remoteSettings().icon }
            var candidate = configuration
            candidate.name = settings.name; candidate.greeting = settings.greeting; candidate.greetingEnabled = settings.greetingEnabled
            candidate.downloadLimit = settings.downloadLimit; candidate.settingsBlob = try settings.encode()
            let rateChanged = candidate.downloadLimit != configuration.downloadLimit
            try commitConfiguration(candidate)
            if rateChanged {
                downloadLimiter.setRate(candidate.downloadLimit)
                for peer in peers.values where activeDownloads.contains(ObjectIdentifier(peer.wire)) { peer.wire.close() }
            }
            try await wire.send(type: 173, transaction: tx, reply: true)
            if rateChanged { await broadcast(type: 419, payload: configuration.downloadLimit.beBytes) }
            for peer in peers.values.filter({ $0.user != nil }) {
                let info = ServerInfo(name: configuration.name, description: configuration.description, userID: peer.user!.id, canModifySettings: privileges(for: peer).contains(61), sessionKey: peer.sessionKey)
                _ = try? await peer.wire.send(type: 105, payload: info.encode())
                _ = try? await peer.wire.send(type: 106, payload: settings.icon)
            }
            record("Updated server settings")
        case 150:
            try requirePrivilege(41, peer: peers[id])
            let request = try DisconnectRequest.decode(b)
            if request.banSeconds != 0 { try requirePrivilege(43, peer: peers[id]); throw KDXError.remote(0x10004) }
            guard let target = peers.values.first(where: { $0.user?.id == request.userID }) else { throw KDXError.remote(0x1000c) }
            // The reference's address-based exception is not decoded; protected users remain protected.
            guard !privileges(for: target).contains(42) else { throw KDXError.remote(0x10014) }
            if request.options & 1 == 0 {
                let notice = DisconnectNotice(senderID: user.id, reason: request.reason, sender: user.nickname)
                do { try await target.wire.send(type: 151, payload: notice.encode()) } catch { target.wire.close() }
            }
            target.wire.close()
            record("\(user.nickname) disconnected \(target.user?.nickname ?? "user")")
        case 154:
            try requirePrivilege(33, peer: peers[id])
            var notice = try BroadcastMessage.decode(b, received: false); notice.senderID = user.id
            await broadcast(type: 155, payload: try notice.encode(received: true))
        case 152:
            try requirePrivilege(40, peer: peers[id]); try b.require(4)
            guard let target = peers.values.first(where: { $0.user?.id == b.u32(0) }), let targetUser = target.user else { throw KDXError.remote(0x1000c) }
            let details = UserInformation(id: targetUser.id, loginTime: target.loginTime, time18: target.lastActivity,
                                          address: target.wire.endpointDescription, nickname: targetUser.nickname,
                                          name3f: target.account?.name ?? "Guest", login: target.account?.login ?? "guest",
                                          name41: configuration.accountClasses.first { $0.id == (target.account?.classID ?? 2) }?.name ?? "")
            try await wire.send(type: 153, payload: details.encode(), transaction: tx, reply: true)
        case 108: try await wire.send(type: 109, transaction: tx, reply: true)
        case 115:
            let address = Array(wire.endpointDescription.utf8.prefix(255))
            try await wire.send(type: 116, payload: [UInt8(address.count)] + address, transaction: tx, reply: true)
        case 600...612:
            try await handleNews(message, id: id, wire: wire)
        case 400:
            let files = try SharedFiles(path: configuration.sharedFolder).list(RemotePath(wire: b).names)
            try await wire.send(type: 401, payload: RemoteFile.encodeList(files), transaction: tx, reply: true)
        case 409:
            try requirePrivilege(20, peer: peers[id])
            let files = try SharedFiles(path: configuration.sharedFolder)
            try await wire.send(type: 410, payload: files.information(RemotePath(wire: b).names).encode(), transaction: tx, reply: true)
        case 200...220:
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
            activeDownloads.insert(ObjectIdentifier(wire))
            defer { activeDownloads.remove(ObjectIdentifier(wire)) }
            try requirePrivilege(10, peer: parent)
            let request = try DownloadRequest(wire: b)
            guard request.options == 0 else { throw KDXError.remote(0x10004) }
            let path = request.path
            let (handle, size) = try files.openFile(path.names)
            defer { try? handle.close() }
            let offset = request.alignedOffset(size: size), resourceSize = try ResourceFork.size(handle.fileDescriptor)
            let resourceOffset = DownloadRequest.alignedOffset(request.resourceOffset, size: resourceSize)
            guard size - offset <= UInt32.max, resourceSize - resourceOffset <= UInt32.max else { throw KDXError.invalid("File is too large for a KDX transfer.") }
            var info = DownloadInfo(dataSize: size, name: path.names.last ?? "")
            info.resourceSize = resourceSize
            info.strings[1] = FileKind.from(name: info.strings[0], isDirectory: false)
            var attributes = stat()
            guard fstat(handle.fileDescriptor, &attributes) == 0 else { throw POSIXError(.EIO) }
            info.created = KDXTime.encode(Date(timeIntervalSince1970: Double(attributes.st_birthtimespec.tv_sec) + Double(attributes.st_birthtimespec.tv_nsec)/1_000_000_000))
            info.modified = KDXTime.encode(Date(timeIntervalSince1970: Double(attributes.st_mtimespec.tv_sec) + Double(attributes.st_mtimespec.tv_nsec)/1_000_000_000))
            try await wire.send(type: 413, payload: info.encode(), transaction: tx, reply: true)
            if configuration.downloadLimit > 0 { try await parent.wire.send(type: 419, payload: configuration.downloadLimit.beBytes) }
            try handle.seek(toOffset: offset)
            try await wire.sendFile(type: 414, length: UInt32(size-offset), source: handle, transaction: tx, reply: true, limiter: downloadLimiter)
            try await wire.sendFile(type: 414, length: UInt32(resourceSize-resourceOffset), source: handle, resourceOffset: resourceOffset, limiter: downloadLimiter)
            appendHistory(kind: 188, peer: parent, detail: path.names.joined(separator: "/"))
            record("Downloaded \(path.names.joined(separator: "/"))")
        case 415:
            try requirePrivilege(11, peer: parent)
            let request = try UploadRequest(wire: b)
            guard request.options == 0, request.resourceSize <= UInt32.max, request.dataSize <= UInt32.max else { throw KDXError.remote(0x10004) }
            // Anonymous sessions cannot resume one another's files.
            let owner = parent.account.map { $0.login + ":" + Data($0.key).base64EncodedString() }
            let upload = try PartialUpload(files: files, request: request, owner: owner)
            try await wire.send(type: 416, payload: UploadReply(dataOffset: upload.reportedOffset).encode(), transaction: tx, reply: true)
            let remaining = request.dataSize - upload.offset
            let length = try await wire.receiveFile(type: 417, sink: upload.handle, maximum: remaining)
            guard length == remaining else { throw KDXError.remote(0x40074) }
            let resourceLength = try await wire.receiveFile(type: 417, sink: upload.handle, maximum: request.resourceSize, resourceOffset: 0)
            guard resourceLength == request.resourceSize else { throw KDXError.remote(0x40074) }
            try upload.commit()
            try await wire.send(type: 418)
            appendHistory(kind: 189, peer: parent, detail: request.strings[0])
            record("Uploaded \(request.strings[0])")
        default: throw KDXError.remote(0x10004)
        }
    }
    private func appendHistory(kind: UInt32, peer: Peer? = nil, detail: String = "") {
        // Keep UTF-8 fields in their one-byte wire bounds without retaining message/password bodies.
        func bounded(_ value: String) -> String {
            var result = ""
            for scalar in value.unicodeScalars { if result.utf8.count + scalar.utf8.count > 255 { break }; result.unicodeScalars.append(scalar) }
            return result
        }
        let entry = RemoteHistoryEntry(kind: kind, userID: peer?.user?.id ?? 0, address: bounded(peer?.wire.endpointDescription ?? ""),
                                      nickname: bounded(peer?.user?.nickname ?? ""), login: bounded(peer?.account?.login ?? peer?.loginAttempt ?? (peer == nil ? "" : "guest")), detail: bounded(detail), time: ServerAccount.now)
        historySequence += 1; history.append((historySequence, entry))
        if history.count > 500 { history.removeFirst(history.count-500) }
    }
    private func historyDetail(_ message: Message) -> String {
        let b = message.payload
        switch message.type {
        case 201,202,204,209,211: return b.count >= 4 ? (try? chatRecord(b.u32(0)).name) ?? "" : ""
        case 400,409: return (try? RemotePath(wire: b).names.joined(separator: "/")) ?? ""
        case 412: return (try? DownloadRequest(wire: b).path.names.joined(separator: "/")) ?? ""
        case 415: return (try? UploadRequest(wire: b).strings[0]) ?? ""
        default: return ""
        }
    }
    private func publishHistory() async {
        for id in Array(peers.keys) {
            guard peers[id]?.historyJoined == true, peers[id]?.historySending == false else { continue }
            peers[id]?.historySending = true
            while let peer = peers[id], peer.historyJoined {
                guard privileges(for: peer).contains(63) else { peers[id]?.historyJoined = false; break }
                guard let next = history.first(where: { $0.sequence > peer.historyCursor }) else { break }
                peers[id]?.historyCursor = next.sequence
                do { try await peer.wire.send(type: 183, payload: next.entry.encode()) }
                catch { peer.wire.close(); break }
            }
            peers[id]?.historySending = false
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
        try validateGrant(account.effective(in: configuration.accountClasses), requester: requester)
    }
    private func validateGrant(_ granted: AccountPrivileges, requester: Peer?) throws {
        let allowed = privileges(for: requester)
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
        case 504:
            try requirePrivilege(52, peer: requester)
            var entry = try AccountClass.decode(b, info: true).0
            guard !entry.name.isEmpty, let index = configuration.accountClasses.firstIndex(where: { $0.id == entry.id }) else { throw KDXError.remote(0x10002) }
            try validateGrant(entry.privileges, requester: requester)
            entry.time = ServerAccount.now
            var candidate = configuration; candidate.accountClasses[index] = entry
            try commitConfiguration(candidate)
            let changed = peers.keys.filter { peers[$0]?.parent == nil && (peers[$0]?.account?.classID ?? 2) == entry.id }
            try await refreshPeerAccess(changed)
            try await wire.send(type: 1, payload: [UInt32(0), message.type].flatMap(\.beBytes), transaction: tx, reply: true)
            record("Updated account class \(entry.name)")
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
            for peerID in changed { peers[peerID]?.account = account }
            try await refreshPeerAccess(changed)
            try await wire.send(type: 1, payload: [UInt32(0), message.type].flatMap(\.beBytes), transaction: tx, reply: true)
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
    private func refreshPeerAccess(_ changed: [UUID]) async throws {
        var departures: [(UInt32, UInt32, WireConnection)] = []
        for peerID in changed {
            let oldRooms = peers[peerID]?.joined ?? []
            let effective = privileges(for: peers[peerID]), classID = peers[peerID]?.account?.classID ?? 2
            if !effective.contains(40) { peers[peerID]?.monitoringConnections = false }
            if !effective.contains(30) { peers[peerID]?.joined = [] }
            else { peers[peerID]?.joined = Set(oldRooms.filter { room in
                (try? chatRecord(room)).map { ChatRecord.permits($0.joinClasses, classID: classID) } ?? false
            }) }
            if let peer = peers[peerID], let userID = peer.user?.id {
                for roomID in oldRooms.subtracting(peer.joined) { departures.append((roomID, userID, peer.wire)) }
            }
            for attached in peers.values where attached.parent == peerID { attached.wire.close() }
            if var user = peers[peerID]?.user {
                user.isAdmin = effective.contains(0)
                if !effective.contains(60) { user.nickname = peers[peerID]?.account?.name ?? "Guest" }
                peers[peerID]?.user = user
                if let index = users.firstIndex(where: { $0.id == user.id }) { users[index] = user }
            }
        }
        removeEmptyPrivateChats()
        for (roomID, userID, departingWire) in departures { await notifyDeparture(roomID: roomID, userID: userID, wire: departingWire) }
        for peerID in changed {
            if let peer = peers[peerID], let user = peer.user {
                await broadcast(type: 102, payload: try user.encode())
                let info = ServerInfo(name: configuration.name, description: configuration.description, userID: user.id, canModifySettings: privileges(for: peer).contains(61), sessionKey: peer.sessionKey)
                _ = try? await peer.wire.send(type: 105, payload: info.encode())
            }
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
        guard let room = privateChats[roomID]?.room ?? configuration.chats.first(where: { $0.id == roomID }) else { throw KDXError.remote(0x1000c) }
        return room
    }
    private func handleChat(_ message: Message, id: UUID, wire: WireConnection) async throws {
        let b = message.payload, tx = message.transaction
        guard let peer = peers[id], let user = peer.user else { throw KDXError.disconnected }
        switch message.type {
        case 200:
            try requirePrivilege(34, peer: peer)
            guard b.isEmpty, privateChats.values.filter({ $0.owner == user.id }).count < 10 else { throw KDXError.remote(0x1000a) }
            var room = ChatRecord(name: "Private \(privateChats.values.filter { $0.owner == user.id }.count + 1)")
            repeat { room.id = UInt32.random(in: 4...UInt32.max) } while (try? chatRecord(room.id)) != nil
            room.key = UInt32.random(in: 1...UInt32.max)
            privateChats[room.id] = (room, user.id); peers[id]?.joined.insert(room.id)
            let window = ChatWindow(id: room.id, key: room.key, members: [user.id], strings: ["", "", room.name, "", ""])
            try await wire.send(type: 216, payload: window.encode(), transaction: tx, reply: true)
        case 211:
            let invite = try ChatInviteRequest.decode(b), room = try chatRecord(invite.roomID)
            guard peer.joined.contains(room.id) else { throw KDXError.remote(0x10014) }
            var invitation = ChatInvitation(roomID: room.id, key: room.key, inviterID: user.id, name: room.name)
            invitation.opaque.put(nextInvitation, at: 0); invitation.opaque.put(UInt16(1), at: 4)
            nextInvitation = nextInvitation == UInt32.max ? 1 : nextInvitation + 1
            let payload = try invitation.encode()
            let targets = Set(invite.users)
            for target in peers.values.filter({ $0.user.map { targets.contains($0.id) } ?? false }).map(\.wire) {
                do { try await target.send(type: 212, payload: payload) } catch { target.close() }
            }
        case 214:
            let rooms = configuration.chats.map { room in
                ChatRoom(id: room.id, key: room.key, name: room.name, description: room.description,
                         memberCount: peers.values.filter { $0.joined.contains(room.id) }.count, flags: room.flags)
            }
            try await wire.send(type: 215, payload: ChatRoom.encodeList(rooms), transaction: tx, reply: true)
        case 202:
            try b.require(8); let room = try chatRecord(b.u32(0))
            try requireChatAccess(30, mask: room.joinClasses, peer: peer)
            guard (privateChats[room.id] == nil && room.flags & 1 == 0) || room.key == b.u32(4) else { throw KDXError.remote(0x10014) }
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
            removeEmptyPrivateChats()
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
            // Named-room administration does not create voice or private rooms.
            guard room.flags == 0, room.key == 0 else { throw KDXError.remote(0x10004) }
            guard !room.name.isEmpty else { throw KDXError.remote(0x1000a) }
            var candidate = configuration
            if message.type == 217 {
                repeat { room.id = UInt32.random(in: 4...UInt32.max) } while (try? chatRecord(room.id)) != nil
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
            if privateChats[room.id] != nil { privateChats.removeValue(forKey: room.id) }
            else { var candidate = configuration; candidate.chats.removeAll { $0.id == room.id }; try commitConfiguration(candidate) }
            let members = peers.values.filter { $0.joined.contains(room.id) }.map(\.wire)
            for peerID in peers.keys { peers[peerID]?.joined.remove(room.id) }
            chatTopics.removeValue(forKey: room.id)
            for member in members { do { try await member.send(type: 221, payload: room.id.beBytes + user.id.beBytes) } catch { member.close() } }
            try await wire.send(type: 1, payload: [UInt32(0), message.type].flatMap(\.beBytes), transaction: tx, reply: true)
            record("Deleted chat \(room.name)")
        default: throw KDXError.remote(0x10004)
        }
    }
    private func removeEmptyPrivateChats() {
        for roomID in Array(privateChats.keys) where !peers.values.contains(where: { $0.joined.contains(roomID) }) {
            privateChats.removeValue(forKey: roomID); chatTopics.removeValue(forKey: roomID)
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

extension KDXServer {
    private func newsPermissions(_ group: NewsGroupInfo, peer: Peer?) -> UInt32 {
        let access = privileges(for: peer), classID = peer?.account?.classID ?? 2
        let read = access.contains(70) && (access.contains(0) || ChatRecord.permits(group.readClasses, classID: classID))
        let post = access.contains(71) && (access.contains(0) || ChatRecord.permits(group.postClasses, classID: classID))
        return (read ? 4 : 0) | (post ? 1 : 0) | (access.contains(72) ? 2 : 0)
    }
    private func handleNews(_ message: Message, id: UUID, wire: WireConnection) async throws {
        let b = message.payload, tx = message.transaction
        guard let peer = peers[id], let user = peer.user else { throw KDXError.disconnected }
        switch message.type {
        case 600, 604:
            try requirePrivilege(73, peer: peer)
            _ = try news.saveGroup(NewsGroupInfo.decode(b), creating: message.type == 600)
            try await wire.send(type: 1, payload: [UInt32(0), message.type].flatMap(\.beBytes), transaction: tx, reply: true)
        case 601:
            try requirePrivilege(73, peer: peer); try b.require(4)
            try news.deleteGroup(b.u32(0))
            try await wire.send(type: 1, payload: [UInt32(0), message.type].flatMap(\.beBytes), transaction: tx, reply: true)
        case 602:
            try requirePrivilege(73, peer: peer); try b.require(4)
            try await wire.send(type: 603, payload: news.group(b.u32(0)).encode(), transaction: tx, reply: true)
        case 605:
            try requirePrivilege(70, peer: peer)
            let groups = try news.groups.map { value in
                let info = try news.group(value.id)
                return NewsGroup(id: info.id, name: info.name, count: Int(info.messageCount), description: info.description, time: info.time)
            }
            try await wire.send(type: 606, payload: NewsGroup.encodeList(groups), transaction: tx, reply: true)
        case 607:
            try b.require(4); let group = try news.group(b.u32(0)), permissions = newsPermissions(group, peer: peer)
            let posts = permissions & 4 == 0 ? [] : news.posts.filter { $0.groupID == group.id }
            var payload = [group.id, permissions, 0, UInt32(posts.count)].flatMap(\.beBytes)
            for post in posts { payload += try post.encode() }
            try await wire.send(type: 608, payload: payload, transaction: tx, reply: true)
        case 609:
            try b.require(8); let group = try news.group(b.u32(0))
            guard newsPermissions(group, peer: peer) & 4 != 0 else { throw KDXError.remote(0x10014) }
            guard let post = news.posts.first(where: { $0.groupID == group.id && $0.id == b.u32(4) }) else { throw KDXError.remote(0x1000c) }
            try await wire.send(type: 610, payload: post.encode(), transaction: tx, reply: true)
        case 611:
            try b.require(16); let group = try news.group(b.u32(0))
            guard newsPermissions(group, peer: peer) & 1 != 0 else { throw KDXError.remote(0x10014) }
            let subjectLength = Int(b[14]), bodyLength = Int(b.u16(12)); try b.require(16+subjectLength+bodyLength)
            let post = try news.add(groupID: group.id, author: user.nickname, login: peer.account?.login ?? "guest", subject: b.text(16..<16+subjectLength), body: b.text(16+subjectLength..<16+subjectLength+bodyLength))
            let payload = [group.id, post.id, UInt32(try news.group(group.id).messageCount)].flatMap(\.beBytes)
            let readers = peers.values.filter { $0.user != nil && newsPermissions(group, peer: $0) & 4 != 0 }.map(\.wire)
            for reader in readers { do { try await reader.send(type: 613, payload: payload) } catch { reader.close() } }
        case 612:
            try b.require(8)
            guard let group = try? news.group(b.u32(0)), news.posts.contains(where: { $0.groupID == group.id && $0.id == b.u32(4) }) else { return }
            let access = privileges(for: peer)
            guard access.contains(0) || ChatRecord.permits(group.readClasses, classID: peer.account?.classID ?? 2) else { throw KDXError.remote(0x10014) }
            try news.delete(groupID: group.id, id: b.u32(4), login: peer.account?.login ?? "guest", admin: access.contains(72))
            await broadcast(type: 614, payload: [group.id, b.u32(4), UInt32(try news.group(group.id).messageCount)].flatMap(\.beBytes))
        default: throw KDXError.remote(0x10004)
        }
    }
}
