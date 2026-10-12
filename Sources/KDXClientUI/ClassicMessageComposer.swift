import AppKit
import KDXCore

/// The original multiline composer uses Return for a newline and keypad Enter
/// for its default action. Keep marked text with AppKit's input method.
@MainActor final class ClassicMessageInput: ClassicTextView {
    var send: (() -> Void)?
    var cancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() {
            if event.keyCode == 76 { send?(); return }
            if event.keyCode == 53 { cancel?(); return }
        }
        super.keyDown(with:event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Don't let a default button consume Return before the native editor.
        if event.keyCode == 36 && event.modifierFlags.intersection([.command,.control,.option]).isEmpty { return false }
        return super.performKeyEquivalent(with:event)
    }
}

@MainActor final class ClassicMessageRecipientView: ClassicSurface {
    private(set) var profile = KDXUser(id:0,nickname:"")
    private var cell: ClassicUserCell?
    func update(_ user: KDXUser) {
        guard cell == nil || user != profile else { return }
        profile = user; cell?.removeFromSuperview()
        let text = ClassicListTextField(labelWithString:user.nickname)
        text.lineBreakMode = .byTruncatingTail; text.font = ClassicStyle.shared.font
        text.textColor = HAPUserRowDrawing.textColor(ClassicUserAdornment(user:user),selected:false,emphasized:false)
        let view = ClassicUserCell(text:text,adornment:ClassicUserAdornment(user:user),rowSize:.normal)
        cell = view; addSubview(view); needsLayout = true; needsDisplay = true
        setAccessibilityLabel("Recipient: \(user.nickname)")
    }
    func applyStyle() {
        cell?.text.font = ClassicStyle.shared.font
        cell?.text.textColor = HAPUserRowDrawing.textColor(ClassicUserAdornment(user:profile),selected:false,emphasized:false)
        cell?.needsLayout = true; needsDisplay = true
    }
    override func layout() { super.layout(); cell?.frame = bounds }
    override func draw(_ dirtyRect: NSRect) {
        HAPUserRowDrawing.background(bounds,profile:ClassicUserAdornment(user:profile),selected:false,emphasized:false,dirtyRect:dirtyRect,size:.normal)
    }
}

/// Control rectangles in the 1.600 constructor at PPC 0x265A0…0x26898.
@MainActor final class ClassicMessageComposerForm: ClassicSurface {
    static let referenceSize = NSSize(width:340,height:336)
    let heading = classicLabel("Send Private Message To:")
    let recipient = ClassicMessageRecipientView()
    let serverLabel = classicLabel("At Server:"), server = classicLabel("")
    let input = ClassicMessageInput()
    let scroll = ClassicScrollView()
    let entry: ClassicFieldFrame
    let send = ClassicButton("Send",height:26) {}
    let cancel = ClassicButton("Cancel",key:"\u{1b}",height:20) {}
    override init(frame: NSRect) {
        scroll.documentView = input; scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = .init(); scroll.scrollerInsets = .init()
        entry = ClassicFieldFrame(scroll)
        super.init(frame:frame)
        input.isRichText = false; input.allowsUndo = true
        input.isVerticallyResizable = true; input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]; input.minSize = .zero
        input.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        input.textContainer?.widthTracksTextView = true
        input.setAccessibilityLabel("Private message")
        server.lineBreakMode = .byTruncatingTail; server.setAccessibilityLabel("Server")
        // Enter is the default action, while Return belongs to the multiline editor.
        send.keyEquivalent = "\u{3}"; send.toolTip = "Send private message (Enter)"
        layout() // Give frame-based children real sizes before AppKit creates mask constraints.
        for view in [heading,recipient,serverLabel,server,entry,send,cancel] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = true }
        input.nextKeyView = send; send.nextKeyView = cancel; cancel.nextKeyView = input
        input.send = { [weak self] in self?.send.performClick(nil) }
        input.cancel = { [weak self] in self?.cancel.performClick(nil) }
        applyStyle()
    }
    convenience init() { self.init(frame:NSRect(origin:.zero,size:Self.referenceSize)) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let dx = bounds.width-340, dy = bounds.height-336
        heading.frame = NSRect(x:10,y:10,width:200,height:16)
        recipient.frame = NSRect(x:10,y:30,width:320+dx,height:32)
        serverLabel.frame = NSRect(x:10,y:64,width:80,height:16)
        server.frame = NSRect(x:100,y:64,width:230+dx,height:16)
        entry.frame = NSRect(x:10,y:90,width:320+dx,height:200+dy)
        send.frame = NSRect(x:210+dx,y:300+dy,width:86,height:26)
        cancel.frame = NSRect(x:110+dx,y:303+dy,width:80,height:20)
    }
    func applyStyle() {
        HAPFieldDrawing.configureEditor(input); recipient.applyStyle(); scroll.applyStyle()
        for label in [heading,serverLabel,server] { label.font = ClassicStyle.shared.font; label.textColor = ClassicStyle.shared.color(5) }
        needsLayout = true; needsDisplay = true
    }
    override func cancelOperation(_ sender: Any?) { cancel.performClick(sender) }
}

