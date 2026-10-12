import AppKit

/// Original menu flag 0x8 selects a compact shared icon/check gutter and 18-pixel rows.
/// Standard menus use separate check and optional icon gutters and 16-pixel rows.
enum HAPMenuLayout {
    case standard, sharedIcons
    var rowHeight: CGFloat { self == .sharedIcons ? 18 : 16 }
    func titleInset(hasIcon: Bool) -> CGFloat { self == .sharedIcons ? 24 : hasIcon ? 36 : 16 }
    var checkInset: CGFloat { self == .sharedIcons ? 4 : 0 }
    var iconInset: CGFloat { self == .sharedIcons ? 4 : 16 }
    func widthPadding(hasIcon: Bool) -> CGFloat { self == .sharedIcons ? 40 : hasIcon ? 52 : 32 }
}

/// Menu drawing: 0x96110/0x96560 and HAP overrides 0x9E540/0x9E600.
@MainActor enum HAPMenuDrawing {
    static func color(_ original: Int, recovery: Int) -> NSColor {
        ClassicStyle.shared.color(ClassicStyle.shared.appearance.colors.count >= 204 ? original : recovery)
    }
    static func tile(_ bitmap: HAPBitmap, in rect: NSRect) {
        HAPBackgroundDrawing.tile(bitmap,in:rect)
    }
    static func background(_ rect: NSRect) {
        color(105,recovery:2).setFill(); rect.fill()
        if let tile = ClassicStyle.shared.artwork?.skins[184] { self.tile(tile,in:rect) }
        if let frame = ClassicStyle.shared.artwork?.skins[185] { frame.draw(in:rect,stretch:true) }
    }
    @discardableResult static func row(_ rect: NSRect, selected: Bool, enabled: Bool, separator: Bool = false, first: Bool = false, last: Bool = false) -> NSColor {
        let skins = ClassicStyle.shared.artwork?.skins ?? [:]
        let selected = selected && enabled && !separator
        let variant = !enabled ? 2 : selected ? 1 : 0
        if separator, let skin = skins[192] {
            skin.draw(in:NSRect(x:rect.minX,y:floor(rect.midY-CGFloat(skin.height)/2),width:rect.width,height:CGFloat(skin.height)),stretch:true,axis:.horizontal)
            return color(107,recovery:5)
        }
        if !separator, skins[186+variant] != nil || skins[189+variant] != nil {
            if let tile = skins[186+variant] { self.tile(tile,in:rect) }
            if let frame = skins[189+variant] { frame.draw(in:rect,stretch:true) }
            let rgb = (skins[189+variant] ?? skins[186+variant])?.textColor ?? 0
            return NSColor(srgbRed:Double((rgb>>16)&255)/255,green:Double((rgb>>8)&255)/255,blue:Double(rgb&255)/255,alpha:1)
        }
        let upper = color(selected ? 108 : 104,recovery:1)
        let fill = color(selected ? 109 : 105,recovery:selected ? 17 : 2)
        let lower = color(selected ? 110 : 106,recovery:3)
        func paint(_ r: NSRect, _ c: NSColor) { guard !r.isEmpty else { return }; c.setFill(); r.fill() }
        if selected { paint(NSRect(x:rect.minX+1,y:rect.minY,width:rect.width-2,height:rect.height),fill) }
        paint(NSRect(x:rect.minX,y:rect.minY,width:1,height:rect.height),upper)
        paint(NSRect(x:rect.maxX-1,y:rect.minY,width:1,height:rect.height),lower)
        if first {
            paint(NSRect(x:rect.minX,y:rect.minY,width:rect.width-1,height:1),upper)
            paint(NSRect(x:rect.maxX-1,y:rect.minY,width:1,height:1),fill)
        }
        if last {
            paint(NSRect(x:rect.minX,y:rect.maxY-1,width:1,height:1),fill)
            paint(NSRect(x:rect.minX+1,y:rect.maxY-1,width:rect.width-2,height:1),lower)
        }
        if separator {
            let y = floor(rect.midY-1)
            paint(NSRect(x:rect.minX,y:y,width:rect.width-1,height:1),lower)
            paint(NSRect(x:rect.minX,y:y+1,width:rect.width,height:1),upper)
        }
        return color(!enabled ? 112 : selected ? 111 : 107,recovery:!enabled ? 7 : selected ? 18 : 5)
    }
    static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let flags = item.keyEquivalentModifierMask
        var text = flags.contains(.command) || flags.contains(.control) ? "^" : ""
        if flags.contains(.option) { text += ":" }
        if flags.contains(.shift) { text += "!" }
        let key = item.keyEquivalent
        if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1,
           scalar.value >= UInt32(NSF1FunctionKey), scalar.value <= UInt32(NSF35FunctionKey) {
            text += "F\(scalar.value-UInt32(NSF1FunctionKey)+1)"
        } else { text += key.uppercased() }
        return text
    }
    static func hasIcon(_ item: NSMenuItem) -> Bool {
        (item.representedObject as? ClassicMenuAction)?.iconID != nil || item.image != nil
    }
    static func size(_ item: NSMenuItem, layout: HAPMenuLayout = .standard) -> NSSize {
        let attributes: [NSAttributedString.Key:Any] = [.font:ClassicStyle.shared.font]
        var width = (item.title as NSString).size(withAttributes:attributes).width+layout.widthPadding(hasIcon:hasIcon(item))
        if item.submenu != nil { width += 16 }
        let shortcut = shortcut(item)
        if !shortcut.isEmpty { width += (shortcut as NSString).size(withAttributes:attributes).width+16 }
        return NSSize(width:ceil(width/2)*2,height:layout.rowHeight)
    }
    static func content(_ item: NSMenuItem, in rect: NSRect, color: NSColor, selected: Bool? = nil, layout: HAPMenuLayout = .standard) {
        guard !item.isSeparatorItem else { return }
        let font = ClassicStyle.shared.font
        let attributes: [NSAttributedString.Key:Any] = [.font:font,.foregroundColor:color]
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        rect.clip()
        if font.fontName.hasPrefix("KDXImported-") {
            NSGraphicsContext.current?.shouldAntialias = false
            NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        }
        func text(_ string: String, x: CGFloat) {
            let value = string as NSString, size = value.size(withAttributes:attributes)
            value.draw(at:NSPoint(x:x,y:floor(rect.midY-size.height/2)),withAttributes:attributes)
        }
        let left = rect.minX+layout.titleInset(hasIcon:hasIcon(item))
        let iconLeft = rect.minX+layout.iconInset
        if let iconID = (item.representedObject as? ClassicMenuAction)?.iconID {
            if let bitmap = ClassicStyle.shared.artwork?.icon(iconID,small:true) {
                let highlighted = selected ?? item.isHighlighted
                let tint: UInt32? = !item.isEnabled || highlighted ? HAPUserRowDrawing.rgb(self.color(!item.isEnabled ? 105 : 109,recovery:!item.isEnabled ? 2 : 17)) : nil
                let icon = bitmap.tintedIcon(tint:tint,text:HAPUserRowDrawing.rgb(color))
                let x = iconLeft+CGFloat((16-icon.width)/2)
                let y = rect.minY+CGFloat((Int(rect.height)-icon.height)/2)
                let destination = NSRect(x:x,y:y,width:CGFloat(icon.width),height:CGFloat(icon.height))
                icon.draw(in:destination)
            }
        } else if let image = item.image {
            image.draw(in:NSRect(x:iconLeft,y:floor(rect.midY-8),width:16,height:16),from:.zero,operation:.sourceOver,fraction:item.isEnabled ? 1 : 0.5,respectFlipped:true,hints:nil)
        }
        if item.state != .off && !(item.state == .on && layout == .sharedIcons && hasIcon(item)) {
            let mark = item.state == .mixed ? "-" : "✓"
            let width = (mark as NSString).size(withAttributes:attributes).width
            text(mark,x:floor(rect.minX+layout.checkInset+(16-width)/2))
        }
        var right = rect.maxX-10
        if item.submenu != nil {
            let y = floor(rect.midY-5.5), x = right-6
            color.setFill()
            for row in 0..<11 {
                NSRect(x:x,y:y+CGFloat(row),width:CGFloat(6-abs(5-row)),height:1).fill()
            }
            right -= 16
        }
        let shortcut = shortcut(item)
        if !shortcut.isEmpty {
            let width = (shortcut as NSString).size(withAttributes:attributes).width
            text(shortcut,x:right-width); right -= width+16
        }
        let label = HAPPopUpDrawing.truncatedTitle(item.title,width:max(0,right-left),attributes:attributes)
        NSRect(x:left,y:rect.minY,width:max(0,right-left),height:rect.height).clip()
        text(label,x:left)
    }
}

