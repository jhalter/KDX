import Foundation
import zlib

// Only reads entry bytes; archive paths are never used as filesystem destinations.
struct TableArchive {
    static let fileLimit = 32 * 1024 * 1024
    static let inflatedLimit = 64 * 1024 * 1024
    struct Entry {
        let method: UInt16
        let flags: UInt16
        let crc: UInt32
        let size: Int
        let packed: Range<Int>
    }
    let bytes: [UInt8]
    let entries: [Entry]
    init(data: Data) throws {
        guard data.count <= Self.fileLimit, data.count >= 22 else { throw KDXError.invalid("Invalid or oversized ZIP archive.") }
        let b = Array(data)
        func u16(_ at: Int) -> UInt16 { UInt16(b[at]) | UInt16(b[at+1]) << 8 }
        func u32(_ at: Int) -> UInt32 { b.le32(at) }
        let lower = max(0, b.count-22-65535)
        guard let end = stride(from: b.count-22, through: lower, by: -1).first(where: {
            u32($0) == 0x06054b50 && $0+22+Int(u16($0+20)) == b.count
        }) else { throw KDXError.invalid("ZIP central directory not found.") }
        let count = Int(u16(end+10)), directory = Int(u32(end+16)), directorySize = Int(u32(end+12))
        guard u16(end+4) == 0, u16(end+6) == 0, Int(u16(end+8)) == count,
              count < 65535, directory < Int(UInt32.max), directorySize < Int(UInt32.max),
              directory <= end, directorySize == end-directory else {
            throw KDXError.invalid("Split, ZIP64, or invalid ZIP archives are not supported.")
        }
        guard count <= 4096 else { throw KDXError.invalid("ZIP archive has too many entries.") }
        var at = directory, result = [Entry](), total = 0
        for _ in 0..<count {
            guard at+46 <= end, u32(at) == 0x02014b50 else { throw KDXError.invalid("Invalid ZIP directory entry.") }
            let flags = u16(at+8), method = u16(at+10), crc = u32(at+16)
            let packed = Int(u32(at+20)), size = Int(u32(at+24)), local = Int(u32(at+42))
            let nameLength = Int(u16(at+28)), extraLength = Int(u16(at+30)), commentLength = Int(u16(at+32))
            let next = at+46+nameLength+extraLength+commentLength
            guard next <= end, u16(at+34) == 0, local+30 <= directory,
                  u32(local) == 0x04034b50, u16(local+6) == flags, u16(local+8) == method else {
                throw KDXError.invalid("Invalid ZIP local header.")
            }
            let localNameLength = Int(u16(local+26)), start = local+30+localNameLength+Int(u16(local+28))
            guard localNameLength == nameLength, start <= directory, packed <= directory-start,
                  b[(local+30)..<(local+30+localNameLength)].elementsEqual(b[(at+46)..<(at+46+nameLength)]) else {
                throw KDXError.invalid("Truncated or inconsistent ZIP entry.")
            }
            if flags & 8 == 0 {
                guard u32(local+14) == crc, Int(u32(local+18)) == packed, Int(u32(local+22)) == size else {
                    throw KDXError.invalid("Inconsistent ZIP entry sizes or checksum.")
                }
            }
            guard size <= Self.fileLimit, total <= Self.inflatedLimit-size else { throw KDXError.invalid("ZIP contents exceed the import size limit.") }
            total += size
            result.append(Entry(method: method, flags: flags, crc: crc, size: size, packed: start..<start+packed))
            at = next
        }
        guard at == end else { throw KDXError.invalid("Unexpected ZIP directory data.") }
        bytes = b; entries = result
    }
    func contents(of entry: Entry) throws -> Data? {
        guard entry.flags & 1 == 0, [UInt16(0),8].contains(entry.method) else { return nil }
        let packed = Array(bytes[entry.packed])
        let result: Data
        if entry.method == 0 {
            guard packed.count == entry.size else { throw KDXError.invalid("Invalid stored ZIP entry length.") }
            result = Data(packed)
        } else {
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw KDXError.invalid("Could not initialize ZIP decompression.")
            }
            defer { inflateEnd(&stream) }
            var output = [UInt8](repeating: 0, count: max(1, entry.size))
            let status = packed.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(source.count)
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.size, stream.total_in == packed.count else {
                throw KDXError.invalid("Invalid or oversized deflated ZIP entry.")
            }
            result = Data(output.prefix(entry.size))
        }
        let checksum = result.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        guard UInt32(checksum) == entry.crc else { throw KDXError.invalid("ZIP entry checksum does not match.") }
        return result
    }
}
