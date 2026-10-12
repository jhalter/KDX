import AppKit

/// Column-title drawing from 0x98EF0 and skin selection from 0x9D2C0.
@MainActor enum HAPTableHeaderDrawing {
    static let height: CGFloat = 20
    static func draw(_ rect: NSRect, title: String, selected: Bool, pressed: Bool, enabled: Bool, alignment: NSTextAlignment = .center) {
        let style = ClassicStyle.shared
        let skin = style.artwork?.skins[!enabled ? 136 : selected || pressed ? 135 : 134]
        let text: NSColor
        if let skin {
            skin.draw(in:rect,stretch:true)
            let rgb = skin.textColor ?? 0
            text = NSColor(srgbRed:Double((rgb>>16)&255)/255,green:Double((rgb>>8)&255)/255,blue:Double(rgb&255)/255,alpha:1)
        } else if style.appearance.colors.count >= 183 {
            let roles: [Int] = !enabled ? [48,43,45,47,49] : pressed ? [41,36,38,40,42] : selected ? [174,181,180,179,182] : [174,175,176,177,178]
            func fill(_ r: NSRect, _ role: Int) { guard !r.isEmpty else { return }; style.color(roles[role]).setFill(); r.fill() }
            let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
            fill(rect,0); fill(rect.insetBy(dx:1,dy:1),2)
            fill(NSRect(x:x+1,y:y+1,width:w-3,height:1),1)
            fill(NSRect(x:x+1,y:y+2,width:1,height:h-4),1)
            fill(NSRect(x:x+2,y:y+h-2,width:w-3,height:1),3)
            fill(NSRect(x:x+w-2,y:y+2,width:1,height:h-4),3)
            text = style.color(roles[4])
        } else { ClassicPainter.bevel(rect,pressed:pressed); text = style.color(5) }
        guard !title.isEmpty else { return }
        let attributes: [NSAttributedString.Key:Any] = [.font:style.font,.foregroundColor:text]
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        // Palette headers call the truncating 0x62400 with three-pixel side
        // insets. Bitmap headers call 0x62280 with the full rectangle instead.
        let interior = skin == nil ? rect.insetBy(dx:3,dy:0) : rect
        guard !interior.isEmpty else { return }
        // 0x62280 passes the existing graphics clip to the glyph blitter; it
        // does not add a per-column clip. Preserve that for bitmap titles.
        if skin == nil { interior.clip() }
        if style.font.fontName.hasPrefix("KDXImported-") {
            NSGraphicsContext.current?.shouldAntialias = false
            NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        }
        let label = (skin == nil ? HAPPopUpDrawing.truncatedTitle(title,width:interior.width,attributes:attributes) : title) as NSString
        let size = label.size(withAttributes:attributes)
        let x: CGFloat
        switch alignment {
        case .left, .natural, .justified: x = interior.minX
        case .right: x = interior.maxX-size.width
        default: x = (interior.midX-size.width/2).rounded(.towardZero)
        }
        label.draw(at:NSPoint(x:x,y:(rect.midY-size.height/2).rounded(.towardZero)),withAttributes:attributes)
    }
}

@MainActor final class ClassicTableHeaderCell: NSTableHeaderCell {
    var sorted = false
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        HAPTableHeaderDrawing.draw(cellFrame,title:stringValue,selected:sorted,pressed:isHighlighted,enabled:isEnabled,alignment:alignment)
    }
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        HAPTableHeaderDrawing.draw(cellFrame,title:stringValue,selected:sorted,pressed:flag,enabled:isEnabled,alignment:alignment)
    }
    // The reference marks the sorted column with the selected header palette
    // (0x89528), without AppKit's added triangle. Native sort semantics remain.
    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {}
}

@MainActor final class ClassicTableHeaderView: NSTableHeaderView {
    enum ColumnMove: CaseIterable {
        case farLeft, left, right, farRight
        var title: String {
            switch self {
            case .farLeft: "Move Column To Far Left"
            case .left: "Move Column Left"
            case .right: "Move Column Right"
            case .farRight: "Move Column To Far Right"
            }
        }
    }
    override var isFlipped: Bool { true }
    override func rightMouseDown(with event: NSEvent) {
        if !ClassicMenu.showContext(for:event,in:self) { super.rightMouseDown(with:event) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), ClassicMenu.showContext(for:event,in:self) { return }
        super.mouseDown(with:event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow,from:nil)
        guard bounds.contains(point) else { return nil }
        return reorderMenu(forColumn:column(at:point))
    }
    /// Original header context menu: 0x89A20, commands 101…104.
    /// Keep the column object, not its current ordinal or the focused table.
    func reorderMenu(forColumn index: Int) -> ClassicMenu? {
        guard let table = tableView, table.isEnabled, table.allowsColumnReordering,
              table.tableColumns.indices.contains(index) else { return nil }
        let column = table.tableColumns[index]
        guard !column.isHidden else { return nil }
        let menu = ClassicMenu(title:column.title)
        for move in ColumnMove.allCases {
            let item = menuItem(move.title) { [weak self, weak table, weak column] in
                guard let self, let table, let column,
                      let destination = destination(for:move,column:column,in:table),
                      let source = table.tableColumns.firstIndex(where: { $0 === column }) else { return }
                table.moveColumn(source,toColumn:destination)
                needsDisplay = true
            }
            item.isEnabled = destination(for:move,column:column,in:table) != nil
            menu.addItem(item)
        }
        return menu
    }
    private func destination(for move: ColumnMove, column: NSTableColumn, in table: NSTableView) -> Int? {
        guard tableView === table, table.isEnabled, table.allowsColumnReordering, !column.isHidden,
              let source = table.tableColumns.firstIndex(where: { $0 === column }) else { return nil }
        let visible = table.tableColumns.indices.filter { !table.tableColumns[$0].isHidden }
        guard let position = visible.firstIndex(of:source) else { return nil }
        let next: Int
        switch move {
        case .farLeft: next = 0
        case .left: next = position-1
        case .right: next = position+1
        case .farRight: next = visible.count-1
        }
        guard visible.indices.contains(next), next != position else { return nil }
        let target = visible[next]
        guard table.delegate?.tableView?(table,shouldReorderColumn:source,toColumn:target) != false else { return nil }
        return target
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        bounds.intersection(dirtyRect).clip()
        HAPTableHeaderDrawing.draw(bounds,title:"",selected:false,pressed:false,enabled:tableView?.isEnabled ?? true)
        guard let tableView else { return }
        // Bitmap titles may extend outside their column. Replay the visible
        // columns in order under the dirty clip so partial redraws compose
        // exactly like a full redraw, including overlapping title glyphs.
        for (index,column) in tableView.tableColumns.enumerated() where !column.isHidden {
            column.headerCell.draw(withFrame:headerRect(ofColumn:index),in:self)
        }
        // 0x89588…0x895D0 paints the unused tail AFTER the column titles.
        // This covers a bitmap title's overflow beyond the final column.
        let end = tableView.tableColumns.indices.filter { !tableView.tableColumns[$0].isHidden }.map { headerRect(ofColumn:$0).maxX }.max() ?? bounds.minX
        if end < bounds.maxX {
            let tail = NSRect(x:end,y:bounds.minY,width:bounds.maxX-end,height:bounds.height)
            if tail.intersects(dirtyRect) { HAPTableHeaderDrawing.draw(tail,title:"",selected:false,pressed:false,enabled:tableView.isEnabled) }
        }
    }
}
