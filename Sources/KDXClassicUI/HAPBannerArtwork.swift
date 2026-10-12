import AppKit

/// Default button-bar image, installed by original PPC routine 0x3FE60.
/// These bytes come only from the user's verified application import.
public struct HAPBannerArtwork: Codable, Equatable, Sendable {
    public let palette: Data
    public let pixels: Data

    init(palette: Data, pixels: Data) throws {
        self.palette = palette; self.pixels = pixels
        try validate()
    }
    init(reference: AssetBytes) throws {
        try self.init(palette:reference.data(0xf3e20,200*4),pixels:reference.data(0xf4140,152*40))
    }
    func validate() throws {
        guard palette.count == 800, pixels.count == 6080,
              stride(from:0,to:800,by:4).allSatisfy({ palette[palette.startIndex+$0] == 0 }),
              pixels.allSatisfy({ $0 < 200 }) else {
            throw AppearanceError.invalid("Invalid original button-bar banner.")
        }
    }
    func bitmap() throws -> HAPBitmap {
        try validate()
        let colors = [UInt8](palette)
        var rgba = Data(); rgba.reserveCapacity(152*40*4)
        for index in pixels {
            let offset = Int(index)*4
            rgba.append(contentsOf:[colors[offset+1],colors[offset+2],colors[offset+3],255])
        }
        return HAPBitmap(width:152,height:40,rgba:rgba,textColor:nil,margins:[0,0,0,0],placement:[0,0,0,0])
    }
}

@MainActor enum HAPBannerDrawing {
    static func imageRect(_ image: HAPBitmap, in bounds: NSRect) -> NSRect {
        // 0x3FED0 centers at native size with signed division toward zero.
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let x = ((bounds.minX+bounds.maxX-width)/2).rounded(.towardZero)
        let y = ((bounds.minY+bounds.maxY-height)/2).rounded(.towardZero)
        return NSRect(x:x,y:y,width:width,height:height)
    }
    static func draw(_ image: HAPBitmap, in bounds: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        bounds.clip()
        image.draw(in:imageRect(image,in:bounds))
    }
}
