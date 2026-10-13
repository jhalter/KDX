import AppKit
import KDXCore

/// Recipient/read state belongs to a server session, not to whichever window has focus.
@MainActor final class ClassicPrivateMessagesState {
    private(set) var recipients = Set<UInt32>()
    private(set) var unread = Set<UInt32>()
    private(set) var selected: UInt32?
    private(set) var profiles: [UInt32:KDXUser] = [:]
    private var seen = Set<UUID>()
    private(set) var needsAttention = false
    private(set) var generation = UUID()
    func update(_ lines: [ChatLine], users: [KDXUser] = [], activeRecipient: UInt32?, windowIsFront: Bool = false) {
        let messages = lines.filter(\.isPrivate), ids = Set(messages.map(\.id))
        for line in messages where !seen.contains(line.id) {
            recipients.insert(line.userID)
            if profiles[line.userID] == nil && !line.isOutgoing { profiles[line.userID] = KDXUser(id:line.userID,nickname:line.sender) }
            if !line.isOutgoing && line.userID != activeRecipient { unread.insert(line.userID) }
            if line.isOutgoing { acknowledgeAttention() }
            else if !windowIsFront { needsAttention = true }
        }
        for user in users where recipients.contains(user.id) { profiles[user.id] = user }
        seen = ids
        if let activeRecipient { unread.remove(activeRecipient) }
    }
    func acknowledgeAttention() { needsAttention = false }
    func select(_ user: UInt32) { recipients.insert(user); selected = user; unread.remove(user) }
    func remove(_ user: UInt32) {
        recipients.remove(user); unread.remove(user); profiles.removeValue(forKey:user)
        if selected == user { selected = nil }
    }
    func reset() { generation = UUID(); recipients = []; unread = []; selected = nil; seen = []; profiles = [:]; needsAttention = false }
}

