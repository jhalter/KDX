import Foundation
import AppKit
import Observation
import KDXCore

public struct ClassicEndpoint: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name = ""
    public var host = ""
    public var port: UInt16 = 10700
    public var login = ""
    public var nickname = "Guest"
    public var tracker = false
    public var autoJoin = true
    public init() {}
    /// Built-in discovery endpoint. Keep its identity stable across address-book reloads.
    public static let defaultTracker: ClassicEndpoint = {
        var endpoint = ClassicEndpoint()
        endpoint.id = UUID(uuidString:"40B43DF1-3489-4B9B-AFF0-77C43E2BFC73")!
        endpoint.name = "Higher Intellect Tracker"
        endpoint.host = "tracker.preterhuman.net"
        endpoint.port = 10800
        endpoint.tracker = true
        return endpoint
    }()
    public var label: String { name.isEmpty ? host : name }
    public func validate() throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !host.contains("/"), port > 0 else { throw KDXError.invalid("Enter a host and a port from 1 to 65535.") }
    }
}

@MainActor public final class ClassicPreferences {
    public static let suite = "org.macos-kdx.KDXClassic"
    public let defaults: UserDefaults
    public let root: URL
    public init(root: URL? = nil, defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.suite) ?? .standard
        self.root = root ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)).appendingPathComponent("KDX Classic", isDirectory: true)
    }
    public var appearanceID: String? { get { defaults.string(forKey: "appearance") } set { defaults.set(newValue, forKey: "appearance") } }
    public var smallButtonBar: Bool { get { defaults.bool(forKey:"smallButtonBar") } set { defaults.set(newValue,forKey:"smallButtonBar") } }
    public var smallUserIcons: Bool {
        get { defaults.object(forKey:"smallUserIcons") as? Bool ?? true }
        set { defaults.set(newValue,forKey:"smallUserIcons") }
    }
    public var smallFileIcons: Bool {
        get { defaults.object(forKey:"smallFileIcons") as? Bool ?? true }
        set { defaults.set(newValue,forKey:"smallFileIcons") }
    }
    public func endpoints() throws -> [ClassicEndpoint] {
        let url = root.appendingPathComponent("address-book.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [.defaultTracker] }
        let data = try Data(contentsOf: url)
        guard data.count < 1024*1024 else { throw KDXError.invalid("Address book exceeds its size limit.") }
        return try JSONDecoder().decode([ClassicEndpoint].self, from: data)
    }
    public func save(endpoints: [ClassicEndpoint]) throws {
        guard endpoints.count <= 1000 else { throw KDXError.invalid("The address book is full.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(endpoints).write(to: root.appendingPathComponent("address-book.json"), options: .atomic)
    }
    public func frame(key: String, fallback: NSRect, screens: [NSRect], minimumSize: NSSize = NSSize(width:180,height:60)) -> NSRect {
        let frame = defaults.string(forKey: "frame."+key).map(NSRectFromString) ?? fallback
        return Self.constrain(frame, to: screens, fallback: fallback,minimumSize:minimumSize)
    }
    public static func constrain(_ frame: NSRect, to screens: [NSRect], fallback: NSRect, minimumSize: NSSize = NSSize(width:180,height:60)) -> NSRect {
        let valid = [frame.minX,frame.minY,frame.width,frame.height].allSatisfy(\.isFinite) && frame.width >= minimumSize.width && frame.height >= minimumSize.height
        // An unavailable display list is not evidence that a saved frame is bad.
        guard let screen = screens.max(by: { $0.intersection(frame).area < $1.intersection(frame).area }) else { return valid ? frame : fallback }
        guard valid else { return fallback.intersection(screen) }
        let width = min(frame.width, screen.width), height = min(frame.height, screen.height)
        return NSRect(x: max(screen.minX, min(frame.minX, screen.maxX-width)), y: max(screen.minY, min(frame.minY, screen.maxY-height)), width: width, height: height)
    }
    public func save(frame: NSRect, key: String) { defaults.set(NSStringFromRect(frame), forKey: "frame."+key) }
}
private extension NSRect { var area: CGFloat { isNull ? 0 : width*height } }

public enum ClassicWindowKind: Hashable, Sendable {
    case chat(UInt32), privateMessage(UInt32), composeMessage(UInt32), privateMessages, profile, users, files(UUID), transfers, rooms
}
public struct ClassicWindowKey: Hashable, Sendable {
    public let session: UUID
    public let kind: ClassicWindowKind
    public init(session: UUID, kind: ClassicWindowKind) { self.session = session; self.kind = kind }
}

@Observable @MainActor public final class ClassicSession {
    public let id = UUID()
    public let endpoint: ClassicEndpoint
    public let client: KDXClient
    public let transfers: ClassicTransferQueue
    public var error: String?
    public var drafts: [ClassicWindowKind: String] = [:]
    @ObservationIgnored var connectionTask: Task<Void, Never>?
    @ObservationIgnored let privateMessages = ClassicPrivateMessagesState()
    @ObservationIgnored private var bannerState = ClassicServerBannerState()
    var serverBanner: HAPBitmap? { bannerState.update(client.serverIcon,connected:client.isConnected) }
    public var title: String { client.serverInfo?.name ?? endpoint.label }
    public init(endpoint: ClassicEndpoint, client: KDXClient? = nil) {
        self.endpoint = endpoint; self.client = client ?? KDXClient()
        self.transfers = ClassicTransferQueue(client: self.client)
    }
    public func connect(password: String, table: ChallengeTable) {
        connectionTask?.cancel(); client.disconnect()
        privateMessages.reset()
        drafts = drafts.filter {
            switch $0.key { case .privateMessage, .composeMessage: return false; default: return true }
        }
        bannerState = ClassicServerBannerState()
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do { try await client.connect(host: endpoint.host == "0" ? "127.0.0.1" : endpoint.host, port: endpoint.port, login: endpoint.login, password: password, nickname: endpoint.nickname, autoJoinPublicChat: endpoint.autoJoin, table: table) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    /// Once submitted, finish the authenticated frame independently of a window's
    /// task. Canceling a write after encryption advances the cipher would force
    /// the core to close the connection shared by the session's other windows.
    func sendPrivate(to recipient: UInt32, text: String, generation: UUID) async throws {
        try Task.checkCancellation()
        guard generation == privateMessages.generation else { throw KDXError.disconnected }
        let writing = Task { @MainActor [self] in
            guard generation == privateMessages.generation else { throw KDXError.disconnected }
            try await client.sendPrivate(to:recipient,text:text)
        }
        try await writing.value
    }
    public func disconnect() { bannerState = ClassicServerBannerState(); connectionTask?.cancel(); connectionTask = nil; transfers.pauseAll(); client.disconnect() }
}

public enum ClassicTransferState: String, Sendable { case queued, running, stopping, stopped, failed, complete }
@Observable @MainActor public final class ClassicTransfer: Identifiable {
    public let id = UUID()
    public let folder: [String]
    public let localURL: URL
    public let file: RemoteFile?
    public var state: ClassicTransferState = .queued
    public var error: String?
    public var progress = 0.0
    public var name: String { file?.name ?? localURL.lastPathComponent }
    public var isUpload: Bool { file == nil }
    public init(folder: [String], localURL: URL, file: RemoteFile? = nil) { self.folder = folder; self.localURL = localURL; self.file = file }
}

@Observable @MainActor public final class ClassicTransferQueue {
    public private(set) var items: [ClassicTransfer] = []
    public private(set) var activeID: UUID?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let perform: @MainActor (ClassicTransfer) async throws -> Void
    @ObservationIgnored private let cancel: @MainActor () -> Void
    @ObservationIgnored private let progress: @MainActor () -> Double
    public var hasPending: Bool { items.contains { [.queued,.running,.stopping].contains($0.state) } }
    public init(client: KDXClient) {
        perform = { item in
            if let file = item.file { try await client.download(file, at: item.folder, to: item.localURL) }
            else { try await client.upload(from: item.localURL, to: item.folder) }
        }
        cancel = { client.cancelTransfer() }; progress = { client.transferProgress }
    }
    init(perform: @escaping @MainActor (ClassicTransfer) async throws -> Void, cancel: @escaping @MainActor () -> Void, progress: @escaping @MainActor () -> Double = { 0 }) {
        self.perform = perform; self.cancel = cancel; self.progress = progress
    }
    public func enqueue(_ item: ClassicTransfer) { items.append(item); pump() }
    public func sampleProgress() { if let item = items.first(where: { $0.id == activeID }) { item.progress = progress() } }
    public func stop(_ item: ClassicTransfer) {
        guard item.state != .complete else { return }
        if activeID == item.id { item.state = .stopping; worker?.cancel(); cancel() }
        else { item.state = .stopped }
    }
    public func retry(_ item: ClassicTransfer) {
        guard [.stopped,.failed].contains(item.state) else { return }
        item.state = .queued; item.error = nil; pump()
    }
    public func move(_ item: ClassicTransfer, by delta: Int) {
        guard item.id != activeID, let index = items.firstIndex(where: { $0.id == item.id }), !items.isEmpty else { return }
        items.remove(at: index); items.insert(item, at: max(0,min(items.count,index+delta)))
    }
    public func remove(_ item: ClassicTransfer) { guard activeID != item.id else { return }; items.removeAll { $0.id == item.id } }
    public func clearCompleted() { items.removeAll { $0.state == .complete } }
    public func pauseAll() { for item in items where [.queued,.running,.stopping].contains(item.state) { stop(item) } }
    private func pump() {
        guard worker == nil, let next = items.first(where: { $0.state == .queued }) else { return }
        activeID = next.id; next.state = .running; next.progress = 0
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                try await perform(next)
                next.state = .complete; next.progress = 1
            } catch {
                if Task.isCancelled || next.state == .stopping { next.state = .stopped }
                else { next.state = .failed; next.error = error.localizedDescription }
            }
            activeID = nil; worker = nil; pump()
        }
    }
}

/// The registration holds only a weak reference. Closing a controller invalidates already-scheduled callbacks.
@MainActor final class ClassicObservation {
    private var generation = UUID()
    private var update: (@MainActor () -> Void)?
    func start(_ update: @escaping @MainActor () -> Void) { self.update = update; track() }
    func stop() { generation = UUID(); update = nil }
    private func track() {
        guard let update else { return }
        let token = generation
        withObservationTracking { update() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.track()
            }
        }
    }
}
