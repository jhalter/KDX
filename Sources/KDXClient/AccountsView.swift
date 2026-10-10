import SwiftUI
import KDXCore

struct AccountsView: View {
    let client: KDXClient
    @State private var error: String?
    @State private var editing: RemoteAccount?
    @State private var originalLogin: String?
    @State private var deleting: AccountListEntry?
    @State private var busy = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Accounts").font(.title2.bold())
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                Button("New Account", systemImage: "person.badge.plus") {
                    originalLogin = nil; editing = RemoteAccount()
                }
            }.padding()
            if client.accounts.isEmpty {
                ContentUnavailableView("No accounts loaded", systemImage: "person.2.badge.key", description: Text("Your account needs permission to view and manage server accounts."))
            } else {
                List(client.accounts) { entry in
                    HStack {
                        VStack(alignment: .leading) { Text(entry.name.isEmpty ? entry.login : entry.name).font(.headline); Text(entry.login).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(client.accountClasses.first { $0.id == entry.classID }?.name ?? "Class \(entry.classID)").foregroundStyle(.secondary)
                        Button("Edit") {
                            perform { originalLogin = entry.login; editing = try await client.account(login: entry.login) }
                        }
                        Button("Delete", role: .destructive) { deleting = entry }
                    }.padding(.vertical, 4)
                }
            }
        }.disabled(busy)
        .overlay(alignment: .bottom) { if busy { ProgressView().padding() } }
        .task { refresh() }
        .sheet(item: $editing) { account in
            AccountEditor(client: client, initial: account, originalLogin: originalLogin) { refresh() }
        }
        .confirmationDialog("Delete account \(deleting?.login ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) {
                guard let login = deleting?.login else { return }; deleting = nil
                perform { try await client.deleteAccount(login: login); if client.isConnected { try await client.loadAccounts() } }
            }
        } message: { Text("The account will be removed from the server. Active sessions using it will disconnect.") }
        .alert("Accounts", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func refresh() { perform { try await client.loadAccountClasses(); try await client.loadAccounts() } }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
}

private struct AccountEditor: View {
    let client: KDXClient
    let originalLogin: String?
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var account: RemoteAccount
    @State private var password = ""
    @State private var replacePassword = false
    @State private var busy = false
    @State private var error: String?
    init(client: KDXClient, initial: RemoteAccount, originalLogin: String?, onSave: @escaping () -> Void) {
        self.client = client; self.originalLogin = originalLogin; self.onSave = onSave
        _account = State(initialValue: initial)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(originalLogin == nil ? "New Account" : "Edit Account").font(.title2.bold())
            Form {
                TextField("Login", text: $account.login)
                TextField("Display name", text: $account.name)
                Picker("Account class", selection: $account.classID) {
                    ForEach(client.accountClasses) { entry in Text(entry.name).tag(entry.id) }
                }
                if originalLogin != nil { Toggle("Replace password", isOn: $replacePassword) }
                if originalLogin == nil || replacePassword {
                    SecureField("Password", text: $password)
                    Text("An empty password allows password-free login to this account.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Privilege overrides") {
                    ForEach(AccountPrivileges.editable, id: \.bit) { privilege in
                        Picker(privilege.name, selection: Binding(get: {
                            account.privilegeMask.contains(privilege.bit) ? (account.privileges.contains(privilege.bit) ? 1 : 0) : -1
                        }, set: { value in
                            account.privilegeMask.set(privilege.bit, value != -1)
                            account.privileges.set(privilege.bit, value == 1)
                        })) {
                            Text("From class").tag(-1); Text("Allow").tag(1); Text("Deny").tag(0)
                        }
                    }
                }
            }.formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Save") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            if let originalLogin { try await client.updateAccount(account, originalLogin: originalLogin, newPassword: replacePassword ? password : nil) }
                            else { try await client.createAccount(account, password: password) }
                            onSave(); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(account.login.isEmpty)
            }
        }.padding().frame(width: 580, height: 660).disabled(busy)
        .alert("Account", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
}

struct ChangePasswordView: View {
    let client: KDXClient
    let onChanged: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change Password").font(.title2.bold())
            SecureField("New password", text: $password)
            SecureField("Confirm password", text: $confirmation)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Change Password") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await client.changePassword(to: password); onChanged(password); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(password.isEmpty || password != confirmation)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 420).disabled(busy)
        .alert("Password", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
}
