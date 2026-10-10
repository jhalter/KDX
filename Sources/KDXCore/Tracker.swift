import Foundation

/// Tracker 1.110 records derived from static inspection; see docs/TRACKER-PROTOCOL.md.
public struct TrackerGroup: Identifiable, Equatable, Sendable {
    public let id: Int
    public let serverCount: UInt16
    public let name: String
    public let description: String
    let nameBytes: [UInt8]

    static func decodeList(_ bytes: [UInt8]) throws -> [Self] {
        try bytes.require(4)
        let count = Int(bytes.u32(0))
        guard count <= (bytes.count - 4) / 8 else { throw KDXError.invalid("Invalid tracker group count.") }
        var at = 4, groups = [Self]()
        for id in 0..<count {
            try bytes.require(at + 8)
            let nameEnd = at + 8 + Int(bytes[at + 6])
            let end = nameEnd + Int(bytes[at + 7]), next = (end + 3) & ~3
            try bytes.require(next)
            let name = Array(bytes[at + 8..<nameEnd])
            groups.append(Self(id: id, serverCount: bytes.u16(at), name: String(decoding: name, as: UTF8.self),
                               description: bytes.text(nameEnd..<end), nameBytes: name))
            at = next
        }
        guard at == bytes.count else { throw KDXError.invalid("Unexpected tracker group data.") }
        return groups
    }
    func serverListRequest() -> [UInt8] { [0, 0, UInt8(nameBytes.count), 0] + nameBytes }
}

public struct TrackerServer: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let description: String
    public let host: String?
    public let port: UInt16?
    public var isTracker: Bool { header.u16(14) & 1 != 0 }
    // Retain unknown fields without assigning unverified meanings to them.
    let header: [UInt8]
    let address: [UInt8]
    let extra: [UInt8]

    static func decodeList(_ bytes: [UInt8]) throws -> [Self] {
        // The original tracker sends an empty payload for a group with no servers.
        if bytes.isEmpty { return [] }
        try bytes.require(4)
        let count = Int(bytes.u32(0))
        guard count <= (bytes.count - 4) / 28 else { throw KDXError.invalid("Invalid tracker server count.") }
        var at = 4, servers = [Self]()
        for id in 0..<count {
            try bytes.require(at + 28)
            let header = Array(bytes[at..<at + 28])
            var cursor = at + 28, fields = [[UInt8]]()
            for size in header[24..<28] {
                let end = cursor + Int(size); try bytes.require(end)
                fields.append(Array(bytes[cursor..<end])); cursor = end
            }
            let next = (cursor + 3) & ~3; try bytes.require(next)
            let address = fields[0]
            servers.append(Self(id: id, name: String(decoding: fields[1], as: UTF8.self),
                                description: String(decoding: fields[2], as: UTF8.self),
                                host: address.count == 6 ? address.prefix(4).map(String.init).joined(separator: ".") : nil,
                                port: address.count == 6 ? address.u16(4) : nil,
                                header: header, address: address, extra: fields[3]))
            at = next
        }
        guard at == bytes.count else { throw KDXError.invalid("Unexpected tracker server data.") }
        return servers
    }
}

/// Browsing is anonymous and independent of server-account credentials.
@MainActor public struct KDXTrackerClient {
    public static let defaultPort: UInt16 = 10800
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16 = defaultPort) { self.host = host; self.port = port }

    public func groups(table: ChallengeTable) async throws -> [TrackerGroup] {
        let wire = try WireConnection(host: host, port: port)
        return try TrackerGroup.decodeList(await Self.query(wire: wire, type: 700, replyType: 701, table: table))
    }
    public func servers(in group: TrackerGroup, table: ChallengeTable) async throws -> [TrackerServer] {
        let wire = try WireConnection(host: host, port: port)
        return try TrackerServer.decodeList(await Self.query(wire: wire, type: 702, replyType: 703, payload: group.serverListRequest(), table: table))
    }
    static func query(wire: WireConnection, type: UInt32, replyType: UInt32, payload: [UInt8] = [], table: ChallengeTable,
                      timeout: Duration = .seconds(30)) async throws -> [UInt8] {
        // A total deadline also bounds a peer that keeps sending unrelated messages or partial data.
        let deadline = Task { try? await Task.sleep(for: timeout); if !Task.isCancelled { wire.close() } }
        defer { deadline.cancel(); wire.close() }
        try Task.checkCancellation()
        wire.ioTimeout = .seconds(15)
        try await wire.start()
        try await wire.authenticateClient(name: [], key: AccountKey(password: ""), table: table, expectedVersion: 0x30)
        let transaction = try await wire.send(type: type, payload: payload)
        for _ in 0..<64 {
            let reply = try await wire.receive()
            guard reply.isReply, reply.transaction == transaction else { continue }
            if reply.type == 1 {
                guard reply.payload.count == 8 || reply.payload.count == 24 else { throw KDXError.invalid("Invalid tracker status.") }
                let code = reply.payload.u32(0)
                guard code != 0 else { throw KDXError.invalid("Tracker did not return the requested list.") }
                throw KDXError.remote(code)
            }
            guard reply.type == replyType else { throw KDXError.invalid("Unexpected tracker reply.") }
            try Task.checkCancellation()
            return reply.payload
        }
        throw KDXError.invalid("Tracker sent too many unrelated messages.")
    }
}
