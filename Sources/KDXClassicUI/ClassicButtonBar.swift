import AppKit

/// VWIN maan / mnsm control rectangles, in content coordinates.
enum ClassicBarAction: CaseIterable {
    case commands, connect, addressBook, messages, transfers, files, chat, news, users, exit
    var title: String {
        switch self {
        case .commands: "Commands"
        case .connect: "Connect…"
        case .addressBook: "Address Book"
        case .messages: "Messages"
        case .transfers: "File Transfers"
        case .files: "File Browser"
        case .chat: "Chat"
        case .news: "News"
        case .users: "User List"
        case .exit: "Exit"
        }
    }
    var iconID: Int {
        switch self {
        case .commands: 73
        case .connect: 84
        case .addressBook: 78
        case .messages: 89
        case .transfers: 86
        case .files: 93
        case .chat: 88
        case .news: 87
        case .users: 90
        case .exit: 74
        }
    }
    func rect(compact: Bool) -> NSRect {
        let index = Self.allCases.firstIndex(of:self)!
        if compact { return NSRect(x:index == 0 ? 156 : 195+29*(index-1),y:5,width:index == 0 ? 40 : 30,height:30) }
        return NSRect(x:4,y:index == 0 ? 44 : 71+21*(index-1),width:144,height:index == 0 ? 28 : 22)
    }
}

@MainActor final class ClassicButtonBarView: ClassicSurface {
    static func referenceSize(compact: Bool) -> NSSize { NSSize(width:compact ? 520 : 152,height:compact ? 40 : 282) }
    let compact: Bool
    private let picker: ClassicPopUpButton
    private let status: NSTextField
    private var pickerConstraints: [NSLayoutConstraint] = []
    private var serverBanner: HAPBitmap?
    private var blinkTask: Task<Void,Never>?
    private(set) var isBlinking = false
    private(set) var lightState: HAPWonderLightState = .idle
    let buttons: [ClassicButton]
    let connectionCount = classicLabel("0"), transferCount = classicLabel("0")
    let connectionIcon = ClassicIconView(), transferIcon = ClassicIconView()
    init(compact: Bool, picker: ClassicPopUpButton, status: NSTextField, buttons: [ClassicButton]) {
        precondition(buttons.count == ClassicBarAction.allCases.count)
        self.compact = compact; self.buttons = buttons
        self.picker = picker; self.status = status
        super.init(frame:NSRect(origin:.zero,size:Self.referenceSize(compact:compact)))
        func place(_ view: NSView, _ rect: NSRect) {
            addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
            let inset = view.alignmentRectInsets
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo:leadingAnchor,constant:rect.minX+inset.left),
                view.topAnchor.constraint(equalTo:topAnchor,constant:rect.minY+inset.top),
                view.widthAnchor.constraint(equalToConstant:rect.width-inset.left-inset.right),
                view.heightAnchor.constraint(equalToConstant:rect.height-inset.top-inset.bottom)
            ])
        }
        // Keep native selection/keyboard/AX under the original banner artwork.
        addSubview(picker); picker.translatesAutoresizingMaskIntoConstraints = false
        place(status,NSRect(x:4,y:23,width:144,height:16))
        status.lineBreakMode = .byTruncatingTail
        for (action,button) in zip(ClassicBarAction.allCases,buttons) {
            let tip = button.toolTip
            button.iconOnly = compact
            if action == .messages { button.wonderLight = .idle }
            if let tip { button.toolTip = tip }
            place(button,action.rect(compact:compact))
        }
        connectionIcon.iconID = 84; transferIcon.iconID = 86
        connectionIcon.setAccessibilityElement(false); transferIcon.setAccessibilityElement(false)
        place(connectionIcon,compact ? NSRect(x:463,y:3,width:16,height:16) : NSRect(x:20,y:264,width:16,height:16))
        place(transferIcon,compact ? NSRect(x:463,y:21,width:16,height:16) : NSRect(x:80,y:264,width:16,height:16))
        // The original compact label records extend to x=538, beyond its 520px
        // content width. Limit these native fields to the visible content area.
        place(connectionCount,compact ? NSRect(x:483,y:3,width:37,height:16) : NSRect(x:40,y:264,width:32,height:16))
        place(transferCount,compact ? NSRect(x:483,y:21,width:37,height:16) : NSRect(x:100,y:264,width:32,height:16))
        connectionCount.setAccessibilityLabel("Connections"); transferCount.setAccessibilityLabel("Active transfers")
        setAccessibilityLabel("Button Bar")
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func applyStyle() {
        picker.banner = serverBanner ?? (try? ClassicStyle.shared.chromeArtwork?.banner?.bitmap())
        status.isHidden = picker.banner != nil
        let rect = picker.banner != nil ? NSRect(x:0,y:0,width:152,height:40) : NSRect(x:4,y:2,width:144,height:20)
        let inset = picker.alignmentRectInsets
        NSLayoutConstraint.deactivate(pickerConstraints)
        pickerConstraints = [
            picker.leadingAnchor.constraint(equalTo:leadingAnchor,constant:rect.minX+inset.left),
            picker.topAnchor.constraint(equalTo:topAnchor,constant:rect.minY+inset.top),
            picker.widthAnchor.constraint(equalToConstant:rect.width-inset.left-inset.right),
            picker.heightAnchor.constraint(equalToConstant:rect.height-inset.top-inset.bottom)
        ]
        NSLayoutConstraint.activate(pickerConstraints)
    }
    func updateBanner(_ banner: HAPBitmap?) {
        guard serverBanner != banner else { return }
        serverBanner = banner; applyStyle()
    }
    func updateUnreadMessages(_ count: Int) {
        guard let index = ClassicBarAction.allCases.firstIndex(of:.messages) else { return }
        let button = buttons[index]
        button.title = "Messages"
        button.toolTip = count > 0 ? "Messages — \(count) conversations with unread messages" : "Messages"
        button.setAccessibilityLabel(button.toolTip)
        button.needsDisplay = true
    }
    func updateMessageAlert(_ blinking: Bool) {
        guard isBlinking != blinking else { return }
        isBlinking = blinking; setLight(blinking ? .red : .idle)
        restartBlinking()
    }
    private func setLight(_ state: HAPWonderLightState) {
        lightState = state
        buttons[ClassicBarAction.allCases.firstIndex(of:.messages)!].wonderLight = state
    }
    func advanceLight() {
        guard isBlinking else { return }
        setLight(lightState == .red ? .amber : .red)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); restartBlinking() }
    private func restartBlinking() {
        blinkTask?.cancel(); blinkTask = nil
        guard isBlinking, window != nil else { return }
        blinkTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(1)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.advanceLight()
            }
        }
    }
    deinit { blinkTask?.cancel() }
    func updateCounts(connections: Int, transfers: Int) {
        connectionCount.stringValue = String(connections); transferCount.stringValue = String(transfers)
        connectionCount.toolTip = "\(connections) connections"; transferCount.toolTip = "\(transfers) active transfers"
    }
}