@MainActor final class ClassicMessageComposerWindow: ClassicWindowController, NSTextViewDelegate {
    let session: ClassicSession
    let recipientID: UInt32
    let generation: UUID
    let form = ClassicMessageComposerForm()
    var sent: (() -> Void)?
    private(set) var isSending = false
    private var profile: KDXUser
    private var frameInsets = NSSize(width:12,height:28)
    var draftKey: ClassicWindowKind { .composeMessage(recipientID) }
    var isCurrentConnection: Bool { generation == session.privateMessages.generation }
    init(session: ClassicSession, user: UInt32, preferences: ClassicPreferences) {
        self.session = session; recipientID = user; generation = session.privateMessages.generation
        profile = session.client.users.first { $0.id == user } ?? session.privateMessages.profiles[user] ?? KDXUser(id:user,nickname:"User \(user)")
        super.init(title:"Message To: \(profile.nickname)",key:"send-message",size:NSSize(width:352,height:364),preferences:preferences)
        form.input.string = session.drafts[draftKey] ?? ""; form.input.delegate = self
        form.send.invoke = { [weak self] in self?.sendText() }
        form.cancel.invoke = { [weak self] in self?.cancelMessage() }
        chrome.layoutSubtreeIfNeeded(); install(form)
        window?.initialFirstResponder = form.input
        observation.start { [weak self] in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        let user = isCurrentConnection ? session.client.users.first { $0.id == recipientID } : nil
        if let user { profile = user }
        form.recipient.update(profile)
        title = "Message To: \(profile.nickname) — \(session.title)"
        form.server.stringValue = !isCurrentConnection ? "Connection changed" : session.title+(user == nil || !session.client.isConnected ? " (disconnected)" : "")
        form.server.toolTip = !isCurrentConnection ? "Reopen Send Message from the current user list." : form.server.stringValue
        form.input.isEditable = isCurrentConnection
        let bytes = form.input.string.utf8.count
        form.send.isEnabled = isCurrentConnection && session.client.isConnected && user != nil && !isSending && (1...4096).contains(bytes)
        form.send.toolTip = bytes > 4096 ? "Message is \(bytes) UTF-8 bytes; the maximum is 4096." : "Send private message (Enter)"
        form.send.setAccessibilityHelp(form.send.toolTip)
    }
    func textDidChange(_ notification: Notification) {
        if isCurrentConnection { session.drafts[draftKey] = form.input.string }
        refresh()
    }
    func sendText() {
        guard !form.input.hasMarkedText(), form.send.isEnabled, !isSending else { return }
        run("send-message") { [weak self] in
            guard let self else { return }
            if try await sendMessage() { requestClose() }
        }
    }
    /// Returns true only when the captured draft was sent and is still current.
    /// Kept separate from closing the window for headless transport verification.
    func sendMessage() async throws -> Bool {
        guard isCurrentConnection else { throw KDXError.invalid("The connection changed. Reopen Send Message from the current user list.") }
        guard !isSending else { return false }
        guard session.client.isConnected, session.client.users.contains(where: { $0.id == recipientID }) else { throw KDXError.disconnected }
        let text = form.input.string
        guard (1...4096).contains(text.utf8.count) else { throw KDXError.invalid("Message must contain 1–4096 UTF-8 bytes.") }
        session.drafts[draftKey] = text
        isSending = true; refresh(); defer { isSending = false; refresh() }
        try Task.checkCancellation()
        try await session.sendPrivate(to:recipientID,text:text,generation:generation)
        guard isCurrentConnection else { return false }
        session.privateMessages.update(session.client.chat,users:session.client.users,activeRecipient:nil)
        session.privateMessages.acknowledgeAttention(); sent?()
        guard form.input.string == text, session.drafts[draftKey] == text else { return false }
        session.drafts.removeValue(forKey:draftKey); form.input.string = ""
        return !Task.isCancelled
    }
    func cancelMessage() {
        if isCurrentConnection { session.drafts.removeValue(forKey:draftKey) }
        form.input.string = ""; requestClose()
    }
    override func applyStyle() {
        super.applyStyle(); form.applyStyle()
        let probe = NSRect(x:0,y:0,width:1000,height:1000), content = HAPWindowDrawing.contentRect(in:probe)
        let insets = NSSize(width:probe.width-content.width,height:probe.height-content.height)
        if let window {
            window.minSize = NSSize(width:280+insets.width,height:200+insets.height)
            if insets != frameInsets {
                let old = window.frame, size = NSSize(width:old.width+insets.width-frameInsets.width,height:old.height+insets.height-frameInsets.height)
                window.setFrame(NSRect(x:old.minX,y:old.maxY-size.height,width:size.width,height:size.height),display:false)
            }
        }
        frameInsets = insets
    }
}
