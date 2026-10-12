import AppKit

enum HAPScrollPart: Int, CaseIterable {
    case none = 0, decrement = 1, increment = 2, trailingDecrement = 3, leadingIncrement = 4, pageBefore = 5, pageAfter = 6, knob = 7
    var native: NSScroller.Part {
        switch self {
        case .none: .noPart
        case .decrement, .trailingDecrement: .decrementLine
        case .increment, .leadingIncrement: .incrementLine
        case .pageBefore: .decrementPage
        case .pageAfter: .incrementPage
        case .knob: .knob
        }
    }
}

/// Pixel layout from 0x94830 (palette controls) and 0x9DD20 (bitmap skins).
struct HAPScrollLayout {
    let bounds: NSRect
    let horizontal: Bool
    let enabled: Bool
    let value: Double
    let proportion: CGFloat
    var parts: [HAPScrollPart:NSRect] = [:]
    var track = NSRect.zero
    var skinID: Int?
    var thumbID: Int?
    var paired = false
    var usesSkins: Bool { skinID != nil }
    var knob: NSRect { parts[.knob] ?? .zero }
    var length: CGFloat { horizontal ? bounds.width : bounds.height }
    func slice(_ start: CGFloat, _ end: CGFloat) -> NSRect {
        horizontal ? NSRect(x:bounds.minX+start,y:bounds.minY,width:max(0,end-start),height:bounds.height) : NSRect(x:bounds.minX,y:bounds.minY+start,width:bounds.width,height:max(0,end-start))
    }
    init(bounds: NSRect, horizontal: Bool, value: Double, proportion: CGFloat, enabled: Bool, skins: [Int:HAPBitmap] = [:]) {
        self.bounds = bounds; self.horizontal = horizontal; self.enabled = enabled
        self.value = value; self.proportion = proportion
        let length = horizontal ? bounds.width : bounds.height
        let axis = horizontal ? 0 : 1, offset = horizontal ? 0 : 19
        paired = length >= 129
        var start: CGFloat = paired ? 30 : 15, end = length-start, minimum: CGFloat = 17, minimumTrack: CGFloat = 34
        // Disabled skins include all decoration; their controls are not interactive.
        if !enabled, let skin = skins[148+offset] {
            let edges = skin.margins[axis]+skin.margins[axis+2]
            skinID = length < CGFloat(edges) ? (skins[149+offset] == nil ? nil : 149+offset) : 148+offset
            if skinID != nil { return }
        }
        let candidate = (length < 128 ? 147 : 146)+offset
        if let background = skins[candidate] {
            let edgeSum = CGFloat(background.margins[axis]+background.margins[axis+2])
            if length < edgeSum, skins[149+offset] != nil { skinID = 149+offset; return }
            if length >= edgeSum, let thumb = skins[150+offset] {
                skinID = candidate; thumbID = 150+offset; paired = length >= 128
                start = CGFloat(background.placement[axis]); end = length-CGFloat(background.placement[axis+2])
                minimum = CGFloat(max(16,thumb.margins[axis]+thumb.margins[axis+2])); minimumTrack = minimum+10
                let leadingEnd = paired ? floor(start/2) : start
                let trailingStart = paired ? length-floor((length-end)/2) : end
                parts[.decrement] = slice(0,leadingEnd); parts[.increment] = slice(trailingStart,length)
                if paired {
                    parts[.leadingIncrement] = slice(leadingEnd,start)
                    parts[.trailingDecrement] = slice(end,trailingStart)
                }
            }
        }
        if skinID == nil {
            guard length >= 31 else { return }
            parts[.decrement] = slice(0,16); parts[.increment] = slice(length-16,length)
            if paired {
                parts[.leadingIncrement] = slice(15,31)
                parts[.trailingDecrement] = slice(length-31,length-15)
            }
        }
        track = slice(start,end)
        guard end-start >= minimumTrack else { parts[.pageBefore] = track; return }
        let ratio = proportion.isFinite ? max(0,min(1,proportion)) : 1
        let position = value.isFinite ? max(0,min(1,value)) : 0
        let size = min(end-start,max(minimum,floor((end-start)*ratio)))
        let origin = start+floor((end-start-size)*position)
        parts[.knob] = slice(origin,origin+size)
        parts[.pageBefore] = slice(start,origin+(usesSkins ? 0 : 1))
        parts[.pageAfter] = slice(origin+size-(usesSkins ? 0 : 1),end)
    }
    func hit(_ point: NSPoint) -> HAPScrollPart {
        guard enabled, bounds.contains(point) else { return .none }
        for part in [HAPScrollPart.knob,.decrement,.increment,.trailingDecrement,.leadingIncrement,.pageBefore,.pageAfter] {
            if parts[part]?.contains(point) == true { return part }
        }
        return .none
    }
    func value(forKnobOrigin origin: CGFloat) -> Double {
        let start = horizontal ? track.minX : track.minY
        let travel = (horizontal ? track.width-knob.width : track.height-knob.height)
        guard travel > 0 else { return 0 }
        return Double(max(0,min(1,(origin-start)/travel)))
    }
    /// The bitmap renderer sizes the pressed thumb independently of the normal
    /// thumb used for hit testing (0x9D740 and 0x9DB70).
    func drawingKnob(using bitmap: HAPBitmap) -> NSRect {
        let axis = horizontal ? 0 : 1
        let minimum = CGFloat(max(16,bitmap.margins[axis]+bitmap.margins[axis+2]))
        let length = horizontal ? track.width : track.height
        guard length >= minimum+10 else { return .zero }
        let ratio = proportion.isFinite ? max(0,min(1,proportion)) : 1
        let position = value.isFinite ? max(0,min(1,value)) : 0
        let size = min(length,max(minimum,floor(length*ratio)))
        let start = (horizontal ? track.minX-bounds.minX : track.minY-bounds.minY)+floor((length-size)*position)
        return slice(start,start+size)
    }
}

