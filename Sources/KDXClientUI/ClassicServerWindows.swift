import AppKit
import KDXCore

@MainActor func serverWindowSize(_ content: NSSize) -> NSSize {
    let probe = NSRect(x:0,y:0,width:1000,height:1000), inner = HAPWindowDrawing.contentRect(in:probe)
    return NSSize(width:content.width+probe.width-inner.width,height:content.height+probe.height-inner.height)
}

@MainActor final class ClassicServerJournal: ClassicTextView {
    override func menu(for event: NSEvent) -> NSMenu? { menu }
    override func rightMouseDown(with event: NSEvent) {
        if !ClassicMenu.showContext(for:event,in:self) { super.rightMouseDown(with:event) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), ClassicMenu.showContext(for:event,in:self) { return }
        super.mouseDown(with:event)
    }
}

/// Original constructor 0x401000: a 550×240 text journal filling the content.
@MainActor final class ClassicServerConsole: ClassicWindowController {
    static let referenceSize = NSSize(width:550,height:240)
    let transcript = ClassicServerJournal()
    let scroll = ClassicScrollView()
    private var displayed = ""
    init(preferences: ClassicPreferences) {
        super.init(title:"KDX Server",key:"server-console",size:serverWindowSize(Self.referenceSize),preferences:preferences)
        window?.minSize = serverWindowSize(NSSize(width:150,height:70))
        transcript.isEditable = false; transcript.isSelectable = true; transcript.isRichText = false
        transcript.autoresizingMask = [.width]; transcript.minSize = .zero
        transcript.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        transcript.isVerticallyResizable = true; transcript.isHorizontallyResizable = false
        transcript.textContainer?.widthTracksTextView = true
        transcript.setAccessibilityLabel("Server activity")
        scroll.documentView = transcript; scroll.hasVerticalScroller = true
        install(scroll); window?.initialFirstResponder = transcript
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ model: ClassicServerModel) {
        let setup = model.tableReady ? "Use the window menu to start the server or change settings." : "Challenge table required. Choose Challenge Table… from the window menu."
        let log = model.server.log.map { "\($0.date.formatted(date:.omitted,time:.standard))  \($0.text)" }.joined(separator:"\n")
        var text = "KDX Server\n\(model.status)\n\(setup)\n"
        if !log.isEmpty { text += "\n"+log }
        if model.configuration.tracker.enabled { text += "\n\(model.server.trackerStatus)" }
        if let error = model.configurationError { text += "\nSettings could not be loaded: \(error)" }
        guard displayed != text else { return }
        let atBottom = transcript.bounds.height <= scroll.contentView.bounds.maxY+20
        displayed = text; transcript.string = text
        if atBottom { transcript.scrollToEndOfDocument(nil) }
    }
    override func applyStyle() {
        super.applyStyle()
        transcript.backgroundColor = ClassicStyle.shared.color(15); transcript.textColor = ClassicStyle.shared.color(16)
        transcript.insertionPointColor = ClassicStyle.shared.color(16)
        transcript.selectedTextAttributes = [.backgroundColor:ClassicStyle.shared.color(17),.foregroundColor:ClassicStyle.shared.color(18)]
    }
    override func requestClose() { minimize() }
}

