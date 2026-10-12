import AppKit

@MainActor class ClassicTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        if font?.fontName.hasPrefix("KDXImported-") == true {
            NSGraphicsContext.current?.shouldAntialias = false
            NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        }
        super.draw(dirtyRect)
    }
}

/// Field border: 0x959B0 / 0x9C6E0. Text insets and fill: 0x7FE00.
/// Native text editors keep selection, marked text, undo and secure entry.
@MainActor enum HAPFieldDrawing {
    static func skinID(focused: Bool, enabled: Bool) -> Int { !enabled ? 87 : focused ? 86 : 85 }
    static func frame(_ rect: NSRect, focused: Bool, enabled: Bool, fillInterior: Bool = true, compact: Bool = false) {
        let style = ClassicStyle.shared
        func fill(_ r: NSRect, _ slot: Int) { guard !r.isEmpty else { return }; style.color(slot).setFill(); r.fill() }
        func outline(_ r: NSRect, _ slot: Int) {
            fill(NSRect(x:r.minX,y:r.minY,width:r.width,height:1),slot)
            fill(NSRect(x:r.minX,y:r.maxY-1,width:r.width,height:1),slot)
            fill(NSRect(x:r.minX,y:r.minY,width:1,height:r.height),slot)
            fill(NSRect(x:r.maxX-1,y:r.minY,width:1,height:r.height),slot)
        }
        fill(rect,2)
        if let skin = style.artwork?.skins[skinID(focused:focused,enabled:enabled)] {
            skin.draw(in:rect,stretch:true)
        } else if focused && enabled && !compact {
            // The outermost focus outline omits its four corner pixels.
            fill(NSRect(x:rect.minX+1,y:rect.minY,width:rect.width-2,height:1),9)
            fill(NSRect(x:rect.minX+1,y:rect.maxY-1,width:rect.width-2,height:1),9)
            fill(NSRect(x:rect.minX,y:rect.minY+1,width:1,height:rect.height-2),9)
            fill(NSRect(x:rect.maxX-1,y:rect.minY+1,width:1,height:rect.height-2),9)
            outline(rect.insetBy(dx:1,dy:1),9)
            outline(rect.insetBy(dx:2,dy:2),4)
        } else {
            // Original flag 0x40 starts the bevel at the outer edge, omits the
            // palette focus ring, and keeps bitmap state selection unchanged.
            let inset: CGFloat = compact ? 0 : 1
            let r = rect.insetBy(dx:inset,dy:inset)
            fill(NSRect(x:r.minX,y:r.minY,width:r.width-1,height:1),3)
            fill(NSRect(x:r.minX,y:r.minY+1,width:1,height:r.height-2),3)
            fill(NSRect(x:r.minX+1,y:r.maxY-1,width:r.width-1,height:1),1)
            fill(NSRect(x:r.maxX-1,y:r.minY+1,width:1,height:r.height-2),1)
            outline(rect.insetBy(dx:inset+1,dy:inset+1),enabled ? 4 : 6)
        }
        // The original field overwrites the skin's center with the text background.
        if fillInterior { fill(rect.insetBy(dx:3,dy:3),10) }
    }
    static func textRect(_ rect: NSRect) -> NSRect { rect.insetBy(dx:4,dy:4) }
    // NSTextFieldCell applies drawingRect horizontally plus its own two-pixel
    // padding, but uses the supplied frame's top for vertical text placement.
    // Compensate here so the native glyphs start at the original four-pixel inset.
    static func nativeCellRect(_ rect: NSRect) -> NSRect { rect.insetBy(dx:-2,dy:2) }
    // The field editor's two-pixel line-fragment padding supplies the other half
    // of the horizontal inset; it has no corresponding vertical padding.
    static func editorRect(_ rect: NSRect) -> NSRect { rect.insetBy(dx:2,dy:4) }
    static func focused(_ view: NSView) -> Bool {
        guard let window = view.window, window.isKeyWindow else { return false }
        if window.firstResponder === view { return true }
        if let field = view as? NSTextField, let editor = field.currentEditor() { return window.firstResponder === editor }
        if let responder = window.firstResponder as? NSView { return responder.isDescendant(of:view) }
        return false
    }
    static func configure(_ cell: NSTextFieldCell) {
        cell.isBordered = false; cell.isBezeled = false; cell.drawsBackground = false
        cell.isEditable = true; cell.isSelectable = true; cell.isScrollable = true
        cell.usesSingleLineMode = true; cell.wraps = false; cell.lineBreakMode = .byClipping
        cell.font = ClassicStyle.shared.font; cell.textColor = ClassicStyle.shared.color(11)
        cell.focusRingType = .none
    }
    static func configureEditor(_ editor: NSText) {
        guard let editor = editor as? NSTextView else { return }
        let style = ClassicStyle.shared
        editor.font = style.font; editor.backgroundColor = style.color(10); editor.textColor = style.color(11)
        editor.insertionPointColor = style.color(14)
        editor.selectedTextAttributes = [.backgroundColor:style.color(12),.foregroundColor:style.color(13)]
    }
    static func size(_ cell: NSTextFieldCell) -> NSSize {
        let font = ClassicStyle.shared.font
        let size = (cell.stringValue as NSString).size(withAttributes:[.font:font])
        return NSSize(width:ceil(size.width)+8,height:ceil(("Ag" as NSString).size(withAttributes:[.font:font]).height)+8)
    }
    static func text(_ cell: NSTextFieldCell, frame: NSRect, in view: NSView) {
        // 0x7FED4 and 0x8BAFC keep text in slot 11 when the border is disabled.
        // Draw an enabled copy to suppress AppKit's automatic disabled-color blend;
        // the real control stays disabled, and a secure cell still masks its text.
        let placeholder = cell.stringValue.isEmpty ? (cell.placeholderAttributedString ?? cell.placeholderString.map { NSAttributedString(string:$0) }) : nil
        let drawingCell = !cell.isEnabled || placeholder != nil ? (cell.copy() as? NSTextFieldCell ?? cell) : cell
        if drawingCell !== cell { drawingCell.isEnabled = true }
        drawingCell.textColor = ClassicStyle.shared.color(11)
        if let placeholder {
            // HAP backgrounds do not follow the system's light/dark appearance.
            // Use the theme's field text for this modern hint, on a drawing copy
            // so neither the empty value nor the caller's attributes change.
            let hint = NSMutableAttributedString(attributedString:placeholder)
            hint.addAttributes([.font:ClassicStyle.shared.font,.foregroundColor:ClassicStyle.shared.color(11)],range:NSRange(location:0,length:hint.length))
            drawingCell.placeholderAttributedString = hint
        }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        frame.insetBy(dx:3,dy:3).clip()
        if cell.font?.fontName.hasPrefix("KDXImported-") == true { NSGraphicsContext.current?.shouldAntialias = false }
        drawingCell.drawInterior(withFrame:nativeCellRect(frame),in:view)
    }
}