@MainActor final class ClassicMenuItemView: NSView {
    weak var item: NSMenuItem?
    var first = false, last = false
    var layout = HAPMenuLayout.standard
    var menuOffset: CGFloat = 0
    var menuHeight: CGFloat = 0
    var highlightedOverride: Bool?
    var activateOverride: (() -> Bool)?
    override var isFlipped: Bool { true }
    init(item: NSMenuItem) {
        self.item = item
        super.init(frame:NSRect(origin:.zero,size:HAPMenuDrawing.size(item)))
        autoresizingMask = [.width]
        setAccessibilityElement(!item.isSeparatorItem); setAccessibilityRole(.menuItem)
    }
    required init?(coder: NSCoder) { super.init(coder:coder) }
    private var representedItem: NSMenuItem? { item ?? enclosingMenuItem }
    override func accessibilityLabel() -> String? { representedItem?.title }
    override func isAccessibilityEnabled() -> Bool { representedItem?.isEnabled == true }
    override func isAccessibilityFocused() -> Bool { highlightedOverride ?? super.isAccessibilityFocused() }
    override func accessibilityValue() -> Any? { representedItem?.state.rawValue }
    override func accessibilityPerformPress() -> Bool { activate() }
    override func draw(_ dirtyRect: NSRect) {
        guard let item = representedItem else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform(); transform.translateX(by:0,yBy:-menuOffset); transform.concat()
        let rect = NSRect(x:bounds.minX,y:bounds.minY+menuOffset,width:bounds.width,height:bounds.height)
        rect.clip()
        HAPMenuDrawing.background(NSRect(x:rect.minX,y:0,width:rect.width,height:max(menuHeight,rect.maxY)))
        let selected = highlightedOverride ?? item.isHighlighted
        let color = HAPMenuDrawing.row(rect,selected:selected,enabled:item.isEnabled,separator:item.isSeparatorItem,first:first,last:last)
        HAPMenuDrawing.content(item,in:rect,color:color,selected:selected,layout:layout)
    }
    @discardableResult func activate() -> Bool {
        guard let item = representedItem, item.isEnabled, !item.isHidden, !item.isSeparatorItem else { return false }
        if let activateOverride { return activateOverride() }
        guard item.submenu == nil, let menu = item.menu else { return false }
        let index = menu.index(of:item)
        guard index >= 0 else { return false }
        menu.cancelTracking()
        menu.performActionForItem(at:index)
        return true
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow,from:nil)) { activate() }
    }
}

