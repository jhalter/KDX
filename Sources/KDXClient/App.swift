import SwiftUI
import UniformTypeIdentifiers
import KDXCore
import AppKit

@main struct KDXClientApp: App {
    var body: some Scene {
        WindowGroup("KDX Client") { ClientView().frame(minWidth: 850, minHeight: 580) }
            .defaultSize(width: 1060, height: 720)
    }
}

struct ClientView: View {
    @State private var client = KDXClient()
    @AppStorage("client.host") private var host = "127.0.0.1"
    @AppStorage("client.port") private var port = "10700"
    @AppStorage("client.login") private var login = ""
    @AppStorage("client.nickname") private var nickname = ""
    @AppStorage("client.info") private var profileInfo = ""
    @State private var password = ""
    @State private var roomDrafts: [UInt32: String] = [:]
    @State private var privateDrafts: [UInt32: String] = [:]
    private var draft: String {
        get {
            if let recipient { return privateDrafts[recipient] ?? "" }
            return client.joinedRoom.flatMap { roomDrafts[$0] } ?? ""
        }
        nonmutating set {
            if let recipient { privateDrafts[recipient] = newValue }
            else if let room = client.joinedRoom { roomDrafts[room] = newValue }
        }
    }
    @State private var error: String?
    @State private var viewingHistory = false
    @State private var editingServerSettings = false
    @State private var viewingGreeting = false
    @State private var inspectingFile: FileInspection?
    @State private var importing = false
    @State private var tableReady = false
    @State private var section = "Chat"
    @State private var newsGroup: UInt32 = 1
    @State private var editingNewsGroup: NewsGroupInfo?
    @State private var deletingNewsGroup: NewsGroup?
    @State private var composing = false
    @State private var newsSubject = ""
    @State private var newsBody = ""
    @State private var posting = false
    @State private var changingPassword = false
    @State private var composingBroadcast = false
    @State private var viewingBroadcasts = false
    @State private var disconnectingUser: KDXUser?
    @State private var editingProfile = false
    @State private var inspectingUser: KDXUser?
    @State private var recipient: UInt32?
    @State private var editingChat: ChatRecord?
    @State private var deletingChat: ChatRoom?
    @State private var inviting = false
    @State private var editingTopic = false
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                Label("KDX", systemImage: "network").font(.largeTitle.bold())
                Label(client.state, systemImage: client.isConnected ? "circle.fill" : "circle")
                    .font(.caption).foregroundStyle(client.isConnected ? .green : .secondary)
                if client.isConnected {
                    Text(client.serverInfo?.name ?? "Server").font(.headline)
                    Text(client.serverInfo?.description ?? "").font(.callout).foregroundStyle(.secondary)
                    Picker("Section", selection: $section) {
                        Text("Chat").tag("Chat"); Text("Files").tag("Files"); Text("News").tag("News"); Text("Accounts").tag("Accounts")
                    }.pickerStyle(.segmented)
                    Divider()
                    HStack {
                        Text("CHAT ROOMS").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Create Room", systemImage: "plus") { editingChat = ChatRecord(name: "") }.labelStyle(.iconOnly)
                    }
                    ScrollView {
                    LazyVStack(spacing: 2) {
                    ForEach(client.rooms) { room in
                        Button { section = "Chat"; perform { try await client.join(room: room.id, key: room.key) } } label: {
                            HStack {
                                Image(systemName: client.joinedRooms[room.id] == nil ? "number" : "checkmark.circle.fill")
                                    .help(client.joinedRooms[room.id] == nil ? "Join room" : "Joined room")
                                Text(room.name); Spacer()
                                if let unread = client.unreadRooms[room.id], unread > 0 {
                                    Text("\(unread)").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                                        .accessibilityLabel("\(unread) unread messages")
                                }
                                Text("\(room.memberCount)").foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain).padding(8)
                            .background(client.joinedRoom == room.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contextMenu {
                                if client.joinedRooms[room.id] != nil { Button("Leave Room") { perform { try await client.leaveRoom(room.id) } } }
                                if room.flags & 1 == 0 { Button("Edit Room…") { perform { editingChat = try await client.chatRecord(id: room.id) } } }
                                if room.id != 1 { Button("Delete Room…", role: .destructive) { deletingChat = room } }
                            }
                    }
                    }
                    }.frame(minHeight: 70, maxHeight: 220)
                    if !client.chatInvitations.isEmpty {
                        Text("CHAT INVITATIONS").font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                        ForEach(client.chatInvitations) { invitation in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(invitation.name).font(.headline)
                                Text("From \(client.users.first { $0.id == invitation.inviterID }?.nickname ?? "User \(invitation.inviterID)")").font(.caption)
                                HStack {
                                    Button("Accept") { section = "Chat"; perform { try await client.acceptInvitation(invitation) } }
                                    Button("Decline") { client.dismissInvitation(invitation) }
                                }
                            }
                        }
                        }.frame(maxHeight: 180)
                    }
                    Spacer()
                    Button("Server History…", systemImage: "clock.arrow.circlepath") { viewingHistory = true }
                    Button("Show Greeting…") { viewingGreeting = true }
                    if client.serverInfo?.canModifySettings == true { Button("Server Settings…") { editingServerSettings = true } }
                    Button("Broadcast…", systemImage: "megaphone") { composingBroadcast = true }
                    if let notice = client.broadcasts.last {
                        Button { viewingBroadcasts = true } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Broadcasts (\(client.broadcasts.count))", systemImage: "megaphone.fill")
                                Text("\(notice.sender): \(notice.text)").font(.caption).lineLimit(2)
                            }
                        }.buttonStyle(.plain)
                    }
                    Button("My Profile…", systemImage: "person.crop.circle") { editingProfile = true }
                    Toggle("Away", isOn: Binding(get: { client.currentUser?.status == 1 }, set: { value in perform { try await client.setStatus(value ? 1 : 0) } }))
                    Button("Change Password…", systemImage: "key") { changingPassword = true }
                    Button("Disconnect", systemImage: "eject") { client.disconnect() }
                } else {
                    Form {
                        TextField("Host", text: $host)
                        TextField("Port", text: $port)
                        TextField("Account", text: $login, prompt: Text("Guest"))
                        SecureField("Password", text: $password)
                        TextField("Nickname", text: $nickname)
                    }.textFieldStyle(.roundedBorder)
                    Button { connect() } label: {
                        HStack { if client.isConnecting { ProgressView().controlSize(.small) }; Text(client.isConnecting ? "Connecting…" : "Connect").frame(maxWidth: .infinity) }
                    }.buttonStyle(.borderedProminent).disabled(client.isConnecting || !tableReady).keyboardShortcut(.defaultAction)
                    if client.isConnecting { Button("Cancel") { client.disconnect() } }
                    Spacer()
                    Label(tableReady ? "Challenge table ready" : "Import a KDX challenge table", systemImage: tableReady ? "checkmark.seal" : "key")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Import KDX Binary or Table…") { importing = true }
                    Text("Select an uncompressed original KDX program, or a challenge-table.bin exported by the reference client.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding().navigationSplitViewColumnWidth(min: 260, ideal: 290)
        } detail: {
            if client.isConnected { if section == "Files" { fileBrowser } else if section == "News" { newsBrowser } else if section == "Accounts" { AccountsView(client: client) } else { conversation } }
            else {
                ContentUnavailableView("Connect to your community", systemImage: "bubble.left.and.bubble.right", description: Text("Join a KDX server to chat and exchange private messages."))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .item]) { result in
            do { try KDXStorage.importTable(from: result.get()); tableReady = true } catch { self.error = error.localizedDescription }
        }
        .onChange(of: client.isConnected) { _, connected in
            if !connected { roomDrafts = [:]; privateDrafts = [:]; recipient = nil }
        }
        .sheet(isPresented: $viewingHistory) { ServerHistoryView(client: client) }
        .sheet(isPresented: $editingServerSettings) { ServerSettingsView(client: client) }
        .sheet(isPresented: $viewingGreeting) { ServerGreetingView(client: client) }
        .onChange(of: client.greeting) { old, value in if old == nil, value != nil { viewingGreeting = true } }
        .sheet(item: $inspectingFile) { FileInformationView(client: client, path: $0.path) }
        .sheet(isPresented: $composingBroadcast) { BroadcastComposer(client: client) }
        .sheet(isPresented: $viewingBroadcasts) { BroadcastHistory(client: client) }
        .sheet(item: $disconnectingUser) { DisconnectUserView(client: client, user: $0) }
        .sheet(isPresented: $editingProfile) { ProfileEditorView(client: client) }
        .sheet(item: $inspectingUser) { UserInformationView(client: client, user: $0) }
        .onChange(of: client.currentUser?.nickname) { _, value in if let value, client.isConnected { nickname = value } }
        .onChange(of: client.currentUser?.info) { _, value in if let value, client.isConnected { profileInfo = value } }
        .sheet(isPresented: $inviting) { ChatInviteView(client: client) }
        .sheet(item: $editingChat) { ChatEditorView(client: client, room: $0) }
        .sheet(isPresented: $editingTopic) { ChatTopicEditor(client: client, topic: client.chatTopics[client.joinedRoom ?? 0]?.text ?? "") }
        .confirmationDialog("Delete Chat Room", isPresented: Binding(get: { deletingChat != nil }, set: { if !$0 { deletingChat = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let room = deletingChat { perform { try await client.deleteChat(id: room.id) } }; deletingChat = nil }
            Button("Cancel", role: .cancel) { deletingChat = nil }
        } message: { Text("Delete “\(deletingChat?.name ?? "")”? Everyone in this room will leave it.") }
        .sheet(isPresented: $changingPassword) { ChangePasswordView(client: client) { password = $0 } }
        .onChange(of: client.sessionLogin) { _, value in if client.isConnected { login = value } }
        .task { tableReady = (try? KDXStorage.loadTable()) != nil }
        .onChange(of: client.lastError) { _, value in if let value { error = value } }
        .alert("KDX", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private var newsBrowser: some View {
        VStack {
            HStack {
                Picker("Newsgroup", selection: $newsGroup) { ForEach(client.newsGroups) { group in Text(group.name).tag(group.id) } }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { perform { try await refreshNews() } }
                Menu("Groups", systemImage: "folder.badge.gearshape") {
                    Button("Create Newsgroup…") { editingNewsGroup = NewsGroupInfo(name: "") }
                    Button("Edit Newsgroup…") { perform { editingNewsGroup = try await client.newsGroup(id: newsGroup) } }.disabled(client.newsGroups.isEmpty)
                    Button("Delete Newsgroup…", role: .destructive) { deletingNewsGroup = client.newsGroups.first { $0.id == newsGroup } }.disabled(client.newsGroups.isEmpty)
                }
                Button("Post…", systemImage: "square.and.pencil") { composing = true }.disabled(client.newsPermissions & 1 == 0)
            }.padding()
            List(client.newsPosts) { post in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(post.subject).font(.headline)
                        Spacer()
                        if client.newsPermissions & 2 != 0 || (!client.sessionLogin.isEmpty && post.login == client.sessionLogin && post.id == client.newsPosts.first?.id) {
                            Button("Delete", role: .destructive) { perform { try await client.deleteNews(post) } }
                        }
                    }
                    Text("\(post.author) · \(post.date.formatted())").font(.caption).foregroundStyle(.secondary)
                    Text(post.body).textSelection(.enabled)
                }.padding(.vertical, 10)
            }.overlay { if client.newsPosts.isEmpty { ContentUnavailableView("No news yet", systemImage: "newspaper", description: Text(client.newsPermissions & 4 == 0 && client.newsPermissions & 1 != 0 ? "You can post to this group, but cannot read its posts." : "Posts from this server will appear here.")) } }
        }
        .task { perform { try await refreshNews() } }
        .onChange(of: newsGroup) { _, value in if client.newsGroups.contains(where: { $0.id == value }) { perform { try await client.loadNews(group: value) } } }
        .onChange(of: client.newsGroups) { _, groups in if !groups.contains(where: { $0.id == newsGroup }), let first = groups.first { newsGroup = first.id } }
        .onChange(of: client.newsRevision) { _, _ in perform { try await refreshNews() } }
        .sheet(item: $editingNewsGroup) { NewsGroupEditorView(client: client, group: $0) }
        .confirmationDialog("Delete Newsgroup", isPresented: Binding(get: { deletingNewsGroup != nil }, set: { if !$0 { deletingNewsGroup = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let group = deletingNewsGroup { perform { try await client.deleteNewsGroup(id: group.id); try await refreshNews() } }; deletingNewsGroup = nil }
            Button("Cancel", role: .cancel) { deletingNewsGroup = nil }
        } message: { Text("Delete “\(deletingNewsGroup?.name ?? "")” and all its posts?") }
        .sheet(isPresented: $composing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Post News").font(.title2.bold())
                TextField("Subject", text: $newsSubject).textFieldStyle(.roundedBorder)
                TextEditor(text: $newsBody).frame(minHeight: 200).border(.quaternary)
                HStack {
                    Button("Cancel") { composing = false }.disabled(posting)
                    Spacer()
                    Button(posting ? "Posting…" : "Post") {
                        posting = true
                        Task {
                            defer { posting = false }
                            do { try await client.postNews(group: newsGroup, subject: newsSubject, body: newsBody); composing = false; newsSubject = ""; newsBody = "" }
                            catch { self.error = error.localizedDescription }
                        }
                    }.buttonStyle(.borderedProminent).disabled(posting || newsSubject.isEmpty || newsBody.isEmpty)
                }
            }.padding(24).frame(width: 520)
        }
    }
    private func refreshNews() async throws {
        try await client.loadNewsGroups()
        if !client.newsGroups.contains(where: { $0.id == newsGroup }), let first = client.newsGroups.first { newsGroup = first.id }
        if client.newsGroups.contains(where: { $0.id == newsGroup }) { try await client.loadNews(group: newsGroup) }
    }
    private var fileBrowser: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Up", systemImage: "arrow.up") { perform { try await client.listFiles(path: Array(client.filePath.dropLast())) } }.disabled(client.filePath.isEmpty)
                Text("/" + client.filePath.joined(separator: "/")).font(.headline)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { perform { try await client.listFiles(path: client.filePath) } }
                Button("Folder Info", systemImage: "info.circle") { inspectingFile = FileInspection(path: client.filePath) }
                Button("Upload…", systemImage: "square.and.arrow.up") { chooseUpload() }.disabled(client.transferStatus != nil)
            }.padding()
            Divider()
            List(client.files) { file in
                HStack {
                    Image(systemName: file.isDirectory ? "folder.fill" : "doc").foregroundStyle(file.isDirectory ? .blue : .secondary)
                    Text(file.name)
                    Spacer()
                    if !file.isDirectory { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file)).foregroundStyle(.secondary) }
                    Button("Info", systemImage: "info.circle") { inspectingFile = FileInspection(path: client.filePath + [file.name]) }.labelStyle(.iconOnly)
                    Button(file.isDirectory ? "Open" : "Download…") {
                        if file.isDirectory { perform { try await client.listFiles(path: client.filePath + [file.name]) } }
                        else { chooseDownload(file) }
                    }.disabled(client.transferStatus != nil)
                }.padding(.vertical, 4)
            }.overlay { if client.files.isEmpty { ContentUnavailableView("No files", systemImage: "folder", description: Text("This folder is empty or has not been shared.")) } }
            if let status = client.transferStatus {
                VStack { HStack { Text(status); Spacer(); Button("Cancel") { client.cancelTransfer() } }; ProgressView(value: client.transferProgress) }.padding()
            }
        }.task { perform { try await client.listFiles(path: client.filePath) } }
    }
    private func chooseUpload() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            perform { try await client.upload(from: url) }
        }
    }
    private func chooseDownload(_ file: RemoteFile) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = file.name
        panel.message = "Choose the same destination to resume an interrupted download."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            perform { try await client.download(file, to: url) }
        }
    }
    private var conversation: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(client.rooms.first { $0.id == client.joinedRoom }?.name ?? client.chatWindow?.name ?? "Choose a room", systemImage: "number").font(.title2.bold())
                        if let topic = client.chatTopics[client.joinedRoom ?? 0], !topic.text.isEmpty { Text(topic.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    Spacer()
                    Menu("Room", systemImage: "ellipsis.circle") {
                        Button("Create Private Chat") { perform { try await client.createPrivateChat() } }
                        Button("Invite Users…") { inviting = true }.disabled(client.joinedRoom == nil)
                        Button("Set Topic…") { editingTopic = true }.disabled(client.joinedRoom == nil)
                        Button("Leave Room") { perform { try await client.leaveRoom() } }.disabled(client.joinedRoom == nil)
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") { perform { try await client.refreshRooms() } }.labelStyle(.iconOnly)
                }.padding()
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(client.chat) { line in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        if line.isPrivate { Image(systemName: "lock.fill").foregroundStyle(.orange) }
                                        Text(line.sender).fontWeight(.semibold)
                                        Text(line.date, style: .time).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(line.text).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                            }
                        }.padding()
                    }.onChange(of: client.chat.last?.id) { _, _ in if let id = client.chat.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                }
                Divider()
                VStack(spacing: 8) {
                    if let recipient {
                        HStack {
                            Label("Private message to \(client.users.first { $0.id == recipient }?.nickname ?? "user")", systemImage: "lock")
                            Spacer(); Button("Cancel") { self.recipient = nil }
                        }.font(.caption)
                    }
                    HStack {
                        TextField(recipient == nil ? "Message the room" : "Private message", text: Binding(get: { draft }, set: { draft = $0 })).textFieldStyle(.roundedBorder).onSubmit(send)
                            .disabled(recipient == nil && client.joinedRoom == nil)
                        Button("Send", systemImage: "paperplane.fill", action: send).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (recipient == nil && client.joinedRoom == nil))
                    }
                }.padding()
            }
            Divider()
            VStack(alignment: .leading) {
                Text("ONLINE · \(client.users.count)").font(.caption.bold()).foregroundStyle(.secondary).padding([.horizontal,.top])
                List(client.users) { user in
                    HStack {
                        Image(systemName: user.isAdmin ? "person.badge.key.fill" : "person.fill")
                        VStack(alignment: .leading) {
                            Text(user.nickname)
                            if user.status == 1 { Text("Away").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if client.chatWindow?.members.contains(user.id) == true { Image(systemName: "bubble.left.fill").font(.caption).foregroundStyle(.secondary).help("In this room") }
                    }
                        .contextMenu {
                            Button("User Information…") { inspectingUser = user }
                            if user.id != client.serverInfo?.userID {
                                Button("Private Message") { recipient = user.id }
                                Button("Disconnect User…", role: .destructive) { disconnectingUser = user }
                            }
                        }
                }.listStyle(.sidebar)
            }.frame(width: 190)
        }
    }
    private func connect() {
        guard let value = UInt16(port), value > 0 else { error = "Enter a port between 1 and 65535."; return }
        perform { try await client.connect(host: host, port: value, login: login, password: password, nickname: nickname, info: profileInfo, table: KDXStorage.loadTable()) }
    }
    private func send() {
        let text = draft, target = recipient, room = client.joinedRoom
        perform {
            if let target {
                try await client.sendPrivate(to: target, text: text)
                if privateDrafts[target] == text { privateDrafts[target] = "" }
            } else if let room {
                try await client.sendChat(text, room: room)
                if roomDrafts[room] == text { roomDrafts[room] = "" }
            }
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await action() } catch { self.error = error.localizedDescription } }
    }
}
