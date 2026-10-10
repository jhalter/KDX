import Foundation
import CryptoKit

public struct AccountKey: Sendable {
    let bytes: [UInt8]
    public init(password: String) {
        if password.isEmpty {
            bytes = [0xda,0x39,0xa3,0xee,0xca,0xae,0xbe,0x6e,0x5e,0x6b,0x4b,0x0d,0xba,0x8e,0x29,0xba,0x32,0x55,0xbf,0xef,0x18,0xa2,0xb5,0xc4,0x95,0x60,0x18,0x90,0xaf,0xd8,7,9]
        } else {
            let data = Array(password.utf8)
            let digest = Array(Insecure.SHA1.hash(data: Data(data)))
            let fnv = data.reduce(UInt32(1)) { ($0 &* 0x01000193) ^ UInt32($1) }
            bytes = digest + digest.prefix(8) + fnv.beBytes
        }
    }
    init(bytes: [UInt8]) throws { guard bytes.count == 32 else { throw KDXError.invalid("Invalid account key.") }; self.bytes = bytes }
}

public struct ChallengeTable: Sendable {
    let bytes: [UInt8]
    public init(file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65536, TableArchive.fileLimit+1-data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= TableArchive.fileLimit else { throw KDXError.invalid("Import files must be 32 MiB or smaller.") }
        }
        try self.init(data: data)
    }
    public init(data: Data) throws {
        guard data.count <= TableArchive.fileLimit else { throw KDXError.invalid("Import files must be 32 MiB or smaller.") }
        if data.starts(with: [0x50,0x4b,0x03,0x04]) {
            let archive = try TableArchive(data: data)
            for entry in archive.entries {
                if let file = try archive.contents(of: entry), let table = Self.verifiedBytes(in: file) { bytes = table; return }
            }
            throw KDXError.invalid("No verified KDX challenge table found in this ZIP. Choose an original KDX program archive.")
        }
        guard let table = Self.verifiedBytes(in: data) else {
            throw KDXError.invalid("No verified KDX challenge table found. Import an original KDX program, its ZIP archive, or a saved table.")
        }
        bytes = table
    }
    private static func verifiedBytes(in data: Data) -> [UInt8]? {
        let expected = "4fca7636e77e85fdde95862a6be66e12e5e031ad61add65c5e975d3daff4b9e7"
        func valid(_ table: Data) -> Bool { SHA256.hash(data: table).map { String(format: "%02x", $0) }.joined() == expected }
        if data.count == 1739, valid(data) { return Array(data) }
        let marker = Data("This program including the following story".utf8)
        var searchStart = data.startIndex
        while searchStart < data.endIndex, let range = data.range(of: marker, in: searchStart..<data.endIndex) {
            let start = range.lowerBound
            if data.endIndex-start >= 1739 {
                let table = Data(data[start..<start+1739])
                if valid(table) { return Array(table) }
            }
            searchStart = range.upperBound
        }
        return nil
    }
    // Internal initializer only for independent, synthetic transport tests.
    init(testBytes: [UInt8]) { precondition(testBytes.count == 1739); bytes = testBytes }
    func response(_ offset: UInt16) throws -> [UInt8] {
        let at = Int(offset)
        guard at + 20 <= bytes.count else { throw KDXError.invalid("Challenge offset out of range.") }
        return Array(bytes[at..<at+20])
    }
    public func save(to url: URL) throws { try Data(bytes).write(to: url, options: .atomic) }
}

func xorWire(_ data: [UInt8]) throws -> [UInt8] {
    try data.require(4)
    guard data.count % 4 == 0 else { throw KDXError.invalid("Invalid handshake alignment.") }
    var out = data, key = data.u32(0)
    for at in stride(from: 4, to: data.count, by: 4) { key = (key << 1) &+ 0x4878; out.put(data.u32(at) ^ key, at: at) }
    return out
}

struct Hello: Sendable, Equatable {
    var version: UInt8
    var challenge: UInt16
    var nonce: [UInt8]
    var name: [UInt8]
    init(server: Bool, name: [UInt8] = []) {
        version = server ? 0x20 : 0x10; challenge = UInt16.random(in: 0..<1720)
        nonce = (0..<12).map { _ in UInt8.random(in: .min ... .max) }; self.name = name
    }
    static func length(_ data: [UInt8]) throws -> Int {
        try data.require(36)
        let h = try xorWire(Array(data.prefix(36)))
        guard h.u32(4) == 0x25545850, h.u32(8) == 0x254b4458, h[12] == 1 else { throw KDXError.invalid("Unsupported KDX handshake.") }
        guard h[15] <= 31 else { throw KDXError.invalid("Login name exceeds 31 bytes.") }
        let len = (Int(h[15]) + Int(h[14]) + Int(h.u16(20)) + 39) & ~3
        guard len <= 2048 else { throw KDXError.invalid("Handshake exceeds protocol limit.") }
        return len
    }
    init(wire: [UInt8]) throws {
        let len = try Self.length(wire); try wire.require(len)
        let h = try xorWire(Array(wire.prefix(len))), at = 36 + Int(h[14]) + Int(h.u16(20))
        version = h[13]; challenge = h.u16(22); nonce = Array(h[24..<36]); name = Array(h[at..<at+Int(h[15])])
    }
    func encode(key: UInt32 = .random(in: .min ... .max)) throws -> [UInt8] {
        guard name.count <= 31, nonce.count == 12 else { throw KDXError.invalid("Invalid login name or nonce.") }
        var out = [UInt8](repeating: 0, count: 36)
        out.put(key, at: 0); out.put(UInt32(0x25545850), at: 4); out.put(UInt32(0x254b4458), at: 8)
        out[12] = 1; out[13] = version; out[15] = UInt8(name.count); out.put(challenge, at: 22)
        out.replaceSubrange(24..<36, with: nonce); out += name; out.pad(4)
        return try xorWire(out)
    }
}

