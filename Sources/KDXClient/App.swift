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
    @State private var draft = ""
    @State private var error: String?
    @State private var importing = false
    @State private var tableReady = false
    @State private var section = "Chat"
    @State private var newsGroup: UInt32 = 1
    @State private var composing = false
    @State private var newsSubject = ""
    @State private var newsBody = ""
    @State private var posting = false
    @State private var changingPassword = false
    @State private var editingProfile = false
    @State private var inspectingUser: KDXUser?
    @State private var recipient: UInt32?
    @State private var editingChat: ChatRecord?
    @State private var deletingChat: ChatRoom?
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
                    ForEach(client.rooms) { room in
                        Button { section = "Chat"; perform { try await client.join(room: room.id, key: room.key) } } label: {
                            HStack { Image(systemName: "number"); Text(room.name); Spacer(); Text("\(room.memberCount)").foregroundStyle(.secondary) }
                        }.buttonStyle(.plain).padding(8)
                            .background(client.joinedRoom == room.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contextMenu {
                                Button("Edit Room…") { perform { editingChat = try await client.chatRecord(id: room.id) } }
                                if room.id != 1 { Button("Delete Room…", role: .destructive) { deletingChat = room } }
                            }
                    }
                    Spacer()
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
        .sheet(isPresented: $editingProfile) { ProfileEditorView(client: client) }
        .sheet(item: $inspectingUser) { UserInformationView(client: client, user: $0) }
        .onChange(of: client.currentUser?.nickname) { _, value in if let value, client.isConnected { nickname = value } }
        .onChange(of: client.currentUser?.info) { _, value in if let value, client.isConnected { profileInfo = value } }
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
                Button("Refresh", systemImage: "arrow.clockwise") { perform { try await client.loadNews(group: newsGroup) } }
                Button("Post…", systemImage: "square.and.pencil") { composing = true }.disabled(client.newsPermissions & 1 == 0)
            }.padding()
            List(client.newsPosts) { post in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(post.subject).font(.headline)
                        Spacer()
                        if client.newsPermissions & 2 != 0 || (!login.isEmpty && post.login == login) {
                            Button("Delete", role: .destructive) { perform { try await client.deleteNews(post) } }
                        }
                    }
                    Text("\(post.author) · \(post.date.formatted())").font(.caption).foregroundStyle(.secondary)
                    Text(post.body).textSelection(.enabled)
                }.padding(.vertical, 10)
            }.overlay { if client.newsPosts.isEmpty { ContentUnavailableView("No news yet", systemImage: "newspaper", description: Text("Posts from this server will appear here.")) } }
        }
        .task { perform { try await client.loadNewsGroups(); if let first = client.newsGroups.first { newsGroup = first.id; try await client.loadNews(group: first.id) } } }
        .onChange(of: newsGroup) { _, value in perform { try await client.loadNews(group: value) } }
        .onChange(of: client.newsRevision) { _, _ in perform { try await client.loadNews(group: newsGroup) } }
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
    private var fileBrowser: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Up", systemImage: "arrow.up") { perform { try await client.listFiles(path: Array(client.filePath.dropLast())) } }.disabled(client.filePath.isEmpty)
                Text("/" + client.filePath.joined(separator: "/")).font(.headline)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { perform { try await client.listFiles(path: client.filePath) } }
                Button("Upload…", systemImage: "square.and.arrow.up") { chooseUpload() }.disabled(client.transferStatus != nil)
            }.padding()
            Divider()
            List(client.files) { file in
                HStack {
                    Image(systemName: file.isDirectory ? "folder.fill" : "doc").foregroundStyle(file.isDirectory ? .blue : .secondary)
                    Text(file.name)
                    Spacer()
                    if !file.isDirectory { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file)).foregroundStyle(.secondary) }
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
                    }.onChange(of: client.chat.count) { _, _ in if let id = client.chat.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
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
                        TextField(recipient == nil ? "Message the room" : "Private message", text: $draft).textFieldStyle(.roundedBorder).onSubmit(send)
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
                            if user.id != client.serverInfo?.userID { Button("Private Message") { recipient = user.id } }
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
        let text = draft
        perform {
            if let recipient { try await client.sendPrivate(to: recipient, text: text) } else { try await client.sendChat(text) }
            draft = ""
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await action() } catch { self.error = error.localizedDescription } }
    }
}
