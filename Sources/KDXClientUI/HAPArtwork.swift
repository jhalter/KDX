import AppKit

/// HAP v1 contains data-only indexed raster records, not drawing bytecode.
/// See docs/HAP-FORMAT.md for the original decoder and stretch routine addresses.
public struct HAPArtwork: Codable, Equatable, Sendable {
    public let skins: Data
    public let icons: Data
    public init(skins: Data, icons: Data) throws {
        self.skins = skins; self.icons = icons
        _ = try decode()
    }
    public func decode() throws -> HAPDecodedArtwork {
        var budget = 16 * 1024 * 1024
        return try HAPDecodedArtwork(skins: Self.table(skins, header: 64, count: 512, recordHeader: 20, budget: &budget),
                                     icons: Self.table(icons, header: 0, count: 768, recordHeader: 8, budget: &budget))
    }
    private static func table(_ data: Data, header: Int, count: Int, recordHeader: Int, budget: inout Int) throws -> [Int: HAPBitmap] {
        if data.isEmpty { return [:] }
        let b = try AssetBytes(data), tableEnd = header + count * 4
        _ = try b.range(0, tableEnd)
        var result: [Int: HAPBitmap] = [:], records: [Int: HAPBitmap] = [:]
        var spans: [Range<Int>] = []
        for index in 0..<count {
            let offset = try b.u32(header + index * 4)
            if offset == 0 { continue }
            guard offset >= tableEnd, offset % 4 == 0 else { throw AppearanceError.invalid("Invalid HAP bitmap offset.") }
            if let existing = records[offset] { result[index] = existing; continue }
            let (bitmap, length) = try HAPBitmap.decode(b, at: offset, header: recordHeader, budget: &budget)
            let span = offset..<offset+length
            guard !spans.contains(where: { $0.overlaps(span) }) else { throw AppearanceError.invalid("Overlapping HAP bitmap records.") }
            spans.append(span); records[offset] = bitmap; result[index] = bitmap
        }
        return result
    }
}

public struct HAPDecodedArtwork: Sendable {
    public let skins: [Int: HAPBitmap]
    /// Four slots per icon ID: small, large, and two reserved slots.
    public let icons: [Int: HAPBitmap]
    // Keep layers separate: merging dictionaries would incorrectly select an
    // override's small icon when its large slot and the reference large slot
    // are absent. Original 0x99A58 falls back entirely to the reference atlas.
    var referenceIcons: [Int: HAPBitmap]? = nil
    public func icon(_ id: Int, small: Bool) -> HAPBitmap? {
        guard (0..<192).contains(id) else { return nil }
        if let referenceIcons {
            return icons[id*4+(small ? 0 : 1)] ?? referenceIcons[id*4+(small ? 0 : 1)] ?? (small ? nil : referenceIcons[id*4])
        }
        // Before the original application is imported, retain the standalone
        // theme's small icon as a minimal missing-asset recovery path.
        return small ? icons[id*4] : (icons[id*4+1] ?? icons[id*4])
    }
}

