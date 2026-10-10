import SwiftUI
import KDXCore

struct TrackerBrowserView: View {
    let choose: (String, UInt16) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tracker.host") private var host = ""
    @AppStorage("tracker.port") private var port = "10800"
    @State private var groups: [TrackerGroup] = []
    @State private var servers: [TrackerServer] = []
    @State private var selectedGroup: Int?
    @State private var selectedServer: Int?
    @State private var search = ""
    @State private var error: String?
    @State private var lookup: Task<Void, Never>?
    @State private var lookupID = UUID()
    @State private var browsed = false
    private var visibleServers: [TrackerServer] {
        servers.filter { search.isEmpty || "\($0.name) \($0.description) \($0.host ?? "")".localizedCaseInsensitiveContains(search) }
    }
    private var chosen: TrackerServer? { visibleServers.first { $0.id == selectedServer } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Browse Trackers").font(.title2.bold())
            HStack {
                TextField("Tracker address", text: $host)
                TextField("Port", text: $port).frame(width: 80)
                Button("Browse", action: loadGroups).disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lookup != nil)
            }.textFieldStyle(.roundedBorder).disabled(lookup != nil)
            HSplitView {
                VStack(alignment: .leading) {
                    Text("Groups").font(.headline)
                    List(groups, selection: $selectedGroup) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(group.name.isEmpty ? "Unnamed group" : group.name); Spacer(); Text("\(group.serverCount)").foregroundStyle(.secondary) }
                            if !group.description.isEmpty { Text(group.description).font(.caption).foregroundStyle(.secondary) }
                        }.tag(group.id)
                    }
                    .overlay { if groups.isEmpty { Text(browsed ? "No groups listed." : "Enter a tracker address to browse.").foregroundStyle(.secondary).padding() } }
                }.frame(minWidth: 180, idealWidth: 220)
                VStack(alignment: .leading) {
                    HStack {
                        Text("Servers").font(.headline)
                        Spacer()
                        Button("Refresh", systemImage: "arrow.clockwise") { loadServers() }.labelStyle(.iconOnly).disabled(selectedGroup == nil || lookup != nil)
                    }
                    TextField("Search servers", text: $search).textFieldStyle(.roundedBorder)
                    List(visibleServers, selection: $selectedServer) { server in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(server.name.isEmpty ? "Unnamed entry" : server.name, systemImage: server.isTracker ? "network" : "server.rack").font(.headline)
                            if !server.description.isEmpty { Text(server.description).font(.callout).foregroundStyle(.secondary) }
                            if let host = server.host, let port = server.port {
                                Text("\(host):\(String(port))").font(.caption).foregroundStyle(.secondary)
                            } else { Text("Unsupported address format").font(.caption).foregroundStyle(.secondary) }
                        }.tag(server.id)
                    }.overlay {
                        if servers.isEmpty && lookup == nil { Text(selectedGroup == nil ? "Select a group." : "No servers listed.").foregroundStyle(.secondary) }
                        else if !servers.isEmpty && visibleServers.isEmpty { Text("No matching servers.").foregroundStyle(.secondary) }
                    }
                }.frame(minWidth: 350)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if lookup != nil {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                    Button("Cancel") { cancel() }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(chosen?.isTracker == true ? "Use Tracker Address" : "Use Server") {
                    if let server = chosen, let address = server.host, let number = server.port, number > 0 {
                        if server.isTracker { host = address; port = String(number); reset() }
                        else { choose(address, number); dismiss() }
                    }
                }.buttonStyle(.borderedProminent).disabled(chosen?.host == nil || chosen?.port == nil || chosen?.port == 0 || lookup != nil)
            }
        }.padding(24).frame(width: 780, height: 560)
            .onChange(of: selectedGroup) { _, value in if value != nil || !groups.isEmpty { loadServers() } }
            .onChange(of: host) { _, _ in reset() }
            .onChange(of: port) { _, _ in reset() }
            .onDisappear { cancel() }
    }
    private func cancel() { lookupID = UUID(); lookup?.cancel(); lookup = nil }
    private func reset() { cancel(); groups = []; servers = []; selectedGroup = nil; selectedServer = nil; browsed = false; error = nil }
    private func endpoint() throws -> KDXTrackerClient {
        guard let number = UInt16(port), number > 0 else { throw KDXError.invalid("Enter a port between 1 and 65535.") }
        return KDXTrackerClient(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: number)
    }
    private func loadGroups() {
        reset()
        let id = lookupID
        lookup = Task {
            defer { if lookupID == id { lookup = nil } }
            do {
                let result = try await endpoint().groups(table: KDXStorage.loadTable())
                guard !Task.isCancelled, lookupID == id else { return }
                groups = result; browsed = true
            } catch { if !Task.isCancelled, lookupID == id { self.error = error.localizedDescription } }
        }
    }
    private func loadServers() {
        cancel(); servers = []; selectedServer = nil; error = nil
        guard let group = groups.first(where: { $0.id == selectedGroup }) else { return }
        let id = lookupID
        lookup = Task {
            defer { if lookupID == id { lookup = nil } }
            do {
                let result = try await endpoint().servers(in: group, table: KDXStorage.loadTable())
                guard !Task.isCancelled, lookupID == id else { return }
                servers = result
            } catch { if !Task.isCancelled, lookupID == id { self.error = error.localizedDescription } }
        }
    }
}
