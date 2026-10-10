import Foundation

public struct RemoteServerSettings: Sendable {
    public var name: String
    public var greeting: String
    public var greetingEnabled: Bool
    public var downloadLimit: UInt32
    var icon: [UInt8]
    private var original: [UInt8]
    private var header: [UInt8]
    private var sections: [[UInt8]]
    init(name: String, greeting: String = "", greetingEnabled: Bool = false, downloadLimit: UInt32 = 0, icon: [UInt8] = []) {
        self.name = name; self.greeting = greeting; self.greetingEnabled = greetingEnabled; self.downloadLimit = downloadLimit; self.icon = icon
        header = [UInt8](repeating: 0, count: 112); original = []
        header.replaceSubrange(0..<8, with: Array("%KDXSSTG".utf8)); header.put(UInt16(1), at: 8)
        sections = Array(repeating: [], count: 11); sections[0] = [UInt8](repeating: 0, count: 96)
    }
    init(wire b: [UInt8]) throws {
        try b.require(112)
        guard b.count <= 0x10000, Array(b[..<8]) == Array("%KDXSSTG".utf8), b.u16(8) == 1 else { throw KDXError.invalid("Unsupported server settings format.") }
        header = Array(b[..<112]); original = b; sections = []; var ranges = [Range<Int>]()
        for at in stride(from: 12, to: 100, by: 8) {
            let offset = Int(b.u32(at)), length = Int(b.u32(at+4))
            guard offset <= b.count, length <= b.count-offset, length == 0 || offset >= 112 else { throw KDXError.invalid("Invalid settings section.") }
            if length > 0 {
                let range = offset..<offset+length
                guard !ranges.contains(where: { $0.overlaps(range) }) else { throw KDXError.invalid("Overlapping settings sections.") }
                ranges.append(range)
            }
            sections.append(Array(b[offset..<offset+length]))
        }
        let main = sections[0]; try main.require(93)
        guard let end = main[92...].firstIndex(of: 0), let name = String(bytes: main[92..<end], encoding: .utf8), !name.isEmpty else { throw KDXError.invalid("Invalid server name.") }
        self.name = name; greetingEnabled = main[35] & 2 != 0; downloadLimit = main.u32(56); icon = sections[5]
        if sections[3].isEmpty { greeting = "" }
        else { try sections[3].require(4); greeting = sections[3].text(4..<sections[3].count) }
    }
    func encode() throws -> [UInt8] {
        let name = try shortText(name), greeting = Array(greeting.utf8)
        guard !name.isEmpty, !name.contains(0), greeting.count <= 8192, icon.count <= 8192 else { throw KDXError.invalid("Invalid name, greeting, or icon size.") }
        var sections = sections
        var main = Array(sections[0].prefix(92)); main[35] = greetingEnabled ? main[35] | 2 : main[35] & ~2
        main.put(downloadLimit, at: 56); main += name + [0]; main.pad(4)
        var greetingBytes: [UInt8] = []
        if !greeting.isEmpty { greetingBytes = (sections[3].count >= 4 ? Array(sections[3].prefix(4)) : [0,0,0,0]) + greeting }
        if main == sections[0], greetingBytes == sections[3], icon == sections[5], !original.isEmpty { return original }
        sections[0] = main; sections[3] = greetingBytes; sections[5] = icon
        var out = header
        for (index, section) in sections.enumerated() {
            let at = 12 + index * 8
            out.put(UInt32(section.isEmpty && header.u32(at) == 0 ? 0 : out.count), at: at)
            out.put(UInt32(section.count), at: at+4)
            out += section; out.pad(4)
        }
        guard out.count <= 0x10000 else { throw KDXError.invalid("Server settings exceed 64 KiB.") }
        return out
    }
}

@MainActor final class DownloadLimiter {
    private(set) var rate: UInt32 = 0
    private var tokens: Double = 0
    private var last = ContinuousClock.now
    var chunkSize: Int { rate == 0 ? 65536 : max(16, min(65536, Int(rate / 10) & ~15)) }
    func setRate(_ value: UInt32) { rate = value; tokens = Double(chunkSize); last = .now }
    func acquire(_ count: Int, isClosed: () -> Bool = { false }) async throws {
        var remaining = Double(count)
        while remaining > 0 && rate > 0 {
            try Task.checkCancellation()
            guard !isClosed() else { throw KDXError.disconnected }
            let now = ContinuousClock.now, elapsed = last.duration(to: now).components
            tokens = min(Double(chunkSize), tokens + (Double(elapsed.seconds) + Double(elapsed.attoseconds)/1e18) * Double(rate)); last = now
            let used = min(tokens, remaining); tokens -= used; remaining -= used
            if remaining > 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
    }
}
