import AppKit

/// Original 0x9AB70, for HAP icon buttons with a left label (flags 0x28)
/// or no label (0x20). The column is sized by the control, not the bitmap.
struct HAPIconButtonLayout {
    let iconRegion: NSRect
    let labelRegion: NSRect
    var small: Bool { iconRegion.width < 24 || iconRegion.height < 24 }
    init(bounds: NSRect, iconOnly: Bool) {
        let width: CGFloat = bounds.height < 40 ? 16 : 32
        iconRegion = NSRect(x:bounds.minX+(iconOnly ? 0 : 6),y:bounds.minY+4,
                            width:iconOnly ? bounds.width : width,height:max(0,bounds.height-8))
        labelRegion = iconOnly ? .zero : NSRect(x:bounds.minX+width+10,y:bounds.minY,
                                               width:max(0,bounds.width-width-13),height:bounds.height)
    }
    func iconRect(_ bitmap: HAPBitmap) -> NSRect {
        let x = iconRegion.minX+CGFloat((Int(iconRegion.width)-bitmap.width)/2)
        let y = iconRegion.minY+CGFloat((Int(iconRegion.height)-bitmap.height)/2)
        return NSRect(x:x,y:y,width:CGFloat(bitmap.width),height:CGFloat(bitmap.height))
    }
}

@MainActor enum HAPIconButtonDrawing {
    /// The square three-pixel bezel at 0x95790, selected by the original bar's
    /// 0x2A/0x22 flags. Ordinary text buttons use a different clipped-corner path.
    static func border(_ rect: NSRect, pressed: Bool, enabled: Bool) -> NSColor {
        let base = !enabled ? 43 : pressed ? 36 : 29
        let style = ClassicStyle.shared, w = rect.width, h = rect.height
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        rect.clip()
        func fill(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ slot: Int) {
            guard width > 0, height > 0 else { return }
            style.color(base+slot).setFill()
            NSRect(x:rect.minX+x,y:rect.minY+y,width:width,height:height).fill()
        }
        func horizontal(_ x: CGFloat, _ y: CGFloat, _ end: CGFloat, _ slot: Int) { fill(x,y,end-x,1,slot) }
        func vertical(_ x: CGFloat, _ y: CGFloat, _ end: CGFloat, _ slot: Int) { fill(x,y,1,end-y,slot) }
        func pixel(_ x: CGFloat, _ y: CGFloat, _ slot: Int) { fill(x,y,1,1,slot) }
        fill(0,0,w,h,5); fill(1,1,w-2,h-2,2)
        pixel(1,1,0); horizontal(2,1,w-2,0); pixel(w-2,1,2)
        horizontal(2,2,w-3,1); pixel(w-3,2,2)
        pixel(2,h-3,2); horizontal(3,h-3,w-2,3)
        pixel(1,h-2,2); horizontal(2,h-2,w-1,4)
        vertical(1,2,h-2,0); vertical(2,3,h-3,1)
        vertical(w-3,3,h-3,3); vertical(w-2,2,h-2,4)
        return style.color(base+6)
    }
}
