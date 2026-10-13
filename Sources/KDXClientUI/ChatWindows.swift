import AppKit
import KDXCore

extension ClassicApplication {
    func showRooms(_ session: ClassicSession) {
        guard !existing(session,.rooms) else { return }
        let c = ClassicWindowController(title:"Chats — \(session.title)",key:"rooms",size:NSSize(width:520,height:340),preferences:preferences)
        let list = ClassicList(columns:["Chat","Description","Users","Unread"],key:"rooms",preferences:preferences)
        list.activate = { [weak self, weak c] row in
            guard let id = UInt32(row.id) else { return }
            c?.run { try await session.client.join(room:id); self?.showChat(session,room:id) }
        }
        let create = ClassicButton("New Private Chat") { [weak self, weak c] in c?.run { let room = try await session.client.createPrivateChatWindow(); self?.showChat(session,room:room.id) } }
        c.install(classicColumn([classicRow([ClassicButton("Refresh") { [weak c] in c?.run { try await session.client.refreshRooms() } },create]),list]))
        c.observation.start { [weak c, weak list] in
            c?.title = "Chats — \(session.title)"
            list?.rows = session.client.rooms.map { ClassicRow(id:String($0.id),values:[$0.name,$0.description,String($0.memberCount),String(session.client.unreadRooms[$0.id] ?? 0)]) }
        }
        register(c,session:session,kind:.rooms)
    }
    func showChat(_ session: ClassicSession, room: UInt32) {
        guard !existing(session,.chat(room)) else { return }
        let c = ChatWindowController(session:session,room:room,preferences:preferences)
        c.openPrivate = { [weak self] user in self?.showPrivate(session,user:user) }
        c.windowMenu.addItem(menuItem("Show Files") { [weak self] in self?.showFiles(session) })
        c.windowMenu.addItem(menuItem("Show User List") { [weak self] in self?.showUsers(session) })
        register(c,session:session,kind:.chat(room))
    }
    func showPrivate(_ session: ClassicSession, user: UInt32) {
        let kind = ClassicWindowKind.composeMessage(user)
        if let existing = windows[ClassicWindowKey(session:session.id,kind:kind)] as? ClassicMessageComposerWindow {
            if existing.isCurrentConnection { restore(existing); return }
            existing.requestClose()
        }
        let controller = ClassicMessageComposerWindow(session:session,user:user,preferences:preferences)
        controller.sent = { [weak self] in self?.refreshBar() }
        register(controller,session:session,kind:kind)
    }
    func showMessages(_ session: ClassicSession, user: UInt32? = nil) {
        session.privateMessages.update(session.client.chat,users:session.client.users,activeRecipient:nil)
        session.privateMessages.acknowledgeAttention(); refreshBar()
        if let existing = windows[ClassicWindowKey(session:session.id,kind:.privateMessages)] as? PrivateMessagesWindowController {
            if let user { existing.select(user) }
            restore(existing); return
        }
        let controller = PrivateMessagesWindowController(session:session,preferences:preferences,user:user)
        controller.openUsers = { [weak self] in self?.showUsers(session) }
        controller.compose = { [weak self] user in self?.showPrivate(session,user:user) }
        controller.readStateChanged = { [weak self] in self?.refreshBar() }
        register(controller,session:session,kind:.privateMessages)
    }
    func editProfile(_ session: ClassicSession, using controller: ClassicWindowController?) {
        guard session.client.isConnected, let user = session.client.currentUser else { return }
        if let existing = windows[ClassicWindowKey(session:session.id,kind:.profile)] as? ClassicProfileWindow {
            if existing.isCurrentConnection { restore(existing); return }
            existing.requestClose()
        }
        register(ClassicProfileWindow(session:session,user:user,preferences:preferences),session:session,kind:.profile)
    }