@MainActor enum HAPScrollDrawing {
    static func draw(_ layout: HAPScrollLayout, pressed: HAPScrollPart = .none) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        layout.bounds.clip()
        let style = ClassicStyle.shared
        let axis: NSLayoutConstraint.Orientation = layout.horizontal ? .horizontal : .vertical
        let normalThumbID = layout.horizontal ? 150 : 169
        let selectedThumb = style.artwork?.skins[normalThumbID+(pressed == .knob ? 1 : 0)]
        var drawingSkins = style.artwork?.skins ?? [:]
        // Drawing and hit testing are separate in the original. A theme can
        // supply only a pressed thumb, or give it different stretch margins.
        drawingSkins[normalThumbID] = selectedThumb
        let bitmapLayout = HAPScrollLayout(bounds:layout.bounds,horizontal:layout.horizontal,value:layout.value,proportion:layout.proportion,enabled:layout.enabled,skins:drawingSkins)
        let disabledID = layout.horizontal ? 148 : 167
        // 0x9D738/0x9DB68 return false when the selected thumb is missing.
        // The caller paints the palette control using the existing hit layout;
        // it never substitutes the normal-state bitmap.
        let canDrawSkin = layout.enabled ? (bitmapLayout.thumbID == nil || selectedThumb != nil) : (bitmapLayout.skinID == disabledID || bitmapLayout.skinID == disabledID+1)
        if canDrawSkin, let id = bitmapLayout.skinID, let background = style.artwork?.skins[id] {
            let layout = bitmapLayout
            background.draw(in:layout.bounds,stretch:true,axis:axis)
            guard layout.enabled, let thumbID = layout.thumbID else { return }
            let offset = layout.horizontal ? 0 : 19
            if (1...4).contains(pressed.rawValue) {
                let buttonID = (layout.paired ? 155+pressed.rawValue : 159+pressed.rawValue)+offset
                if let skin = style.artwork?.skins[buttonID] {
                    let trailing = pressed == .increment || pressed == .trailingDecrement
                    let p = skin.placement, b = layout.bounds
                    let x = layout.horizontal && trailing ? b.maxX-CGFloat(skin.width+p[2]) : b.minX+CGFloat(p[0])
                    let y = !layout.horizontal && trailing ? b.maxY-CGFloat(skin.height+p[3]) : b.minY+CGFloat(p[1])
                    skin.draw(in:NSRect(x:x,y:y,width:CGFloat(skin.width),height:CGFloat(skin.height)))
                }
            }
            let knob = selectedThumb.map { layout.drawingKnob(using:$0) } ?? .zero
            if !knob.isEmpty {
                selectedThumb?.draw(in:knob,stretch:true,axis:axis)
                if let grip = style.artwork?.skins[thumbID+3+(pressed == .knob ? 1 : 0)] {
                    grip.draw(in:NSRect(x:floor(knob.midX-CGFloat(grip.width)/2),y:floor(knob.midY-CGFloat(grip.height)/2),width:CGFloat(grip.width),height:CGFloat(grip.height)))
                }
            }
            return
        }
        guard style.appearance.colors.count >= 158 else { ClassicPainter.bevel(layout.bounds); return }
        if layout.parts.isEmpty { bevel(layout.bounds,pressed:false,enabled:layout.enabled,knob:false); return }
        for part in [HAPScrollPart.pageBefore,.pageAfter] {
            if let rect = layout.parts[part], !rect.isEmpty { trough(rect,horizontal:layout.horizontal,pressed:pressed == part,enabled:layout.enabled) }
        }
        for part in [HAPScrollPart.decrement,.increment,.trailingDecrement,.leadingIncrement] {
            guard let rect = layout.parts[part] else { continue }
            bevel(rect,pressed:pressed == part,enabled:layout.enabled,knob:false)
            let slot = !layout.enabled ? 157 : pressed == part ? 136 : 132
            arrow(rect,horizontal:layout.horizontal,forward:part == .increment || part == .leadingIncrement,slot:slot)
        }
        if !layout.knob.isEmpty {
            bevel(layout.knob,pressed:pressed == .knob,enabled:layout.enabled,knob:true)
            grip(layout.knob,horizontal:layout.horizontal,pressed:pressed == .knob,enabled:layout.enabled)
        }
    }
    private static func fill(_ rect: NSRect, _ slot: Int) {
        guard rect.width > 0, rect.height > 0 else { return }
        ClassicStyle.shared.color(slot).setFill(); rect.fill()
    }
    /// 0x93E90: one-pixel outline around a two-pixel bevel.
    private static func bevel(_ rect: NSRect, pressed: Bool, enabled: Bool, knob: Bool) {
        let base = !enabled ? 153 : knob ? (pressed ? 140 : 137) : (pressed ? 133 : 129)
        let outline = enabled ? 128 : 156, x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        fill(rect,outline); fill(rect.insetBy(dx:1,dy:1),base+1)
        fill(NSRect(x:x+1,y:y+1,width:w-3,height:1),base)
        fill(NSRect(x:x+1,y:y+2,width:1,height:h-4),base)
        fill(NSRect(x:x+2,y:y+h-2,width:w-3,height:1),base+2)
        fill(NSRect(x:x+w-2,y:y+2,width:1,height:h-4),base+2)
    }
    /// 0x94510/0x946A0, a recessed trough, open toward the thumb.
    private static func trough(_ rect: NSRect, horizontal: Bool, pressed: Bool, enabled: Bool) {
        let colors = !enabled ? [156,153,153,154,155,155] : [128]+Array((pressed ? 148 : 143)...(pressed ? 152 : 147))
        let w = horizontal ? rect.width : rect.height, h = horizontal ? rect.height : rect.width
        func paint(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ index: Int) {
            let r = horizontal ? NSRect(x:rect.minX+x,y:rect.minY+y,width:width,height:height) : NSRect(x:rect.minX+y,y:rect.minY+x,width:height,height:width)
            fill(r,colors[index])
        }
        paint(0,0,w,1,0); paint(0,h-1,w,1,0)
        paint(3,3,w-3,h-6,3)
        paint(1,1,w-1,1,5); paint(2,2,w-2,1,4)
        paint(2,h-3,w-2,1,2); paint(1,h-2,w-1,1,1)
        paint(1,1,1,h-3,5); paint(2,2,1,h-5,4)
    }
    private static func arrow(_ rect: NSRect, horizontal: Bool, forward: Bool, slot: Int) {
        let x = floor(rect.midX-(horizontal ? 4 : 7)/2), y = floor(rect.midY-(horizontal ? 7 : 4)/2)
        for row in 0..<4 {
            let start = forward ? row : 3-row, size = 8-2*start
            fill(NSRect(x:x+(horizontal ? CGFloat(row) : CGFloat(start)),y:y+(horizontal ? CGFloat(start) : CGFloat(row)),width:horizontal ? 1 : CGFloat(size),height:horizontal ? CGFloat(size) : 1),slot)
        }
    }
    private static func grip(_ rect: NSRect, horizontal: Bool, pressed: Bool, enabled: Bool) {
        let style = ClassicStyle.shared
        guard let data = horizontal ? style.chromeArtwork?.horizontalScrollGrip : style.chromeArtwork?.verticalScrollGrip, data.count == 16 else { return }
        let base = !enabled ? 153 : pressed ? 140 : 137, slots = [base,base+1,base,base+2]
        let bytes = [UInt8](data), left = floor(rect.midX-4), top = floor(rect.midY-4)
        for y in 0..<8 { for x in 0..<8 {
            let index = Int(bytes[y*2+x/4] >> (6-(x%4)*2) & 3)
            fill(NSRect(x:left+CGFloat(x),y:top+CGFloat(y),width:1,height:1),slots[index])
        } }
    }
}