@MainActor final class PrivateMessagesWindowController: ClassicWindowController, NSTextViewDelegate {
    let session: ClassicSession
    let recipients: ClassicList
    let input = ChatInput(), transcript = ClassicTextView()
    let send = ClassicButton("Send") {}
    let recipientLabel = classicLabel("Select a recipient")
    var openUsers: (() -> Void)?
    var compose: ((UInt32) -> Void)?
    var readStateChanged: (() -> Void)?
    private(set) var selectedUser: UInt32?
    private var refreshing = false
    private var sending = Set<UInt32>()
    private var lastIDs: [UUID] = []
    private var sessionGeneration: UUID
    init(session: ClassicSession, preferences: ClassicPreferences, user: UInt32? = nil) {
        self.session = session; sessionGeneration = session.privateMessages.generation
        recipients = ClassicList(columns:["Name"],key:"message-recipients",preferences:preferences,kind:.users)
        super.init(title:"Private Messages — \(session.title)",key:"private-messages",size:NSSize(width:760,height:440),preferences:preferences)
        transcript.isEditable = false; transcript.isSelectable = true
        for editor in [transcript,input] {
            editor.isRichText = false; editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
            editor.autoresizingMask = [.width]; editor.minSize = .zero
            editor.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
            editor.textContainer?.widthTracksTextView = true
        }
        let history = ClassicScrollView(); history.documentView = transcript; history.hasVerticalScroller = true
        let entry = ClassicScrollView(); entry.documentView = input; entry.hasVerticalScroller = true
        for scroll in [history,entry,recipients.scroll] {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = .init(); scroll.scrollerInsets = .init()
        }
        let conversation = ClassicPaneSplitView(vertical:false,key:"private-input",preferences:preferences,portion:0.72,minimums:(106,54))
        conversation.addPane(ClassicFieldFrame(history)); conversation.addPane(ClassicFieldFrame(entry))
        let split = ClassicPaneSplitView(vertical:true,key:"private-recipients",preferences:preferences,portion:0.25,minimums:(140,250))
        split.addPane(recipients); split.addPane(conversation)
        recipientLabel.lineBreakMode = .byTruncatingTail
        recipientLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        input.delegate = self; input.send = { [weak self] in self?.sendText() }
        send.invoke = { [weak self] in self?.sendText() }
        recipients.selectionChanged = { [weak self] row in
            guard let self, !refreshing, let id = row.flatMap({ UInt32($0.id) }) else { return }
            select(id)
        }
        recipients.activate = { [weak self] row in
            guard let id = UInt32(row.id) else { return }; self?.select(id); self?.compose?(id)
        }
        let menu = ClassicMenu(title:"")
        menu.addItem(menuItem("Delete Messages") { [weak self] in
            guard let self, let id = recipients.selected.flatMap({ UInt32($0.id) }) else { return }; deleteMessages(with:id)
        })
        recipients.table.menu = menu
        let newMessage = ClassicButton("New Message…") { [weak self] in self?.openUsers?() }
        let actions = classicRow([newMessage,recipientLabel,send])
        actions.heightAnchor.constraint(equalToConstant:24).isActive = true
        split.setContentHuggingPriority(.defaultLow,for:.vertical)
        chrome.layoutSubtreeIfNeeded() // Establish content bounds before attaching the fixed-height action row.
        install(classicColumn([split,actions]))
        window?.minSize = NSSize(width:480,height:260)
        window?.initialFirstResponder = input
        session.privateMessages.update(session.client.chat,users:session.client.users,activeRecipient:nil)
        if let user = user ?? session.privateMessages.selected { select(user) }
        observation.start { [weak self] in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func select(_ user: UInt32) {
        if let previous = selectedUser { session.drafts[.privateMessage(previous)] = input.string }
        selectedUser = user; session.privateMessages.select(user)
        input.string = session.drafts[.privateMessage(user)] ?? ""
        lastIDs = []; transcript.string = ""; refresh(); readStateChanged?()
    }
    func refresh() {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        if sessionGeneration != session.privateMessages.generation {
            sessionGeneration = session.privateMessages.generation
            selectedUser = nil; input.string = ""; transcript.string = ""; lastIDs = []
        }
        session.privateMessages.update(session.client.chat,users:session.client.users,activeRecipient:window?.isKeyWindow == true ? selectedUser : nil,windowIsFront:window?.isKeyWindow == true)
        let unread = session.privateMessages.unread.count
        title = "Private Messages\(unread > 0 ? " [\(unread)]" : "") — \(session.title)"
        recipients.rows = session.privateMessages.recipients.sorted().map { id in
            let user = session.client.users.first { $0.id == id } ?? session.privateMessages.profiles[id] ?? KDXUser(id:id,nickname:"User \(id)")
            return ClassicRow(id:String(id),values:[user.nickname],userAdornment:ClassicUserAdornment(user:user,unreadMessage:session.privateMessages.unread.contains(id)))
        }
        let index = selectedUser.flatMap { id in recipients.visible.firstIndex { $0.id == String(id) } }
        recipients.table.selectRowIndexes(index.map { IndexSet(integer:$0) } ?? [],byExtendingSelection:false)
        let lines = selectedUser.map { session.client.privateMessages(with:$0) } ?? []
        if lines.map(\.id) != lastIDs {
            let atBottom = transcript.visibleRect.maxY >= transcript.bounds.maxY-24
            transcript.string = lines.map { "<\($0.sender)> \($0.text)" }.joined(separator:"\n")
            lastIDs = lines.map(\.id)
            if atBottom { transcript.scrollToEndOfDocument(nil) }
        }
        let user = session.client.users.first { $0.id == selectedUser }
        recipientLabel.stringValue = user?.nickname ?? selectedUser.map { "\(session.privateMessages.profiles[$0]?.nickname ?? "User \($0)") — Offline" } ?? "Select a recipient"
        input.isEditable = selectedUser != nil
        send.isEnabled = session.client.isConnected && user != nil && !sending.contains(user!.id)
    }
    func textDidChange(_ notification: Notification) {
        if let selectedUser { session.drafts[.privateMessage(selectedUser)] = input.string }
    }
    func sendText() {
        guard let recipient = selectedUser, send.isEnabled, !input.string.isEmpty else { return }
        let text = input.string, generation = session.privateMessages.generation
        session.drafts[.privateMessage(recipient)] = text
        sending.insert(recipient); refresh()
        run("send-\(recipient)") { [weak self, session] in
            guard let self else { return }
            defer { sending.remove(recipient); refresh() }
            guard generation == session.privateMessages.generation else { return }
            try await session.sendPrivate(to:recipient,text:text,generation:generation)
            guard generation == session.privateMessages.generation else { return }
            session.privateMessages.acknowledgeAttention(); readStateChanged?()
            if session.drafts[.privateMessage(recipient)] == text {
                session.drafts[.privateMessage(recipient)] = ""
                if selectedUser == recipient && input.string == text { input.string = "" }
            }
        }
    }
    func deleteMessages(with user: UInt32) {
        session.client.deletePrivateMessages(with:user)
        session.privateMessages.remove(user); session.drafts.removeValue(forKey:.privateMessage(user))
        if selectedUser == user { selectedUser = nil; input.string = ""; transcript.string = ""; lastIDs = [] }
        refresh(); readStateChanged?()
    }
    override func windowDidBecomeKey(_ notification: Notification) { super.windowDidBecomeKey(notification); session.privateMessages.acknowledgeAttention(); refresh(); readStateChanged?() }
    override func applyStyle() {
        super.applyStyle()
        for editor in [transcript,input] { HAPFieldDrawing.configureEditor(editor) }
    }
}
