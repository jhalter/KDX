import AppKit

/// KOLR draw callback 0xA54D0: compact field frame, a two-pixel white
/// inset outline, RGB center, then a one-pixel black pressed outline.
@MainActor enum HAPProfileDrawing {
    static func colorWell(_ rect: NSRect, rgb: UInt32, pressed: Bool, focused: Bool, enabled: Bool) {
        HAPFieldDrawing.frame(rect,focused:pressed || focused,enabled:enabled,fillInterior:false,compact:true)
        func outline(_ rect: NSRect, width: CGFloat, color: UInt32) {
            guard !rect.isEmpty else { return }
            HAPUserRowDrawing.color(color).setFill()
            NSRect(x:rect.minX,y:rect.minY,width:rect.width,height:min(width,rect.height)).fill()
            NSRect(x:rect.minX,y:max(rect.minY,rect.maxY-width),width:rect.width,height:min(width,rect.height)).fill()
            NSRect(x:rect.minX,y:rect.minY,width:min(width,rect.width),height:rect.height).fill()
            NSRect(x:max(rect.minX,rect.maxX-width),y:rect.minY,width:min(width,rect.width),height:rect.height).fill()
        }
        outline(rect.insetBy(dx:2,dy:2),width:2,color:0xffffff)
        let center = rect.insetBy(dx:4,dy:4)
        if !center.isEmpty { HAPUserRowDrawing.color(rgb).setFill(); center.fill() }
        if pressed && enabled { outline(rect.insetBy(dx:2,dy:2),width:1,color:0) }
    }
    static func iconWell(_ rect: NSRect, bytes: [UInt8], focused: Bool, enabled: Bool) {
        HAPFieldDrawing.frame(rect,focused:focused,enabled:enabled,fillInterior:false)
        // IMGS callback 0xACA50 uses literal white for the empty canvas and
        // the margins around the centered image, independently of field slot 10.
        let canvas = rect.insetBy(dx:3,dy:3)
        guard !canvas.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        canvas.clip(); HAPUserRowDrawing.color(0xffffff).setFill(); canvas.fill()
        ClassicUserIcon(bytes)?.bitmap(small:false).draw(in:NSRect(x:floor(rect.midX-16),y:floor(rect.midY-16),width:32,height:32))
    }
}

@MainActor private final class ClassicProfileColorCell: NSButtonCell {
    override func draw(withFrame frame: NSRect, in view: NSView) {
        guard let well = view as? ClassicProfileColorWell else { return }
        HAPProfileDrawing.colorWell(frame,rgb:well.rgb,pressed:isHighlighted,focused:HAPFieldDrawing.focused(well),enabled:isEnabled)
    }
}
@MainActor final class ClassicProfileColorWell: NSButton {
    var rgb: UInt32 = 0 { didSet { needsDisplay = true; toolTip = String(format:"#%06X",rgb); setAccessibilityValue(toolTip) } }
    var invoke: (() -> Void)?
    override var isFlipped: Bool { true }
    init(_ label: String) {
        super.init(frame:.zero); cell = ClassicProfileColorCell(textCell:"")
        setButtonType(.momentaryChange); target = self; action = #selector(choose)
        focusRingType = .none
        setAccessibilityLabel(label); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func choose() { invoke?() }
}

@MainActor private final class ClassicProfileIconCell: NSButtonCell {
    override func draw(withFrame frame: NSRect, in view: NSView) {
        guard let well = view as? ClassicProfileIconWell else { return }
        HAPProfileDrawing.iconWell(frame,bytes:well.bytes,focused:HAPFieldDrawing.focused(well),enabled:isEnabled)
    }
}
@MainActor final class ClassicProfileIconWell: NSButton {
    var bytes: [UInt8] = [] { didSet { needsDisplay = true; setAccessibilityValue(bytes.isEmpty ? "No icon" : "32 by 32 pixel icon") } }
    var choose: (() -> Void)?, pasteIcon: (() -> Void)?, copyIcon: (() -> Void)?, removeIcon: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame:frame); cell = ClassicProfileIconCell(textCell:"")
        setButtonType(.momentaryChange); target = self; action = #selector(importIcon)
        focusRingType = .none
        setAccessibilityLabel("User icon"); setAccessibilityHelp("Choose an image, or paste an image. Icons are converted to 32 by 32 pixels.")
        let menu = ClassicMenu(title:"")
        menu.addItem(menuItem("Choose Image…") { [weak self] in self?.importIcon() })
        menu.addItem(menuItem("Copy") { [weak self] in self?.copy(nil) })
        menu.addItem(menuItem("Paste") { [weak self] in self?.paste(nil) })
        menu.addItem(menuItem("Delete") { [weak self] in self?.remove() })
        self.menu = menu
    }
    convenience init() { self.init(frame:.zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func importIcon() { if isEnabled { choose?() } }
    @objc func copy(_ sender: Any?) { if isEnabled { copyIcon?() } }
    @objc func paste(_ sender: Any?) { if isEnabled { pasteIcon?() } }
    private func remove() { if isEnabled { removeIcon?() } }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { remove(); return }
        super.keyDown(with:event)
    }
    override func rightMouseDown(with event: NSEvent) {
        if !ClassicMenu.showContext(for:event,in:self) { super.rightMouseDown(with:event) }
    }
}
