import Foundation
@testable import KDXCore

@MainActor final class MemoryTransport: ByteTransport {
    let peerHost = "127.0.0.1"
    let endpointDescription = "127.0.0.1:12345"
    weak var peer: MemoryTransport?
    private var buffer = [UInt8]()
    private var pending: (Int, CheckedContinuation<[UInt8], Error>)?
    private var partialRead = false
    private var closed = false
    static func pair() -> (WireConnection, WireConnection) {
        let (a, b) = endpoints()
        return (WireConnection(transport: a), WireConnection(transport: b))
    }
    static func endpoints() -> (MemoryTransport, MemoryTransport) {
        let a = MemoryTransport(), b = MemoryTransport(); a.peer = b; b.peer = a
        return (a, b)
    }
    func start() async throws { if closed { throw KDXError.disconnected } }
    func read(_ count: Int) async throws -> [UInt8] {
        partialRead = false
        if count == 0 { return [] }
        // Preserve bytes delivered before a remote close, like a TCP FIN.
        if buffer.count >= count { let result = Array(buffer.prefix(count)); buffer.removeFirst(count); return result }
        guard !closed else { throw KDXError.disconnected }
        precondition(pending == nil)
        return try await withCheckedThrowingContinuation { pending = (count, $0); drain() }
    }
    func readSome(maximum: Int) async throws -> [UInt8] {
        if !buffer.isEmpty { let count = min(maximum, buffer.count), result = Array(buffer.prefix(count)); buffer.removeFirst(count); return result }
        guard !closed else { throw KDXError.disconnected }
        precondition(pending == nil); partialRead = true
        return try await withCheckedThrowingContinuation { pending = (maximum, $0); drain() }
    }
    func write(_ bytes: [UInt8]) async throws {
        guard !closed, let peer, !peer.closed else { throw KDXError.disconnected }
        // Feed tiny fragments to exercise read-exact behavior.
        for start in stride(from: 0, to: bytes.count, by: 7) {
            peer.buffer += bytes[start..<min(start+7, bytes.count)]
            peer.drain()
        }
    }
    private func drain() {
        guard let (maximum, waiter) = pending, buffer.count >= (partialRead ? 1 : maximum) else { return }
        let count = partialRead ? min(maximum, buffer.count) : maximum
        let result = Array(buffer.prefix(count)); buffer.removeFirst(count); pending = nil; waiter.resume(returning: result)
    }
    func close() {
        guard !closed else { return }
        closed = true; pending?.1.resume(throwing: KDXError.disconnected); pending = nil
        peer?.close()
    }
}
