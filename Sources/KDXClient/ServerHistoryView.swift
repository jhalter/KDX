import SwiftUI
import KDXCore

struct ServerHistoryView: View {
    let client: KDXClient
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var search = ""
    private var entries: [RemoteHistoryEntry] {
        client.history.reversed().filter { search.isEmpty || [$0.event,$0.nickname,$0.login,$0.address,$0.detail].joined(separator: " ").localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server History").font(.title2.bold())
            Text("Recent activity and live updates. Up to 500 events are retained in this session.").font(.caption).foregroundStyle(.secondary)
            TextField("Filter events, users, or paths", text: $search).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red) }
            Table(entries) {
                TableColumn("Time") { Text($0.date.formatted(date: .abbreviated, time: .standard)) }.width(170)
                TableColumn("Event", value: \.event).width(150)
                TableColumn("User") { entry in
                    VStack(alignment: .leading) {
                        Text(entry.nickname.isEmpty ? "Server" : entry.nickname)
                        if !entry.login.isEmpty { Text(entry.login).font(.caption).foregroundStyle(.secondary) }
                    }
                }.width(120)
                TableColumn("Details") { entry in
                    VStack(alignment: .leading) {
                        Text(entry.detail).textSelection(.enabled)
                        Text(entry.address).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 800, height: 480)
        .task { do { try await client.startHistory() } catch { self.error = error.localizedDescription } }
        .onDisappear { Task { try? await client.stopHistory() } }
    }
}
