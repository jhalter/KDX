import AppKit

@MainActor public final class ClassicStyle {
    public static let shared = ClassicStyle()
    public var appearance = ClassicAppearance.recovery { didSet { updateArtwork() } }
    private var referenceChrome: HAPChromeArtwork?
    private var referenceIcons: [Int: HAPBitmap]?
    var chromeArtwork: HAPChromeArtwork? { appearance.chromeArtwork ?? referenceChrome }
    public func configureAssets(_ appearances: [ClassicAppearance]) {
        referenceChrome = appearances.compactMap(\.chromeArtwork).first { (try? $0.validate()) != nil }
        referenceIcons = nil
        for candidate in appearances {
            guard let source = candidate.artwork,
                  AppearanceDecoder.digest(source.icons) == AppearanceDecoder.referenceIconAtlasSHA256,
                  let decoded = try? source.decode() else { continue }
            referenceIcons = decoded.icons
            break
        }
        updateArtwork()
        configureFonts(appearances.flatMap { $0.fonts ?? [] })
    }
    private func updateArtwork() {
        if var selected = try? appearance.artwork?.decode() {
            selected.referenceIcons = referenceIcons
            artwork = selected
        } else if let referenceIcons {
            artwork = HAPDecodedArtwork(skins:[:],icons:[:],referenceIcons:referenceIcons)
        } else { artwork = nil }
    }
    public private(set) var artwork: HAPDecodedArtwork?
    public private(set) var font = NSFont.systemFont(ofSize: 11)
    private var fontSources: [String:(Data,Int)] = [:]
    public private(set) var fontChoices: [(id:String,title:String)] = []
    public var fontChoiceID: String? { didSet { updateFont() } }
    public private(set) var fontError: String?
    public func configureFonts(_ sources: [Data]) {
        fontSources = [:]; fontChoices = []
        var seen = Set<String>()
        for data in sources {
            let digest = AppearanceDecoder.digest(data)
            guard seen.insert(digest).inserted, let decoded = try? HaxialFont(data:data) else { continue }
            for (index,strike) in decoded.strikes.enumerated() {
                let id = digest+"-\(index)"
                fontSources[id] = (data,index)
                fontChoices.append((id,"\(decoded.name) \(strike.height)"+(strike.style.isEmpty ? "" : " \(strike.style)")))
            }
        }
        updateFont()
    }
    private func updateFont() {
        fontError = nil
        // 0xB3404 installs Myoklonika as the original default font.
        let choice = fontChoiceID.flatMap { fontSources[$0] } ?? fontChoices.first(where: { $0.title == "Myoklonika 15" }).flatMap { fontSources[$0.id] } ?? fontChoices.first.flatMap { fontSources[$0.id] }
        guard let (data,index) = choice else { font = NSFont.systemFont(ofSize:11); return }
        do { font = try HaxialNativeFonts.shared.font(data:data,strike:index) }
        catch { fontError = error.localizedDescription; font = NSFont.systemFont(ofSize:11) }
    }
    public func color(_ slot: Int) -> NSColor { appearance.color(slot) }
}

