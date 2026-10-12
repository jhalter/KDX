import AppKit
import CoreText

/// Converts each set-pixel run to an unhinted rectangular contour. The resulting
/// font is process-local, so NSTextView retains native editing and Unicode fallback.
/// No font program, bytecode, or original executable code is copied or executed.
enum HaxialOpenType {
    static func make(_ strike: HaxialFontStrike, identity: String) throws -> Data {
        let unit = 64, em = strike.height*64
        let source = [strike.glyphs[26]] + strike.glyphs
        var glyf = FontBytes(), loca = FontBytes(), hmtx = FontBytes()
        var maxPoints = 0, maxContours = 0, pointBudget = 1_000_000
        var minX = 0, minY = 0, maxX = 0, maxY = 0, maxAdvance = 0, minRight = 0
        for glyph in source {
            loca.u32(glyf.count)
            var points: [(Int,Int)] = []
            for y in 0..<glyph.height {
                var x = 0
                while x < glyph.width {
                    if !glyph.isSet(x:x,y:y) { x += 1; continue }
                    let start = x
                    while x < glyph.width && glyph.isSet(x:x,y:y) { x += 1 }
                    let left = (glyph.x+start)*unit, right = (glyph.x+x)*unit
                    let top = (strike.height-glyph.y-y)*unit, bottom = top-unit
                    points += [(left,bottom),(left,top),(right,top),(right,bottom)]
                }
            }
            guard points.count <= 65532, points.count <= pointBudget else { throw AppearanceError.invalid("Font outlines exceed their size limit.") }
            pointBudget -= points.count
            let x0 = points.map(\.0).min() ?? 0, y0 = points.map(\.1).min() ?? 0
            let x1 = points.map(\.0).max() ?? 0, y1 = points.map(\.1).max() ?? 0
            guard [x0,y0,x1,y1].allSatisfy({ (-32768...32767).contains($0) }) else { throw AppearanceError.invalid("Font bounds exceed OpenType limits.") }
            minX = min(minX,x0); minY = min(minY,y0); maxX = max(maxX,x1); maxY = max(maxY,y1)
            maxAdvance = max(maxAdvance,glyph.advance*unit); minRight = min(minRight,glyph.advance*unit-x1)
            hmtx.u16(glyph.advance*unit); hmtx.u16(x0)
            if points.isEmpty { continue }
            let contours = points.count/4
            maxPoints = max(maxPoints,points.count); maxContours = max(maxContours,contours)
            glyf.u16(contours); for n in [x0,y0,x1,y1] { glyf.u16(n) }
            for contour in 0..<contours { glyf.u16(contour*4+3) }
            glyf.u16(0) // no TrueType instructions
            glyf.bytes += [UInt8](repeating:1,count:points.count) // all points on curve, signed word deltas
            for axis in 0..<2 {
                var previous = 0
                for point in points {
                    let value = axis == 0 ? point.0 : point.1
                    guard (-32768...32767).contains(value-previous) else { throw AppearanceError.invalid("Font outline delta is too large.") }
                    glyf.u16(value-previous); previous = value
                }
            }
            glyf.align()
        }
        loca.u32(glyf.count)
        var head = FontBytes()
        head.u32(0x10000); head.u32(0x10000); head.u32(0); head.u32(0x5f0f3cf5)
        head.u16(3); head.u16(em); head.zeros(16)
        for n in [minX,minY,maxX,maxY,0,strike.height,2,1,0] { head.u16(n) }
        var hhea = FontBytes(); hhea.u32(0x10000)
        for n in [em,0,0,maxAdvance,minX,minRight,maxX,1,0,0,0,0,0,0,0,source.count] { hhea.u16(n) }
        var maxp = FontBytes(); maxp.u32(0x10000)
        for n in [source.count,maxPoints,maxContours,0,0,1,0,0,0,0,0,0,0,0] { maxp.u16(n) }
        var mapping = FontBytes()
        let mapped = strike.glyphs.enumerated().filter { $0.element.advance > 0 }
        mapping.u16(12); mapping.u16(0); mapping.u32(16+mapped.count*12); mapping.u32(0); mapping.u32(mapped.count)
        for (i,glyph) in mapped { mapping.u32(Int(glyph.codepoint)); mapping.u32(Int(glyph.codepoint)); mapping.u32(i+1) }
        var cmap = FontBytes(); cmap.u16(0); cmap.u16(2)
        cmap.u16(0); cmap.u16(4); cmap.u32(20); cmap.u16(3); cmap.u16(10); cmap.u32(20)
        cmap.bytes += mapping.bytes
        var name = FontBytes(), strings = FontBytes()
        let records: [(Int,String)] = [(1,identity),(2,"Regular"),(3,identity),(4,identity),(5,"Version 1.0"),(6,identity)]
        name.u16(0); name.u16(records.count); name.u16(6+records.count*12)
        for (id,text) in records {
            let encoded = text.data(using:.utf16BigEndian) ?? Data()
            for n in [3,1,0x409,id,encoded.count,strings.count] { name.u16(n) }
            strings.bytes += encoded
        }
        name.bytes += strings.bytes
        var post = FontBytes(); post.u32(0x30000); post.zeros(28)
        var os2 = FontBytes(); os2.u16(0)
        for n in [em/2,400,5,0] { os2.u16(n) }
        os2.zeros(22+10) // sub/super metrics, strikeout, family classification, PANOSE
        os2.u32(1); os2.zeros(12); os2.bytes += Array("KDXC".utf8)
        for n in [0x40,32,0xffff,em,0,0,max(em,maxY),max(0,-minY)] { os2.u16(n) }
        var gasp = FontBytes(); for n in [1,1,65535,0] { gasp.u16(n) } // preserve pixel edges, no smoothing requested
        let tables = ["head":head,"hhea":hhea,"maxp":maxp,"cmap":cmap,"name":name,"post":post,"OS/2":os2,"glyf":glyf,"loca":loca,"hmtx":hmtx,"gasp":gasp]
        var font = FontBytes(), payload = FontBytes()
        let count = tables.count, power = 1 << Int(floor(log2(Double(count))))
        font.u32(0x10000); for n in [count,power*16,Int(log2(Double(power))),count*16-power*16] { font.u16(n) }
        var headOffset = 0
        for tag in tables.keys.sorted() {
            let table = tables[tag]!, offset = 12+count*16+payload.count
            if tag == "head" { headOffset = offset }
            font.bytes += Array(tag.utf8); font.u32(Int(table.checksum)); font.u32(offset); font.u32(table.count)
            payload.bytes += table.bytes; payload.align()
        }
        font.bytes += payload.bytes
        let adjustment = 0xb1b0afba &- font.checksum
        for i in 0..<4 { font.bytes[headOffset+8+i] = UInt8(truncatingIfNeeded:adjustment >> (24-i*8)) }
        return Data(font.bytes)
    }
}

