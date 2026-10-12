import AppKit

struct ClassicDialogField: Equatable {
    let id: String
    let label: String
    var value = ""
    var secure = false
}

@MainActor final class ClassicDialogRequest {
    let id = UUID()
    let title: String
    let message: String
    private(set) var fields: [ClassicDialogField]
    let acceptTitle: String
    let cancelTitle: String?
    private var completion: (([String:String]?) -> Void)?
    init(title: String, message: String = "", fields: [ClassicDialogField] = [], acceptTitle: String = "OK", cancelTitle: String? = "Cancel", completion: @escaping ([String:String]?) -> Void = { _ in }) {
        self.title = title; self.message = message; self.fields = fields
        self.acceptTitle = acceptTitle; self.cancelTitle = cancelTitle; self.completion = completion
    }
    func resolve(_ values: [String:String]?) {
        let callback = completion; completion = nil
        for index in fields.indices where fields[index].secure { fields[index].value = "" }
        callback?(values)
    }
}

/// One queue per owning window. Stale responses never complete another request.
/// Invalidation cancels pending forms exactly once and rejects reentrant enqueues.
@MainActor final class ClassicDialogQueue {
    private var requests: [ClassicDialogRequest] = []
    private(set) var isClosed = false
    var active: ClassicDialogRequest? { requests.first }
    var changed: (() -> Void)?
    func enqueue(_ request: ClassicDialogRequest) {
        guard !isClosed else { request.resolve(nil); return }
        requests.append(request); changed?()
    }
    func complete(id: UUID, values: [String:String]?) {
        guard active?.id == id else { return }
        let request = requests.removeFirst()
        request.resolve(values); changed?()
    }
    func invalidate() {
        guard !isClosed else { return }
        isClosed = true
        let pending = requests; requests.removeAll()
        pending.forEach { $0.resolve(nil) }; changed?()
    }
}

/// A bounded, scrollable message and native editors, drawn with the current HAP.
/// Layout is an AppKit adaptation; exact original dialog templates are not decoded.
@MainActor final class ClassicDialogContent: ClassicSurface {
    let request: ClassicDialogRequest
    let message = ClassicLabelField(wrappingLabelWithString:"")
    let messageScroll = ClassicScrollView()
    let accept: ClassicButton
    let cancel: ClassicButton?
    private(set) var fields: [String:NSTextField] = [:]
    private var labels: [NSTextField] = []
    var respond: ((Bool) -> Void)?
    var values: [String:String] { fields.mapValues(\.stringValue) }
    var firstEditor: NSTextField? { request.fields.first.flatMap { fields[$0.id] } }

