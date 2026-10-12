import AppKit

extension HAPBitmap {
    /// 0x99660: state-color averaging, or the exact white/black
    /// two-entry template palette rendered transparently in the text color.
    func tintedIcon(tint: UInt32?, text: UInt32) -> HAPBitmap {
        guard tint != nil || monochromeIconTemplate else { return self }
        var pixels = Array(rgba)
        for index in stride(from:0,to:pixels.count,by:4) {
            if monochromeIconTemplate {
                let white = pixels[index] == 255
                pixels[index+3] = white ? 0 : 255
                for (component,shift) in [16,8,0].enumerated() { pixels[index+component] = UInt8((text >> shift)&255) }
            } else if let tint {
                for (component,shift) in [16,8,0].enumerated() {
                    let source = Int(pixels[index+component])
                    // White uses the reference's lookup table at file 0xF89D8,
                    // which rounds upward for even source components.
                    pixels[index+component] = UInt8(tint == 0xffffff ? source/2+128 : (source+Int((tint >> shift)&255))/2)
                }
            }
        }
        return HAPBitmap(width:width,height:height,rgba:Data(pixels),textColor:textColor,margins:margins,placement:placement)
    }
}
