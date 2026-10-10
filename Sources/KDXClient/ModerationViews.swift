import SwiftUI
import KDXCore

struct BroadcastComposer: View {
    let client: KDXClient
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Broadcast to Everyone").font(.title2.bold())
            Text("Every connected user will receive this message, including users in other chat rooms.").foregroundStyle(.secondary)
            TextEditor(text: $text).frame(minHeight: 180).border(.quaternary)
            Text("\(text.utf8.count) / 2048 bytes").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(sending ? "Sending…" : "Send Broadcast") {
                    sending = true
                    Task {
                        defer { sending = false }
                        do { try await client.sendBroadcast(text); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(text.isEmpty || text.utf8.count > 2048)
            }
        }.padding(24).frame(width: 500).disabled(sending)
    }
}

struct BroadcastHistory: View {
    let client: KDXClient
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server Broadcasts").font(.title2.bold())
            List(client.broadcasts.reversed()) { message in
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.sender).font(.headline)
                    Text(message.text).textSelection(.enabled)
                    Text(message.date.formatted()).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 500, height: 420)
    }
}

struct DisconnectUserView: View {
    let client: KDXClient
    let user: KDXUser
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var quietly = false
    @State private var sending = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Disconnect \(user.nickname)?").font(.title2.bold())
            Text("This ends the user's session and active transfers. They can reconnect.").foregroundStyle(.secondary)
            TextField("Reason (optional)", text: $reason).textFieldStyle(.roundedBorder).disabled(quietly)
            Toggle("Disconnect without a notice", isOn: $quietly)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(sending ? "Disconnecting…" : "Disconnect", role: .destructive) {
                    sending = true
                    Task {
                        defer { sending = false }
                        do { try await client.disconnectUser(id: user.id, reason: quietly ? "" : reason, quietly: quietly); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(reason.utf8.count > 255)
            }
        }.padding(24).frame(width: 440).disabled(sending)
    }
}
