import AppKit

/// Original 0x993F0 palette transform and 0x3FB30/0x3FD50 notification states.
public enum HAPWonderLightState: Int, CaseIterable {
    case idle = 6, red = 7, amber = 8
    var tint: UInt32 {
        switch self { case .idle: 0x909090; case .red: 0xdd0000; case .amber: 0xff7f00 }
    }
}

/// Imported data only: a 16-color palette and a high-nibble-first 16×16 raster.
public struct HAPWonderLightArtwork: Codable, Equatable, Sendable {
    public let palette: Data
    public let pixels: Data
    init(palette: Data, pixels: Data) throws {
        self.palette = palette; self.pixels = pixels; try validate()
    }
    init(reference: AssetBytes) throws {
        try self.init(palette:reference.data(0x109400,64),pixels:reference.data(0x109440,128))
    }
    func validate() throws {
        guard palette.count == 64, pixels.count == 128,
              stride(from:0,to:64,by:4).allSatisfy({ palette[palette.startIndex+$0] == 0 }) else {
            throw AppearanceError.invalid("Invalid original WonderLight artwork.")
        }
    }
    func bitmap(_ state: HAPWonderLightState) throws -> HAPBitmap {
        try validate()
        let source = [UInt8](palette), raster = [UInt8](pixels)
        let tint = [Int(state.tint >> 16),Int((state.tint >> 8)&255),Int(state.tint&255)]
        let colors = (0..<16).map { index -> [UInt8] in
            let scaled = (0..<3).map { Int(source[index*4+$0+1])*tint[$0]*2/255 }
            let spill = scaled.map { max(0,$0-255)/2 }
            return (0..<3).map { UInt8(min(255,scaled[$0]+spill[($0+1)%3]+spill[($0+2)%3])) }
        }
        var rgba = Data(); rgba.reserveCapacity(1024)
        for pixel in 0..<256 {
            let index = Int(pixel%2 == 0 ? raster[pixel/2] >> 4 : raster[pixel/2]&15)
            rgba.append(contentsOf:colors[index]+[index == 0 ? 0 : 255])
        }
        return HAPBitmap(width:16,height:16,rgba:rgba,textColor:nil,margins:[0,0,0,0],placement:[0,0,0,0])
    }
}

@MainActor enum HAPWonderLightDrawing {
    static func rect(in bounds: NSRect) -> NSRect {
        // 0x3FBD0: narrow buttons center the light; wide ones use x + 110.
        NSRect(x:bounds.width < 40 ? ((bounds.minX+bounds.maxX-16)/2).rounded(.towardZero) : bounds.minX+110,
               y:((bounds.minY+bounds.maxY-16)/2).rounded(.towardZero),width:16,height:16)
    }
    static func draw(_ state: HAPWonderLightState, in bounds: NSRect) {
        let rect = rect(in:bounds)
        if let bitmap = try? ClassicStyle.shared.chromeArtwork?.wonderLight?.bitmap(state) { bitmap.draw(in:rect) }
        else {
            // Minimal setup/recovery indicator when the original data isn't installed.
            HAPUserRowDrawing.color(state.tint).setFill()
            NSBezierPath(ovalIn:rect.insetBy(dx:2,dy:2)).fill()
        }
    }
}