@MainActor public enum ClassicPainter {
    public static func bevel(_ rect: NSRect, pressed: Bool = false, fill: NSColor? = nil) {
        let style = ClassicStyle.shared
        (fill ?? style.color(2)).setFill(); rect.fill()
        (pressed ? style.color(3) : style.color(1)).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
        (pressed ? style.color(1) : style.color(3)).setFill()
        NSRect(x: rect.minX, y: rect.maxY-1, width: rect.width, height: 1).fill()
        NSRect(x: rect.maxX-1, y: rect.minY, width: 1, height: rect.height).fill()
    }
    /// Pure offscreen drawing used by controls and headless raster checks; this never captures a screen.
    public static func button(_ rect: NSRect, title: String, pressed: Bool, enabled: Bool, defaultButton: Bool, iconID: Int? = nil, iconOnly: Bool = false, wonderLight: HAPWonderLightState? = nil) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        rect.clip()
        let style = ClassicStyle.shared
        let skinID = (iconID != nil ? 33 : defaultButton ? 21 : 9) + (!enabled ? 2 : pressed ? 1 : 0)
        let skin = style.artwork?.skins[skinID]
        var textColor = style.color(enabled ? 5 : 7)
        if let skin { skin.draw(in: rect, stretch: true) }
        else if style.appearance.colors.count >= 204 {
            textColor = iconID != nil ? HAPIconButtonDrawing.border(rect,pressed:pressed,enabled:enabled) : HAPPaletteDrawing.button(rect,pressed:pressed,enabled:enabled,defaultButton:defaultButton)
        }
        else {
            if defaultButton && enabled { bevel(rect) }
            bevel(defaultButton ? rect.insetBy(dx:3,dy:3) : rect, pressed:pressed)
        }
        let renderedTextColor = skin?.textColor.map(HAPUserRowDrawing.color) ?? textColor
        let tint: UInt32? = !enabled || pressed ? HAPUserRowDrawing.rgb(style.color(style.appearance.colors.count >= 204 ? (!enabled ? 45 : 38) : 2)) : nil
        let layout = HAPIconButtonLayout(bounds:rect,iconOnly:iconOnly)
        if let wonderLight { HAPWonderLightDrawing.draw(wonderLight,in:rect) }
        if wonderLight != nil && iconOnly { return }
        let icon = iconID.flatMap { style.artwork?.icon($0,small:layout.small) }?.tintedIcon(tint:tint,text:HAPUserRowDrawing.rgb(renderedTextColor))
        if let icon, !layout.iconRegion.isEmpty { icon.draw(in:layout.iconRect(icon)) }
        if iconOnly && icon != nil { return }
        // Keep the compact bar usable before the user imports any artwork.
        let text = (iconOnly ? String(title.prefix(2)) : title) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: style.font, .foregroundColor: renderedTextColor]
        let size = text.size(withAttributes: attributes)
        if style.font.fontName.hasPrefix("KDXImported-") {
            NSGraphicsContext.current?.shouldAntialias = false
            NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        }
        let labelRect = !iconOnly && iconID != nil ? layout.labelRegion : rect
        labelRect.clip()
        let label = HAPPopUpDrawing.truncatedTitle(text as String,width:labelRect.width,attributes:attributes) as NSString
        let labelWidth = label.size(withAttributes:attributes).width
        label.draw(at:NSPoint(x:floor(!iconOnly && iconID != nil ? labelRect.minX : rect.midX-labelWidth/2),y:floor(rect.midY-size.height/2)),withAttributes:attributes)
    }
}

final class ClassicButtonCell: NSButtonCell {
    var iconID: Int?
    var iconOnly = false
    var wonderLight: HAPWonderLightState?
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        ClassicPainter.button(cellFrame, title:title, pressed:isHighlighted, enabled:isEnabled, defaultButton:keyEquivalent == "\r" || keyEquivalent == "\u{3}", iconID:iconID,iconOnly:iconOnly,wonderLight:wonderLight)
    }
}
@MainActor final class ClassicButton: NSButton {
    var wonderLight: HAPWonderLightState? {
        get { (cell as? ClassicButtonCell)?.wonderLight }
        set { (cell as? ClassicButtonCell)?.wonderLight = newValue; needsDisplay = true }
    }
    private let controlHeight: CGFloat
    override var isFlipped: Bool { true }
    var invoke: (() -> Void)?
    var iconID: Int? { get { (cell as? ClassicButtonCell)?.iconID } set { (cell as? ClassicButtonCell)?.iconID = newValue; needsDisplay = true; invalidateIntrinsicContentSize() } }
    var iconOnly: Bool {
        get { (cell as? ClassicButtonCell)?.iconOnly ?? false }
        set { (cell as? ClassicButtonCell)?.iconOnly = newValue; toolTip = newValue ? title : nil; needsDisplay = true; invalidateIntrinsicContentSize() }
    }
    override var intrinsicContentSize: NSSize {
        if iconOnly { return NSSize(width:32,height:controlHeight) }
        let width = (title as NSString).size(withAttributes:[.font:ClassicStyle.shared.font]).width
        return NSSize(width:max(28,ceil(width)+16+(iconID == nil ? 0 : 22)),height:controlHeight)
    }
    init(_ title: String, key: String = "", height: CGFloat = 24, action: @escaping () -> Void) {
        controlHeight = height
        super.init(frame: .zero); cell = ClassicButtonCell(textCell: title); self.title = title
        font = ClassicStyle.shared.font; target = self; self.action = #selector(performAction)
        keyEquivalent = key; keyEquivalentModifierMask = []; invoke = action
        focusRingType = .none; setAccessibilityRole(.button); setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func performAction() { invoke?() }
}

@MainActor class ClassicSurface: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { HAPBackgroundDrawing.fill(bounds.intersection(dirtyRect),in:self) }
}

