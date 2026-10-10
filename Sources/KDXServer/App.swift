import SwiftUI
import UniformTypeIdentifiers
import KDXCore
import AppKit

@main struct KDXServerApp: App {
    var body: some Scene { Window("KDX Server", id: "server") { ServerView().frame(minWidth: 820, minHeight: 600) }.defaultSize(width: 980, height: 740) }
}
struct ServerView: View {
    @State private var server = KDXServer()
    @State private var configuration = ServerConfiguration()
    @State private var port = "10700"
    @State private var accountLogin = ""
    @State private var accountPassword = ""
    @State private var accountAdmin = false
    @State private var error: String?
    @State private var importing = false
    @State private var tableReady = false
    @State private var starting = false
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                Label("KDX Server", systemImage: "server.rack").font(.title.bold())
                Label(server.isRunning ? "Listening on \(server.port ?? 0)" : "Stopped", systemImage: "circle.fill")
                    .foregroundStyle(server.isRunning ? .green : .secondary)
                Text("\(server.users.count)").font(.system(size: 48, weight: .light, design: .rounded))
                Text("connected users").foregroundStyle(.secondary)
                if server.isRunning { Button("Stop Server", systemImage: "stop.fill") { server.stop() }.buttonStyle(.bordered) }
                else { Button(starting ? "Starting…" : "Start Server", systemImage: "play.fill", action: start).buttonStyle(.borderedProminent).disabled(!tableReady || starting) }
                Spacer()
                Label(tableReady ? "Challenge table ready" : "Challenge table required", systemImage: "key").font(.caption)
                Button("Import KDX Binary or Table…") { importing = true }.disabled(server.isRunning)
                Text("Use an uncompressed original KDX binary or an exported challenge-table.bin.").font(.caption).foregroundStyle(.secondary)
            }.padding().navigationSplitViewColumnWidth(min: 235, ideal: 260)
        } detail: {
            TabView {
                Form {
                    Section("Server") {
                        TextField("Name", text: $configuration.name)
                        TextField("Description", text: $configuration.description)
                        TextField("TCP port", text: $port)
                        Toggle("Allow guest connections", isOn: $configuration.allowGuests)
                        LabeledContent("Shared folder") {
                            Text(configuration.sharedFolder.isEmpty ? "None" : configuration.sharedFolder).lineLimit(1).truncationMode(.middle)
                            Button("Choose…") {
                                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                                panel.begin { result in if result == .OK, let url = panel.url { configuration.sharedFolder = url.path } }
                            }
                        }
                        Text("Guests may download. Signed-in accounts may upload. Existing files are never overwritten.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Accounts") {
                        ForEach(configuration.accounts) { account in
                            HStack {
                                Label(account.login, systemImage: account.isAdmin ? "person.badge.key" : "person")
                                Spacer(); Text(account.isAdmin ? "Administrator" : "Member").foregroundStyle(.secondary)
                                Button("Remove", role: .destructive) { configuration.accounts.removeAll { $0.id == account.id } }
                            }
                        }
                        TextField("Login", text: $accountLogin)
                        SecureField("Password", text: $accountPassword)
                        Toggle("Administrator", isOn: $accountAdmin)
                        Button("Add Account") { addAccount() }.disabled(accountLogin.isEmpty || accountPassword.isEmpty)
                    }
                    Button("Save Settings") { save() }
                    Text("Changes apply when the server next starts. Passwords are stored as KDX account keys in an owner-readable settings file.").font(.caption).foregroundStyle(.secondary)
                }.formStyle(.grouped).disabled(server.isRunning || starting).tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                VStack {
                    if server.users.isEmpty { ContentUnavailableView("No connected users", systemImage: "person.2", description: Text("Clients appear here after signing in.")) }
                    else {
                        Table(server.users) {
                            TableColumn("Nickname", value: \.nickname)
                            TableColumn("Role") { user in Text(user.isAdmin ? "Administrator" : "Member") }
                            TableColumn("Connection") { user in Button("Disconnect") { server.disconnectUser(user.id) } }
                        }
                    }
                }.tabItem { Label("Users", systemImage: "person.2") }
                List(server.log) { entry in
                    HStack(alignment: .top) { Text(entry.date, style: .time).monospacedDigit().foregroundStyle(.secondary); Text(entry.text).textSelection(.enabled) }
                }.tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
            }.padding()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .item]) { result in
            do { try KDXStorage.importTable(from: result.get()); tableReady = true } catch { self.error = error.localizedDescription }
        }
        .task {
            tableReady = (try? KDXStorage.loadTable()) != nil
            do {
                let url = try KDXStorage.configurationURL()
                if FileManager.default.fileExists(atPath: url.path) { configuration = try ServerConfiguration.load(from: url); port = String(configuration.port) }
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: server.lastError) { _, value in if let value { error = value } }
        .alert("KDX Server", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func addAccount() {
        guard accountLogin.utf8.count <= 31, !configuration.accounts.contains(where: { $0.login == accountLogin }) else { error = "Use a unique login of at most 31 UTF-8 bytes."; return }
        configuration.accounts.append(ServerAccount(login: accountLogin, password: accountPassword, isAdmin: accountAdmin))
        accountLogin = ""; accountPassword = ""; accountAdmin = false
    }
    private func save() {
        do {
            guard let value = UInt16(port), value > 0 else { throw KDXError.invalid("Enter a port between 1 and 65535.") }
            configuration.port = value
            configuration.newsFile = try KDXStorage.directory().appendingPathComponent("news.json").path
            try configuration.save(to: KDXStorage.configurationURL())
        } catch { self.error = error.localizedDescription }
    }
    private func start() {
        guard let value = UInt16(port), value > 0 else { error = "Enter a port between 1 and 65535."; return }
        configuration.port = value; starting = true
        Task {
            defer { starting = false }
            do {
                configuration.newsFile = try KDXStorage.directory().appendingPathComponent("news.json").path
                try configuration.save(to: KDXStorage.configurationURL())
                try await server.start(configuration: configuration, table: KDXStorage.loadTable())
            } catch { self.error = error.localizedDescription }
        }
    }
}
