import SwiftUI
import KDXCore

struct ChatEditorView: View {
    let client: KDXClient
    @State var room: ChatRecord
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(room.id == 0 ? "Create Chat Room" : "Edit Chat Room").font(.title2.bold())
            Form {
                TextField("Name", text: $room.name)
                TextField("Description", text: $room.description)
            }.textFieldStyle(.roundedBorder)
            Text("Access by account class").font(.headline)
            Text("Each user also needs the matching permission on their account.").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow { Text("Class"); Text("Join"); Text("Send"); Text("Set topic") }.font(.caption.bold())
                ForEach(client.accountClasses) { accountClass in
                    GridRow {
                        Text(accountClass.name).frame(maxWidth: .infinity, alignment: .leading)
                        Toggle("Join", isOn: access($room.joinClasses, classID: accountClass.id)).labelsHidden()
                        Toggle("Send", isOn: access($room.sendClasses, classID: accountClass.id)).labelsHidden()
                        Toggle("Set topic", isOn: access($room.topicClasses, classID: accountClass.id)).labelsHidden()
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.disabled(saving)
                Spacer()
                Button(saving ? "Saving…" : "Save") {
                    saving = true; error = nil
                    Task {
                        defer { saving = false }
                        do { try await client.saveChat(room, creating: room.id == 0); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || room.name.isEmpty || client.accountClasses.isEmpty)
            }
        }.padding(24).frame(width: 510)
        .task {
            do { try await client.loadAccountClasses() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func access(_ mask: Binding<UInt32>, classID: UInt8) -> Binding<Bool> {
        let bit: UInt32 = classID < 32 ? UInt32(1) << (31 - Int(classID)) : 0
        return Binding(get: { mask.wrappedValue & bit != 0 }, set: { allowed in
            mask.wrappedValue = allowed ? mask.wrappedValue | bit : mask.wrappedValue & ~bit
        })
    }
}

struct ChatTopicEditor: View {
    let client: KDXClient
    @State var topic: String
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Chat Topic").font(.title2.bold())
            TextField("Topic", text: $topic).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.disabled(saving)
                Spacer()
                Button(saving ? "Saving…" : "Save") {
                    saving = true; error = nil
                    Task {
                        defer { saving = false }
                        do { try await client.setTopic(topic); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(saving)
            }
        }.padding(24).frame(width: 460)
    }
}

struct ChatInviteView: View {
    let client: KDXClient
    @State private var selected: Set<UInt32> = []
    @State private var sending = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Invite to \(client.chatWindow?.name ?? "Chat")").font(.title2.bold())
            Text("Select up to 20 connected users.").foregroundStyle(.secondary)
            List(client.users.filter { $0.id != client.currentUser?.id }) { user in
                Toggle(user.nickname, isOn: Binding(get: { selected.contains(user.id) }, set: { value in
                    if value { selected.insert(user.id) } else { selected.remove(user.id) }
                }))
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(sending ? "Sending…" : "Send Invitations") {
                    sending = true
                    Task {
                        defer { sending = false }
                        do { try await client.inviteToChat(users: selected.sorted()); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || selected.count > 20)
            }
        }.padding(24).frame(width: 420, height: 400).disabled(sending)
    }
}
