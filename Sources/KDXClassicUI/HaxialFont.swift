import Foundation

/// The original %FNT v2 raster format. All references are file offsets.
public struct HaxialFont: Sendable {
    public let name: String
    public let strikes: [HaxialFontStrike]
    public init(data: Data) throws {
        guard data.count <= 4*1024*1024 else { throw AppearanceError.invalid("Font exceeds its size limit.") }
        let b = try AssetBytes(data)
        _ = try b.range(0,184)
        guard try b.data(0,4) == Data("%FNT".utf8), try b.u16(4) == 2,
              try b.u32(8) == data.count else { throw AppearanceError.invalid("Unsupported or truncated Haxial font.") }
        func string(_ at: Int, _ capacity: Int) throws -> String {
            let length = Int(b.bytes[at])
            guard length < capacity, let value = String(data:try b.data(at+1,length),encoding:.macOSRoman) else { throw AppearanceError.invalid("Invalid Haxial font name.") }
            return value
        }
        name = try string(24,64); _ = try string(88,96)
        let styles = Int(b.bytes[7])
        guard !name.isEmpty, (1...16).contains(styles) else { throw AppearanceError.invalid("Unsupported Haxial font styles.") }
        _ = try b.range(184,styles*84)
        var strikes: [HaxialFontStrike] = [], budget = 4*1024*1024
        for style in 0..<styles {
            let at = 184+style*84, count = Int(b.bytes[at+11]), sizes = try b.u32(at+12)
            guard (1...16).contains(count), strikes.count+count <= 32 else { throw AppearanceError.invalid("Too many font strikes.") }
            let styleName = try string(at+20,64)
            _ = try b.range(sizes,count*24)
            for size in 0..<count {
                let record = sizes+size*24, height = Int(b.bytes[record]), glyphCount = try b.u32(record+16), glyphAt = try b.u32(record+20)
                guard (1...255).contains(height), (256...4096).contains(glyphCount) else { throw AppearanceError.invalid("Unsupported font strike.") }
                _ = try b.range(glyphAt,glyphCount*16)
                var glyphs: [HaxialGlyph] = [], previousCodepoint = 255
                for i in 0..<glyphCount {
                    let g = glyphAt+i*16, codepoint = try b.u32(g), bitmap = try b.u32(g+4)
                    let width = Int(b.bytes[g+8]), h = Int(b.bytes[g+9]), stride = (width+7)/8
                    guard (i < 256 ? codepoint == i : codepoint > previousCodepoint),
                          codepoint <= 0x10ffff, !(0xd800...0xdfff).contains(codepoint), stride*h <= budget else { throw AppearanceError.invalid("Invalid font glyph table.") }
                    if i >= 256 { previousCodepoint = codepoint }
                    let pixels = try b.data(bitmap,stride*h); budget -= pixels.count
                    glyphs.append(HaxialGlyph(codepoint:UInt32(codepoint),width:width,height:h,x:Int(b.bytes[g+10]),y:Int(b.bytes[g+11]),advance:Int(b.bytes[g+12]),bits:pixels))
                }
                strikes.append(HaxialFontStrike(name:name,style:styleName,height:height,glyphs:glyphs))
            }
        }
        self.strikes = strikes
    }
}

public struct HaxialFontStrike: Sendable {
    public let name: String
    public let style: String
    public let height: Int
    public let glyphs: [HaxialGlyph]
}

public struct HaxialGlyph: Sendable {
    public let codepoint: UInt32
    public let width: Int
    public let height: Int
    public let x: Int
    public let y: Int
    public let advance: Int
    public let bits: Data
    public func isSet(x: Int, y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return bits[y*((width+7)/8)+x/8] & (0x80 >> (x%8)) != 0
    }
}
