import AppKit
import ImageIO
import KDXCore

/// Converts user-selected images to the original opaque 32×32 indexed profile
/// format. This is independent of HAP artwork and never adds files to a theme.
enum ClassicProfileImage {
    static let maximumBytes = 16*1024*1024
    static func load(_ url: URL, background: UInt32) throws -> [UInt8] {
        let values = try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximumBytes else {
            throw AppearanceError.invalid("Choose an image file no larger than 16 MiB.")
        }
        return try decode(Data(contentsOf:url,options:.mappedIfSafe),background:background)
    }
    static func decode(_ data: Data, background: UInt32) throws -> [UInt8] {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...4096).contains(width), (1...4096).contains(height), width*height <= 16*1024*1024 else {
            throw AppearanceError.invalid("Choose a single image up to 4096×4096 pixels.")
        }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source,0,[
            kCGImageSourceCreateThumbnailFromImageAlways:true,
            kCGImageSourceCreateThumbnailWithTransform:true,
            kCGImageSourceThumbnailMaxPixelSize:32,
            kCGImageSourceShouldCacheImmediately:true
        ] as CFDictionary), let space = CGColorSpace(name:CGColorSpace.sRGB) else {
            throw AppearanceError.invalid("This image could not be decoded.")
        }
        var rgba = [UInt8](repeating:0,count:32*32*4)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data:buffer.baseAddress,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(red:CGFloat((background>>16)&255)/255,green:CGFloat((background>>8)&255)/255,blue:CGFloat(background&255)/255,alpha:1)
            context.fill(CGRect(x:0,y:0,width:32,height:32))
            let scale = min(32/CGFloat(thumbnail.width),32/CGFloat(thumbnail.height))
            let w = max(1,(CGFloat(thumbnail.width)*scale).rounded()), h = max(1,(CGFloat(thumbnail.height)*scale).rounded())
            context.interpolationQuality = .high
            context.draw(thumbnail,in:CGRect(x:floor((32-w)/2),y:floor((32-h)/2),width:w,height:h))
            return true
        }
        guard rendered else { throw AppearanceError.invalid("The icon could not be converted.") }
        return try encode(rgba:rgba)
    }
    static func encode(rgba: [UInt8]) throws -> [UInt8] {
        guard rgba.count == 4096 else { throw AppearanceError.invalid("Profile icons must be 32×32 pixels.") }
        let rgb = stride(from:0,to:rgba.count,by:4).map { UInt32(rgba[$0])<<16 | UInt32(rgba[$0+1])<<8 | UInt32(rgba[$0+2]) }
        var palette = [UInt32](), indices = [UInt8](), lookup = [UInt32:UInt8]()
        for color in rgb {
            if let index = lookup[color] { indices.append(index) }
            else if palette.count < 256 {
                let index = UInt8(palette.count); lookup[color] = index; palette.append(color); indices.append(index)
            } else { break }
        }
        if indices.count != 1024 {
            // Deterministic 3/3/2 quantization for images with more than 256
            // colors. Existing indexed icons keep their exact source colors.
            palette = (0..<256).map { index in
                let red = UInt32((index >> 5) * 255 / 7)
                let green = UInt32(((index >> 2) & 7) * 255 / 7)
                let blue = UInt32((index & 3) * 255 / 3)
                return (red << 16) | (green << 8) | blue
            }
            indices = rgb.map { UInt8((($0>>16)&0xe0) | (($0>>11)&0x1c) | (($0>>6)&3)) }
        }
        let packed = palette.count <= 16
        var bytes: [UInt8] = [packed ? 1 : 3,UInt8(palette.count-1)]
        for color in palette { bytes += [UInt8((color>>16)&255),UInt8((color>>8)&255),UInt8(color&255)] }
        if packed { for offset in stride(from:0,to:1024,by:2) { bytes.append(indices[offset]<<4 | indices[offset+1]) } }
        else { bytes += indices }
        return bytes
    }
    @MainActor static func png(_ bytes: [UInt8]) -> Data? {
        guard let icon = ClassicUserIcon(bytes),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:32,pixelsHigh:32,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:128,bitsPerPixel:32),
              let output = bitmap.bitmapData else { return nil }
        let pixels = icon.bitmap(small:false).rgba
        pixels.copyBytes(to:output,count:4096)
        return bitmap.representation(using:.png,properties:[:])
    }
}

struct ClassicProfileDraft: Equatable {
    var nickname: String
    var info: String
    var colors: [UInt8]
    var icon: [UInt8]
    var gradient: Bool
    init(_ user: KDXUser) {
        nickname = user.nickname; info = user.info; colors = user.colors; icon = user.icon; gradient = user.flags & 4 != 0
    }
    var usesAppearanceColors: Bool { colors == [UInt8](repeating:0,count:6) }
    func color(_ background: Bool) -> UInt32 {
        guard colors.count == 6 else { return 0 }
        let offset = background ? 3 : 0
        return UInt32(colors[offset])<<16 | UInt32(colors[offset+1])<<8 | UInt32(colors[offset+2])
    }
    mutating func setColor(_ rgb: UInt32, background: Bool) {
        if colors.count != 6 { colors = [UInt8](repeating:0,count:6) }
        let offset = background ? 3 : 0
        colors.replaceSubrange(offset..<offset+3,with:[UInt8((rgb>>16)&255),UInt8((rgb>>8)&255),UInt8(rgb&255)])
    }
}
