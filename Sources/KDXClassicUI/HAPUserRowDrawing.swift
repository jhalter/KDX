import AppKit

/// User-list background and text rules from 0x429D0. AppKit still owns native
/// column layout, selection, focus, sorting, filtering and accessible text.
@MainActor enum HAPUserRowDrawing {
    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed:CGFloat((rgb >> 16)&255)/255,green:CGFloat((rgb >> 8)&255)/255,blue:CGFloat(rgb&255)/255,alpha:1)
    }
    static func textColor(_ profile: ClassicUserAdornment, selected: Bool, emphasized: Bool) -> NSColor {
        if selected && emphasized { return ClassicStyle.shared.color(18) }
        return profile.foreground.map(color) ?? ClassicStyle.shared.color(16)
    }
    static func rgb(_ color: NSColor) -> UInt32 {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        return UInt32((c.redComponent*255).rounded()) << 16 | UInt32((c.greenComponent*255).rounded()) << 8 | UInt32((c.blueComponent*255).rounded())
    }
    /// 0x61C40 uses signed division truncated toward zero and divides by the
    /// entire width, not width-1. Consequently the final pixel stops short of end.
    nonisolated static func gradientColor(start: UInt32, end: UInt32, offset: Int, width: Int) -> UInt32 {
        guard width > 0 else { return start }
        let position = max(0,min(offset,width-1))
        var result: UInt32 = 0
        for shift in [16,8,0] {
            let first = Int((start >> shift)&255), last = Int((end >> shift)&255)
            result |= UInt32(first+(last-first)*position/width) << shift
        }
        return result
    }
    static func background(_ rect: NSRect, profile: ClassicUserAdornment, selected: Bool, emphasized: Bool, dirtyRect: NSRect, size: ClassicUserRowSize = .compact) {
        let active = selected && emphasized
        let base = active ? ClassicStyle.shared.color(17) : profile.background.map(color) ?? ClassicStyle.shared.color(15)
        base.setFill(); rect.intersection(dirtyRect).fill()
        guard profile.gradient else { return }
        let start = Int(rect.minX)+size.gradientOrigin, end = Int(rect.maxX), width = end-start
        guard width > 0 else { return }
        let foreground = rgb(textColor(profile,selected:selected,emphasized:emphasized)), background = rgb(base)
        let clipped = rect.intersection(dirtyRect)
        guard !clipped.isEmpty else { return }
        let first = max(start,Int(floor(clipped.minX))), last = min(end,Int(ceil(clipped.maxX)))
        guard first < last else { return }
        for x in first..<last {
            color(gradientColor(start:background,end:foreground,offset:x-start,width:width)).setFill()
            NSRect(x:CGFloat(x),y:clipped.minY,width:1,height:clipped.height).intersection(clipped).fill()
        }
    }
    static func inactiveSelection(_ rect: NSRect, size: ClassicUserRowSize = .compact) {
        // 0x42CF0: inward outline after the class bar, 2px compact / 3px normal.
        let area = NSRect(x:rect.minX+size.classWidth,y:rect.minY,width:max(0,rect.width-size.classWidth),height:rect.height)
        let width = size.outlineWidth
        guard !area.isEmpty else { return }
        ClassicStyle.shared.color(17).setFill()
        NSRect(x:area.minX,y:area.minY,width:area.width,height:min(width,area.height)).fill()
        NSRect(x:area.minX,y:max(area.minY,area.maxY-width),width:area.width,height:min(width,area.height)).fill()
        NSRect(x:area.minX,y:area.minY,width:min(width,area.width),height:area.height).fill()
        NSRect(x:max(area.minX,area.maxX-width),y:area.minY,width:min(width,area.width),height:area.height).fill()
    }
}
