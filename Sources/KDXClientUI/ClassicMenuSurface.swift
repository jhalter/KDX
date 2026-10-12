import AppKit

/// A menu's original rectangular content area, without the system menu window's
/// rounded frame or padding. Geometry and navigation are testable without windows.
@MainActor final class ClassicMenuSurface: NSView {
    let source: ClassicMenu
    let items: [NSMenuItem]
    let rows: [ClassicMenuItemView]
    let contentHeight: CGFloat
    private(set) var selectedIndex: Int?
    private(set) var scrollOffset: CGFloat = 0
    private var prefix = ""
    private var prefixTime: TimeInterval = 0
    var activateItem: ((NSMenuItem) -> Bool)?
    var cancel: (() -> Void)?
    override var isFlipped: Bool { true }

    init(menu: ClassicMenu, maximumHeight: CGFloat) {
        menu.prepareForDisplay()
        source = menu
        items = menu.items.filter { !$0.isHidden }
        rows = items.compactMap { item in
            guard let original = item.view as? ClassicMenuItemView else { return nil }
            let row = ClassicMenuItemView(item:item)
            row.first = original.first; row.last = original.last; row.layout = original.layout
            row.menuOffset = original.menuOffset; row.menuHeight = original.menuHeight
            row.frame.size = original.frame.size
            row.highlightedOverride = false
            return row
        }
        contentHeight = rows.reduce(0) { $0+$1.frame.height }
        let width = rows.map(\.frame.width).max() ?? 80
        super.init(frame:NSRect(x:0,y:0,width:width,height:min(contentHeight,max(1,maximumHeight))))
        setAccessibilityElement(true); setAccessibilityRole(.menu); setAccessibilityLabel(menu.title)
        for row in rows {
            row.activateOverride = { [weak self, weak item = row.item] in
                guard let self, let item else { return false }
                return activateItem?(item) ?? false
            }
            addSubview(row)
        }
        positionRows()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var selectedItem: NSMenuItem? { selectedIndex.map { items[$0] } }
    func eligible(_ index: Int) -> Bool {
        items.indices.contains(index) && items[index].menu === source && !items[index].isHidden && items[index].isEnabled && !items[index].isSeparatorItem
    }
    func index(at point: NSPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        return rows.firstIndex { $0.frame.contains(point) }
    }
    func select(_ index: Int?, reveal: Bool = false) {
        let previous = selectedIndex
        selectedIndex = index.flatMap { eligible($0) ? $0 : nil }
        if previous != selectedIndex, window != nil {
            NSAccessibility.post(element:self,notification:.selectedChildrenChanged)
            if let selectedIndex { NSAccessibility.post(element:rows[selectedIndex],notification:.focusedUIElementChanged) }
        }
        for (index,row) in rows.enumerated() { row.highlightedOverride = index == selectedIndex; row.needsDisplay = true }
        if reveal, let index = selectedIndex {
            let row = rows[index], top = row.menuOffset, bottom = top+row.frame.height
            if top < scrollOffset { scroll(to:top) }
            else if bottom > scrollOffset+bounds.height { scroll(to:bottom-bounds.height) }
        }
    }
    func move(_ delta: Int) {
        let candidates = items.indices.filter(eligible)
        guard !candidates.isEmpty else { select(nil); return }
        let next: Int
        if let selectedIndex, let current = candidates.firstIndex(of:selectedIndex) {
            next = (current+delta%candidates.count+candidates.count)%candidates.count
        } else { next = delta < 0 ? candidates.count-1 : 0 }
        select(candidates[next],reveal:true)
    }
    func movePage(_ direction: Int) {
        let candidates = items.indices.filter(eligible)
        guard let first = candidates.first else { return }
        let start = selectedIndex ?? first
        let target = rows[start].menuOffset+CGFloat(direction)*bounds.height
        let index = candidates.min { abs(rows[$0].menuOffset-target) < abs(rows[$1].menuOffset-target) }
        select(index,reveal:true)
    }
    func edge(last: Bool) { select(last ? items.indices.last(where:eligible) : items.indices.first(where:eligible),reveal:true) }
    func typeSelect(_ text: String, time: TimeInterval) {
        guard !text.isEmpty else { return }
        if time-prefixTime > 1 { prefix = "" }
        prefixTime = time
        let repeated = prefix.count == 1 && prefix.compare(text,options:[.caseInsensitive,.diacriticInsensitive]) == .orderedSame
        if !repeated { prefix += text }
        let start = repeated ? (selectedIndex ?? -1)+1 : selectedIndex ?? 0
        for step in 0..<items.count {
            let index = (start+step)%items.count
            if eligible(index), items[index].title.range(of:prefix,options:[.anchored,.caseInsensitive,.diacriticInsensitive]) != nil {
                select(index,reveal:true); return
            }
        }
    }
    func scroll(by delta: CGFloat) { scroll(to:scrollOffset+delta) }
    private func scroll(to offset: CGFloat) {
        scrollOffset = min(max(0,offset),max(0,contentHeight-bounds.height))
        positionRows(); needsDisplay = true
    }
    private func positionRows() {
        for row in rows { row.frame.origin = NSPoint(x:0,y:row.menuOffset-scrollOffset) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform(); transform.translateX(by:0,yBy:-scrollOffset); transform.concat()
        HAPMenuDrawing.background(NSRect(x:0,y:0,width:bounds.width,height:contentHeight))
    }
    override func accessibilityPerformCancel() -> Bool {
        guard let cancel else { return false }; cancel(); return true
    }
    override func accessibilitySelectedChildren() -> [Any]? { selectedIndex.map { [rows[$0]] } ?? [] }

    /// Coordinates are in AppKit screen space (bottom-left origin). Keep the
    /// complete rectangle on its display, including negative-coordinate screens.
    static func frame(size: NSSize, topLeft: NSPoint, screen: NSRect) -> NSRect {
        let width = min(size.width,screen.width), height = min(size.height,screen.height)
        return NSRect(x:min(max(topLeft.x,screen.minX),screen.maxX-width),
                      y:min(max(topLeft.y-height,screen.minY),screen.maxY-height),width:width,height:height)
    }
    static func submenuFrame(size: NSSize, parent: NSRect, rowTop: CGFloat, screen: NSRect) -> NSRect {
        let x = parent.maxX+size.width <= screen.maxX ? parent.maxX : parent.minX-size.width
        return frame(size:size,topLeft:NSPoint(x:x,y:rowTop),screen:screen)
    }
}