/// An original three-pixel frame around a native scroll view. Keeping it outside
/// the scroll view gives AppKit the correct viewport without painting over text.
@MainActor final class ClassicFieldFrame: NSView {
    let content: NSView
    override var isFlipped: Bool { true }
    init(_ content: NSView) {
        self.content = content; super.init(frame:.zero)
        translatesAutoresizingMaskIntoConstraints = false; content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo:leadingAnchor,constant:3),
            content.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-3),
            content.topAnchor.constraint(equalTo:topAnchor,constant:3),
            content.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-3)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        HAPFieldDrawing.frame(bounds,focused:HAPFieldDrawing.focused(self),enabled:true,fillInterior:false)
    }
}

@MainActor final class ClassicTextFieldCell: NSTextFieldCell {
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        // NSCell's copy path does not safely retain Swift reference ivars.
        // Placeholder/disabled drawing copies this cell, so the view owns the
        // editor and copied cells carry no editor storage to over-release.
        (controlView as? ClassicTextField)?.classicFieldEditor
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { HAPFieldDrawing.textRect(rect) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        HAPFieldDrawing.frame(cellFrame,focused:HAPFieldDrawing.focused(controlView),enabled:isEnabled)
        HAPFieldDrawing.text(self,frame:cellFrame,in:controlView)
    }
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj); HAPFieldDrawing.configureEditor(editor); return editor
    }
    override var cellSize: NSSize { HAPFieldDrawing.size(self) }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame:HAPFieldDrawing.editorRect(rect),in:controlView,editor:textObj,delegate:delegate,start:selStart,length:selLength)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame:HAPFieldDrawing.editorRect(rect),in:controlView,editor:textObj,delegate:delegate,event:event)
    }
}

@MainActor final class ClassicSecureTextFieldCell: NSSecureTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect { HAPFieldDrawing.textRect(rect) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        HAPFieldDrawing.frame(cellFrame,focused:HAPFieldDrawing.focused(controlView),enabled:isEnabled)
        HAPFieldDrawing.text(self,frame:cellFrame,in:controlView)
    }
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj); HAPFieldDrawing.configureEditor(editor); return editor
    }
    override var cellSize: NSSize { HAPFieldDrawing.size(self) }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame:HAPFieldDrawing.editorRect(rect),in:controlView,editor:textObj,delegate:delegate,start:selStart,length:selLength)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame:HAPFieldDrawing.editorRect(rect),in:controlView,editor:textObj,delegate:delegate,event:event)
    }
}

@MainActor final class ClassicTextField: NSTextField {
    fileprivate lazy var classicFieldEditor: ClassicTextView = {
        let editor = ClassicTextView()
        editor.isFieldEditor = true
        return editor
    }()
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        let fieldCell = ClassicTextFieldCell(textCell:""); HAPFieldDrawing.configure(fieldCell); cell = fieldCell
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func textDidBeginEditing(_ notification: Notification) { super.textDidBeginEditing(notification); needsDisplay = true }
    override func textDidEndEditing(_ notification: Notification) { super.textDidEndEditing(notification); needsDisplay = true }
    func applyStyle() {
        font = ClassicStyle.shared.font; textColor = ClassicStyle.shared.color(11)
        if let editor = currentEditor() { HAPFieldDrawing.configureEditor(editor) }
        invalidateIntrinsicContentSize(); needsDisplay = true
    }
}

@MainActor final class ClassicSecureTextField: NSSecureTextField {
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        let fieldCell = ClassicSecureTextFieldCell(textCell:""); HAPFieldDrawing.configure(fieldCell); cell = fieldCell
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func textDidBeginEditing(_ notification: Notification) { super.textDidBeginEditing(notification); needsDisplay = true }
    override func textDidEndEditing(_ notification: Notification) { super.textDidEndEditing(notification); needsDisplay = true }
    func applyStyle() {
        font = ClassicStyle.shared.font; textColor = ClassicStyle.shared.color(11)
        if let editor = currentEditor() { HAPFieldDrawing.configureEditor(editor) }
        invalidateIntrinsicContentSize(); needsDisplay = true
    }
}
