import SwiftUI
import KDXCore

struct ServerSettingsView: View {
    let client: KDXClient
    @State private var settings: RemoteServerSettings?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if let settings { ServerSettingsEditor(client: client, initial: settings) }
            else {
                VStack(spacing: 16) {
                    if let error { Text(error).foregroundStyle(.red) } else { ProgressView("Loading server settings…") }
                    Button("Cancel") { dismiss() }
                }.padding(24).frame(width: 440)
            }
        }.task {
            do { settings = try await client.serverSettings() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct ServerSettingsEditor: View {
    let client: KDXClient
    @State private var settings: RemoteServerSettings
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(client: KDXClient, initial: RemoteServerSettings) { self.client = client; _settings = State(initialValue: initial) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server Settings").font(.title2.bold())
            TextField("Server name", text: $settings.name).textFieldStyle(.roundedBorder)
            Toggle("Show greeting on login", isOn: $settings.greetingEnabled)
            TextEditor(text: $settings.greeting).frame(height: 160).border(.quaternary)
            TextField("Total download limit (bytes/sec)", value: $settings.downloadLimit, format: .number).textFieldStyle(.roundedBorder)
            Text("Use 0 for unlimited speed. The limit is shared across all downloads. Changing it interrupts active downloads; retry them to resume.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await client.updateServerSettings(settings); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(settings.name.isEmpty || settings.name.utf8.count > 255 || settings.greeting.utf8.count > 8192)
            }
        }.padding(24).frame(width: 520).disabled(saving)
    }
}

struct ServerGreetingView: View {
    let client: KDXClient
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(client.serverInfo?.name ?? "Server Greeting").font(.title2.bold())
            ScrollView { Text(client.greeting ?? error ?? "Loading greeting…").frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 480, height: 320)
        .task { do { try await client.loadGreeting() } catch { self.error = error.localizedDescription } }
    }
}