@MainActor final class ClassicTableView: NSTableView {
    var beginFiltering: ((NSEvent) -> Bool)?
    var filterCommand: ((NSEvent) -> Bool)?
    var command: ((NSEvent) -> Bool)?
    override func drawBackground(inClipRect clipRect: NSRect) {
        let column = sortDescriptors.first?.key.flatMap { key in tableColumns.firstIndex { $0.identifier.rawValue == key } }
        HAPListDrawing.background(clipRect,sortedColumn:column.map { rect(ofColumn:$0) })
    }
    override func drawGrid(inClipRect clipRect: NSRect) {
        // Original separators belong to populated rows, not the empty list area.
        let range = rows(in:clipRect)
        guard range.location != NSNotFound, range.location < numberOfRows else { return }
        ClassicStyle.shared.color(20).setFill()
        for row in range.location..<min(numberOfRows,NSMaxRange(range)) {
            let rect = rect(ofRow:row)
            NSRect(x:clipRect.minX,y:rect.maxY,width:clipRect.width,height:1).intersection(clipRect).fill()
        }
    }
    override func keyDown(with event: NSEvent) {
        if filterCommand?(event) == true { return }
        if command?(event) == true { return }
        if Self.startsFilter(event), beginFiltering?(event) == true { return }
        super.keyDown(with: event)
    }
    static func startsFilter(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command,.control]).isEmpty else { return false }
        // Inspect the unmodified character only to distinguish text keys from
        // navigation. Deliver the ORIGINAL event to AppKit for dead keys/IME.
        let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
        return !text.isEmpty && text.unicodeScalars.allSatisfy {
            $0.properties.generalCategory != .control && !(0xf700...0xf8ff).contains($0.value)
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        if !ClassicMenu.showContext(for:event,in:self) { super.rightMouseDown(with:event) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), ClassicMenu.showContext(for:event,in:self) { return }
        super.mouseDown(with:event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return super.menu(for: event)
    }
}

@MainActor final class ClassicIconView: NSView {
    var iconID: Int = 17
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { ClassicStyle.shared.artwork?.icon(iconID, small: true)?.draw(in: bounds) }
}

