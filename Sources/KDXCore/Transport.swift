import Foundation
@preconcurrency import Network

@MainActor protocol ByteTransport: AnyObject {
    var endpointDescription: String { get }
    var peerHost: String { get }
    func start() async throws
    func read(_ count: Int) async throws -> [UInt8]
    func write(_ bytes: [UInt8]) async throws
    func close()
}

/// Network.framework handles socket I/O; state and continuations are serialized on the main actor.
@MainActor final class TCPTransport: ByteTransport {
    let network: NWConnection
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var closed = false
    var endpointDescription: String { network.endpoint.debugDescription }
    var peerHost: String { if case .hostPort(let host, _) = network.endpoint { return host.debugDescription }; return endpointDescription }
    init(network: NWConnection) { self.network = network }
    convenience init(host: String, port: UInt16) throws {
        guard port > 0, !host.isEmpty, let endpoint = NWEndpoint.Port(rawValue: port) else { throw KDXError.invalid("Enter a host and port between 1 and 65535.") }
        self.init(network: NWConnection(host: NWEndpoint.Host(host), port: endpoint, using: .tcp))
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            readyWaiter = continuation
            network.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.readyWaiter?.resume(); self.readyWaiter = nil
                    case .failed(let error): self.failReady(error); self.close()
                    case .cancelled: self.failReady(KDXError.disconnected)
                    default: break
                    }
                }
            }
            network.start(queue: .main)

        }
    }
    private func failReady(_ error: Error) { readyWaiter?.resume(throwing: error); readyWaiter = nil }
    func close() { guard !closed else { return }; closed = true; failReady(KDXError.disconnected); network.cancel() }
    func read(_ count: Int) async throws -> [UInt8] {
        guard !closed else { throw KDXError.disconnected }
        if count == 0 { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            network.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: Array(data)) }
                else { continuation.resume(throwing: complete ? KDXError.disconnected : KDXError.invalid("Truncated TCP data.")) }
            }
        }
    }
    func write(_ bytes: [UInt8]) async throws {
        guard !closed else { throw KDXError.disconnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            network.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

@MainActor final class WireConnection {
    private let transport: any ByteTransport
    var cipher: SessionCipher?
    private var nextTransaction = UInt32.random(in: 1...UInt32.max)
    private var closed = false
    var ioTimeout: Duration?
    var handshakeTimeout: Duration = .seconds(15)
    var endpointDescription: String { transport.endpointDescription }
    var peerHost: String { transport.peerHost }
    init(transport: any ByteTransport) { self.transport = transport }
    convenience init(network: NWConnection) { self.init(transport: TCPTransport(network: network)) }
    convenience init(host: String, port: UInt16) throws { self.init(transport: try TCPTransport(host: host, port: port)) }
    func start() async throws { try await performIO(timeout: handshakeTimeout) { try await self.transport.start() } }
    func close() { guard !closed else { return }; closed = true; transport.close() }
    func read(_ count: Int, timeout: Duration? = nil) async throws -> [UInt8] { try await performIO(timeout: timeout ?? ioTimeout) { try await self.transport.read(count) } }
    func write(_ bytes: [UInt8]) async throws { try await performIO(timeout: ioTimeout ?? .seconds(30)) { try await self.transport.write(bytes) } }
    private func performIO<T: Sendable>(timeout: Duration?, _ operation: @MainActor () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard !closed else { throw KDXError.disconnected }
        var timedOut = false
        let timer = timeout.map { duration in
            Task { [weak self] in
                do { try await Task.sleep(for: duration) } catch { return }
                timedOut = true; self?.close()
            }
        }
        defer { timer?.cancel() }
        return try await withTaskCancellationHandler {
            do {
                let value = try await operation()
                try Task.checkCancellation()
                if timedOut { throw KDXError.invalid("The connection stopped responding.") }
                guard !closed else { throw KDXError.disconnected }
                return value
            } catch {
                if timedOut { throw KDXError.invalid("The connection stopped responding.") }
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
    }
    func receiveHello() async throws -> Hello {
        var bytes = try await read(36)
        let remaining = try Hello.length(bytes) - 36
        bytes += try await read(remaining)
        return try Hello(wire: bytes)
    }
    func authenticateClient(name: [UInt8], key: AccountKey, table: ChallengeTable) async throws {
        let timeout = Task { [weak self] in try? await Task.sleep(for: self?.handshakeTimeout ?? .seconds(15)); if !Task.isCancelled { self?.close() } }
        defer { timeout.cancel() }
        let hello = Hello(server: false, name: name)
        try await write(hello.encode())
        let server = try await receiveHello()
        guard server.nonce != hello.nonce else { throw KDXError.authentication }
        try await write(Proof(key: key, nonce: server.nonce, response: table.response(server.challenge)).encode())
        try Proof(wire: await read(44)).verify(key: key, nonce: hello.nonce, response: table.response(hello.challenge))
        cipher = SessionCipher(key: key)
    }
    func allocateTransaction() -> UInt32 {
        let value = nextTransaction; nextTransaction = nextTransaction &+ 1; if nextTransaction == 0 { nextTransaction = 1 }; return value
    }
    @discardableResult func send(type: UInt32, payload: [UInt8] = [], transaction: UInt32? = nil, reply: Bool = false) async throws -> UInt32 {
        guard let cipher else { throw KDXError.authentication }
        let id = transaction ?? allocateTransaction()
        try await write(cipher.seal(Message(transaction: id, type: type, isReply: reply, payload: payload)))
        return id
    }
    func receive(limit: Int = 0x100000, newsLimit: Int? = nil) async throws -> Message {
        guard let cipher else { throw KDXError.authentication }
        let header = try cipher.header(await read(16), limit: max(limit, newsLimit ?? limit))
        guard header.length <= (header.type == 608 ? newsLimit ?? limit : limit) else { throw KDXError.invalid("Message exceeds its protocol limit.") }
        return try await cipher.open(header, payload: read(header.paddedLength, timeout: .seconds(30)))
    }
    func sendFile(type: UInt32, length: UInt32, source: FileHandle?, resourceOffset: UInt64? = nil, transaction: UInt32? = nil, reply: Bool = false, progress: (UInt64) -> Void = { _ in }) async throws {
        guard let cipher else { throw KDXError.authentication }
        let tx = transaction ?? allocateTransaction()
        try await write(cipher.sealHeader(transaction: tx, type: type, reply: reply, length: length))
        let fill = (tx &* 0x41c64e6d &+ 0x3039).leBytes
        var sent = 0
        while sent < Int(length) {
            try Task.checkCancellation()
            let count = min(65536, Int(length) - sent)
            guard let source else { throw KDXError.invalid("Missing transfer source.") }
            let bytes = try resourceOffset.map { try ResourceFork.read(source.fileDescriptor, offset: $0 + UInt64(sent), count: count) } ?? source.read(upToCount: count)
            guard let bytes, bytes.count == count else { throw KDXError.invalid("Source file ended before its advertised size.") }
            var plain = Array(bytes)
            while plain.count % 16 != 0 { plain.append(fill[plain.count % 4]) }
            var encrypted = [UInt8](); encrypted.reserveCapacity(plain.count)
            for at in stride(from: 0, to: plain.count, by: 16) { encrypted += cipher.cipher.encrypt(Array(plain[at..<at+16])) }
            try await write(encrypted); sent += count; progress(UInt64(sent))
        }
    }
    func receiveFile(type: UInt32, sink: FileHandle?, maximum: UInt64, resourceOffset: UInt64? = nil, transaction: UInt32? = nil, progress: (UInt64) -> Void = { _ in }) async throws -> UInt64 {
        guard let cipher else { throw KDXError.authentication }
        let header = try cipher.header(await read(16), limit: Int(UInt32.max))
        guard header.type == type, transaction == nil || (header.transaction == transaction && header.flags & 1 != 0), UInt64(header.length) <= maximum, header.length == 0 || sink != nil else { throw KDXError.invalid("Unexpected transfer data or size.") }
        var received = 0
        while received < header.length {
            try Task.checkCancellation()
            let count = min(65536, header.length - received), padded = (count+15) & ~15
            let encrypted = try await read(padded)
            var plain = [UInt8](); plain.reserveCapacity(padded)
            for at in stride(from: 0, to: padded, by: 16) { plain += cipher.cipher.decrypt(Array(encrypted[at..<at+16])) }
            let data = Data(plain.prefix(count))
            if let resourceOffset, let sink { try ResourceFork.write(sink.fileDescriptor, offset: resourceOffset + UInt64(received), bytes: data) }
            else { try sink?.write(contentsOf: data) }
            received += count; progress(UInt64(received))
        }
        return UInt64(received)
    }

}