public struct HAPBitmap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Straight-alpha, top-to-bottom RGBA pixels. Native drawing never executes legacy code.
    public let rgba: Data
    public let textColor: UInt32?
    public let margins: [Int] // left, top, right, bottom
    public let placement: [Int]
    // Preserve the exact palette identity for the original icon-template branch.
    var monochromeIconTemplate = false

    static func decode(_ b: AssetBytes, at offset: Int, header: Int, budget: inout Int) throws -> (HAPBitmap, Int) {
        _ = try b.range(offset, header)
        let width = try b.u16(offset), height = try b.u16(offset+2)
        let flags = Int(b.bytes[offset+4]), depth = Int(b.bytes[offset+5])
        let count = Int(b.bytes[offset+6])+1, transparent = Int(b.bytes[offset+7])
        // 0x99660 uses the low nibble to locate an icon's color raster. Modes 2/4/8
        // precede it with a padded auxiliary plane, which the original drawing path
        // skips rather than composites. Control skins have a different descriptor
        // (0x9B4D0); only their established opaque/keyed layouts are accepted here.
        let mode = flags & 0x0f
        guard (header == 8 ? [0,1,2,4,8].contains(mode) : [0,1].contains(mode)), [1,2,4,8].contains(depth),
              width > 0, height > 0, width <= 16384, height <= 16384,
              width * height <= budget / 4,
              mode != 1 || transparent < count else { throw AppearanceError.invalid("Unsupported or oversized HAP bitmap.") }
        let stride = ((width * depth + 31) / 32) * 4
        let auxiliaryStride = header == 8 && mode >= 2 ? ((width * mode + 31) / 32) * 4 : 0
        let paletteAt = offset + header, pixelsAt = paletteAt + count * 4 + auxiliaryStride * height
        _ = try b.range(paletteAt, count*4 + auxiliaryStride*height + stride*height)
        let palette = try (0..<count).map { UInt32(try b.u32(paletteAt+$0*4)) }
        guard palette.allSatisfy({ $0 <= 0xffffff }) else { throw AppearanceError.invalid("Unsupported HAP bitmap palette.") }
        let margins = header == 20 ? Array(b.bytes[offset+12..<offset+16]).map(Int.init) : [0,0,0,0]
        guard margins[0]+margins[2] < width, margins[1]+margins[3] < height else { throw AppearanceError.invalid("Invalid HAP stretch margins.") }
        budget -= width * height * 4
        var rgba = [UInt8](); rgba.reserveCapacity(width*height*4)
        for y in 0..<height {
            for x in 0..<width {
                let bit = x * depth, packed = Int(b.bytes[pixelsAt+y*stride+bit/8])
                let index = (packed >> (8-depth-bit%8)) & ((1 << depth)-1)
                guard index < count else { throw AppearanceError.invalid("Invalid HAP pixel palette index.") }
                let rgb = palette[index]
                rgba += [UInt8((rgb >> 16)&255), UInt8((rgb >> 8)&255), UInt8(rgb&255), mode == 1 && index == transparent ? 0 : 255]
            }
        }
        let textColor = header == 20 ? UInt32(try b.u32(offset+8)) : nil
        let placement = header == 20 ? Array(b.bytes[offset+16..<offset+20]).map(Int.init) : [0,0,0,0]
        return (HAPBitmap(width: width, height: height, rgba: Data(rgba), textColor: textColor, margins: margins, placement: placement, monochromeIconTemplate: header == 8 && palette == [0xffffff,0]), pixelsAt-offset+stride*height)
    }

    public func cgImage(opaque: Bool = false) -> CGImage? {
        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: (opaque ? CGImageAlphaInfo.noneSkipLast : .last).rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Original 0x9B810: corners retain their pixels; edges repeat a single column/row;
    /// the center repeats the pixel at (left, top). This is not a scaled texture.
    @MainActor public func draw(in rect: NSRect, stretch: Bool = false, axis: NSLayoutConstraint.Orientation? = nil) {
        guard let image = cgImage(), rect.width > 0, rect.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.imageInterpolation = .none
        rect.clip()
        func drawPart(_ source: CGRect, _ destination: CGRect) {
            guard source.width > 0, source.height > 0, destination.width > 0, destination.height > 0,
                  let part = image.cropping(to: source) else { return }
            NSImage(cgImage: part, size: source.size).draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        }
        if !stretch { drawPart(CGRect(x:0,y:0,width:width,height:height), rect); return }
        let l = CGFloat(margins[0]), t = CGFloat(margins[1]), r = CGFloat(margins[2]), b = CGFloat(margins[3])
        // 0x9BBC0 / 0x9BD30 preserve every pixel on the non-stretched axis.
        if let axis {
            let horizontal = axis == .horizontal
            let leading = horizontal ? l : t, trailing = horizontal ? r : b
            let sourceLength = CGFloat(horizontal ? width : height), length = horizontal ? rect.width : rect.height
            guard length >= leading+trailing else { return }
            for (source,lengthSource,destination,lengthDestination) in [(CGFloat(0),leading,CGFloat(0),leading),(leading,CGFloat(1),leading,length-leading-trailing),(sourceLength-trailing,trailing,length-trailing,trailing)] {
                let from = horizontal ? CGRect(x:source,y:0,width:lengthSource,height:CGFloat(height)) : CGRect(x:0,y:source,width:CGFloat(width),height:lengthSource)
                let to = horizontal ? CGRect(x:rect.minX+destination,y:rect.minY,width:lengthDestination,height:CGFloat(height)) : CGRect(x:rect.minX,y:rect.minY+destination,width:CGFloat(width),height:lengthDestination)
                drawPart(from,to)
            }
            return
        }
        guard rect.width >= l+r, rect.height >= t+b else { return }
        let sx: [CGFloat] = [0,l,CGFloat(width)-r], sy: [CGFloat] = [0,t,CGFloat(height)-b]
        let sw: [CGFloat] = [l,1,r], sh: [CGFloat] = [t,1,b]
        let dx = [rect.minX,rect.minX+l,rect.maxX-r], dy = [rect.minY,rect.minY+t,rect.maxY-b]
        let dw = [l,rect.width-l-r,r], dh = [t,rect.height-t-b,b]
        for y in 0..<3 { for x in 0..<3 {
            drawPart(CGRect(x:sx[x],y:sy[y],width:sw[x],height:sh[y]), CGRect(x:dx[x],y:dy[y],width:dw[x],height:dh[y]))
        } }
    }
}
