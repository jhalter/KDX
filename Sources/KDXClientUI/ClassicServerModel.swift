import Foundation
import Observation
import KDXCore

/// Local server state shared by every classic window. Editors hold independent
/// drafts and commit against a revision so remote administration cannot be lost.
@Observable @MainActor final class ClassicServerModel {
    let server: KDXServer
    private(set) var configuration = ServerConfiguration()
    private(set) var starting = false
    private(set) var configurationError: String?
    var error: String?
    @ObservationIgnored private let configurationURL: URL
    @ObservationIgnored private let tableLoader: () throws -> ChallengeTable
    @ObservationIgnored private var startTask: Task<Void,Never>?
    @ObservationIgnored private let observation = ClassicObservation()
    @ObservationIgnored private var wasRunning = false
    @ObservationIgnored private var lastServerError: String?

    init(server: KDXServer = KDXServer(), configurationURL: URL,
         tableLoader: @escaping () throws -> ChallengeTable = { try KDXStorage.loadTable() }) {
        self.server = server; self.configurationURL = configurationURL
        self.tableLoader = tableLoader
    }
    var editable: Bool { !server.isRunning && !starting && configurationError == nil }
    var status: String {
        if starting { return "Starting server…" }
        if server.isRunning { return "Listening on port \(server.port ?? 0) — \(server.users.count) users connected" }
        return "Server stopped"
    }
    func load() {
        do {
            try FileManager.default.createDirectory(at:configurationURL.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            if FileManager.default.fileExists(atPath:configurationURL.path) { configuration = try ServerConfiguration.load(from:configurationURL) }
            configurationError = nil
        } catch { configurationError = error.localizedDescription; self.error = error.localizedDescription }
        observation.start { [weak self] in
            guard let self else { return }
            let running = server.isRunning
            if running || wasRunning { configuration = server.configuration }
            wasRunning = running
            if server.lastError != lastServerError {
                lastServerError = server.lastError
                if let message = server.lastError { error = message }
            }
        }
    }
    func save(_ candidate: ServerConfiguration, replacing base: ServerConfiguration) throws {
        guard editable else { throw KDXError.invalid("Stop the server before changing local settings.") }
        guard configuration == base else { throw KDXError.invalid("Settings changed in another window or through remote administration. Close and reopen this window before saving.") }
        guard candidate.port > 0 else { throw KDXError.invalid("Enter a port between 1 and 65535.") }
        var candidate = candidate
        candidate.newsFile = configurationURL.deletingLastPathComponent().appendingPathComponent("news.json").path
        try candidate.save(to:configurationURL)
        configuration = candidate
    }
    func start() {
        guard editable else { return }
        do {
            let table = try tableLoader()
            try save(configuration,replacing:configuration)
            let candidate = configuration
            starting = true; lastServerError = nil
            startTask = Task { [weak self] in
                guard let self else { return }
                defer { starting = false; startTask = nil }
                guard !Task.isCancelled else { return }
                do { try await server.start(configuration:candidate,table:table,configurationURL:configurationURL) }
                catch {
                    // Listener failures also arrive through server.lastError.
                    // Report them once; synchronous validation/storage errors come here only.
                    if !Task.isCancelled, server.lastError != error.localizedDescription { self.error = error.localizedDescription }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func stop() {
        if server.isRunning || wasRunning { configuration = server.configuration }
        wasRunning = false
        startTask?.cancel(); server.stop()
    }
    func shutdown() { observation.stop(); stop() }

    static func localSettings(_ base: ServerConfiguration, login: String, password: String, confirmation: String, port: String) throws -> ServerConfiguration {
        guard let port = UInt16(port), port > 0 else { throw KDXError.invalid("Enter a port between 1 and 65535.") }
        guard !login.isEmpty, login.utf8.count <= 31, !login.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {
            throw KDXError.invalid("Enter an administrator login of 1–31 UTF-8 bytes without control characters.")
        }
        guard password == confirmation else { throw KDXError.invalid("Passwords do not match.") }
        var result = base; result.port = port
        let index = base.accounts.firstIndex { $0.effective(in:base.accountClasses).contains(0) }
        guard !base.accounts.enumerated().contains(where: { $0.offset != index && $0.element.login == login }) else {
            throw KDXError.invalid("That login is already used by another account.")
        }
        if let index {
            result.accounts[index].login = login
            if !password.isEmpty { result.accounts[index].setPassword(password) }
        } else {
            guard !password.isEmpty else { throw KDXError.invalid("Enter an administrator password.") }
            result.accounts.append(ServerAccount(login:login,password:password,isAdmin:true))
        }
        return result
    }
}
