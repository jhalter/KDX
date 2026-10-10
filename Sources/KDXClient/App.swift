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
    @State private var recipient: UInt32?
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
                        Text("Chat").tag("Chat"); Text("Files").tag("Files"); Text("News").tag("News")
                    }.pickerStyle(.segmented)
                    Divider()
                    Text("CHAT ROOMS").font(.caption).foregroundStyle(.secondary)
                    ForEach(client.rooms) { room in
                        Button { perform { try await client.join(room: room.id, key: room.key) } } label: {
                            HStack { Image(systemName: "number"); Text(room.name); Spacer(); Text("\(room.memberCount)").foregroundStyle(.secondary) }
                        }.buttonStyle(.plain).padding(8)
                            .background(client.joinedRoom == room.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    Spacer()
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
            if client.isConnected { if section == "Files" { fileBrowser } else if section == "News" { newsBrowser } else { conversation } }
            else {
                ContentUnavailableView("Connect to your community", systemImage: "bubble.left.and.bubble.right", description: Text("Join a KDX server to chat and exchange private messages."))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .item]) { result in
            do { try KDXStorage.importTable(from: result.get()); tableReady = true } catch { self.error = error.localizedDescription }
        }
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
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            perform { try await client.download(file, to: url) }
        }
    }
    private var conversation: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Label(client.rooms.first { $0.id == client.joinedRoom }?.name ?? "Chat", systemImage: "number").font(.title2.bold())
                    Spacer()
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
                        Button("Send", systemImage: "paperplane.fill", action: send).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding()
            }
            Divider()
            VStack(alignment: .leading) {
                Text("ONLINE · \(client.users.count)").font(.caption.bold()).foregroundStyle(.secondary).padding([.horizontal,.top])
                List(client.users) { user in
                    HStack { Image(systemName: user.isAdmin ? "person.badge.key.fill" : "person.fill"); Text(user.nickname); Spacer() }
                        .contextMenu { if user.id != client.serverInfo?.userID { Button("Private Message") { recipient = user.id } } }
                }.listStyle(.sidebar)
            }.frame(width: 190)
        }
    }
    private func connect() {
        guard let value = UInt16(port), value > 0 else { error = "Enter a port between 1 and 65535."; return }
        perform { try await client.connect(host: host, port: value, login: login, password: password, nickname: nickname, table: KDXStorage.loadTable()) }
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
