import AppKit

/// Horizontal SLDR renderer: 0x97060 and HAP overrides at 0x9CDF0.
@MainActor enum HAPColorSliderDrawing {
    static func skins(pressed: Bool, enabled: Bool) -> (HAPBitmap,HAPBitmap)? {
        let state = !enabled ? 2 : pressed ? 1 : 0
        guard let track = ClassicStyle.shared.artwork?.skins[110+state],
              let thumb = ClassicStyle.shared.artwork?.skins[114+state] else { return nil }
        return (track,thumb)
    }
    static func geometry(_ rect: NSRect, value: Int, pressed: Bool, enabled: Bool) -> (track: NSRect, thumb: NSRect, travel: CGFloat) {
        let value = CGFloat(min(255,max(0,value)))
        if let (track,thumb) = skins(pressed:pressed,enabled:enabled) {
            let y = ((rect.minY+rect.maxY-CGFloat(track.height))/2).rounded(.towardZero)
            let travel = max(0,rect.width-CGFloat(track.placement[0]+track.placement[2]+thumb.width))
            return (NSRect(x:rect.minX,y:y,width:rect.width,height:CGFloat(track.height)),
                    NSRect(x:rect.minX+CGFloat(track.placement[0])+floor(travel*value/255),y:y-CGFloat(thumb.placement[1]),width:CGFloat(thumb.width),height:CGFloat(thumb.height)),travel)
        }
        let y = ((rect.minY+rect.maxY-7)/2).rounded(.towardZero), travel = max(0,rect.width-23)
        return (NSRect(x:rect.minX,y:y,width:rect.width,height:7),NSRect(x:rect.minX+5+floor(travel*value/255),y:y-4,width:13,height:16),travel)
    }
    static func draw(_ rect: NSRect, value: Int, pressed: Bool, enabled: Bool) {
        guard !rect.isEmpty else { return }
        let style = ClassicStyle.shared, state = !enabled ? 2 : pressed ? 1 : 0
        if let track = style.artwork?.skins[110+state] {
            let y = ((rect.minY+rect.maxY-CGFloat(track.height))/2).rounded(.towardZero)
            track.draw(in:NSRect(x:rect.minX,y:y,width:rect.width,height:CGFloat(track.height)),stretch:true,axis:.horizontal)
            if let thumb = style.artwork?.skins[114+state] {
                guard rect.width >= CGFloat(track.placement[0]+track.placement[2]+thumb.width) else { return }
                thumb.draw(in:geometry(rect,value:value,pressed:pressed,enabled:enabled).thumb); return
            }
            // The reference draws its track before discovering a missing thumb,
            // then overlays palette drawing. Do not substitute a normal variant.
        }
        let g = geometryWithoutSkins(rect,value:value)
        let t = g.track, x = t.minX, y = t.minY, w = t.width
        func fill(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ slot: Int) {
            guard width > 0, height > 0 else { return }
            style.color(slot).setFill(); NSRect(x:x,y:y,width:width,height:height).fill()
        }
        let trackFill = !enabled ? 171 : pressed ? 168 : 166
        let line = !enabled ? 173 : pressed ? 169 : 167
        fill(x+2,y+2,w-4,3,trackFill)
        fill(x+1,y,w-3,1,3); fill(x,y+1,1,4,3); fill(x+1,y+1,1,1,3)
        fill(x+2,y+6,w-3,1,1); fill(x+w-1,y+2,1,4,1)
        for point in [NSPoint(x:x+1,y:y+5),NSPoint(x:x+w-2,y:y+5),NSPoint(x:x+w-2,y:y+1)] { fill(point.x,point.y,1,1,1) }
        fill(x+2,y+1,w-4,1,line); fill(x+2,y+5,w-4,1,line)
        fill(x+1,y+2,1,3,line); fill(x+w-2,y+2,1,3,line)
        guard rect.width >= 23 else { return }
        let base = !enabled ? 170 : pressed ? 162 : 158
        if let data = style.chromeArtwork?.horizontalSliderThumb {
            let slots = [0,base,base,base+1,base+2,base+2,base+3]
            let bytes = [UInt8](data)
            for row in 0..<16 { for column in 0..<13 {
                let byte = bytes[row*7+column/2], index = Int(column%2 == 0 ? byte >> 4 : byte & 15)
                if index > 0 { fill(g.thumb.minX+CGFloat(column),g.thumb.minY+CGFloat(row),1,1,slots[index]) }
            } }
        } else {
            // Minimal recovery thumb until the original artwork is imported.
            fill(g.thumb.minX,g.thumb.minY,13,16,base+3)
            fill(g.thumb.minX+1,g.thumb.minY+1,11,14,base+1)
        }
    }
    private static func geometryWithoutSkins(_ rect: NSRect, value: Int) -> (track:NSRect,thumb:NSRect) {
        let y = ((rect.minY+rect.maxY-7)/2).rounded(.towardZero)
        return (NSRect(x:rect.minX,y:y,width:rect.width,height:7),
                NSRect(x:rect.minX+5+floor(max(0,rect.width-23)*CGFloat(min(255,max(0,value)))/255),y:y-4,width:13,height:16))
    }
}

