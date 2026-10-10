import Foundation
@preconcurrency import Network

public struct TrackerAdvertisementSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var host = ""
    public var port: UInt16 = 10800
    public var advertisedPort: UInt16 = 0
    public var groups: [String] = []
    public init() {}
    func validate() throws {
        guard !enabled || (!host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && port > 0) else {
            throw KDXError.invalid("Enter a tracker address and a port between 1 and 65535.")
        }
        guard groups.count <= 6 else { throw KDXError.invalid("A tracker advertisement supports at most six groups.") }
        for group in groups { _ = try shortText(group) }
    }
}

/// Static Tracker 1.110 sender/receiver evidence is recorded in TRACKER-PROTOCOL.md.
struct TrackerAdvertisement: Sendable {
    var name: String
    var description: String
    var port: UInt16
    var userCount: UInt16
    var groups: [String]

    func encode() throws -> [UInt8] {
        let name = try shortText(name), description = try shortText(description)
        guard !name.isEmpty, name.count <= 64, port > 0 else {
            throw KDXError.invalid("Tracker advertisements require a server name of 1–64 UTF-8 bytes and a nonzero TCP port.")
        }
        guard groups.count <= 6 else { throw KDXError.invalid("A tracker advertisement supports at most six groups.") }
        let groupBytes = try groups.map(shortText)
        var packet = [UInt8](repeating: 0, count: 64)
        packet.put(UInt32(0x254b4458), at: 0); packet.put(UInt16(0x10), at: 4)
        // Flags are zero for an ordinary server; bit 0 marks a tracker advertisement.
        packet.put(UInt32(port), at: 24); packet.put(userCount, at: 36)
        packet[53] = UInt8(name.count); packet[54] = UInt8(description.count)
        for (index, group) in groupBytes.enumerated() { packet[56 + index] = UInt8(group.count) }
        packet += name + description + groupBytes.flatMap { $0 }
        packet.pad(4)
        packet.put(UInt32(0xcad31ecc), at: 8)
        let checksum = Self.crc(packet, seed: 0xdeadbeef)
        packet.put(checksum, at: 8)
        return Self.obfuscate(packet)
    }
    // Non-reflected CRC-32, no final XOR. This is not the ZIP CRC variant.
    static func crc(_ bytes: [UInt8], seed: UInt32) -> UInt32 {
        var value = seed
        for byte in bytes {
            value ^= UInt32(byte) << 24
            for _ in 0..<8 { value = value & 0x80000000 == 0 ? value << 1 : (value << 1) ^ 0x04c11db7 }
        }
        return value
    }
    static func obfuscate(_ bytes: [UInt8]) -> [UInt8] {
        var result = bytes, state: UInt32 = 0xa5a16c4a
        for at in stride(from: 0, to: bytes.count - bytes.count % 4, by: 4) {
            result.put(bytes.u32(at) ^ state, at: at)
            state = state &* 0x41d28485 &+ 0x322b
        }
        return result
    }
}

@MainActor final class TrackerAdvertiser {
    typealias Send = @MainActor (String, UInt16, [UInt8]) async throws -> Void
    private let send: Send
    private let interval: Duration
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(interval: Duration = .seconds(300), send: @escaping Send = TrackerDatagram.send) {
        self.interval = interval; self.send = send
    }
    func start(settings: TrackerAdvertisementSettings, snapshot: @escaping @MainActor () throws -> TrackerAdvertisement,
               report: @escaping @MainActor (String, Date?) -> Void) {
        stop()
        guard settings.enabled else { return }
        let generation = self.generation, send = self.send, interval = self.interval
        task = Task { [weak self] in
            while !Task.isCancelled && self?.generation == generation {
                do {
                    try settings.validate()
                    let packet = try snapshot().encode()
                    try Task.checkCancellation()
                    try await send(settings.host.trimmingCharacters(in: .whitespacesAndNewlines), settings.port, packet)
                    guard !Task.isCancelled, self?.generation == generation else { return }
                    report("Advertisement sent; tracker acceptance is unconfirmed.", Date())
                } catch {
                    guard !Task.isCancelled, self?.generation == generation else { return }
                    report("Advertisement failed: \(error.localizedDescription)", nil)
                }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }
    func stop() { generation = UUID(); task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

/// One bounded UDP send; transport completion does not prove remote receipt.
@MainActor private final class TrackerDatagram {
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Void, Error>?
    private var sending = false
    private var finished = false
    private init(host: String, port: UInt16) throws {
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: port), port.rawValue > 0 else { throw KDXError.invalid("Invalid tracker endpoint.") }
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
    }
    static func send(host: String, port: UInt16, bytes: [UInt8]) async throws {
        try Task.checkCancellation()
        let sender = try Self(host: host, port: port)
        try await sender.send(bytes)
    }
    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true; connection.stateUpdateHandler = nil; connection.cancel()
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }
    private func send(_ bytes: [UInt8]) async throws {
        let timeout = Task { try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled { self.finish(KDXError.invalid("Tracker advertisement timed out.")) } }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !finished else { continuation.resume(throwing: KDXError.disconnected); return }
                self.continuation = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self, !self.finished else { return }
                        switch state {
                        case .ready:
                            guard !self.sending else { return }; self.sending = true
                            self.connection.send(content: Data(bytes), completion: .contentProcessed { error in
                                Task { @MainActor in self.finish(error) }
                            })
                        case .failed(let error): self.finish(error)
                        case .cancelled: self.finish(KDXError.disconnected)
                        default: break
                        }
                    }
                }
                connection.start(queue: .main)
            }
        } onCancel: { Task { @MainActor in self.finish(CancellationError()) } }
    }
}