    func changeAwayStatus(_ session: ClassicSession, using controller: ClassicWindowController?) {
        guard session.client.isConnected else { return }
        let status: UInt8 = session.client.currentUser?.status == 1 ? 0 : 1
        controller?.run("status-"+session.id.uuidString) { try await session.client.setStatus(status) }
    }
    func reconnect(_ session: ClassicSession, using controller: ClassicWindowController?) {
        guard !session.client.isConnecting, !session.client.isConnected else { return }
        controller?.prompt("Reconnect to \(session.endpoint.label)",secure:true,acceptTitle:"Connect") { [weak controller] password in
            guard !session.client.isConnecting, !session.client.isConnected else { return }
            do { session.connect(password:password,table:try KDXStorage.loadTable()) }
            catch { controller?.showError(error) }
        }
    }
    func showUsers(_ session: ClassicSession) {
        guard !existing(session,.users) else { return }
        let c = ClassicUsersWindow(session:session,preferences:preferences)
        c.serverChoices = { [weak self] in
            self?.sessions.values.sorted { $0.title < $1.title }.map {
                ClassicUserServerChoice(id:$0.id,title:"\($0.title) — \($0.endpoint.host):\($0.endpoint.port)")
            } ?? []
        }
        c.openServer = { [weak self] id in if let self, let selected = self.sessions[id] { self.showUsers(selected) } }
        c.messageUser = { [weak self] id in self?.showPrivate(session,user:id) }
        c.openRoom = { [weak self] room in self?.showChat(session,room:room) }
        c.editProfile = { [weak self, weak c] in self?.editProfile(session,using:c) }
        c.changeStatus = { [weak self, weak c] in self?.changeAwayStatus(session,using:c) }
        c.reconnect = { [weak self, weak c] in self?.reconnect(session,using:c) }
        c.refresh()
        register(c,session:session,kind:.users)
    }
}

@MainActor final class ChatInput: ClassicTextView {
    var send: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), event.keyCode == 36 || event.keyCode == 76 {
            if !event.modifierFlags.contains(.shift) { send?(); return }
        }
        if !hasMarkedText(), event.keyCode == 53 { string = ""; didChangeText(); return }
        super.keyDown(with:event)
    }
}

