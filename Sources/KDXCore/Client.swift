import Foundation
import Observation

@Observable @MainActor public final class KDXClient {
    public private(set) var state = "Disconnected"
    public private(set) var isConnected = false
    public private(set) var isConnecting = false
    public private(set) var serverInfo: ServerInfo?
    public private(set) var users: [KDXUser] = []
    public var currentUser: KDXUser? { users.first { $0.id == serverInfo?.userID } }
    public private(set) var rooms: [ChatRoom] = []
    private var chatLines: [ChatLine] = []
    public var chat: [ChatLine] { chatLines.filter { $0.isPrivate || $0.roomID == joinedRoom } }
    // joinedRoom is the selected room; joinedRooms tracks every open membership.
    public private(set) var joinedRoom: UInt32?
    public private(set) var joinedRooms: [UInt32: ChatWindow] = [:]
    public var chatWindow: ChatWindow? { joinedRoom.flatMap { joinedRooms[$0] } }
    public private(set) var unreadRooms: [UInt32: Int] = [:]
    private var roomTokens: [UInt32: UUID] = [:]
    private var leavingRooms: [UInt32: UUID] = [:]
    public func messages(in room: UInt32) -> [ChatLine] { chatLines.filter { $0.roomID == room } }
    public private(set) var chatTopics: [UInt32: ChatTopic] = [:]
    public private(set) var chatInvitations: [ChatInvitation] = []
    public private(set) var history: [RemoteHistoryEntry] = []
    public private(set) var isViewingHistory = false
    private var connectionMonitorToken: UUID?
    private var historyLoadToken: UUID?
    private var historyLoaded = false
    public private(set) var greeting: String?
    public private(set) var serverIcon: [UInt8] = []
    public private(set) var serverDownloadLimit: UInt32 = 0
    public private(set) var broadcasts: [BroadcastMessage] = []
    public private(set) var disconnectNotice: DisconnectNotice?
    private var joining: UUID?
    private var initializingSession = false
    private var publicChatRequested = false
    private var publicChatJoinTask: Task<Void, Never>?
    private var publicChatJoinToken: UUID?
    public private(set) var lastError: String?
    public private(set) var accounts: [AccountListEntry] = []
    public private(set) var accountClasses: [AccountClass] = []
    public private(set) var sessionLogin = ""
    public private(set) var newsGroups: [NewsGroup] = []
    public private(set) var newsPosts: [NewsPost] = []
    public private(set) var newsPermissions: UInt32 = 0
    public private(set) var newsRevision = 0
    public private(set) var newsGroupID: UInt32?
    private var newsLoadToken: UUID?
    private final class CheckedOperation {
        var error: Error?
        var confirmed = false
        var disconnectingSelf = false
        let deletedLogin: String?
        init(deletedLogin: String?) { self.deletedLogin = deletedLogin }
    }
    private var checkedOperations: [UInt32: CheckedOperation] = [:]
    public private(set) var files: [RemoteFile] = []
    public private(set) var filePath: [String] = []
    public private(set) var transferProgress: Double = 0
    public private(set) var transferStatus: String?
    private var transferFactory: (() throws -> WireConnection)?
    private var activeTransfer: WireConnection?
    private var table: ChallengeTable?
    private var connection: WireConnection?
    private var receiveTask: Task<Void, Never>?
    private struct PendingRequest {
        let token: UUID
        var historyLoadToken: UUID?
        let continuation: CheckedContinuation<Message, Error>
        var timeout: Task<Void, Never>?
    }
    private var pending: [UInt32: PendingRequest] = [:]
    var requestTimeout: Duration = .seconds(15)
    public init() {}
    public func connect(host: String, port: UInt16, login: String, password: String, nickname: String, info: String = "", autoJoinPublicChat: Bool = true, table: ChallengeTable) async throws {
        let wire = try WireConnection(host: host, port: port)
        try await connect(wire: wire, login: login, password: password, nickname: nickname, info: info, autoJoinPublicChat: autoJoinPublicChat, table: table)
        guard connection === wire else { throw KDXError.disconnected }
        transferFactory = { try WireConnection(host: host, port: port) }
    }
    func connect(wire: WireConnection, login: String, password: String, nickname: String, info: String = "", autoJoinPublicChat: Bool = true, table: ChallengeTable) async throws {
        disconnect()
        self.table = table; sessionLogin = login; greeting = nil; serverIcon = []; serverDownloadLimit = 0; disconnectNotice = nil; broadcasts = []
        connection = wire; initializingSession = true; isConnecting = true; state = "Connecting…"; lastError = nil
        do {
            try await wire.start()
            guard connection === wire else { throw KDXError.disconnected }
            state = "Authenticating…"
            try await wire.authenticateClient(name: Array(login.utf8), key: AccountKey(password: password), table: table)
            try await wire.send(type: 100, payload: KDXUser(nickname: nickname.isEmpty ? (login.isEmpty ? "Guest" : login) : nickname, info: info).encode())
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
                        let message = try await wire.receive(newsLimit: 0x4000000)
                        guard let self, self.connection === wire else { return }
                        if message.isReply, let request = self.pending.removeValue(forKey: message.transaction) {
                            request.timeout?.cancel()
                            do {
                                try self.checkStatus(message)
                                if message.type == 181, self.isViewingHistory, request.historyLoadToken == self.historyLoadToken {
                                    self.history = Array(try RemoteHistoryEntry.decodeList(message.payload).suffix(500)); self.historyLoaded = true
                                }
                                if message.type == 203 || message.type == 216 { try self.installChatWindow(message.payload) }
                                request.continuation.resume(returning: message)
                            }
                            catch { request.continuation.resume(throwing: error) }
                        } else { try self.handle(message) }
                    }
                } catch {
                    guard let self, self.connection === wire else { return }
                    self.disconnect(); self.lastError = error.localizedDescription
                }
            }
            do {
                try await refreshRooms()
                let shouldJoin = autoJoinPublicChat || publicChatRequested
                publicChatRequested = false
                if shouldJoin { try await join(room: 1) }
            }
            catch KDXError.remote(let code) where code == 0x10014 { publicChatRequested = false; joinedRoom = nil }
            guard connection === wire else { throw KDXError.disconnected }
            initializingSession = false; schedulePublicChatJoin()
        } catch {
            if connection === wire { disconnect(); lastError = error.localizedDescription }
            throw error
        }
    }
    public func disconnect() {
        publicChatJoinTask?.cancel(); publicChatJoinTask = nil; publicChatJoinToken = nil
        publicChatRequested = false; initializingSession = false
        activeTransfer?.close(); activeTransfer = nil; transferFactory = nil; table = nil
        connectionMonitorToken = nil
        history = []; isViewingHistory = false; historyLoadToken = nil; historyLoaded = false
        accounts = []; accountClasses = []; sessionLogin = ""
        files = []; filePath = []; transferStatus = nil; newsGroups = []; newsPosts = []; newsPermissions = 0; newsGroupID = nil; newsLoadToken = nil; checkedOperations = [:]
        connection?.close(); connection = nil; receiveTask?.cancel(); receiveTask = nil
        for request in pending.values { request.timeout?.cancel(); request.continuation.resume(throwing: KDXError.disconnected) }; pending.removeAll()
        isConnected = false; isConnecting = false; state = "Disconnected"
        serverInfo = nil; users = []; rooms = []; joinedRoom = nil; joinedRooms = [:]; unreadRooms = [:]; roomTokens = [:]; leavingRooms = [:]; chatTopics = [:]; chatInvitations = []; joining = nil; chatLines = []
    }
    func checkStatus(_ message: Message) throws {
        guard message.type == 1 else { return }
        let b = message.payload
        guard b.count == 8 || b.count == 24 else { throw KDXError.invalid("Invalid status reply.") }
        if b.u32(0) != 0 { throw KDXError.remote(b.u32(0)) }
    }
    public func request(type: UInt32, payload: [UInt8] = []) async throws -> Message {
        try Task.checkCancellation()
        guard let wire = connection, isConnected else { throw KDXError.disconnected }
        guard pending.count < 256 else { throw KDXError.invalid("Too many pending requests.") }
        var transaction = wire.allocateTransaction()
        while pending[transaction] != nil { transaction = wire.allocateTransaction() }
        let tx = transaction, token = UUID()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[tx] = PendingRequest(token: token, historyLoadToken: type == 180 ? historyLoadToken : nil, continuation: continuation)
                Task {
                    do { try await wire.send(type: type, payload: payload, transaction: tx) }
                    catch { self.failRequest(tx, token: token, error: error) }
                }
                pending[tx]?.timeout = Task { [weak self, requestTimeout] in
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    self?.failRequest(tx, token: token, error: KDXError.invalid("The server did not reply in time."))
                }
            }
        } onCancel: {
            Task { @MainActor in self.failRequest(tx, token: token, error: CancellationError()) }
        }
        try Task.checkCancellation()
        guard connection === wire else { throw KDXError.disconnected }
        return response
    }
    private func failRequest(_ transaction: UInt32, token: UUID, error: Error) {
        guard pending[transaction]?.token == token, let request = pending.removeValue(forKey: transaction) else { return }
        request.timeout?.cancel(); request.continuation.resume(throwing: error)
    }
    public func updateProfile(nickname: String, info: String) async throws {
        guard let user = currentUser else { throw KDXError.disconnected }
        try await updateProfile(nickname:nickname,info:info,colors:user.colors,icon:user.icon,gradient:user.flags & 4 != 0)
    }
    public func updateProfile(nickname: String, info: String, colors: [UInt8], icon: [UInt8], gradient: Bool) async throws {
        guard var user = currentUser else { throw KDXError.disconnected }
        guard !nickname.isEmpty else { throw KDXError.invalid("Enter a nickname.") }
        user.id = 0; user.nickname = nickname; user.info = info
        user.colors = colors; user.icon = icon
        user.badge = 0; user.server15 = 0; user.server16 = 0; user.flags = gradient ? 4 : 0
        try await sendChecked(type: 100, payload: user.encode())
    }
    public func setStatus(_ status: UInt8) async throws {
        try await sendChecked(type: 110, payload: [status,0,0,0])
    }
    public func startHistory() async throws {
        guard !isViewingHistory else { return }
        let token = UUID(); historyLoadToken = token; historyLoaded = false
        isViewingHistory = true; history = []
        do {
            let reply = try await request(type: 180)
            guard reply.type == 181 else { throw KDXError.invalid("Unexpected server-history reply.") }
        } catch {
            if historyLoadToken == token { isViewingHistory = false; historyLoadToken = nil; historyLoaded = false }
            throw error
        }
    }
    public func stopHistory() async throws {
        isViewingHistory = false; historyLoadToken = nil; historyLoaded = false
        if isConnected { try await sendChecked(type: 182, payload: []) }
    }
    public func serverSettings() async throws -> RemoteServerSettings {
        let reply = try await request(type: 170)
        guard reply.type == 171 else { throw KDXError.invalid("Unexpected server-settings reply.") }
        return try RemoteServerSettings(wire: reply.payload)
    }
    public func updateServerSettings(_ settings: RemoteServerSettings) async throws {
        let reply = try await request(type: 172, payload: settings.encode())
        guard reply.type == 173, reply.payload.isEmpty else { throw KDXError.invalid("Unexpected server-settings confirmation.") }
    }
    public func loadGreeting() async throws { try await sendChecked(type: 112, payload: []) }
    public func sendBroadcast(_ text: String) async throws {
        guard !text.isEmpty else { throw KDXError.invalid("Enter a broadcast message.") }
        try await sendChecked(type: 154, payload: BroadcastMessage(text: text).encode(received: false))
    }
    public func disconnectUser(id: UInt32, reason: String = "", quietly: Bool = false) async throws {
        guard !(quietly && id == serverInfo?.userID) else { throw KDXError.invalid("Self-disconnection requires a notice to confirm completion.") }
        let request = DisconnectRequest(userID: id, options: quietly ? 1 : 0, reason: reason)
        try await sendChecked(type: 150, payload: request.encode())
    }
    public func userInformation(id: UInt32) async throws -> UserInformation {
        let response = try await request(type: 152, payload: id.beBytes)
        guard response.type == 153 else { throw KDXError.invalid("Unexpected user-information reply.") }
        return try UserInformation.decode(response.payload)
    }
    public func connectionMonitor() async throws -> [MonitoredConnection] {
        try Task.checkCancellation()
        guard let wire = connection, isConnected else { throw KDXError.disconnected }
        guard connectionMonitorToken == nil else { throw KDXError.invalid("The connection monitor is already refreshing.") }
        let token = UUID(); connectionMonitorToken = token
        defer { if connectionMonitorToken == token { connectionMonitorToken = nil } }
        do {
            try await sendChecked(type: 140, payload: [])
            let reply = try await request(type: 142)
            guard reply.type == 143 else { throw KDXError.invalid("Unexpected connection-monitor reply.") }
            let entries = try MonitoredConnection.decodeList(reply.payload)
            try await sendChecked(type: 141, payload: [])
            return entries
        } catch {
            // Cleanup must run outside a cancelled caller's task, and only on this session.
            try? await Task { @MainActor in
                guard self.connection === wire else { return }
                try await self.sendChecked(type: 141, payload: [])
            }.value
            throw error
        }
    }
    public func refreshRooms() async throws {
        let response = try await request(type: 214)
        guard response.type == 215 else { throw KDXError.invalid("Unexpected chat-list reply.") }
        rooms = try ChatRoom.list(response.payload)
        for window in joinedRooms.values.sorted(by: { $0.id < $1.id }) where !rooms.contains(where: { $0.id == window.id }) {
            rooms.append(ChatRoom(id: window.id, key: window.key, name: window.name, description: "Private chat", memberCount: window.members.count, flags: 1))
        }
    }
    public func join(room: UInt32, key: UInt32 = 0) async throws {
        guard leavingRooms[room] == nil else { throw KDXError.invalid("The room is still closing.") }
        guard joining == nil else { throw KDXError.invalid("A room is already being opened.") }
        if joinedRooms[room] != nil { joinedRoom = room; unreadRooms.removeValue(forKey: room); return }
        let token = UUID(); joining = token
        defer { if joining == token { joining = nil; schedulePublicChatJoin() } }
        let response = try await request(type: 202, payload: room.beBytes + key.beBytes)
        guard response.type == 203, chatWindow?.id == room else { throw KDXError.invalid("Unexpected join reply.") }
    }
    private func schedulePublicChatJoin() {
        guard publicChatRequested, !initializingSession, joining == nil, publicChatJoinTask == nil,
              isConnected, let wire = connection else { return }
        publicChatRequested = false
        let token = UUID(); publicChatJoinToken = token
        publicChatJoinTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.publicChatJoinToken == token {
                    self.publicChatJoinTask = nil; self.publicChatJoinToken = nil; self.schedulePublicChatJoin()
                }
            }
            guard self.connection === wire else { return }
            if self.joining != nil { self.publicChatRequested = true; return }
            do { try await self.join(room: 1) }
            catch { if self.connection === wire, !Task.isCancelled { self.lastError = error.localizedDescription } }
        }
    }
    private func installChatWindow(_ payload: [UInt8]) throws {
        let window = try ChatWindow.decode(payload)
        joinedRooms[window.id] = window; roomTokens[window.id] = UUID(); joinedRoom = window.id; unreadRooms.removeValue(forKey: window.id)
        if !rooms.contains(where: { $0.id == window.id }) { rooms.append(ChatRoom(id: window.id, key: window.key, name: window.name, description: "Private chat", memberCount: window.members.count, flags: 1)) }
        updateMemberCount(room: window.id)
    }
    public func leaveRoom(_ roomID: UInt32? = nil) async throws {
        guard let room = roomID ?? joinedRoom, let token = roomTokens[room], leavingRooms[room] == nil else { return }
        leavingRooms[room] = token
        defer { if leavingRooms[room] == token { leavingRooms.removeValue(forKey: room) } }
        try await sendChecked(type: 204, payload: room.beBytes)
        // A reconnect or a fresh join while the leave unwinds must keep its state.
        if roomTokens[room] == token { removeMembership(room: room) }
    }
    private func removeMembership(room: UInt32) {
        joinedRooms.removeValue(forKey: room); roomTokens.removeValue(forKey: room); unreadRooms.removeValue(forKey: room); chatTopics.removeValue(forKey: room)
        if joinedRoom == room { joinedRoom = nil }
        rooms.removeAll { $0.id == room && $0.flags & 1 != 0 }
        if let index = rooms.firstIndex(where: { $0.id == room }) { rooms[index].memberCount = max(0, rooms[index].memberCount-1) }
    }
    public func createPrivateChat() async throws {
        _ = try await createPrivateChatWindow()
    }
    /// Returns the created room independently of the currently focused room.
    public func createPrivateChatWindow() async throws -> ChatWindow {
        guard joining == nil else { throw KDXError.invalid("A room is already being opened.") }
        let token = UUID(); joining = token
        defer { if joining == token { joining = nil; schedulePublicChatJoin() } }
        let reply = try await request(type: 200)
        guard reply.type == 216 else { throw KDXError.invalid("Unexpected private-chat reply.") }
        return try ChatWindow.decode(reply.payload)
    }
    public func inviteToChat(users: [UInt32], room target: UInt32? = nil) async throws {
        guard let room = target ?? joinedRoom, joinedRooms[room] != nil else { throw KDXError.invalid("Join a chat first.") }
        try await sendChecked(type: 211, payload: ChatInviteRequest(roomID: room, users: users).encode())
    }
    public func acceptInvitation(_ invitation: ChatInvitation) async throws {
        try await join(room: invitation.roomID, key: invitation.key)
        dismissInvitation(invitation)
    }
    public func dismissInvitation(_ invitation: ChatInvitation) { chatInvitations.removeAll { $0.id == invitation.id } }
    public func chatRecord(id: UInt32) async throws -> ChatRecord {
        let response = try await request(type: 218, payload: id.beBytes)
        guard response.type == 219 else { throw KDXError.invalid("Unexpected chat-info reply.") }
        return try ChatRecord.decode(response.payload)
    }
    public func saveChat(_ room: ChatRecord, creating: Bool) async throws {
        let type: UInt32 = creating ? 217 : 220
        let response = try await request(type: type, payload: room.encode())
        try checkMutation(response, type: type)
        try await refreshRooms()
    }
    public func deleteChat(id: UInt32) async throws {
        let response = try await request(type: 201, payload: id.beBytes)
        try checkMutation(response, type: 201)
        try await refreshRooms()
    }
    private func checkMutation(_ response: Message, type: UInt32) throws {
        guard response.type == 1, response.payload.count == 8, response.payload.u32(0) == 0, response.payload.u32(4) == type else { throw KDXError.invalid("Unexpected update reply.") }
    }
    public func setTopic(_ text: String, room target: UInt32? = nil) async throws {
        guard let room = target ?? joinedRoom, joinedRooms[room] != nil else { throw KDXError.invalid("Join a chat first.") }
        let bytes = try shortText(text)
        var payload = [UInt8](repeating: 0, count: 12)
        payload.put(room, at: 0); payload[10] = UInt8(bytes.count)
        try await sendChecked(type: 209, payload: payload + bytes)
    }
    public func sendChat(_ text: String, room target: UInt32? = nil) async throws {
        guard let room = target ?? joinedRoom, joinedRooms[room] != nil else { throw KDXError.invalid("Join a chat first.") }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 4096 else { throw KDXError.invalid("Chat text must contain 1–4096 UTF-8 bytes.") }
        try await sendChecked(type: 207, payload: room.beBytes + [UInt8](repeating: 0, count: 8) + bytes)
    }
    public func sendPrivate(to id: UInt32, text: String) async throws {
        guard let connection else { throw KDXError.disconnected }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 4096 else { throw KDXError.invalid("Message must contain 1–4096 UTF-8 bytes.") }
        try await connection.send(type: 300, payload: id.beBytes + [UInt8](repeating: 0, count: 12) + bytes)
        guard self.connection === connection, isConnected else { throw KDXError.disconnected }
        appendLine(ChatLine(userID: id, sender: "To \(users.first { $0.id == id }?.nickname ?? String(id))", text: text, isPrivate: true, isOutgoing: true))
    }
    public func loadAccounts() async throws {
        let response = try await request(type: 512)
        guard response.type == 513 else { throw KDXError.invalid("Unexpected account-list reply.") }
        accounts = try AccountListEntry.decodeList(response.payload)
    }
    public func loadAccountClasses() async throws {
        let response = try await request(type: 505)
        guard response.type == 506 else { throw KDXError.invalid("Unexpected account-class reply.") }
        accountClasses = try AccountClass.decodeList(response.payload)
    }
    public func accountClass(id: UInt8) async throws -> AccountClass {
        let response = try await request(type: 502, payload: [id])
        guard response.type == 503 else { throw KDXError.invalid("Unexpected account-class information.") }
        let entry = try AccountClass.decode(response.payload, info: true).0
        guard entry.id == id else { throw KDXError.invalid("Unexpected account class in reply.") }
        return entry
    }
    public func updateAccountClass(_ entry: AccountClass) async throws {
        guard !entry.name.isEmpty else { throw KDXError.invalid("Enter an account class name.") }
        let response = try await request(type: 504, payload: entry.encode(info: true, padded: false))
        try checkMutation(response, type: 504)
    }
    public func account(login: String) async throws -> RemoteAccount {
        let response = try await request(type: 509, payload: Array(login.utf8))
        guard response.type == 510 else { throw KDXError.invalid("Unexpected account reply.") }
        return try RemoteAccount.decode(response.payload)
    }
    public func createAccount(_ account: RemoteAccount, password: String) async throws {
        try ServerAccount.validateLogin(account.login)
        var record = account; record.key = AccountKey(password: password).bytes
        try await accountMutation(type: 507, record: record)
    }
    public func updateAccount(_ account: RemoteAccount, originalLogin: String, newPassword: String? = nil) async throws {
        try ServerAccount.validateLogin(account.login)
        var record = account; record.editor = originalLogin
        record.key = newPassword.map { AccountKey(password: $0).bytes } ?? [UInt8](repeating: 0, count: 32)
        try await accountMutation(type: 511, record: record)
        if sessionLogin == originalLogin { sessionLogin = account.login }
    }
    private func accountMutation(type: UInt32, record: RemoteAccount) async throws {
        let response = try await request(type: type, payload: record.encode())
        try checkMutation(response, type: type)
    }
    public func deleteAccount(login: String) async throws { try await sendChecked(type: 508, payload: Array(login.utf8)) }
    public func changePassword(to password: String) async throws {
        let response = try await request(type: 550, payload: AccountKey(password: password).bytes)
        guard response.type == 551, response.payload.isEmpty else { throw KDXError.invalid("Password change was not acknowledged.") }
    }
    public func loadNewsGroups() async throws {
        let response = try await request(type: 605)
        guard response.type == 606 else { throw KDXError.invalid("Unexpected newsgroup list.") }
        newsGroups = try NewsGroup.decodeList(response.payload)
        if let newsGroupID, !newsGroups.contains(where: { $0.id == newsGroupID }) { self.newsGroupID = nil; newsPosts = []; newsPermissions = 0; newsLoadToken = nil }
    }
    public func newsGroup(id: UInt32) async throws -> NewsGroupInfo {
        let response = try await request(type: 602, payload: id.beBytes)
        guard response.type == 603 else { throw KDXError.invalid("Unexpected newsgroup information.") }
        return try NewsGroupInfo.decode(response.payload)
    }
    public func saveNewsGroup(_ group: NewsGroupInfo, creating: Bool) async throws {
        try group.validate()
        let type: UInt32 = creating ? 600 : 604
        try checkMutation(await request(type: type, payload: group.encode()), type: type)
        try await loadNewsGroups()
        if newsGroupID == group.id { try await loadNews(group: group.id) }
    }
    public func deleteNewsGroup(id: UInt32) async throws {
        try checkMutation(await request(type: 601, payload: id.beBytes), type: 601)
        try await loadNewsGroups()
    }
    public func loadNews(group: UInt32 = 1) async throws {
        let token = UUID(); newsLoadToken = token; newsGroupID = group
        newsPosts = []; newsPermissions = 0
        let response = try await request(type: 607, payload: group.beBytes)
        guard newsLoadToken == token else { return }
        guard response.type == 608 else { throw KDXError.invalid("Unexpected news reply.") }
        try response.payload.require(16)
        guard response.payload.u32(0) == group else { throw KDXError.invalid("Unexpected newsgroup in reply.") }
        let posts = try NewsPost.decodeList(response.payload)
        guard posts.allSatisfy({ $0.groupID == group }) else { throw KDXError.invalid("News reply contains a different group.") }
        newsPosts = posts.sorted { $0.id > $1.id }; newsPermissions = response.payload.u32(4)
    }
    public func postNews(group: UInt32 = 1, subject: String, body: String) async throws {
        let subjectBytes = Array(subject.utf8), bodyBytes = Array(body.utf8)
        guard !subjectBytes.isEmpty, subjectBytes.count <= 128, !bodyBytes.isEmpty, bodyBytes.count <= 16384 else { throw KDXError.invalid("Use a subject of 1–128 bytes and a body of 1–16384 bytes.") }
        var payload = [UInt8](repeating: 0, count: 16)
        payload.put(group, at: 0); payload.put(UInt16(bodyBytes.count), at: 12); payload[14] = UInt8(subjectBytes.count)
        payload += subjectBytes + bodyBytes; payload.pad(4)
        try await sendChecked(type: 611, payload: payload)
        if newsGroupID == nil || newsGroupID == group { try await loadNews(group: group) }
    }
    public func deleteNews(_ post: NewsPost) async throws {
        try await sendChecked(type: 612, payload: post.groupID.beBytes + post.id.beBytes)
        if newsGroupID == post.groupID { try await loadNews(group: post.groupID) }
    }
    private func sendChecked(type: UInt32, payload: [UInt8]) async throws {
        guard let connection else { throw KDXError.disconnected }
        let tx = connection.allocateTransaction()
        let operation = CheckedOperation(deletedLogin: type == 508 ? String(bytes: payload, encoding: .utf8) : nil)
        operation.disconnectingSelf = type == 150 && payload.count >= 4 && payload.u32(0) == serverInfo?.userID
        checkedOperations[tx] = operation
        defer { if checkedOperations[tx] === operation { checkedOperations.removeValue(forKey: tx) } }
        do {
            try await connection.send(type: type, payload: payload, transaction: tx)
            // KDX mutations often have no success reply. This round trip is an ordering barrier.
            _ = try await request(type: 115)
        } catch {
            // Self-removal closes the session after its explicit 515 or 151 notification.
            if operation.confirmed && operation.error == nil { return }
            throw error
        }
        if let error = operation.error { throw error }
    }
    func setTransferFactory(_ factory: @escaping () throws -> WireConnection) { transferFactory = factory }
    public func fileInformation(path: [String]) async throws -> RemoteFileInformation {
        let response = try await request(type: 409, payload: RemotePath(path).encode())
        guard response.type == 410 else { throw KDXError.invalid("Unexpected file-information reply.") }
        return try RemoteFileInformation.decode(response.payload)
    }
    /// Returns a listing without changing the legacy selected-folder properties.
    public func files(at path: [String]) async throws -> [RemoteFile] {
        let response = try await request(type: 400, payload: RemotePath(path).encode())
        guard response.type == 401 else { throw KDXError.invalid("Unexpected file-list reply.") }
        return try RemoteFile.decodeList(response.payload)
    }
    public func listFiles(path: [String] = []) async throws {
        let entries = try await files(at: path)
        files = entries; filePath = path
    }
    public func markRoomRead(_ room: UInt32) { if unreadRooms[room] != nil { unreadRooms.removeValue(forKey: room) } }
    public func selectRoom(_ room: UInt32?) {
        joinedRoom = room.flatMap { joinedRooms[$0] == nil ? nil : $0 }
        if let joinedRoom { markRoomRead(joinedRoom) }
    }
    public func privateMessages(with user: UInt32) -> [ChatLine] {
        chatLines.filter { $0.isPrivate && $0.userID == user }
    }
    public func deletePrivateMessages(with user: UInt32) { chatLines.removeAll { $0.isPrivate && $0.userID == user } }
    public var privateMessageUsers: [UInt32] { Array(Set(chatLines.filter(\.isPrivate).map(\.userID))).sorted() }

    public func cancelTransfer() { activeTransfer?.close() }
    private func attach() async throws -> WireConnection {
        guard let info = serverInfo, let table, let factory = transferFactory else { throw KDXError.disconnected }
        guard activeTransfer == nil else { throw KDXError.invalid("A transfer is already running.") }
        let wire = try factory(); activeTransfer = wire; wire.ioTimeout = .seconds(30)
        do {
            try await wire.start()
            try await wire.authenticateClient(name: [0] + info.userID.beBytes, key: AccountKey(bytes: info.sessionKey), table: table)
            guard activeTransfer === wire, isConnected else { throw KDXError.disconnected }
            return wire
        } catch { wire.close(); if activeTransfer === wire { activeTransfer = nil }; throw error }
    }
    public func download(_ file: RemoteFile, to destination: URL) async throws {
        try await download(file, at: filePath, to: destination)
    }
    /// The folder is captured by the caller; browsing cannot redirect a queued download.
    public func download(_ file: RemoteFile, at folder: [String], to destination: URL) async throws {
        guard let connection else { throw KDXError.disconnected }
        let path = folder + [file.name]
        let identity = DownloadIdentity(server: connection.endpointDescription, account: sessionLogin, path: path, destination: destination.lastPathComponent)
        let staging = try PartialDownload(destination: destination, identity: identity)
        let wire = try await attach()
        defer { wire.close(); if activeTransfer === wire { activeTransfer = nil; transferStatus = nil } }
        transferStatus = "\(staging.offset == 0 ? "Downloading" : "Resuming") \(file.name)"; transferProgress = 0
        let tx = try await wire.send(type: 412, payload: DownloadRequest(path: RemotePath(path), dataOffset: staging.offset, resourceOffset: staging.resourceOffset).encode())
        let reply = try await wire.receive(); try checkStatus(reply)
        guard reply.type == 413, reply.transaction == tx, reply.isReply else { throw KDXError.invalid("Unexpected download reply.") }
        let info = try DownloadInfo(wire: reply.payload), size = info.dataSize
        guard size <= UInt32.max, info.resourceSize <= UInt32.max else { throw KDXError.invalid("A file fork exceeds the KDX limit of 4 GiB.") }
        let total = size + info.resourceSize
        try staging.prepare(info)
        guard staging.offset <= size, staging.resourceOffset <= info.resourceSize else { throw KDXError.invalid("Invalid download resume offset.") }
        transferProgress = total == 0 ? 1 : Double(staging.offset + staging.resourceOffset)/Double(total)
        let remaining = size - staging.offset
        let count = try await wire.receiveFile(type: 414, sink: staging.handle, maximum: remaining, transaction: tx) { value in
            if self.activeTransfer === wire { self.transferProgress = total == 0 ? 1 : Double(staging.offset + staging.resourceOffset + value)/Double(total) }
        }
        guard count == remaining else { throw KDXError.invalid("Incomplete download. Retry the same destination to resume.") }
        let resourceRemaining = info.resourceSize - staging.resourceOffset
        let resourceCount = try await wire.receiveFile(type: 414, sink: staging.handle, maximum: resourceRemaining, resourceOffset: staging.resourceOffset) { value in
            if self.activeTransfer === wire { self.transferProgress = total == 0 ? 1 : Double(size + staging.resourceOffset + value)/Double(total) }
        }
        guard resourceCount == resourceRemaining else { throw KDXError.invalid("Incomplete resource fork. Retry the same destination to resume.") }
        guard activeTransfer === wire else { throw KDXError.disconnected }
        try staging.commit(); transferProgress = 1
    }
    public func upload(from source: URL) async throws {
        let folder = filePath
        try await upload(from: source, to: folder)
        if filePath == folder { try await listFiles(path: folder) }
    }
    public func upload(from source: URL, to folder: [String]) async throws {
        let wire = try await attach()
        defer { wire.close(); if activeTransfer === wire { activeTransfer = nil; transferStatus = nil } }
        transferStatus = "Uploading \(source.lastPathComponent)"; transferProgress = 0
        let store = try SharedFiles(path: source.deletingLastPathComponent().path)
        let (handle, size) = try store.openFile([source.lastPathComponent]); defer { try? handle.close() }
        let resourceSize = try ResourceFork.size(handle.fileDescriptor), total = size + resourceSize
        guard size <= UInt32.max, resourceSize <= UInt32.max else { throw KDXError.invalid("A file fork exceeds the KDX limit of 4 GiB.") }
        var request = UploadRequest(dataSize: size, name: source.lastPathComponent, folder: RemotePath(folder)); request.resourceSize = resourceSize
        let tx = try await wire.send(type: 415, payload: request.encode())
        let reply = try await wire.receive(); try checkStatus(reply)
        guard reply.type == 416, reply.transaction == tx, reply.isReply else { throw KDXError.invalid("Unexpected upload reply.") }
        let uploadReply = try UploadReply(wire: reply.payload)
        guard uploadReply.resourceOffset == .max || uploadReply.resourceOffset == 0 else { throw KDXError.invalid("Unexpected upload resource-fork offset.") }
        let offset = try uploadReply.alignedOffset(size: size)
        try handle.seek(toOffset: offset)
        if offset > 0 { transferStatus = "Resuming upload of \(source.lastPathComponent)" }
        transferProgress = total == 0 ? 1 : Double(offset)/Double(total)
        try await wire.sendFile(type: 417, length: UInt32(size-offset), source: handle) { value in if self.activeTransfer === wire { self.transferProgress = total == 0 ? 1 : Double(offset+value)/Double(total) } }
        try await wire.sendFile(type: 417, length: UInt32(resourceSize), source: handle, resourceOffset: 0) { value in
            if self.activeTransfer === wire { self.transferProgress = total == 0 ? 1 : Double(size+value)/Double(total) }
        }
        let complete = try await wire.receive(); try checkStatus(complete)
        guard complete.type == 418 else { throw KDXError.invalid("Upload was not acknowledged.") }
        guard activeTransfer === wire else { throw KDXError.disconnected }
        transferProgress = 1
    }
    private func handle(_ message: Message) throws {
        let b = message.payload
        switch message.type {
        case 1:
            do { try checkStatus(message) } catch {
                if let operation = checkedOperations[message.transaction] { operation.error = error }
                else { lastError = error.localizedDescription }
            }
        case 183:
            guard isViewingHistory, historyLoaded else { break }
            let (entry, used) = try RemoteHistoryEntry.decode(b)
            guard used == b.count else { throw KDXError.invalid("Unexpected history update.") }
            history.append(entry); if history.count > 500 { history.removeFirst(history.count-500) }
        case 106: serverIcon = b
        case 107:
            try b.require(4); greeting = b.text(4..<b.count)
        case 419:
            try b.require(4); serverDownloadLimit = b.u32(0)
        case 151:
            let notice = try DisconnectNotice.decode(b)
            if notice.senderID == serverInfo?.userID {
                for operation in checkedOperations.values where operation.disconnectingSelf { operation.confirmed = true }
            }
            disconnectNotice = notice
            disconnect(); lastError = notice.description
        case 155:
            var notice = try BroadcastMessage.decode(b, received: true)
            notice.sender = users.first { $0.id == notice.senderID }?.nickname ?? "User \(notice.senderID)"
            broadcasts.append(notice)
            if broadcasts.count > 100 { broadcasts.removeFirst(broadcasts.count-100) }
        case 515:
            let login = b.text(0..<b.count); accounts.removeAll { $0.login == login }
            for operation in checkedOperations.values where operation.deletedLogin == login { operation.confirmed = true }
        case 613, 614: newsRevision += 1
        case 101: users = try KDXUser.list(b)
        case 102, 103:
            let (user, _) = try KDXUser.decode(b); users.removeAll { $0.id == user.id }; users.append(user)
        case 104:
            try b.require(4); users.removeAll { $0.id == b.u32(0) }
            for room in joinedRooms.keys {
                joinedRooms[room]?.members.removeAll { $0 == b.u32(0) }; updateMemberCount(room: room)
            }
        case 205, 206:
            try b.require(12)
            let room = b.u32(0), userID = b.u32(4)
            guard joinedRooms[room] != nil else { break }
            if message.type == 206, userID == serverInfo?.userID { removeMembership(room: room); break }
            joinedRooms[room]?.members.removeAll { $0 == userID }
            if message.type == 205 { joinedRooms[room]?.members.append(userID) }
            updateMemberCount(room: room)
        case 213:
            publicChatRequested = true; schedulePublicChatJoin()
        case 212:
            do {
                let invitation = try ChatInvitation.decode(b)
                chatInvitations.removeAll { $0.id == invitation.id }
                chatInvitations.append(invitation)
                if chatInvitations.count > 100 { chatInvitations.removeFirst() }
            } catch { lastError = error.localizedDescription }
        case 210:
            let topic = try ChatTopic.decode(b)
            if joinedRooms[topic.roomID] != nil { chatTopics[topic.roomID] = topic }
        case 221:
            try b.require(8); let roomID = b.u32(0)
            removeMembership(room: roomID); rooms.removeAll { $0.id == roomID }
            chatInvitations.removeAll { $0.roomID == roomID }

        case 105: serverInfo = try ServerInfo.decode(b)
        case 111:
            try b.require(8)
            if let index = users.firstIndex(where: { $0.id == b.u32(0) }) { users[index].status = b[4] }
        case 208:
            try b.require(12)
            let room = b.u32(0)
            guard joinedRooms[room] != nil else { return }
            appendLine(id: b.u32(4), text: b.text(12..<b.count), privateMessage: false, room: room)
            if joinedRoom != room { unreadRooms[room] = min(2000, (unreadRooms[room] ?? 0) + 1) }
        case 301:
            try b.require(17); appendLine(id: b.u32(0), text: b.text(16..<b.count), privateMessage: true)
        default: break
        }
    }
    private func updateMemberCount(room: UInt32) {
        if let window = joinedRooms[room], let index = rooms.firstIndex(where: { $0.id == room }) { rooms[index].memberCount = window.members.count }
    }
    private func appendLine(id: UInt32, text: String, privateMessage: Bool, room: UInt32? = nil) {
        appendLine(ChatLine(userID: id, sender: users.first { $0.id == id }?.nickname ?? "User \(id)", text: text, isPrivate: privateMessage, roomID: room))
    }
    private func appendLine(_ line: ChatLine) {
        chatLines.append(line)
        if chatLines.count > 2000 { chatLines.removeFirst(chatLines.count - 2000) }
    }
}
