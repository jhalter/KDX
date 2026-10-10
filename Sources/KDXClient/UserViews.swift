import SwiftUI
import KDXCore

struct ProfileEditorView: View {
    let client: KDXClient
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var info = ""
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("My Profile").font(.title2.bold())
            Form {
                TextField("Nickname", text: $nickname)
                TextField("About me", text: $info)
            }.textFieldStyle(.roundedBorder)
            Text("The server may require your account name as your nickname.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.disabled(saving)
                Spacer()
                Button(saving ? "Saving…" : "Save") {
                    saving = true; error = nil
                    Task {
                        defer { saving = false }
                        do { try await client.updateProfile(nickname: nickname, info: info); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || nickname.isEmpty || nickname.utf8.count > 255 || info.utf8.count > 127)
            }
        }.padding(24).frame(width: 440)
        .onAppear { nickname = client.currentUser?.nickname ?? ""; info = client.currentUser?.info ?? "" }
    }
}

struct UserInformationView: View {
    let client: KDXClient
    let user: KDXUser
    @Environment(\.dismiss) private var dismiss
    @State private var details: UserInformation?
    @State private var error: String?
    private var current: KDXUser { client.users.first { $0.id == user.id } ?? user }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(current.nickname, systemImage: current.isAdmin ? "person.badge.key.fill" : "person.fill").font(.title2.bold())
            if !current.info.isEmpty { Text(current.info).textSelection(.enabled) }
            LabeledContent("Status", value: current.status == 0 ? "Available" : current.status == 1 ? "Away" : "Status \(current.status)")
            if let details {
                LabeledContent("Account", value: details.login)
                LabeledContent("Address", value: details.address)
                if let date = details.connectedAt { LabeledContent("Connected", value: date.formatted()) }
            } else if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 440)
        .task {
            do { details = try await client.userInformation(id: user.id) }
            catch { self.error = error.localizedDescription }
        }
    }
}
