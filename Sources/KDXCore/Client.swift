import Foundation
import Observation

@Observable @MainActor public final class KDXClient {
    public private(set) var state = "Disconnected"
    public private(set) var isConnected = false
    public private(set) var isConnecting = false
    public private(set) var serverInfo: ServerInfo?
    public private(set) var users: [KDXUser] = []
    public private(set) var rooms: [ChatRoom] = []
    public private(set) var chat: [ChatLine] = []
    public private(set) var joinedRoom: UInt32?
    public private(set) var lastError: String?
    public private(set) var newsGroups: [NewsGroup] = []
    public private(set) var newsPosts: [NewsPost] = []
    public private(set) var newsPermissions: UInt32 = 0
    public private(set) var newsRevision = 0
    private var checkedTransactions: Set<UInt32> = []
    private var operationErrors: [UInt32: Error] = [:]
    public private(set) var files: [RemoteFile] = []
    public private(set) var filePath: [String] = []
    public private(set) var transferProgress: Double = 0
    public private(set) var transferStatus: String?
    private var transferFactory: (() throws -> WireConnection)?
    private var activeTransfer: WireConnection?
    private var table: ChallengeTable?
    private var connection: WireConnection?
    private var receiveTask: Task<Void, Never>?
    private var pending: [UInt32: CheckedContinuation<Message, Error>] = [:]
    public init() {}
    public func connect(host: String, port: UInt16, login: String, password: String, nickname: String, table: ChallengeTable) async throws {
        try await connect(wire: WireConnection(host: host, port: port), login: login, password: password, nickname: nickname, table: table)
        transferFactory = { try WireConnection(host: host, port: port) }
    }
    func connect(wire: WireConnection, login: String, password: String, nickname: String, table: ChallengeTable) async throws {
        disconnect()
        self.table = table
        connection = wire; isConnecting = true; state = "Connecting…"; lastError = nil
        do {
            try await wire.start()
            guard connection === wire else { throw KDXError.disconnected }
            state = "Authenticating…"
            try await wire.authenticateClient(name: Array(login.utf8), key: AccountKey(password: password), table: table)
            try await wire.send(type: 100, payload: KDXUser(nickname: nickname.isEmpty ? (login.isEmpty ? "Guest" : login) : nickname).encode())
            let timeout = Task { try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled { wire.close() } }
            defer { timeout.cancel() }
            var gotUsers = false
            while serverInfo == nil || !gotUsers {
                let message = try await wire.receive()
                guard connection === wire else { throw KDXError.disconnected }
                if message.type == 1 { try checkStatus(message) }
                try handle(message)
                if message.type == 101 { gotUsers = true }
            }
            guard connection === wire else { throw KDXError.disconnected }
            isConnecting = false; isConnected = true; state = "Connected"
            receiveTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await wire.receive()
                        guard let self, self.connection === wire else { return }
                        if message.isReply, let continuation = self.pending.removeValue(forKey: message.transaction) {
                            do { try self.checkStatus(message); continuation.resume(returning: message) }
                            catch { continuation.resume(throwing: error) }
                        } else { try self.handle(message) }
                    }
                } catch {
                    guard let self, self.connection === wire else { return }
                    self.disconnect(); self.lastError = error.localizedDescription
                }
            }
            try await refreshRooms()
            try await join(room: 1)
        } catch {
            if connection === wire { disconnect(); lastError = error.localizedDescription }
            throw error
        }
    }
    public func disconnect() {
        activeTransfer?.close(); activeTransfer = nil; transferFactory = nil; table = nil
        files = []; filePath = []; transferStatus = nil; newsGroups = []; newsPosts = []; checkedTransactions = []; operationErrors = [:]
        connection?.close(); connection = nil; receiveTask?.cancel(); receiveTask = nil
        for continuation in pending.values { continuation.resume(throwing: KDXError.disconnected) }; pending.removeAll()
        isConnected = false; isConnecting = false; state = "Disconnected"
        serverInfo = nil; users = []; rooms = []; joinedRoom = nil; chat = []
    }
    func checkStatus(_ message: Message) throws {
        guard message.type == 1 else { return }
        let b = message.payload
        guard b.count == 8 || b.count == 24 else { throw KDXError.invalid("Invalid status reply.") }
        if b.u32(0) != 0 { throw KDXError.remote(b.u32(0)) }
    }
    public func request(type: UInt32, payload: [UInt8] = []) async throws -> Message {
        guard let wire = connection, isConnected else { throw KDXError.disconnected }
        let transaction = wire.allocateTransaction()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[transaction] = continuation
                Task {
                    do { try await wire.send(type: type, payload: payload, transaction: transaction) }
                    catch { self.pending.removeValue(forKey: transaction)?.resume(throwing: error) }
                }
                Task {
                    try? await Task.sleep(for: .seconds(15))
                    self.pending.removeValue(forKey: transaction)?.resume(throwing: KDXError.invalid("The server did not reply in time."))
                }
            }
        } onCancel: {
            Task { @MainActor in self.pending.removeValue(forKey: transaction)?.resume(throwing: CancellationError()) }
        }
    }
    public func refreshRooms() async throws { rooms = try ChatRoom.list(await request(type: 214).payload) }
    public func join(room: UInt32, key: UInt32 = 0) async throws {
        let response = try await request(type: 202, payload: room.beBytes + key.beBytes)
        guard response.type == 203 else { throw KDXError.invalid("Unexpected join reply.") }
        try response.payload.require(36)
        let previous = joinedRoom; joinedRoom = room; chat.removeAll()
        if let previous, previous != room { try await connection?.send(type: 204, payload: previous.beBytes) }
    }
    public func sendChat(_ text: String) async throws {
        guard let connection, let room = joinedRoom else { throw KDXError.disconnected }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 4096 else { throw KDXError.invalid("Chat text must contain 1–4096 UTF-8 bytes.") }
        try await connection.send(type: 207, payload: room.beBytes + [UInt8](repeating: 0, count: 8) + bytes)
    }
    public func sendPrivate(to id: UInt32, text: String) async throws {
        guard let connection else { throw KDXError.disconnected }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 4096 else { throw KDXError.invalid("Message must contain 1–4096 UTF-8 bytes.") }
        try await connection.send(type: 300, payload: id.beBytes + [UInt8](repeating: 0, count: 12) + bytes)
        chat.append(ChatLine(userID: id, sender: "To \(users.first { $0.id == id }?.nickname ?? String(id))", text: text, isPrivate: true))
    }
    public func loadNewsGroups() async throws { newsGroups = try NewsGroup.decodeList(await request(type: 605).payload) }
    public func loadNews(group: UInt32 = 1) async throws {
        let response = try await request(type: 607, payload: group.beBytes)
        newsPosts = try NewsPost.decodeList(response.payload).sorted { $0.date > $1.date }
        newsPermissions = response.payload.u32(4)
    }
    public func postNews(group: UInt32 = 1, subject: String, body: String) async throws {
        let subjectBytes = Array(subject.utf8), bodyBytes = Array(body.utf8)
        guard !subjectBytes.isEmpty, subjectBytes.count <= 128, !bodyBytes.isEmpty, bodyBytes.count <= 16384 else { throw KDXError.invalid("Use a subject of 1–128 bytes and a body of 1–16384 bytes.") }
        var payload = [UInt8](repeating: 0, count: 16)
        payload.put(group, at: 0); payload.put(UInt16(bodyBytes.count), at: 12); payload[14] = UInt8(subjectBytes.count)
        payload += subjectBytes + bodyBytes; payload.pad(4)
        try await sendChecked(type: 611, payload: payload)
        try await loadNews(group: group)
    }
    public func deleteNews(_ post: NewsPost) async throws {
        try await sendChecked(type: 612, payload: post.groupID.beBytes + post.id.beBytes)
        try await loadNews(group: post.groupID)
    }
    private func sendChecked(type: UInt32, payload: [UInt8]) async throws {
        guard let connection else { throw KDXError.disconnected }
        let tx = connection.allocateTransaction(); checkedTransactions.insert(tx)
        defer { checkedTransactions.remove(tx); operationErrors.removeValue(forKey: tx) }
        try await connection.send(type: type, payload: payload, transaction: tx)
        // KDX mutations often have no success reply. This round trip is an ordering barrier.
        _ = try await request(type: 115)
        if let error = operationErrors[tx] { throw error }
    }
    func setTransferFactory(_ factory: @escaping () throws -> WireConnection) { transferFactory = factory }
    public func listFiles(path: [String] = []) async throws {
        let response = try await request(type: 400, payload: RemotePath(path).encode())
        let entries = try RemoteFile.decodeList(response.payload)
        files = entries; filePath = path
    }
    public func cancelTransfer() { activeTransfer?.close() }
    private func attach() async throws -> WireConnection {
        guard let info = serverInfo, let table, let factory = transferFactory else { throw KDXError.disconnected }
        guard activeTransfer == nil else { throw KDXError.invalid("A transfer is already running.") }
        let wire = try factory(); activeTransfer = wire
        do {
            try await wire.start()
            try await wire.authenticateClient(name: [0] + info.userID.beBytes, key: AccountKey(bytes: info.sessionKey), table: table)
            return wire
        } catch { wire.close(); activeTransfer = nil; throw error }
    }
    public func download(_ file: RemoteFile, to destination: URL) async throws {
        let wire = try await attach()
        defer { wire.close(); activeTransfer = nil; transferStatus = nil }
        transferStatus = "Downloading \(file.name)"; transferProgress = 0
        let parent = destination.deletingLastPathComponent()
        let store = try SharedFiles(path: parent.path)
        let staging = try store.beginUpload(folder: [], name: destination.lastPathComponent)
        let request = [UInt8](repeating: 0, count: 24) + (try RemotePath(filePath + [file.name]).encode())
        let tx = try await wire.send(type: 412, payload: request)
        let info = try await wire.receive(); try checkStatus(info)
        guard info.type == 413, info.transaction == tx, info.isReply else { throw KDXError.invalid("Unexpected download reply.") }
        try info.payload.require(76)
        let size = info.payload.u64(0), resourceSize = info.payload.u64(8)
        guard size <= UInt32.max, resourceSize == 0 else { throw KDXError.invalid("This transfer requires unsupported resource-fork handling or exceeds 4 GiB.") }
        let count = try await wire.receiveFile(type: 414, sink: staging.handle, maximum: size, transaction: tx) { value in self.transferProgress = size == 0 ? 1 : Double(value)/Double(size) }
        guard count == size else { throw KDXError.invalid("Incomplete download.") }
        _ = try await wire.receiveFile(type: 414, sink: nil, maximum: 0)
        try staging.commit(); transferProgress = 1
    }
    public func upload(from source: URL) async throws {
        let wire = try await attach()
        defer { wire.close(); activeTransfer = nil; transferStatus = nil }
        transferStatus = "Uploading \(source.lastPathComponent)"; transferProgress = 0
        let store = try SharedFiles(path: source.deletingLastPathComponent().path)
        let (handle, size) = try store.openFile([source.lastPathComponent]); defer { try? handle.close() }
        guard size <= UInt32.max else { throw KDXError.invalid("The KDX transfer limit is 4 GiB.") }
        let name = try shortText(source.lastPathComponent), path = try RemotePath(filePath).encode()
        guard path.count <= UInt16.max else { throw KDXError.invalid("Path is too long.") }
        var payload = [UInt8](repeating: 0, count: 76)
        payload.put(size, at: 0); payload.put(UInt16(path.count), at: 70); payload[72] = UInt8(name.count)
        payload += name + path
        let tx = try await wire.send(type: 415, payload: payload)
        let reply = try await wire.receive(); try checkStatus(reply)
        guard reply.type == 416, reply.transaction == tx, reply.isReply else { throw KDXError.invalid("Unexpected upload reply.") }
        try reply.payload.require(24); let offset = reply.payload.u64(0)
        guard offset <= size else { throw KDXError.invalid("Invalid upload resume offset.") }
        try handle.seek(toOffset: offset)
        try await wire.sendFile(type: 417, length: UInt32(size-offset), source: handle) { value in self.transferProgress = size == 0 ? 1 : Double(offset+value)/Double(size) }
        try await wire.sendFile(type: 417, length: 0, source: nil)
        let complete = try await wire.receive(); try checkStatus(complete)
        guard complete.type == 418 else { throw KDXError.invalid("Upload was not acknowledged.") }
        transferProgress = 1
        try await listFiles(path: filePath)
    }
    private func handle(_ message: Message) throws {
        let b = message.payload
        switch message.type {
        case 1:
            do { try checkStatus(message) } catch {
                if checkedTransactions.contains(message.transaction) { operationErrors[message.transaction] = error }
                else { lastError = error.localizedDescription }
            }
        case 613, 614: newsRevision += 1
        case 101: users = try KDXUser.list(b)
        case 102, 103:
            let (user, _) = try KDXUser.decode(b); users.removeAll { $0.id == user.id }; users.append(user)
        case 104: try b.require(4); users.removeAll { $0.id == b.u32(0) }
        case 105: serverInfo = try ServerInfo.decode(b)
        case 208:
            try b.require(12)
            guard b.u32(0) == joinedRoom else { return }
            appendLine(id: b.u32(4), text: b.text(12..<b.count), privateMessage: false)
        case 301:
            try b.require(17); appendLine(id: b.u32(0), text: b.text(16..<b.count), privateMessage: true)
        default: break
        }
    }
    private func appendLine(id: UInt32, text: String, privateMessage: Bool) {
        chat.append(ChatLine(userID: id, sender: users.first { $0.id == id }?.nickname ?? "User \(id)", text: text, isPrivate: privateMessage))
        if chat.count > 2000 { chat.removeFirst(chat.count - 2000) }
    }
}