struct ClassicRow: Equatable { let id: String; var values: [String]; var iconID: Int? = nil; var userAdornment: ClassicUserAdornment? = nil; var progress: Double? = nil }
@MainActor final class ClassicList: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let table = ClassicTableView()
    let filter = ClassicTextField()
    let scroll = ClassicScrollView()
    var rows: [ClassicRow] = [] { didSet { if rows != oldValue { reload() } } }
    private(set) var visible: [ClassicRow] = []
    private(set) var filterQuery = ""
    var selected: ClassicRow? { visible.indices.contains(table.selectedRow) ? visible[table.selectedRow] : nil }
    var activate: ((ClassicRow) -> Void)?
    var selectionChanged: ((ClassicRow?) -> Void)?
    private let key: String
    private let preferences: ClassicPreferences
    private let kind: ClassicListKind
    private(set) var userRowSize: ClassicUserRowSize = .compact
    private(set) var fileRowSize: ClassicFileRowSize = .compact
    private var restoring = true
    private var restoringSelection = false
    private var filterHeight: NSLayoutConstraint!
    private var filterGap: NSLayoutConstraint!
    var isFiltering: Bool { !filter.isHidden }
    init(columns: [String], key: String, preferences: ClassicPreferences, kind: ClassicListKind = .plain) {
        self.key = key; self.preferences = preferences; self.kind = kind; super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        filter.delegate = self; filter.font = ClassicStyle.shared.font; filter.isHidden = true
        filter.setAccessibilityLabel("Filter list")
        table.setAccessibilityHelp("Type to filter this list. Escape clears the filter.")
        filter.translatesAutoresizingMaskIntoConstraints = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        let scrollFrame = ClassicFieldFrame(scroll)
        addSubview(filter); addSubview(scrollFrame)
        table.headerView = ClassicTableHeaderView(frame:NSRect(x:0,y:0,width:0,height:HAPTableHeaderDrawing.height))
        table.headerView?.setAccessibilityHelp("Click a column to sort. Use its context menu to move the column left or right.")
        table.dataSource = self; table.delegate = self; table.style = .plain; table.rowHeight = 19; table.intercellSpacing = NSSize(width: 3, height: 1)
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.usesAlternatingRowBackgroundColors = false; table.allowsColumnReordering = true; table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.target = self; table.doubleAction = #selector(doubleClick)
        for (i, name) in columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(i))); column.title = name
            column.headerCell = ClassicTableHeaderCell(textCell:name); column.headerCell.alignment = .center
            column.width = preferences.defaults.double(forKey: "column.\(key).\(i)")
            if column.width < 40 { column.width = i == 0 ? 180 : 130 }
            column.minWidth = 40; column.sortDescriptorPrototype = NSSortDescriptor(key: String(i), ascending: true)
            table.addTableColumn(column)
        }
        if let order = preferences.defaults.array(forKey: "column-order."+key) as? [String] {
            for (destination, id) in order.enumerated() where destination < table.tableColumns.count {
                if let source = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) { table.moveColumn(source, toColumn: destination) }
            }
        }
        if let sort = preferences.defaults.string(forKey: "sort."+key) { table.sortDescriptors = [NSSortDescriptor(key: sort, ascending: !preferences.defaults.bool(forKey: "descending."+key))] }
        table.beginFiltering = { [weak self] event in self?.beginFiltering(with:event) ?? false }
        table.filterCommand = { [weak self] event in
            guard let self, self.isFiltering, event.keyCode == 53, event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty else { return false }
            self.clearFilter(); return true
        }
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        filterHeight = filter.heightAnchor.constraint(equalToConstant:0)
        filterGap = scrollFrame.bottomAnchor.constraint(equalTo:filter.topAnchor)
        NSLayoutConstraint.activate([filter.bottomAnchor.constraint(equalTo:bottomAnchor), filter.leadingAnchor.constraint(equalTo:leadingAnchor), filter.trailingAnchor.constraint(equalTo:trailingAnchor), filterHeight, scrollFrame.topAnchor.constraint(equalTo:topAnchor), filterGap, scrollFrame.leadingAnchor.constraint(equalTo:leadingAnchor), scrollFrame.trailingAnchor.constraint(equalTo:trailingAnchor)])
        restoring = false; applyStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func refreshHeaders() {
        for column in table.tableColumns {
            (column.headerCell as? ClassicTableHeaderCell)?.sorted = table.sortDescriptors.first?.key == column.identifier.rawValue
            column.headerCell.font = ClassicStyle.shared.font
        }
        table.headerView?.needsDisplay = true
    }
    func applyStyle() {
        let selection = selectedIDs
        userRowSize = kind == .users && !preferences.smallUserIcons ? .normal : .compact
        fileRowSize = preferences.smallFileIcons ? .compact : .normal
        table.rowHeight = kind == .files ? fileRowSize.rowHeight : userRowSize.rowHeight
        filter.applyStyle()
        scroll.applyStyle()
        updateFilterLayout()
        table.backgroundColor = ClassicStyle.shared.color(15); table.gridColor = ClassicStyle.shared.color(20)
        scroll.lineScroll = table.rowHeight+table.intercellSpacing.height
        refreshHeaders(); reloadTable(preserving:selection)
    }
    func reload() {
        let selection = selectedIDs
        visible = rows.filter { filterQuery.isEmpty || $0.values.joined(separator: " ").localizedCaseInsensitiveContains(filterQuery) }
        if let sort = table.sortDescriptors.first, let key = sort.key, let column = Int(key) {
            visible.sort { a,b in
                let x = a.values.indices.contains(column) ? a.values[column] : "", y = b.values.indices.contains(column) ? b.values[column] : ""
                let result = x.compare(y, options: [.caseInsensitive,.numeric])
                return sort.ascending ? result == .orderedAscending : result == .orderedDescending
            }
        }
        reloadTable(preserving:selection)
    }
    private var selectedIDs: Set<String> {
        Set(table.selectedRowIndexes.compactMap { visible.indices.contains($0) ? visible[$0].id : nil })
    }
    private func reloadTable(preserving selection: Set<String>) {
        // Row indices may now belong to different files, groups or recipients.
        // Restore every surviving identity before allowing selection actions.
        // Merely sorting or restyling must not initiate another tracker query.
        restoringSelection = true
        table.reloadData()
        table.selectRowIndexes(IndexSet(visible.indices.filter { selection.contains(visible[$0].id) }),byExtendingSelection:false)
        restoringSelection = false
        if selectedIDs != selection { selectionChanged?(selected) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ClassicTableRowView(); view.userAdornment = visible[row].userAdornment
        view.userRowSize = userRowSize
        return view
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let column = Int(tableColumn?.identifier.rawValue ?? "0") ?? 0
        if kind == .transfers, column == 4, let progress = visible[row].progress {
            return ClassicProgressView(progress:progress)
        }
        let text = ClassicListTextField(labelWithString: visible[row].values.indices.contains(column) ? visible[row].values[column] : "")
        text.font = ClassicStyle.shared.font; text.textColor = ClassicStyle.shared.color(16); text.lineBreakMode = .byTruncatingTail
        if column == 0, let adornment = visible[row].userAdornment {
            return ClassicUserCell(text:text,adornment:adornment,rowSize:userRowSize)
        }
        if column == 0, let id = visible[row].iconID {
            if kind == .files { return ClassicFileCell(text:text,iconID:id,rowSize:fileRowSize) }
            let icon = ClassicIconView(); icon.iconID = id
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant:16),icon.heightAnchor.constraint(equalToConstant:16)])
            let container = NSStackView(views:[icon,text]); container.spacing = 4; container.alignment = .centerY
            return container
        }
        return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !restoringSelection { selectionChanged?(selected) }
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        refreshHeaders()
        if !restoring, let sort = table.sortDescriptors.first { preferences.defaults.set(sort.key, forKey: "sort."+key); preferences.defaults.set(!sort.ascending, forKey: "descending."+key) }; reload()
    }
    func tableViewColumnDidResize(_ notification: Notification) { saveColumns() }
    func tableViewColumnDidMove(_ notification: Notification) { saveColumns() }
    private func saveColumns() {
        guard !restoring else { return }
        for column in table.tableColumns { preferences.defaults.set(column.width, forKey: "column.\(key).\(column.identifier.rawValue)") }
        preferences.defaults.set(table.tableColumns.map(\.identifier.rawValue), forKey: "column-order."+key)
    }
    func showFilter() {
        filter.isHidden = false; updateFilterLayout()
    }
    private func updateFilterLayout() {
        filterHeight.constant = isFiltering ? max(22,filter.intrinsicContentSize.height) : 0
        filterGap.constant = isFiltering ? -6 : 0
    }
    private func beginFiltering(with event: NSEvent) -> Bool {
        let wasFiltering = isFiltering
        showFilter(); layoutSubtreeIfNeeded()
        guard window?.makeFirstResponder(filter) == true, let editor = filter.currentEditor() as? NSTextView else {
            if !wasFiltering { filter.isHidden = true; updateFilterLayout() }
            return false
        }
        editor.setSelectedRange(NSRange(location:(editor.string as NSString).length,length:0))
        editor.interpretKeyEvents([event])
        return true
    }
    func clearFilter() {
        // Escape while composing is handled by the input method before this
        // command reaches us. Never discard active marked text here.
        if (filter.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
        window?.makeFirstResponder(table)
        filter.stringValue = ""; filterQuery = ""; filter.isHidden = true; updateFilterLayout(); reload()
    }
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as AnyObject? === filter else { return }
        let editor = obj.userInfo?["NSFieldEditor"] as? NSTextView ?? filter.currentEditor() as? NSTextView
        // Keep composition visible, but filter on committed text only.
        guard editor?.hasMarkedText() != true else { return }
        filterQuery = filter.stringValue
        if filter.stringValue.isEmpty { clearFilter() } else { reload() }
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as AnyObject? === filter else { return }
        let editor = obj.userInfo?["NSFieldEditor"] as? NSTextView
        guard editor?.hasMarkedText() != true else { return }
        filterQuery = filter.stringValue
        if filterQuery.isEmpty { filter.isHidden = true; updateFilterLayout() }
        reload()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === filter, !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            clearFilter(); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            window?.makeFirstResponder(table)
            if !visible.isEmpty {
                let upward = commandSelector == #selector(NSResponder.moveUp(_:))
                let row = table.selectedRow
                let selected: Int
                if row < 0 { selected = upward ? visible.count-1 : 0 }
                else if commandSelector == #selector(NSResponder.insertNewline(_:)) { selected = row }
                else { selected = min(visible.count-1,max(0,row+(upward ? -1 : 1))) }
                table.selectRowIndexes(IndexSet(integer:selected),byExtendingSelection:false)
                table.scrollRowToVisible(selected)
            }
            return true
        default: return false
        }
    }
    @objc private func doubleClick() { if let selected { activate?(selected) } }
}