    init(request: ClassicDialogRequest) {
        self.request = request
        accept = ClassicButton(request.acceptTitle,key:"\r") {}
        cancel = request.cancelTitle.map { title in ClassicButton(title,key:"\u{1b}") {} }
        super.init(frame:.zero)
        message.stringValue = request.message; message.isSelectable = true
        messageScroll.documentView = message; messageScroll.hasVerticalScroller = true
        messageScroll.autohidesScrollers = true
        messageScroll.hasHorizontalScroller = false; messageScroll.drawsBackground = false
        addSubview(messageScroll)
        for specification in request.fields {
            let field: NSTextField = specification.secure ? ClassicSecureTextField() : ClassicTextField()
            field.stringValue = specification.value; field.setAccessibilityLabel(specification.label)
            fields[specification.id] = field
            let label = classicLabel(specification.label); labels.append(label)
            addSubview(label); addSubview(field)
        }
        for button in [accept,cancel].compactMap({ $0 }) {
            button.translatesAutoresizingMaskIntoConstraints = true
            button.frame = NSRect(x:0,y:0,width:80,height:24)
            addSubview(button)
        }
        accept.invoke = { [weak self] in self?.respond?(true) }
        cancel?.invoke = { [weak self] in self?.respond?(false) }
        var controls: [NSView] = request.fields.compactMap { fields[$0.id] }
        controls += [accept]; if let cancel { controls.append(cancel) }
        for index in controls.indices { controls[index].nextKeyView = controls[(index+1)%controls.count] }
        refreshStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func cancelOperation(_ sender: Any?) { respond?(false) }
    private func messageHeight(width: CGFloat) -> CGFloat {
        guard !request.message.isEmpty else { return 0 }
        let font = ClassicStyle.shared.font
        let bounds = NSRect(x:0,y:0,width:max(40,width),height:CGFloat.greatestFiniteMagnitude)
        let height = message.cell?.cellSize(forBounds:bounds).height ?? font.ascender-font.descender
        return max(ceil(font.ascender-font.descender),ceil(height)+4)
    }
    var preferredSize: NSSize {
        NSSize(width:420,height:32+CGFloat(request.fields.count)*52+min(220,messageHeight(width:378))+(request.message.isEmpty ? 0 : 12)+30)
    }
    func refreshStyle() {
        message.font = ClassicStyle.shared.font; message.textColor = ClassicStyle.shared.color(5)
        messageScroll.applyStyle(); messageScroll.drawsBackground = false
        for label in labels { label.font = ClassicStyle.shared.font; label.textColor = ClassicStyle.shared.color(5) }
        for field in fields.values {
            (field as? ClassicTextField)?.applyStyle(); (field as? ClassicSecureTextField)?.applyStyle()
        }
        accept.font = ClassicStyle.shared.font; cancel?.font = ClassicStyle.shared.font
        needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout()
        let width = max(0,bounds.width-24), buttonY = max(12,bounds.height-36)
        let messageArea = max(0,buttonY-12-CGFloat(request.fields.count)*52-(request.message.isEmpty ? 0 : 12)-12)
        messageScroll.isHidden = request.message.isEmpty
        messageScroll.frame = NSRect(x:12,y:12,width:width,height:messageArea)
        message.frame = NSRect(x:0,y:0,width:max(40,width-18),height:messageHeight(width:width-18))
        var top: CGFloat = request.message.isEmpty ? 12 : messageScroll.frame.maxY+12
        for (index,specification) in request.fields.enumerated() {
            labels[index].frame = NSRect(x:12,y:top,width:width,height:20)
            fields[specification.id]?.frame = NSRect(x:12,y:top+21,width:width,height:24)
            top += 52
        }
        let acceptWidth = max(80,accept.intrinsicContentSize.width)
        accept.frame = NSRect(x:max(12,bounds.maxX-12-acceptWidth),y:buttonY,width:acceptWidth,height:24)
        if let cancel {
            let cancelWidth = max(80,cancel.intrinsicContentSize.width)
            cancel.frame = NSRect(x:max(12,accept.frame.minX-12-cancelWidth),y:buttonY,width:cancelWidth,height:24)
        }
    }
    func clearSensitiveValues() {
        for specification in request.fields where specification.secure {
            fields[specification.id]?.currentEditor()?.string = ""
            fields[specification.id]?.stringValue = ""
        }
    }
}

@MainActor final class ClassicDialogController: ClassicWindowController {
    let form: ClassicDialogContent
    var responseRequested: ((Bool) -> Void)?
    private var responded = false
    init(request: ClassicDialogRequest, preferences: ClassicPreferences) {
        form = ClassicDialogContent(request:request)
        let size = form.preferredSize
        super.init(title:request.title,key:"dialog",size:NSSize(width:size.width+12,height:size.height+28),preferences:preferences)
        chrome.isDialog = true; windowMenu.removeAllItems()
        window?.styleMask = [.borderless]
        window?.setAccessibilitySubrole(.dialog)
        install(form)
        window?.defaultButtonCell = form.accept.cell as? NSButtonCell
        window?.initialFirstResponder = form.firstEditor ?? form.accept
        form.respond = { [weak self] accepted in self?.requestResponse(accepted) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func requestResponse(_ accepted: Bool) {
        guard !responded else { return }; responded = true
        window?.makeFirstResponder(nil)
        responseRequested?(accepted)
    }
    override func requestClose() { requestResponse(false) }
    override func saveFrame() {} // Dialog geometry and passwords are never persisted.
    override func applyStyle() {
        super.applyStyle(); form.refreshStyle()
        let size = form.preferredSize
        let sample = NSRect(x:0,y:0,width:1000,height:1000), content = HAPWindowDrawing.contentRect(in:NSRect(x:0,y:0,width:1000,height:1000))
        window?.setContentSize(NSSize(width:size.width+sample.width-content.width,height:size.height+sample.height-content.height))
    }
}
