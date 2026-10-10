import SwiftUI
import KDXCore

struct ConnectionMonitorView: View {
    let client: KDXClient
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [MonitoredConnection] = []
    @State private var error: String?
    @State private var refreshing = false
    @State private var refreshID = UUID()
    @State private var updated: Date?
    @State private var search = ""
    private var filtered: [MonitoredConnection] {
        entries.filter { search.isEmpty || [$0.nickname,$0.login,$0.accountName,$0.address].joined(separator: " ").localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Connection Monitor").font(.title2.bold())
                Spacer()
                if refreshing { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }.disabled(refreshing)
            }
            TextField("Filter users, accounts, or addresses", text: $search).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red) }
            Table(filtered) {
                TableColumn("User", value: \.nickname).width(120)
                TableColumn("Account") { entry in
                    VStack(alignment: .leading) {
                        Text(entry.login)
                        Text(entry.accountName).font(.caption).foregroundStyle(.secondary)
                    }
                }.width(150)
                TableColumn("Address", value: \.address).width(160)
                TableColumn("Connected") { entry in
                    Text(entry.connectedAt?.formatted(date: .abbreviated, time: .standard) ?? "Unknown")
                }
                TableColumn("Last activity") { entry in
                    Text(entry.lastActiveAt?.formatted(date: .omitted, time: .standard) ?? "Unknown")
                }
            }
            HStack {
                if let updated { Text("\(entries.count) sessions · Updated \(updated.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 850, height: 460)
        .task(id: refreshID) { await poll() }
    }
    private func poll() async {
        do {
            while !Task.isCancelled {
                refreshing = true; error = nil
                entries = try await client.connectionMonitor(); updated = Date(); refreshing = false
                try await Task.sleep(for: .seconds(3))
            }
        } catch is CancellationError { refreshing = false }
        catch { refreshing = false; entries = []; self.error = error.localizedDescription }
    }
}