@MainActor final class ClassicButtonBarWindow: ClassicWindowController {
    let compact: Bool
    init(title: String, compact: Bool, preferences: ClassicPreferences) {
        self.compact = compact
        let size = ClassicButtonBarView.referenceSize(compact:compact)
        super.init(title:title,key:compact ? "button-bar.compact" : "button-bar",size:NSSize(width:size.width+12,height:size.height+28),preferences:preferences,minimumFrameSize:NSSize(width:1,height:1))
        window?.level = .floating; chrome.allowsResize = false
        if let maximize = windowMenu.item(withTitle:"Maximize / Restore") { windowMenu.removeItem(maximize) }
        fitBar()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func applyStyle() { super.applyStyle(); fitBar() }
    override func maximize() { fitBar() }
    private func fitBar() {
        guard let window else { return }
        let probe = NSRect(x:0,y:0,width:1000,height:1000), content = HAPWindowDrawing.contentRect(in:probe)
        let reference = ClassicButtonBarView.referenceSize(compact:compact)
        let size = NSSize(width:reference.width+probe.width-content.width,height:reference.height+probe.height-content.height)
        window.minSize = .zero; window.maxSize = size; window.minSize = size
        let old = window.frame, frame = NSRect(x:old.minX,y:old.maxY-size.height,width:size.width,height:size.height)
        window.setFrame(ClassicPreferences.constrain(frame,to:NSScreen.screens.map(\.visibleFrame),fallback:frame,minimumSize:NSSize(width:1,height:1)),display:false)
    }
}
