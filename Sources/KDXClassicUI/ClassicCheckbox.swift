import AppKit

/// Original checkbox renderer (0x98100) and HAP overrides (0x9C100).
/// AppKit retains the switch's state, keyboard handling, target/action and accessibility.
@MainActor enum HAPCheckboxDrawing {
    static func skinID(state: NSControl.StateValue, pressed: Bool, enabled: Bool, radio: Bool = false) -> Int {
        (state == .mixed ? 49 : state == .on ? 45 : 41) + (radio ? 12 : 0) + (!enabled ? 2 : pressed ? 1 : 0)
    }
    static func size(title: String, radio: Bool = false) -> NSSize {
        let style = ClassicStyle.shared
        // Reserve the largest state image so toggling never shifts surrounding controls.
        let skins = [41,42,43,45,46,47,49,50,51].compactMap { style.artwork?.skins[$0+(radio ? 12 : 0)] }
        return NSSize(width:ceil((title as NSString).size(withAttributes:[.font:style.font]).width)+CGFloat(skins.map(\.width).max() ?? 14)+6,
                      height:max(22,CGFloat(skins.map(\.height).max() ?? 14),ceil(style.font.ascender-style.font.descender)))
    }
    static func draw(_ rect: NSRect, title: String, state: NSControl.StateValue, pressed: Bool, enabled: Bool, radio: Bool = false) {
        let style = ClassicStyle.shared
        let skin = style.artwork?.skins[skinID(state:state,pressed:pressed,enabled:enabled,radio:radio)]
        let width = CGFloat(skin?.width ?? 14), height = CGFloat(skin?.height ?? 14)
        let imageRect = NSRect(x:rect.minX+2,y:floor(rect.midY-height/2),width:width,height:height)
        let textColor: NSColor
        if let skin {
            skin.draw(in:imageRect)
            let rgb = skin.textColor ?? 0
            textColor = NSColor(srgbRed:Double((rgb>>16)&255)/255,green:Double((rgb>>8)&255)/255,blue:Double(rgb&255)/255,alpha:1)
        } else {
            let artwork = style.chromeArtwork
            let data = radio
                ? (state == .mixed ? artwork?.radioMixed : state == .on ? artwork?.radioOn : artwork?.radioOff)
                : (state == .mixed ? artwork?.checkboxMixed : state == .on ? artwork?.checkboxOn : artwork?.checkboxOff)
            if let data, style.appearance.colors.count >= 50 {
                let base = !enabled ? 43 : pressed ? 36 : 29
                // Index zero is unused in the square checkbox; 1 is the check mark.
                let roles = [2,base+6,base,base,base+1,base+2,base+3,base+4,base+5]
                for y in 0..<14 { for x in 0..<14 {
                    let packed = data[y*7+x/2]
                    let index = Int(x.isMultiple(of:2) ? packed>>4 : packed&15)
                    // The round variant uses 0x633A0 with transparent index zero.
                    if radio && index == 0 { continue }
                    style.color(roles[index]).setFill()
                    NSRect(x:imageRect.minX+CGFloat(x),y:imageRect.minY+CGFloat(y),width:1,height:1).fill()
                } }
            } else if radio {
                // Setup/older-catalog recovery only; imported radios use original pixels.
                let circle = NSBezierPath(ovalIn:imageRect.insetBy(dx:0.5,dy:0.5))
                style.color(2).setFill(); circle.fill()
                style.color(enabled ? 5 : 7).setStroke(); circle.lineWidth = 1; circle.stroke()
                if state != .off {
                    style.color(enabled ? 5 : 7).setFill()
                    if state == .mixed { imageRect.insetBy(dx:3,dy:6).fill() }
                    else { NSBezierPath(ovalIn:imageRect.insetBy(dx:4,dy:4)).fill() }
                }
            } else {
                ClassicPainter.bevel(imageRect,pressed:pressed)
                if state != .off {
                    style.color(enabled ? 5 : 7).setFill()
                    if state == .mixed { imageRect.insetBy(dx:3,dy:6).fill() }
                    else {
                        for (x,y) in [(3,6),(4,7),(5,8),(6,7),(7,6),(8,5),(9,4)] {
                            NSRect(x:imageRect.minX+CGFloat(x),y:imageRect.minY+CGFloat(y),width:2,height:2).fill()
                        }
                    }
                }
            }
            textColor = style.color(enabled ? 5 : 7)
        }
        let textRect = NSRect(x:rect.minX+width+6,y:rect.minY,width:max(0,rect.width-width-6),height:rect.height)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key:Any] = [.font:style.font,.foregroundColor:textColor,.paragraphStyle:paragraph]
        let size = (title as NSString).size(withAttributes:attributes)
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        textRect.clip()
        if style.font.fontName.hasPrefix("KDXImported-") { NSGraphicsContext.current?.shouldAntialias = false }
        (title as NSString).draw(in:NSRect(x:textRect.minX,y:floor(textRect.midY-size.height/2),width:textRect.width,height:size.height),withAttributes:attributes)
    }
}

@MainActor final class ClassicCheckboxCell: NSButtonCell {
    var radio = false
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        HAPCheckboxDrawing.draw(cellFrame,title:title,state:state,pressed:isHighlighted,enabled:isEnabled,radio:radio)
    }
}

@MainActor final class ClassicCheckbox: NSButton {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        HAPCheckboxDrawing.size(title:title)
    }
    init(_ title: String) {
        super.init(frame:.zero)
        cell = ClassicCheckboxCell(textCell:title); setButtonType(.switch); self.title = title
        font = ClassicStyle.shared.font; focusRingType = .none
        setAccessibilityRole(.checkBox); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