@MainActor private final class ClassicColorSliderCell: NSSliderCell {
    private var dragOffset: CGFloat = 0
    override func draw(withFrame frame: NSRect, in view: NSView) {
        HAPColorSliderDrawing.draw(frame,value:Int(doubleValue),pressed:isHighlighted,enabled:isEnabled)
    }
    override func knobRect(flipped: Bool) -> NSRect {
        guard let view = controlView else { return .zero }
        // Hit geometry uses the normal variants even while pressed (0x9D1B0).
        return HAPColorSliderDrawing.geometry(view.bounds,value:Int(doubleValue),pressed:false,enabled:true).thumb
    }
    override func startTracking(at point: NSPoint, in view: NSView) -> Bool {
        guard isEnabled else { return false }
        let thumb = knobRect(flipped:view.isFlipped)
        if thumb.contains(point) { dragOffset = point.x-thumb.minX; return true }
        dragOffset = floor(thumb.width/2); update(point,in:view); return true
    }
    override func continueTracking(last lastPoint: NSPoint, current point: NSPoint, in view: NSView) -> Bool {
        guard isEnabled else { return false }; update(point,in:view); return true
    }
    private func update(_ point: NSPoint, in view: NSView) {
        let g = HAPColorSliderDrawing.geometry(view.bounds,value:0,pressed:false,enabled:true)
        guard g.travel > 0 else { return }
        doubleValue = min(255,max(0,((point.x-g.thumb.minX-dragOffset)*255/g.travel).rounded(.towardZero)))
        view.needsDisplay = true
    }
}

/// Native slider keyboard, tracking dispatch and accessibility, with imported drawing.
@MainActor final class ClassicColorSlider: NSSlider {
    init(_ label: String) {
        super.init(frame:.zero); cell = ClassicColorSliderCell()
        minValue = 0; maxValue = 255; isContinuous = true; sliderType = .linear
        numberOfTickMarks = 0; focusRingType = .none
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command,.control,.option]).isEmpty else { super.keyDown(with:event); return }
        let value: Int
        switch event.keyCode {
        case 123,125: value = Int(doubleValue)-1
        case 124,126: value = Int(doubleValue)+1
        case 115: value = 0
        case 119: value = 255
        default: super.keyDown(with:event); return
        }
        _ = adjust(to:value)
    }
    override func accessibilityPerformIncrement() -> Bool { adjust(to:Int(doubleValue)+1) }
    override func accessibilityPerformDecrement() -> Bool { adjust(to:Int(doubleValue)-1) }
    private func adjust(to value: Int) -> Bool {
        guard isEnabled else { return false }
        let value = Double(min(255,max(0,value)))
        guard value != doubleValue else { return false }
        doubleValue = value; needsDisplay = true; sendAction(action,to:target); return true
    }
}
