import SwiftUI
import KDXCore

struct NewsGroupEditorView: View {
    let client: KDXClient
    @State var group: NewsGroupInfo
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(group.id == 0 ? "Create Newsgroup" : "Edit Newsgroup").font(.title2.bold())
            Form {
                TextField("Name", text: $group.name)
                TextField("Description", text: $group.description)
                TextField("Storage limit (KiB)", value: $group.sizeLimitKiB, format: .number)
            }.textFieldStyle(.roundedBorder)
            Text("Oldest posts are removed when the storage limit is exceeded. Reducing the limit can remove existing posts.").font(.caption).foregroundStyle(.secondary)
            Text("Access by account class").font(.headline)
            Text("Users also need the matching account permission.").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow { Text("Class"); Text("Read"); Text("Post") }.font(.caption.bold())
                ForEach(client.accountClasses) { accountClass in
                    GridRow {
                        Text(accountClass.name).frame(maxWidth: .infinity, alignment: .leading)
                        Toggle("Read", isOn: access($group.readClasses, classID: accountClass.id)).labelsHidden()
                        Toggle("Post", isOn: access($group.postClasses, classID: accountClass.id)).labelsHidden()
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.disabled(saving)
                Spacer()
                Button(saving ? "Saving…" : "Save") {
                    saving = true; error = nil
                    Task {
                        defer { saving = false }
                        do { try await client.saveNewsGroup(group, creating: group.id == 0); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || group.name.isEmpty || group.sizeLimitKiB == 0 || client.accountClasses.isEmpty)
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
