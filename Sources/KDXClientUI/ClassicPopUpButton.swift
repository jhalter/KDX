import AppKit

/// Original selector: palette renderer 0x96970, bitmap renderer 0x9C450.
@MainActor enum HAPPopUpDrawing {
    static func textRect(_ rect: NSRect) -> NSRect {
        guard rect.width >= 38 else { return .zero }
        return NSRect(x:rect.minX+8,y:rect.minY,width:rect.width-31,height:rect.height)
    }

    static func arrowRect(_ rect: NSRect, skin: HAPBitmap? = nil) -> NSRect {
        guard let skin else {
            let area = rect.width <= 28 ? rect : NSRect(x:rect.maxX-22,y:rect.minY,width:22,height:rect.height)
            return NSRect(x:floor(area.midX-4.5),y:floor(area.midY-2.5),width:9,height:5)
        }
        let width = CGFloat(skin.width), height = CGFloat(skin.height)
        if rect.width <= 28 {
            return NSRect(x:floor(rect.midX-width/2),y:floor(rect.midY-height/2),width:width,height:height)
        }
        let p = skin.placement.map(CGFloat.init)
        let x = p[0] != 0 ? rect.minX+p[0] : rect.maxX-width-p[2]
        let y = p[1] != 0 ? rect.minY+p[1] : p[3] != 0 ? rect.maxY-height-p[3] : floor(rect.midY-height/2)
        return NSRect(x:x,y:y,width:width,height:height)
    }

    @discardableResult static func frame(_ rect: NSRect, pressed: Bool, enabled: Bool) -> NSColor {
        let style = ClassicStyle.shared
        let variant = !enabled ? 2 : pressed ? 1 : 0
        let body = style.artwork?.skins[(rect.width <= 28 ? 77 : 73)+variant]
        let color: NSColor
        if let body {
            body.draw(in:rect,stretch:true)
            let rgb = body.textColor ?? 0
            color = NSColor(srgbRed:Double((rgb >> 16)&255)/255,green:Double((rgb >> 8)&255)/255,blue:Double(rgb&255)/255,alpha:1)
            if let arrow = style.artwork?.skins[81+variant] {
                arrow.draw(in:arrowRect(rect,skin:arrow))
                return color
            }
        } else if rect.width <= 28, let button = style.artwork?.skins[9+variant] {
            // 0x969E8 calls the ordinary pushbutton renderer for a compact
            // selector, including its bitmap override. Its arrow still uses
            // the palette text color rather than that button skin's text RGB.
            button.draw(in:rect,stretch:true)
            color = style.color((!enabled ? 43 : pressed ? 36 : 29)+6)
        } else if style.appearance.colors.count >= 204 {
            color = paletteFrame(rect,pressed:pressed,enabled:enabled)
        } else {
            ClassicPainter.bevel(rect,pressed:pressed)
            color = style.color(enabled ? 5 : 7)
        }
        let arrow = arrowRect(rect)
        color.setFill()
        for row in 0..<5 {
            NSRect(x:arrow.minX+CGFloat(row),y:arrow.minY+CGFloat(row),width:CGFloat(9-2*row),height:1).fill()
        }
        return color
    }

    private static func paletteFrame(_ rect: NSRect, pressed: Bool, enabled: Bool) -> NSColor {
        if rect.width <= 28 { return HAPPaletteDrawing.button(rect,pressed:pressed,enabled:enabled) }
        let base = !enabled ? 43 : pressed ? 36 : 29
        let style = ClassicStyle.shared, w = rect.width, h = rect.height
        func fill(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ slot: Int) {
            guard width > 0, height > 0 else { return }
            style.color(base+slot).setFill()
            NSRect(x:rect.minX+x,y:rect.minY+y,width:width,height:height).fill()
        }
        func pixel(_ x: CGFloat, _ y: CGFloat, _ slot: Int) { fill(x,y,1,1,slot) }
        func horizontal(_ x: CGFloat, _ y: CGFloat, _ end: CGFloat, _ slot: Int) { fill(x,y,end-x,1,slot) }
        func vertical(_ x: CGFloat, _ y: CGFloat, _ end: CGFloat, _ slot: Int) { fill(x,y,1,end-y,slot) }
        fill(2,2,w-5,h-4,2)
        horizontal(2,0,w-2,5); pixel(1,1,5); horizontal(2,1,w-3,0)
        pixel(w-3,1,3); pixel(w-2,1,5); pixel(2,2,0)
        vertical(0,2,h-2,5); vertical(1,2,h-3,0)
        pixel(1,h-3,2); pixel(1,h-2,5); pixel(2,h-2,2)
        horizontal(3,h-2,w-2,4); pixel(w-2,h-2,5); horizontal(2,h-1,w-2,5)
        vertical(w-3,3,h-3,3); pixel(w-2,2,3); vertical(w-2,3,h-2,4); vertical(w-1,2,h-2,5)
        pixel(w-22,1,2); vertical(w-22,2,h-2,4); vertical(w-21,2,h-2,0)
        vertical(w-20,3,h-3,1); horizontal(w-20,2,w-3,1); pixel(w-3,2,2)
        horizontal(w-19,h-3,w-3,3); pixel(w-3,h-3,4); pixel(w-4,h-4,3)
        return style.color(base+6)
    }