/// The system menu bar stays native. In-window popups use our borderless AppKit
/// surface; NSMenu continues to own item identities, targets and key equivalents.
@MainActor final class ClassicMenu: NSMenu, NSMenuDelegate {
    override init(title: String) {
        super.init(title:title); delegate = self; autoenablesItems = false
    }
    required init(coder: NSCoder) { super.init(coder:coder); delegate = self }
    @discardableResult func present(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        guard let selected = ClassicMenuTracking.selection(menu:self,positioning:item,at:location,in:view),
              ClassicMenuTracking.canActivate(selected,in:self), let menu = selected.menu else { return false }
        let index = menu.index(of:selected)
        guard index >= 0 else { return false }
        menu.performActionForItem(at:index)
        return true
    }
    @discardableResult static func showContext(for event: NSEvent, in view: NSView) -> Bool {
        guard let menu = view.menu(for:event) as? ClassicMenu else { return false }
        menu.present(positioning:nil,at:view.convert(event.locationInWindow,from:nil),in:view)
        return true
    }
    // The AppKit adapter chooses the original shared-gutter mode for menus containing icons.
    // Explicit overrides allow callers to retain independent check and icon columns.
    var layoutOverride: HAPMenuLayout?
    func prepareForDisplay() {
        font = ClassicStyle.shared.font
        let visible = items.filter { !$0.isHidden }
        let layout = layoutOverride ?? (visible.contains(where:HAPMenuDrawing.hasIcon) ? .sharedIcons : .standard)
        let width = min(600,max(80,visible.map { HAPMenuDrawing.size($0,layout:layout).width }.max() ?? 80))
        let height = visible.reduce(CGFloat(0)) { $0 + (($1.view != nil && !($1.view is ClassicMenuItemView)) ? $1.view!.frame.height : layout.rowHeight) }
        var offset: CGFloat = 0
        for (index,item) in visible.enumerated() {
            if let view = item.view, !(view is ClassicMenuItemView) { offset += view.frame.height; continue }
            let view = item.view as? ClassicMenuItemView ?? ClassicMenuItemView(item:item)
            view.item = item; view.first = index == 0; view.last = index == visible.count-1; view.menuOffset = offset
            view.menuHeight = height; view.layout = layout
            view.frame.size = NSSize(width:width,height:layout.rowHeight)
            offset += view.frame.height
            if item.view !== view { item.view = view }
            view.needsDisplay = true
        }
    }
    func menuWillOpen(_ menu: NSMenu) { prepareForDisplay() }
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for row in items { row.view?.needsDisplay = true }
    }
}
