import AppKit

@MainActor struct ClassicDockState {
    private(set) var controllers: [ClassicWindowController] = []
    var isEmpty: Bool { controllers.isEmpty }
    mutating func add(_ controller: ClassicWindowController) {
        if !controllers.contains(where: { $0 === controller }) { controllers.append(controller) }
    }
    mutating func remove(_ controller: ClassicWindowController) { controllers.removeAll { $0 === controller } }
}

/// 0xB9B50 / 0xB9B90: 200-wide content, 22-high square buttons, flags 0xA.
/// No icon is supplied; the original left-aligned label starts at x + 10.
@MainActor enum HAPDockDrawing {
    static let width: CGFloat = 200
    static let rowHeight: CGFloat = 22
    static func button(_ bounds: NSRect, title: String, pressed: Bool, enabled: Bool) {
        let style = ClassicStyle.shared
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        bounds.clip()
        let skin = style.artwork?.skins[!enabled ? 35 : pressed ? 34 : 33]
        let textColor: NSColor
        if let skin {
            skin.draw(in:bounds,stretch:true)
            textColor = skin.textColor.map(HAPUserRowDrawing.color) ?? style.color(!enabled ? 49 : pressed ? 42 : 35)
        } else { textColor = HAPIconButtonDrawing.border(bounds,pressed:pressed,enabled:enabled) }
        let label = NSRect(x:bounds.minX+10,y:bounds.minY,width:max(0,bounds.width-13),height:bounds.height)
        let attributes: [NSAttributedString.Key:Any] = [.font:style.font,.foregroundColor:textColor]
        let text = HAPPopUpDrawing.truncatedTitle(title,width:label.width,attributes:attributes) as NSString
        label.clip()
        if style.font.fontName.hasPrefix("KDXImported-") {
            NSGraphicsContext.current?.shouldAntialias = false
            NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        }
        text.draw(at:NSPoint(x:label.minX,y:floor(label.midY-text.size(withAttributes:attributes).height/2)),withAttributes:attributes)
    }
}

@MainActor private final class ClassicDockButtonCell: NSButtonCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        HAPDockDrawing.button(cellFrame,title:title,pressed:isHighlighted,enabled:isEnabled)
    }
}

@MainActor final class ClassicDockButton: NSButton {
    var restore: (() -> Void)?
    override var isFlipped: Bool { true }
    init(title: String, restore: @escaping () -> Void) {
        self.restore = restore
        super.init(frame:NSRect(x:0,y:0,width:HAPDockDrawing.width,height:HAPDockDrawing.rowHeight))
        cell = ClassicDockButtonCell(textCell:title); self.title = title
        font = ClassicStyle.shared.font; focusRingType = .none
        setButtonType(.momentaryPushIn); target = self; action = #selector(restoreWindow)
        toolTip = title; setAccessibilityRole(.button); setAccessibilityLabel("Restore \(title)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func restoreWindow() { restore?() }
}

@MainActor final class ClassicDockView: ClassicSurface {
    private(set) var buttons: [ClassicDockButton] = []
    func update(_ controllers: [ClassicWindowController], restore: @escaping (ClassicWindowController) -> Void) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = controllers.map { controller in
            ClassicDockButton(title:controller.title) { [weak controller] in
                if let controller { restore(controller) }
            }
        }
        for (index,button) in buttons.enumerated() {
            button.frame.origin.y = CGFloat(index)*HAPDockDrawing.rowHeight
            addSubview(button)
            button.nextKeyView = buttons[(index+1)%buttons.count]
        }
        frame.size = NSSize(width:HAPDockDrawing.width,height:CGFloat(buttons.count)*HAPDockDrawing.rowHeight)
    }
}

@MainActor final class ClassicDockWindow: ClassicWindowController {
    let entries = ClassicDockView()
    let scroll = ClassicScrollView()
    init(preferences: ClassicPreferences) {
        super.init(title:"KDX Dock",key:"dock",size:NSSize(width:212,height:50),preferences:preferences,minimumFrameSize:NSSize(width:1,height:1))
        chrome.showsTitleControls = false; chrome.allowsResize = false
        window?.level = .floating
        windowMenu.removeAllItems()
        scroll.documentView = entries; scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = .init(); scroll.scrollerInsets = .init()
        scroll.lineScroll = HAPDockDrawing.rowHeight
        install(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ controllers: [ClassicWindowController], restore: @escaping (ClassicWindowController) -> Void) {
        entries.update(controllers,restore:restore)
        window?.initialFirstResponder = entries.buttons.first
        fitDock()
    }
    override func applyStyle() { super.applyStyle(); fitDock() }
    override func requestClose() {} // A dock cannot close the hidden windows it represents.
    override func minimize() {}
    override func maximize() {}
    override func showWindowMenu() {}
    func fitDock(screens: [NSRect] = NSScreen.screens.map(\.visibleFrame)) {
        guard let window else { return }
        let probe = NSRect(x:0,y:0,width:1000,height:1000), content = HAPWindowDrawing.contentRect(in:probe)
        let inset = NSSize(width:probe.width-content.width,height:probe.height-content.height)
        let old = window.frame
        func overlap(_ screen: NSRect) -> CGFloat {
            let intersection = screen.intersection(old)
            return intersection.isNull ? 0 : intersection.width*intersection.height
        }
        let screen = screens.max { overlap($0) < overlap($1) }
        let rowsHeight = max(HAPDockDrawing.rowHeight,CGFloat(entries.buttons.count)*HAPDockDrawing.rowHeight)
        let height = min(rowsHeight+inset.height,screen?.height ?? rowsHeight+inset.height)
        // Scrolling is an AppKit adaptation for more entries than fit a display.
        scroll.hasVerticalScroller = rowsHeight > height-inset.height
        let size = NSSize(width:min(HAPDockDrawing.width+inset.width+(scroll.hasVerticalScroller ? 16 : 0),screen?.width ?? .greatestFiniteMagnitude),height:height)
        window.minSize = .zero; window.maxSize = size; window.minSize = size
        let proposed = NSRect(x:old.minX,y:old.maxY-size.height,width:size.width,height:size.height)
        window.setFrame(ClassicPreferences.constrain(proposed,to:screens,fallback:proposed,minimumSize:NSSize(width:1,height:1)),display:false)
        chrome.layoutSubtreeIfNeeded(); scroll.tile()
        entries.frame.size = NSSize(width:max(1,scroll.contentSize.width),height:rowsHeight)
        entries.buttons.forEach { $0.frame.size.width = entries.bounds.width }
    }
}
