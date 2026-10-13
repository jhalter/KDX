import AppKit

/// Indexed control artwork embedded outside the HAP in the verified 1.600 executable.
/// Stored as data from the user's import; no original pixels are bundled with the app.
public struct HAPChromeArtwork: Codable, Equatable, Sendable {
    public let close: Data
    public let menu: Data
    public let maximize: Data
    public let minimize: Data
    public let resize: Data
    public let horizontalScrollGrip: Data?
    public let verticalScrollGrip: Data?
    public let checkboxOff: Data?
    public let checkboxOn: Data?
    public let checkboxMixed: Data?
    public let radioOff: Data?
    public let radioOn: Data?
    public let radioMixed: Data?
    public let defaultButtonCorners: Data?
    public let progress: HAPProgressArtwork?
    public let banner: HAPBannerArtwork?
    public let wonderLight: HAPWonderLightArtwork?
    public let horizontalSliderThumb: Data?

    init(reference: AssetBytes) throws {
        close = try reference.data(0x108b38,98)
        maximize = try reference.data(0x108b9c,98)
        minimize = try reference.data(0x108c00,98)
        menu = try reference.data(0x108c68,224)
        resize = try reference.data(0x1094c0,153)
        horizontalScrollGrip = try reference.data(0x108b00,16)
        verticalScrollGrip = try reference.data(0x108b10,16)
        checkboxOff = try reference.data(0x108f54,98)
        checkboxOn = try reference.data(0x108fb8,98)
        checkboxMixed = try reference.data(0x10901c,98)
        radioOff = try reference.data(0x109080,98)
        radioOn = try reference.data(0x1090e4,98)
        radioMixed = try reference.data(0x109148,98)
        defaultButtonCorners = try reference.data(0x108f18,60)
        progress = try HAPProgressArtwork(reference:reference)
        banner = try HAPBannerArtwork(reference:reference)
        wonderLight = try HAPWonderLightArtwork(reference:reference)
        horizontalSliderThumb = try reference.data(0x108dc8,112)
        try validate()
    }
    /// Byte-identical to the PowerPC client's assets, at Windows executable offsets.
    init(windowsClientReference b: AssetBytes) throws {
        close = try b.data(0x1042e0,98); maximize = try b.data(0x104342,98)
        minimize = try b.data(0x1043a4,98); menu = try b.data(0x104406,224)
        resize = try b.data(0x104c64,153)
        horizontalScrollGrip = try b.data(0x11a8a0,16); verticalScrollGrip = try b.data(0x11a8b0,16)
        checkboxOff = try b.data(0x1046fc,98); checkboxOn = try b.data(0x10475e,98); checkboxMixed = try b.data(0x1047c0,98)
        radioOff = try b.data(0x104822,98); radioOn = try b.data(0x104884,98); radioMixed = try b.data(0x1048e6,98)
        defaultButtonCorners = try b.data(0x1046c0,60)
        horizontalSliderThumb = try b.data(0x104566,112)
        progress = try HAPProgressArtwork(digits:b.data(0x104950,100),complete:b.data(0x1049b4,16),caps:b.data(0x1049e8,40))
        banner = try HAPBannerArtwork(palette:b.data(0xf8de4,800),pixels:b.data(0xf9104,6080))
        wonderLight = try HAPWonderLightArtwork(palette:b.data(0x104ba4,64),pixels:b.data(0x104be4,128))
        try validate()
    }
    /// Same toolkit rasters in the verified Windows server shipped in the OSX wrapper.
    init(serverReference b: AssetBytes) throws {
        close = try b.data(0x84618,98); maximize = try b.data(0x8467a,98)
        minimize = try b.data(0x846dc,98); menu = try b.data(0x8473e,224)
        resize = try b.data(0x84f9c,153)
        horizontalScrollGrip = try b.data(0x85090,16); verticalScrollGrip = try b.data(0x850a0,16)
        checkboxOff = try b.data(0x84a34,98); checkboxOn = try b.data(0x84a96,98); checkboxMixed = try b.data(0x84af8,98)
        radioOff = try b.data(0x84b5a,98); radioOn = try b.data(0x84bbc,98); radioMixed = try b.data(0x84c1e,98)
        defaultButtonCorners = try b.data(0x849f8,60)
        horizontalSliderThumb = try b.data(0x8489e,112)
        progress = nil; banner = nil; wonderLight = nil
        try validate()
    }
    func validate() throws {
        try progress?.validate()
        try banner?.validate()
        try wonderLight?.validate()
        if let data = horizontalSliderThumb {
            guard data.count == 112, data.allSatisfy({ $0 >> 4 <= 6 && $0 & 15 <= 6 }) else {
                throw AppearanceError.invalid("Invalid original slider artwork.")
            }
        }
        if let data = defaultButtonCorners {
            guard data.count == 60, data.allSatisfy({ $0 >> 4 <= 4 && $0 & 15 <= 4 }) else {
                throw AppearanceError.invalid("Invalid original default-button artwork.")
            }
        }
        for data in [checkboxOff,checkboxOn,checkboxMixed,radioOff,radioOn,radioMixed].compactMap({ $0 }) {
            guard data.count == 98, data.allSatisfy({ $0 >> 4 <= 8 && $0 & 15 <= 8 }) else {
                throw AppearanceError.invalid("Invalid original checkbox artwork.")
            }
        }
        for data in [horizontalScrollGrip,verticalScrollGrip].compactMap({ $0 }) {
            guard data.count == 16 else { throw AppearanceError.invalid("Invalid scrollbar grip artwork.") }
        }
        for (data,length,maximum) in [(close,98,5),(menu,224,5),(maximize,98,5),(minimize,98,5),(resize,153,6)] {
            guard data.count == length, data.allSatisfy({ Int($0 >> 4) <= maximum && Int($0 & 15) <= maximum }) else {
                throw AppearanceError.invalid("Invalid original window artwork.")
            }
        }
    }
    func pixels(for control: HAPWindowControl) -> Data {
        switch control { case .close: close; case .menu: menu; case .maximize: maximize; case .minimize: minimize }
    }
}

