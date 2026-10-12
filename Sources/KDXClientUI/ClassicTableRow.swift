import AppKit

/// List roles verified in 0x895F0 (column background) and the row renderer at
/// 0x63D0: 15 background, 16 text, 17 selection, 18 selected text,
/// 19 sorted-column background, 20 separators. Inactive selections are outlined.
@MainActor enum HAPListDrawing {
    static func background(_ rect: NSRect, sortedColumn: NSRect?) {
        let style = ClassicStyle.shared
        style.color(15).setFill(); rect.fill()
        if let column = sortedColumn {
            style.color(19).setFill()
            NSRect(x:column.minX,y:rect.minY,width:column.width,height:rect.height).intersection(rect).fill()
        }
    }
    static func selection(_ rect: NSRect, emphasized: Bool) {
        let selection = NSRect(x:rect.minX+1,y:rect.minY+1,width:max(0,rect.width-2),height:max(0,rect.height-1))
        guard !selection.isEmpty else { return }
        ClassicStyle.shared.color(17).setFill()
        if emphasized { selection.fill() }
        else {
            // 0x61A70 uses an inward two-pixel frame for an unfocused list.
            NSRect(x:selection.minX,y:selection.minY,width:selection.width,height:min(2,selection.height)).fill()
            NSRect(x:selection.minX,y:max(selection.minY,selection.maxY-2),width:selection.width,height:min(2,selection.height)).fill()
            NSRect(x:selection.minX,y:selection.minY,width:min(2,selection.width),height:selection.height).fill()
            NSRect(x:max(selection.minX,selection.maxX-2),y:selection.minY,width:min(2,selection.width),height:selection.height).fill()
        }
    }
}

@MainActor final class ClassicTableRowView: NSTableRowView {
    var userAdornment: ClassicUserAdornment? { didSet { refreshText() } }
    var userRowSize: ClassicUserRowSize = .compact { didSet { refreshText() } }
    override var isSelected: Bool { didSet { refreshText() } }
    override var isEmphasized: Bool { didSet { refreshText() } }
    private func refreshText() {
        needsDisplay = true
        func refresh(_ view: NSView) { view.needsDisplay = true; view.subviews.forEach(refresh) }
        subviews.forEach(refresh)
    }
    override func drawBackground(in dirtyRect: NSRect) {
        if let profile = userAdornment {
            HAPUserRowDrawing.background(bounds,profile:profile,selected:isSelected,emphasized:isEmphasized,dirtyRect:dirtyRect,size:userRowSize)
        } // Generic rows retain the table's sorted-column stripe underneath.
    }
    override func drawSelection(in dirtyRect: NSRect) {
        if userAdornment != nil {
            if !isEmphasized { HAPUserRowDrawing.inactiveSelection(bounds,size:userRowSize) }
        } else { HAPListDrawing.selection(bounds,emphasized:isEmphasized) }
    }
}

@MainActor final class ClassicListTextField: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        var ancestor = superview
        while ancestor != nil && !(ancestor is NSTableRowView) { ancestor = ancestor?.superview }
        let row = ancestor as? NSTableRowView
        if let row = row as? ClassicTableRowView, let profile = row.userAdornment {
            textColor = HAPUserRowDrawing.textColor(profile,selected:row.isSelected,emphasized:row.isEmphasized)
        } else if let cell = superview as? ClassicUserCell {
            textColor = HAPUserRowDrawing.textColor(cell.adornment,selected:false,emphasized:false)
        } else {
            textColor = ClassicStyle.shared.color(row?.isSelected == true && row?.isEmphasized == true ? 18 : 16)
        }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        if font?.fontName.hasPrefix("KDXImported-") == true { NSGraphicsContext.current?.shouldAntialias = false }
        super.draw(dirtyRect)
    }
}