private struct FontBytes {
    var bytes: [UInt8] = []
    var count: Int { bytes.count }
    mutating func u16(_ n: Int) { bytes += [UInt8(truncatingIfNeeded:n >> 8),UInt8(truncatingIfNeeded:n)] }
    mutating func u32(_ n: Int) { for shift in stride(from:24,through:0,by:-8) { bytes.append(UInt8(truncatingIfNeeded:n >> shift)) } }
    mutating func zeros(_ n: Int) { bytes += [UInt8](repeating:0,count:n) }
    mutating func align() { while bytes.count % 4 != 0 { bytes.append(0) } }
    var checksum: UInt32 {
        var sum: UInt32 = 0
        for at in stride(from:0,to:bytes.count,by:4) {
            var word: UInt32 = 0
            for i in 0..<4 { word = word << 8 | (at+i < bytes.count ? UInt32(bytes[at+i]) : 0) }
            sum = sum &+ word
        }
        return sum
    }
}

@MainActor final class HaxialNativeFonts {
    static let shared = HaxialNativeFonts()
    private var cache: [String:NSFont] = [:]
    func font(data: Data, strike index: Int = 0) throws -> NSFont {
        let id = "KDXImported-"+String(AppearanceDecoder.digest(data).prefix(24))+"-\(index)"
        if let font = cache[id] { return font }
        let decoded = try HaxialFont(data:data)
        guard decoded.strikes.indices.contains(index) else { throw AppearanceError.invalid("Font strike is missing.") }
        let strike = decoded.strikes[index], sfnt = try HaxialOpenType.make(strike,identity:id)
        guard let provider = CGDataProvider(data:sfnt as CFData), let graphicsFont = CGFont(provider) else { throw AppearanceError.invalid("Unable to create the imported font.") }
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterGraphicsFont(graphicsFont,&error) else { throw (error?.takeRetainedValue() as Error?) ?? AppearanceError.invalid("Unable to register the imported font.") }
        guard let font = NSFont(name:id,size:CGFloat(strike.height)) else { throw AppearanceError.invalid("Imported font is unavailable to AppKit.") }
        cache[id] = font
        return font
    }
}