struct Proof {
    let auth: [UInt8], response: [UInt8]
    let status: UInt8
    static func authentication(key: AccountKey, nonce: [UInt8]) -> [UInt8] {
        let s = key.bytes
        var input = Array(s[0..<4]) + nonce[0..<4] + s[4..<12]
        input += nonce[4..<8]; input += s[12..<20]; input += nonce[8..<12]; input += s[20..<32]
        var digest = Array(Insecure.SHA1.hash(data: Data(input)))
        digest.replaceSubrange(0..<16, with: Twofish(key: s).encrypt(Array(digest.prefix(16))))
        return digest
    }
    init(key: AccountKey, nonce: [UInt8], response: [UInt8]) {
        self.auth = Self.authentication(key: key, nonce: nonce); self.response = response; status = 0x10
    }
    init(wire: [UInt8]) throws {
        try wire.require(44); let plain = try xorWire(Array(wire.prefix(44)))
        auth = Array(plain[..<20]); response = Array(plain[20..<40]); status = plain[40]
    }
    func encode() throws -> [UInt8] { try xorWire(auth + response + [status,0,0,0]) }
    func verify(key: AccountKey, nonce: [UInt8], response expected: [UInt8]) throws {
        let desired = Self.authentication(key: key, nonce: nonce) + expected
        let actual = auth + response
        let difference = zip(actual, desired).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard status == 0x10, actual.count == desired.count, difference == 0 else { throw KDXError.authentication }
    }
}

public struct Message: Sendable {
    public var transaction: UInt32
    public var type: UInt32
    public var isReply: Bool
    public var payload: [UInt8]
    public init(transaction: UInt32 = 1, type: UInt32, isReply: Bool = false, payload: [UInt8] = []) {
        self.transaction = transaction; self.type = type; self.isReply = isReply; self.payload = payload
    }
}
struct MessageHeader {
    let transaction: UInt32, type: UInt32, length: Int
    let flags: UInt8
    var paddedLength: Int { (length + 15) & ~15 }
}
struct SessionCipher: Sendable {
    let cipher: Twofish
    init(key: AccountKey) { cipher = Twofish(key: key.bytes) }
    func seal(_ message: Message) throws -> [UInt8] {
        guard message.transaction != 0, message.type != 0, message.payload.count <= (message.type == 608 ? 0x4000000 : 0x100000) else { throw KDXError.invalid("Message exceeds protocol limits.") }
        var out = sealHeader(transaction: message.transaction, type: message.type, reply: message.isReply, length: UInt32(message.payload.count))
        let fill = (message.transaction &* 0x41c64e6d &+ 0x3039).leBytes
        var payload = message.payload
        while payload.count % 16 != 0 { payload.append(fill[payload.count % 4]) }
        for at in stride(from: 0, to: payload.count, by: 16) { out += cipher.encrypt(Array(payload[at..<at+16])) }
        return out
    }
    func sealHeader(transaction: UInt32, type: UInt32, reply: Bool, length: UInt32) -> [UInt8] {
        let words = [type.rol(13) ^ 0x6e7dfd34, UInt32(reply ? 0x10000 : 0).ror(6) ^ 0xe152da04,
                     transaction.rol(7) ^ 0xa95a759b, length.ror(3) ^ 0x06992e25]
        return cipher.encrypt(words.flatMap(\.beBytes))
    }
    func header(_ bytes: [UInt8], limit: Int) throws -> MessageHeader {
        guard bytes.count == 16 else { throw KDXError.invalid("Invalid header length.") }
        let w = cipher.decrypt(bytes)
        let tx = (w.u32(8) ^ 0xa95a759b).ror(7), type = (w.u32(0) ^ 0x6e7dfd34).ror(13)
        let flags = (w.u32(4) ^ 0xe152da04).rol(6), length = Int((w.u32(12) ^ 0x06992e25).rol(3))
        guard tx != 0, type != 0, flags & 0xff00ffff == 0, length <= limit else { throw KDXError.invalid("Invalid or oversized KDX message header.") }
        return MessageHeader(transaction: tx, type: type, length: length, flags: UInt8(truncatingIfNeeded: flags >> 16))
    }
    func open(_ header: MessageHeader, payload: [UInt8]) throws -> Message {
        guard payload.count == header.paddedLength else { throw KDXError.invalid("Truncated message payload.") }
        var plain = [UInt8](); plain.reserveCapacity(payload.count)
        for at in stride(from: 0, to: payload.count, by: 16) { plain += cipher.decrypt(Array(payload[at..<at+16])) }
        return Message(transaction: header.transaction, type: header.type, isReply: header.flags & 1 != 0, payload: Array(plain.prefix(header.length)))
    }
}