@MainActor final class ClassicLabelField: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        if font?.fontName.hasPrefix("KDXImported-") == true { NSGraphicsContext.current?.shouldAntialias = false }
        super.draw(dirtyRect)
    }
}
@MainActor func classicLabel(_ text: String) -> NSTextField {
    let label = ClassicLabelField(labelWithString: text); label.font = ClassicStyle.shared.font; label.textColor = ClassicStyle.shared.color(5); return label
}
@MainActor func classicField(_ value: String = "", placeholder: String = "") -> NSTextField {
    let field = ClassicTextField(); field.stringValue = value; field.placeholderString = placeholder; field.font = ClassicStyle.shared.font
    field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true; return field
}
@MainActor func classicRow(_ views: [NSView]) -> NSStackView {
    let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 6; row.alignment = .centerY; return row
}
@MainActor func classicColumn(_ views: [NSView]) -> NSStackView {
    let column = NSStackView(views: views); column.orientation = .vertical; column.spacing = 6; column.alignment = .leading; column.distribution = .fill
    for view in views { view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
    return column
}

@MainActor final class ClassicMenuAction: NSObject {
    let action: () -> Void
    let iconID: Int?
    init(_ action: @escaping () -> Void, iconID: Int? = nil) { self.action = action; self.iconID = iconID }
    @objc func run() { action() }
}
@MainActor func menuItem(_ title: String, key: String = "", iconID: Int? = nil, action: @escaping () -> Void) -> NSMenuItem {
    let handler = ClassicMenuAction(action,iconID:iconID), item = NSMenuItem(title: title, action: #selector(ClassicMenuAction.run), keyEquivalent: key)
    item.target = handler; item.representedObject = handler
    // Native menu presentations can still use an image. The themed item view
    // resolves the retained ID at draw time, including after appearance changes.
    if let iconID, let bitmap = ClassicStyle.shared.artwork?.icon(iconID,small:true), let image = bitmap.cgImage() {
        item.image = NSImage(cgImage:image,size:NSSize(width:bitmap.width,height:bitmap.height))
    }
    return item
}