/// VWIN stng at file offset 0x7da6c in the verified server. All primary controls
/// use the original rectangles. KDXCore multiplexes transfers on the main port;
/// its unsupported alternate/transfer listeners are shown disabled, never saved.
@MainActor final class ClassicServerLocalForm: ClassicSurface {
    static let referenceSize = NSSize(width:400,height:280)
    let login = ClassicTextField(), password = ClassicSecureTextField(), confirmation = ClassicSecureTextField()
    let port = ClassicTextField(), alternate = ClassicTextField(), transfer = ClassicTextField()
    let save = ClassicButton("Save",key:"\r",height:26) {}
    let cancel = ClassicButton("Cancel",key:"\u{1b}",height:20) {}
    private(set) var labels: [NSTextField] = []
    init(configuration: ServerConfiguration) {
        super.init(frame:NSRect(origin:.zero,size:Self.referenceSize))
        let admin = configuration.accounts.first { $0.effective(in:configuration.accountClasses).contains(0) }
        login.stringValue = admin?.login ?? ""; port.stringValue = String(configuration.port)
        if admin != nil { password.placeholderString = "Unchanged"; confirmation.placeholderString = "Unchanged" }
        for (view,rect,label) in [
            (login,NSRect(x:180,y:22,width:200,height:26),"Admin Login"),
            (password,NSRect(x:180,y:52,width:200,height:26),"Admin Password"),
            (confirmation,NSRect(x:180,y:82,width:200,height:26),"Confirm Password"),
            (port,NSRect(x:180,y:140,width:100,height:26),"Port Number"),
            (alternate,NSRect(x:180,y:170,width:100,height:26),"Alternate Port"),
            (transfer,NSRect(x:180,y:200,width:100,height:26),"File Transfer Port")
        ] { place(view,rect); view.setAccessibilityLabel(label) }
        for (title,y) in [("Admin Login:",27),("Admin Password:",57),("Confirm Password:",87),("Port Number:",145),("Alternate Port:",175),("File Transfer Port:",205)] {
            let label = classicLabel(title); place(label,NSRect(x:20,y:y,width:160,height:16)); labels.append(label)
        }
        for (view,text) in [(alternate,"Off"),(transfer,"Shared")] {
            view.stringValue = text; view.isEnabled = false
            view.toolTip = "This server uses Port Number for connections and file transfers. Separate listeners are not supported."
            view.setAccessibilityHelp(view.toolTip)
        }
        for y in [175,205] {
            let label = classicLabel("(unavailable)"); place(label,NSRect(x:290,y:y,width:100,height:16)); labels.append(label)
        }
        place(save,NSRect(x:290,y:246,width:96,height:26)); place(cancel,NSRect(x:166,y:249,width:90,height:20))
        let order: [NSView] = [login,password,confirmation,port,save,cancel]
        for i in order.indices { order[i].nextKeyView = order[(i+1)%order.count] }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func place(_ view: NSView, _ rect: NSRect) { view.translatesAutoresizingMaskIntoConstraints = true; view.frame = rect; addSubview(view) }
    func clearPasswords() { password.stringValue = ""; confirmation.stringValue = "" }
    func setEditable(_ value: Bool) { for control in [login,password,confirmation,port,save] as [NSControl] { control.isEnabled = value } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for rect in [NSRect(x:10,y:10,width:380,height:110),NSRect(x:10,y:130,width:380,height:110)] {
            ClassicStyle.shared.color(3).setStroke(); NSBezierPath(rect:rect.insetBy(dx:0.5,dy:0.5)).stroke()
            ClassicStyle.shared.color(1).setStroke(); NSBezierPath(rect:rect.insetBy(dx:1.5,dy:1.5)).stroke()
        }
    }
}

@MainActor final class ClassicServerLocalWindow: ClassicWindowController {
    let form: ClassicServerLocalForm
    init(model: ClassicServerModel, preferences: ClassicPreferences) {
        let base = model.configuration
        form = ClassicServerLocalForm(configuration:base)
        super.init(title:"KDX Server Local Settings",key:"server-local-settings",size:serverWindowSize(ClassicServerLocalForm.referenceSize),preferences:preferences)
        chrome.allowsResize = false
        form.save.invoke = { [weak self] in
            guard let self else { return }
            do {
                let candidate = try ClassicServerModel.localSettings(base,login:form.login.stringValue,password:form.password.stringValue,confirmation:form.confirmation.stringValue,port:form.port.stringValue)
                try model.save(candidate,replacing:base); form.clearPasswords(); requestClose()
            } catch { showError(error) }
        }
        form.cancel.invoke = { [weak self] in self?.requestClose() }
        install(form); window?.initialFirstResponder = form.login; window?.defaultButtonCell = form.save.cell as? NSButtonCell
        observation.start { [weak self] in self?.form.setEditable(model.editable) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func applyStyle() {
        super.applyStyle()
        guard let window else { return }
        let size = serverWindowSize(ClassicServerLocalForm.referenceSize), old = window.frame
        window.minSize = .zero; window.maxSize = size; window.minSize = size
        window.setFrame(NSRect(x:old.minX,y:old.maxY-size.height,width:size.width,height:size.height),display:false)
    }
    override func windowWillClose(_ notification: Notification) { form.clearPasswords(); super.windowWillClose(notification) }
}

/// Padded, scrollable forms for settings formerly in the SwiftUI inspector.
/// These additions intentionally live outside the original console/local form.
@MainActor class ClassicServerFormWindow: ClassicWindowController {
    private let scroll = ClassicScrollView()
    private let surface = ClassicSurface()
    private var column: NSStackView?
    var clearSecrets: (() -> Void)?
    init(title: String, key: String, size: NSSize, preferences: ClassicPreferences) {
        super.init(title:title,key:key,size:serverWindowSize(size),preferences:preferences)
        window?.minSize = serverWindowSize(NSSize(width:min(size.width,400),height:180))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setRows(_ rows: [NSView]) {
        let column = classicColumn(rows); self.column = column
        surface.addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = surface; scroll.hasVerticalScroller = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            surface.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),
            column.topAnchor.constraint(equalTo:surface.topAnchor,constant:10),
            column.leadingAnchor.constraint(equalTo:surface.leadingAnchor,constant:10),
            column.trailingAnchor.constraint(equalTo:surface.trailingAnchor,constant:-10),
            column.bottomAnchor.constraint(equalTo:surface.bottomAnchor,constant:-10)
        ])
        install(scroll)
    }
    override func windowWillClose(_ notification: Notification) { clearSecrets?(); super.windowWillClose(notification) }
}

@MainActor func serverFieldRow(_ label: String, _ field: NSView) -> NSView {
    let title = classicLabel(label); title.widthAnchor.constraint(equalToConstant:150).isActive = true
    field.setAccessibilityLabel(label)
    let row = classicRow([title,field]); field.setContentHuggingPriority(.defaultLow,for:.horizontal)
    return row
}

@MainActor func serverNote(_ text: String) -> NSTextField {
    let note = classicLabel(text); note.maximumNumberOfLines = 0; note.lineBreakMode = .byWordWrapping
    note.cell?.wraps = true; note.cell?.isScrollable = false
    return note
}

@MainActor final class ClassicServerEditor: ClassicSurface {
    let text = ClassicTextView()
    let scroll = ClassicScrollView()
    init(_ value: String, label: String, height: CGFloat) {
        super.init(frame:.zero)
        text.string = value; text.isRichText = false; text.allowsUndo = true
        text.autoresizingMask = [.width]; text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.minSize = .zero; text.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true; text.setAccessibilityLabel(label)
        scroll.documentView = text; scroll.hasVerticalScroller = true
        let frame = ClassicFieldFrame(scroll); addSubview(frame); frame.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant:height),frame.leadingAnchor.constraint(equalTo:leadingAnchor),frame.trailingAnchor.constraint(equalTo:trailingAnchor),frame.topAnchor.constraint(equalTo:topAnchor),frame.bottomAnchor.constraint(equalTo:bottomAnchor)])
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func applyStyle() { HAPFieldDrawing.configureEditor(text) }
}
