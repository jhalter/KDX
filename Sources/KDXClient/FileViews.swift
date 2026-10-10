import SwiftUI
import KDXCore

struct FileInspection: Identifiable {
    let path: [String]
    var id: String { path.joined(separator: "/") }
}

struct FileInformationView: View {
    let client: KDXClient
    let path: [String]
    @State private var details: RemoteFileInformation?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(details?.name ?? path.last ?? "Shared Files").font(.title2.bold())
            Text("/" + path.joined(separator: "/")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let details {
                LabeledContent("Kind", value: details.kind.isEmpty ? "File" : details.kind == "folder" ? "Folder" : details.kind.hasPrefix("exttype/") ? String(details.kind.dropFirst(8)).uppercased() + " file" : details.kind)
                if !details.isDirectory {
                    LabeledContent("Data size", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: details.size), countStyle: .file))
                    LabeledContent("Bytes", value: String(details.size))
                }
                LabeledContent("Created", value: details.created?.formatted() ?? "Unavailable")
                LabeledContent("Modified", value: details.modified?.formatted() ?? "Unavailable")
            } else if let error { Text(error).foregroundStyle(.red) }
            else { ProgressView().controlSize(.small) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 450)
        .task {
            do { details = try await client.fileInformation(path: path) }
            catch { self.error = error.localizedDescription }
        }
    }
}