@MainActor final class ChatWindowController: ClassicWindowController, NSTextViewDelegate {
    let session: ClassicSession
    let room: UInt32?
    let user: UInt32?
    let input = ChatInput()
    let transcript = ClassicTextView()
    let members: ClassicList
    let topic = classicLabel("")
    let send = ClassicButton("Send") {}
    var openPrivate: ((UInt32) -> Void)?
    var lastIDs: [UUID] = []
    var clearedIDs = Set<UUID>()
    var kind: ClassicWindowKind { room.map(ClassicWindowKind.chat) ?? .privateMessage(user!) }
    convenience init(session: ClassicSession, room: UInt32, preferences: ClassicPreferences) { self.init(session:session,room:room,user:nil,preferences:preferences) }
    convenience init(session: ClassicSession, user: UInt32, preferences: ClassicPreferences) { self.init(session:session,room:nil,user:user,preferences:preferences) }
    private init(session: ClassicSession, room: UInt32?, user: UInt32?, preferences: ClassicPreferences) {
        self.session = session; self.room = room; self.user = user
        members = ClassicList(columns:["Name","Description"],key:"chat-users",preferences:preferences,kind:.users)
        super.init(title:"Chat — \(session.title)",key:room == nil ? "private-messages" : "chat",size:NSSize(width:800,height:490),preferences:preferences,minimumFrameSize:NSSize(width:480,height:260))
        transcript.isEditable = false; transcript.isSelectable = true
        for editor in [transcript,input] {
            editor.isRichText = false; editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
            editor.autoresizingMask = [.width]; editor.minSize = .zero
            editor.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
            editor.textContainer?.widthTracksTextView = true
        }
        let history = ClassicScrollView(); history.documentView = transcript; history.hasVerticalScroller = true
        let entry = ClassicScrollView(); entry.documentView = input; entry.hasVerticalScroller = true
        for scroll in [history,entry,members.scroll] {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = .init(); scroll.scrollerInsets = .init()
        }
        input.delegate = self; input.string = session.drafts[kind] ?? ""; input.send = { [weak self] in self?.sendText() }
        let conversation = ClassicPaneSplitView(vertical:false,key:"chat-input",preferences:preferences,portion:0.75,minimums:(136,54))
        conversation.addPane(ClassicFieldFrame(history)); conversation.addPane(ClassicFieldFrame(entry))
        let panes: NSView
        if room != nil {
            let split = ClassicPaneSplitView(vertical:true,key:"chat-users",preferences:preferences,portion:0.7,minimums:(260,170))
            split.addPane(conversation); split.addPane(members); panes = split
        } else { panes = conversation }
        send.invoke = { [weak self] in self?.sendText() }
        let topicButton = ClassicButton("Topic…") { [weak self] in guard let self, let room else { return }; prompt("Chat Topic",initial:session.client.chatTopics[room]?.text ?? "") { [weak self] text in self?.run("topic") { try await session.client.setTopic(text,room:room) } } }
        topicButton.isHidden = room == nil
        let invite = ClassicButton("Invite…") { [weak self] in self?.showInviteMenu() }; invite.isHidden = room == nil
        members.activate = { [weak self] row in if let id = UInt32(row.id) { self?.openPrivate?(id) } }
        let menu = ClassicMenu(title:""); menu.addItem(menuItem("Send Message") { [weak self] in if let id = self?.members.selected?.id, let value = UInt32(id) { self?.openPrivate?(value) } }); menu.addItem(menuItem("Invite Users To This Chat") { [weak self] in self?.showInviteMenu() }); members.table.menu = menu
        topic.lineBreakMode = .byTruncatingTail
        topic.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        topic.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let actions = classicRow([topicButton,invite,topic,send]); actions.distribution = .fill
        actions.heightAnchor.constraint(equalToConstant:24).isActive = true
        panes.setContentHuggingPriority(.defaultLow,for:.vertical)
        install(classicColumn([panes,actions]))
        window?.minSize = NSSize(width:480,height:260)
        window?.initialFirstResponder = input
        windowMenu.addItem(menuItem("Clear Text") { [weak self] in guard let self else { return }; self.clearedIDs.formUnion(self.lines.map(\.id)); self.refresh() })
        if let room { beforeClose = { if session.client.isConnected { try await session.client.leaveRoom(room) } } }
        observation.start { [weak self] in self?.refresh() }
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var lines: [ChatLine] { room.map { session.client.messages(in:$0) } ?? session.client.privateMessages(with:user!) }
    func refresh() {
        let name = room.flatMap { session.client.joinedRooms[$0]?.name } ?? session.client.users.first { $0.id == user }?.nickname ?? "Private Messages"
        let unread = room.flatMap { session.client.unreadRooms[$0] } ?? 0
        title = "\(name)\(unread > 0 ? " [\(unread)]" : "") — \(session.title)"
        let current = lines.filter { !clearedIDs.contains($0.id) }
        if current.map(\.id) != lastIDs {
            let wasAtBottom = transcript.visibleRect.maxY >= transcript.bounds.maxY-24
            transcript.string = current.map { "<\($0.sender)> \($0.text)" }.joined(separator:"\n")
            lastIDs = current.map(\.id)
            if wasAtBottom { transcript.scrollToEndOfDocument(nil) }
        }
        if let room {
            topic.stringValue = session.client.chatTopics[room]?.text ?? ""
            let ids = session.client.joinedRooms[room]?.members ?? []
            members.rows = session.client.users.filter { ids.contains($0.id) }.map { ClassicRow(id:String($0.id),values:[$0.nickname,$0.info],userAdornment:ClassicUserAdornment(user:$0)) }
            send.isEnabled = session.client.isConnected && session.client.joinedRooms[room] != nil
            if window?.isKeyWindow == true { session.client.markRoomRead(room) }
        } else { send.isEnabled = session.client.isConnected && session.client.users.contains { $0.id == user } }
    }
    func textDidChange(_ notification: Notification) { session.drafts[kind] = input.string }
    func sendText() {
        let text = input.string, generation = session.privateMessages.generation; guard !text.isEmpty, send.isEnabled else { return }
        send.isEnabled = false
        run("send") { [weak self] in
            guard let self else { return }
            defer { refresh() }
            if let room { try await session.client.sendChat(text,room:room) }
            else if let user {
                try await session.sendPrivate(to:user,text:text,generation:generation)
                guard generation == session.privateMessages.generation else { return }
            }
            if input.string == text { input.string = ""; session.drafts[kind] = "" }
        }
    }
    func showInviteMenu() {
        guard let room else { return }; let menu = ClassicMenu(title:"")
        for user in session.client.users where !(session.client.joinedRooms[room]?.members.contains(user.id) ?? false) {
            let id = user.id
            menu.addItem(menuItem(user.nickname) { [weak self, session] in self?.run("invite") { try await session.client.inviteToChat(users:[id],room:room) } })
        }
        menu.present(positioning:nil,at:NSPoint(x:40,y:30),in:chrome)
    }
    override func applyStyle() {
        super.applyStyle()
        for text in [transcript,input] { HAPFieldDrawing.configureEditor(text) }
    }
}