    static func draw(_ rect: NSRect, title: String, pressed: Bool, enabled: Bool) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        rect.clip()
        let color = frame(rect,pressed:pressed,enabled:enabled)
        let text = textRect(rect)
        guard text.width > 0 else { return }
        let font = ClassicStyle.shared.font
        let attributes: [NSAttributedString.Key:Any] = [.font:font,.foregroundColor:color]
        let label = truncatedTitle(title,width:text.width,attributes:attributes) as NSString
        let size = label.size(withAttributes:attributes)
        text.clip()
        if font.fontName.hasPrefix("KDXImported-") {
            NSGraphicsContext.current?.shouldAntialias = false
            NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        }
        label.draw(at:NSPoint(x:text.minX,y:floor(text.midY-size.height/2)),withAttributes:attributes)
    }

    // 0x62400 appends the three-byte UTF-8 ellipsis at TOC -0x6DC4.
    // Keep native Unicode characters intact when shortening the label.
    static func truncatedTitle(_ title: String, width: CGFloat, attributes: [NSAttributedString.Key:Any]) -> String {
        guard (title as NSString).size(withAttributes:attributes).width > width else { return title }
        var characters = Array(title)
        while !characters.isEmpty {
            characters.removeLast()
            let candidate = String(characters)+"…"
            if (candidate as NSString).size(withAttributes:attributes).width <= width { return candidate }
        }
        return "…"
    }
}

final class ClassicPopUpButtonCell: NSPopUpButtonCell {
    var banner: HAPBitmap?
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let banner {
            HAPBannerDrawing.draw(banner,in:cellFrame)
        } else {
            HAPPopUpDrawing.draw(cellFrame,title:title,pressed:isHighlighted,enabled:isEnabled)
        }
    }
    override var cellSize: NSSize {
        let font = ClassicStyle.shared.font
        let width = itemTitles.map { ($0 as NSString).size(withAttributes:[.font:font]).width }.max() ?? 0
        let height = ("Ag" as NSString).size(withAttributes:[.font:font]).height
        return NSSize(width:max(38,ceil(width)+31),height:max(22,ceil(height)+6))
    }
}

/// Preserve NSPopUpButton's selection, menu tracking, keyboard and accessibility.
@MainActor final class ClassicPopUpButton: NSPopUpButton {
    override var isFlipped: Bool { true }
    var banner: HAPBitmap? {
        get { (cell as? ClassicPopUpButtonCell)?.banner }
        set { (cell as? ClassicPopUpButtonCell)?.banner = newValue; needsDisplay = true }
    }
    init(_ accessibilityLabel: String? = nil) {
        super.init(frame:.zero,pullsDown:false)
        let classicCell = ClassicPopUpButtonCell(textCell:"",pullsDown:false)
        classicCell.arrowPosition = .noArrow
        cell = classicCell
        menu = ClassicMenu(title:"")
        focusRingType = .none
        setAccessibilityRole(.popUpButton)
        if let accessibilityLabel { setAccessibilityLabel(accessibilityLabel) }
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func accessibilityValue() -> Any? { titleOfSelectedItem }
    override func mouseDown(with event: NSEvent) { performClick(self) }
    override func performClick(_ sender: Any?) {
        guard isEnabled, let menu = menu as? ClassicMenu else { return }
        highlight(true); defer { highlight(false); needsDisplay = true }
        if let selected = ClassicMenuTracking.selection(menu:menu,positioning:selectedItem,at:NSPoint(x:bounds.minX,y:bounds.minY),in:self) {
            choose(selected)
        }
    }
    @discardableResult func choose(_ item: NSMenuItem) -> Bool {
        guard isEnabled, let menu, item.menu === menu, ClassicMenuTracking.canActivate(item,in:menu) else { return false }
        select(item); needsDisplay = true
        sendAction(action,to:target)
        return true
    }
    override func keyDown(with event: NSEvent) {
        if [UInt16(49),36,76,125,126].contains(event.keyCode) { performClick(self) }
        else { super.keyDown(with:event) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }; performClick(self); return true
    }
    func applyStyle() {
        font = ClassicStyle.shared.font
        menu?.font = ClassicStyle.shared.font
        invalidateIntrinsicContentSize(); needsDisplay = true
    }
}