enum HAPWindowControl: CaseIterable {
    case close, menu, maximize, minimize
    var label: String {
        switch self { case .close: "Close window"; case .menu: "Window menu"; case .maximize: "Maximize or restore"; case .minimize: "Minimize to KDX dock" }
    }
    var skinBase: Int {
        switch self { case .close: 207; case .menu: 222; case .maximize: 217; case .minimize: 212 }
    }
    func defaultHitRect(in bounds: NSRect) -> NSRect {
        let x: CGFloat, width: CGFloat
        switch self {
        case .close: x = 3; width = 16
        case .menu: x = 23; width = 39
        case .maximize: x = bounds.width-39; width = 18
        case .minimize: x = bounds.width-21; width = 18
        }
        return NSRect(x:bounds.minX+x,y:bounds.minY,width:width,height:22)
    }
    func defaultImageRect(in bounds: NSRect) -> NSRect {
        let x: CGFloat
        switch self { case .close: x = 5; case .menu: x = 27; case .maximize: x = bounds.width-37; case .minimize: x = bounds.width-19 }
        return NSRect(x:bounds.minX+x,y:bounds.minY+4,width:self == .menu ? 32 : 14,height:14)
    }
}

/// Original window drawing: PPC 0x99D30, 0x99B40, 0x9E770 and 0x9F4E0.
/// All coordinates are whole logical pixels in a flipped AppKit view.
@MainActor enum HAPWindowDrawing {
    static func frameSkin(active: Bool) -> HAPBitmap? { ClassicStyle.shared.artwork?.skins[active ? 205 : 204] }
    static func contentRect(in bounds: NSRect) -> NSRect {
        // Placement bytes, not stretch margins, specify the window's content insets.
        let insets = ClassicStyle.shared.artwork?.skins[204]?.placement ?? [6,22,6,6]
        return NSRect(x:bounds.minX+CGFloat(insets[0]),y:bounds.minY+CGFloat(insets[1]),
                      width:max(0,bounds.width-CGFloat(insets[0]+insets[2])),height:max(0,bounds.height-CGFloat(insets[1]+insets[3])))
    }
    static func controlSkin(_ control: HAPWindowControl, active: Bool, pressed: Bool) -> HAPBitmap? {
        let skins = ClassicStyle.shared.artwork?.skins
        // 0x9F560 enables pressed tracking only when a pressed image exists.
        if pressed, let skin = skins?[control.skinBase+2] { return skin }
        return skins?[control.skinBase + (active ? 1 : 0)]
    }
    static func placedRect(_ skin: HAPBitmap, in bounds: NSRect) -> NSRect {
        NSRect(x:skin.placement[2] != 0 ? bounds.maxX-CGFloat(skin.placement[2]+skin.width) : bounds.minX+CGFloat(skin.placement[0]),
               y:bounds.minY+CGFloat(skin.placement[1]),width:CGFloat(skin.width),height:CGFloat(skin.height))
    }
    static func hitRect(_ control: HAPWindowControl, in bounds: NSRect, active: Bool) -> NSRect {
        guard frameSkin(active:active) != nil else { return control.defaultHitRect(in:bounds) }
        guard let skin = controlSkin(control,active:active,pressed:false) else { return .zero }
        return placedRect(skin,in:bounds)
    }
    static func frame(_ rect: NSRect, active: Bool) {
        if let skin = frameSkin(active:active) { skin.draw(in:rect,stretch:true); return }
        let style = ClassicStyle.shared
        guard style.appearance.colors.count >= 104 else { ClassicPainter.bevel(rect); return }
        let base = active ? 79 : 54, w = rect.width, h = rect.height
        func fill(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ slot: Int) {
            guard width > 0, height > 0 else { return }
            style.color(base+slot).setFill(); NSRect(x:rect.minX+x,y:rect.minY+y,width:width,height:height).fill()
        }
        func horizontal(_ x: CGFloat, _ y: CGFloat, _ end: CGFloat, _ slot: Int) { fill(x,y,end-x,1,slot) }
        func vertical(_ x: CGFloat, _ y: CGFloat, _ end: CGFloat, _ slot: Int) { fill(x,y,1,end-y,slot) }
        func pixel(_ x: CGFloat, _ y: CGFloat, _ slot: Int) { fill(x,y,1,1,slot) }
        for row in 0..<18 { fill(2,CGFloat(row+2),w-4,1,7+row) }
        fill(2,h-4,w-4,2,2); fill(2,20,2,h-24,2); fill(w-4,20,2,h-24,2)
        horizontal(0,0,w,5); horizontal(0,1,w-2,0); pixel(w-2,1,2)
        horizontal(4,20,w-5,4); pixel(w-5,20,2); horizontal(5,21,w-5,5)
        horizontal(5,h-6,w-5,5); pixel(4,h-5,2); horizontal(5,h-5,w-4,0)
        pixel(1,h-2,2); horizontal(2,h-2,w-1,4); horizontal(0,h-1,w,5)
        vertical(0,1,h-1,5); vertical(1,2,h-2,0); vertical(4,21,h-5,4); vertical(5,22,h-6,5)
        vertical(w-1,1,h-1,5); vertical(w-2,2,h-2,4); vertical(w-5,21,h-5,0); vertical(w-6,22,h-6,5)
    }
    static func control(_ control: HAPWindowControl, in bounds: NSRect, active: Bool, pressed: Bool) {
        if frameSkin(active:active) != nil {
            if let skin = controlSkin(control,active:active,pressed:pressed) { skin.draw(in:placedRect(skin,in:bounds)) }
            return
        }
        let rect = control.defaultImageRect(in:bounds), style = ClassicStyle.shared
        if let artwork = style.chromeArtwork {
            indexed(artwork.pixels(for:control),width:Int(rect.width),height:14,stride:Int(rect.width)/2,
                    rect:rect,slots:[5,0,0,2,6,4],base:active ? 79 : 54)
        } else {
            ClassicPainter.bevel(rect,pressed:pressed)
            let symbol = control == .close ? "×" : control == .menu ? "≡" : control == .maximize ? "+" : "−"
            (symbol as NSString).draw(in:rect,withAttributes:[.font:style.font,.foregroundColor:style.color(5)])
        }
    }
    static func resize(in bounds: NSRect, active: Bool) {
        let style = ClassicStyle.shared
        if let skin = style.artwork?.skins[active ? 228 : 227] {
            skin.draw(in:resizeHitRect(in:bounds,active:active))
        } else if let artwork = style.chromeArtwork {
            // Index zero is unused in the original resize raster.
            indexed(artwork.resize,width:17,height:17,stride:9,rect:NSRect(x:bounds.maxX-21,y:bounds.maxY-21,width:17,height:17),slots:[5,4,2,1,0,0,5],base:active ? 79 : 54)
        }
    }
    static func resizeHitRect(in bounds: NSRect, active: Bool) -> NSRect {
        if let skin = ClassicStyle.shared.artwork?.skins[active ? 228 : 227] {
            return NSRect(x:bounds.maxX-CGFloat(skin.width+skin.placement[2]),y:bounds.maxY-CGFloat(skin.height+skin.placement[3]),width:CGFloat(skin.width),height:CGFloat(skin.height))
        }
        return NSRect(x:bounds.maxX-21,y:bounds.maxY-21,width:21,height:21)
    }
    private static func indexed(_ data: Data, width: Int, height: Int, stride: Int, rect: NSRect, slots: [Int], base: Int) {
        // Revalidate decoded catalog data before indexing (Codable bypasses the importer).
        guard data.count == stride*height else { return }
        let bytes = [UInt8](data)
        for y in 0..<height { for x in 0..<width {
            let index = Int(bytes[y*stride+x/2] >> (x % 2 == 0 ? 4 : 0) & 15)
            guard slots.indices.contains(index) else { continue }
            let style = ClassicStyle.shared
            let recoverySlots = [1,1,2,3,3,5,5]
            style.color(style.appearance.colors.count >= 104 ? base+slots[index] : recoverySlots[slots[index]]).setFill()
            NSRect(x:rect.minX+CGFloat(x),y:rect.minY+CGFloat(y),width:1,height:1).fill()
        } }
    }
    static func title(_ text: String, in bounds: NSRect, active: Bool, controls: Bool = true) {
        let style = ClassicStyle.shared, skin = frameSkin(active:active)
        var left = bounds.minX+60, right = bounds.maxX-40
        if !controls { left = bounds.minX+6; right = bounds.maxX-6 }
        else if skin != nil {
            left = bounds.minX; right = bounds.maxX
            for control in HAPWindowControl.allCases {
                guard let bitmap = controlSkin(control,active:active,pressed:false) else { continue }
                let rect = placedRect(bitmap,in:bounds)
                if bitmap.placement[2] != 0 { right = min(right,rect.minX) } else { left = max(left,rect.maxX) }
            }
            left += 2; right -= 2
        }
        let height = CGFloat(skin?.placement[1] ?? 22)
        let color = skin?.textColor.map { NSColor(srgbRed:Double(($0>>16)&255)/255,green:Double(($0>>8)&255)/255,blue:Double($0&255)/255,alpha:1) } ?? style.color(style.appearance.colors.count >= 104 ? (active ? 85 : 60) : 5)
        let attributes: [NSAttributedString.Key:Any] = [.font:style.font,.foregroundColor:color]
        let size = (text as NSString).size(withAttributes:attributes)
        var x = max(left,floor(bounds.midX-size.width/2))
        if skin != nil { x = max(left,min(x,right-size.width)) }
        NSGraphicsContext.saveGraphicsState()
        NSRect(x:left,y:bounds.minY+1,width:max(0,right-left),height:max(0,height-2)).clip()
        if style.font.fontName.hasPrefix("KDXImported-") { NSGraphicsContext.current?.shouldAntialias = false }
        (text as NSString).draw(at:NSPoint(x:x,y:bounds.minY+floor((height-size.height)/2)),withAttributes:attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}
