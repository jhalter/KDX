import Foundation

/// Packet 106 image decoder, verified against PPC 0x36090 (encoder 0x362E0).
/// All dimensions are single bytes; decoded storage is bounded to 255×255 RGBA.
enum ClassicServerBannerDecoder {
    static func decode(_ bytes: [UInt8]) throws -> HAPBitmap {
        guard bytes.count >= 6, bytes[0] == 1 else {
            throw AppearanceError.invalid("Unsupported server banner version.")
        }
        let width = Int(bytes[1]), height = Int(bytes[2]), depth = Int(bytes[3])
        let count = Int(bytes[5])+1
        guard width > 0, height > 0, [4,8].contains(depth) else {
            throw AppearanceError.invalid("Invalid server banner dimensions or depth.")
        }
        let stride = ((width*depth+31)/32)*4
        let pixelsAt = (6+count*3+3) & ~3
        guard bytes.count >= pixelsAt+stride*height else {
            throw AppearanceError.invalid("Truncated server banner.")
        }
        // Header byte 4, palette/row padding and trailing bytes are ignored by
        // the original decoder. Only visible pixels index the palette.
        var rgba = Data(); rgba.reserveCapacity(width*height*4)
        for y in 0..<height { for x in 0..<width {
            let packed = Int(bytes[pixelsAt+y*stride+x*depth/8])
            let index = depth == 8 ? packed : (packed >> (x%2 == 0 ? 4 : 0)) & 15
            guard index < count else { throw AppearanceError.invalid("Invalid server banner palette index.") }
            let color = 6+index*3
            rgba.append(contentsOf:[bytes[color],bytes[color+1],bytes[color+2],255])
        } }
        return HAPBitmap(width:width,height:height,rgba:rgba,textColor:nil,margins:[0,0,0,0],placement:[0,0,0,0])
    }
}

/// One cache per connection. A bad replacement does not discard valid artwork
/// (0x37D90); disconnect/reconnect invalidates all artwork for the old peer.
struct ClassicServerBannerState {
    private var previous: [UInt8]?
    private(set) var bitmap: HAPBitmap?
    mutating func update(_ payload: [UInt8], connected: Bool) -> HAPBitmap? {
        guard connected else { self = Self(); return nil }
        guard payload != previous else { return bitmap }
        previous = payload
        if let decoded = try? ClassicServerBannerDecoder.decode(payload) { bitmap = decoded }
        return bitmap
    }
}
