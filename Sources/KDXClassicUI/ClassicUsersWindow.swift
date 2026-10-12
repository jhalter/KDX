import AppKit
import KDXCore

struct ClassicUserServerChoice: Equatable {
    let id: UUID
    let title: String
}

@MainActor private final class ClassicUsersHeader: ClassicSurface {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        ClassicPainter.bevel(NSRect(x:-1,y:-1,width:bounds.width+2,height:30))
    }
}

/// VWIN usrl: 300×400; server (4,4,236,20), count (243,6,55,16),
/// list (0,29,300,371). Pending invitations use a separate modern extension.
@MainActor final class ClassicUsersForm: ClassicSurface {
    let server = ClassicPopUpButton("Server for this user list")
    let count = classicLabel("0")
    let list: ClassicList
    private let header = ClassicUsersHeader()
    let invitations = ClassicPopUpButton("Chat invitations")
    let accept = ClassicButton("Accept",height:22) {}
    let decline = ClassicButton("Decline",height:22) {}
    let invitationPanel = ClassicSurface()
    var hasInvitations = false {
        didSet {
            invitationPanel.isHidden = !hasInvitations; needsLayout = true
            list.table.nextKeyView = hasInvitations ? invitations : server
        }
    }
    init(preferences: ClassicPreferences) {
        list = ClassicList(columns:["Name","Description","Status"],key:"users",preferences:preferences,kind:.users)
        super.init(frame:NSRect(x:0,y:0,width:300,height:400))
        count.alignment = .right; count.setAccessibilityLabel("Connected users")
        for view in [header,list,invitationPanel] { view.translatesAutoresizingMaskIntoConstraints = true; addSubview(view) }
        header.addSubview(server); header.addSubview(count)
        for view in [invitations,accept,decline] { view.translatesAutoresizingMaskIntoConstraints = true; invitationPanel.addSubview(view) }
        invitationPanel.isHidden = true
        server.nextKeyView = list.table
        list.table.nextKeyView = server; invitations.nextKeyView = accept
        accept.nextKeyView = decline; decline.nextKeyView = server
        layout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height, extra: CGFloat = hasInvitations ? 58 : 0
        header.frame = NSRect(x:0,y:0,width:w,height:29)
        server.frame = NSRect(x:4,y:4,width:max(28,w-64),height:20)
        count.frame = NSRect(x:w-57,y:6,width:55,height:16)
        list.frame = NSRect(x:0,y:29,width:w,height:max(0,h-29-extra))
        invitationPanel.frame = NSRect(x:0,y:h-extra,width:w,height:extra)
        invitations.frame = NSRect(x:4,y:4,width:max(0,w-8),height:20)
        let width = max(0,(w-12)/2)
        accept.frame = NSRect(x:4,y:30,width:width,height:22)
        decline.frame = NSRect(x:8+width,y:30,width:width,height:22)
    }
}

@MainActor class ClassicUsersWindow: ClassicWindowController {
    let session: ClassicSession
    let form: ClassicUsersForm
    var serverChoices: (() -> [ClassicUserServerChoice])?
    var openServer: ((UUID) -> Void)?
    var messageUser: ((UInt32) -> Void)?
    var openRoom: ((UInt32) -> Void)?
    var editProfile: (() -> Void)?
    var changeStatus: (() -> Void)?
    var reconnect: (() -> Void)?
    private var choices: [ClassicUserServerChoice] = []
    private var invitationIDs: [UInt32] = []
    private var generation: UUID
    private let statusItem = NSMenuItem(title:"Disconnected",action:nil,keyEquivalent:"")
    init(session: ClassicSession, preferences: ClassicPreferences) {
        self.session = session; generation = session.privateMessages.generation
        form = ClassicUsersForm(preferences:preferences)
        let probe = NSRect(x:0,y:0,width:1000,height:1000), content = HAPWindowDrawing.contentRect(in:probe)
        super.init(title:"User List — \(session.title)",key:"users",size:NSSize(width:300+probe.width-content.width,height:400+probe.height-content.height),preferences:preferences)
        window?.minSize = NSSize(width:252,height:228)
        window?.initialFirstResponder = form.list.table
        form.server.target = self; form.server.action = #selector(selectServer)
        form.list.activate = { [weak self] _ in self?.sendMessage() }
        let menu = ClassicMenu(title:"")
        menu.addItem(menuItem("Send Message") { [weak self] in self?.sendMessage() })
        menu.addItem(menuItem("Get Info") { [weak self] in self?.getInfo() })
        menu.addItem(menuItem("Invite To New Chat") { [weak self] in self?.invite() })
        form.list.table.menu = menu
        windowMenu.addItem(.separator()); statusItem.isEnabled = false; windowMenu.addItem(statusItem)
        windowMenu.addItem(menuItem("My Profile…") { [weak self] in self?.editProfile?() })
        windowMenu.addItem(menuItem("Away / Back") { [weak self] in self?.changeStatus?() })
        windowMenu.addItem(menuItem("Reconnect…") { [weak self] in self?.reconnect?() })
        form.accept.invoke = { [weak self] in self?.acceptInvitation() }
        form.decline.invoke = { [weak self] in self?.declineInvitation() }
        chrome.layoutSubtreeIfNeeded(); install(form)
        refresh()
        observation.start { [weak self] in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        if generation != session.privateMessages.generation {
            generation = session.privateMessages.generation
            form.list.rows = []; form.list.table.deselectAll(nil)
        }
        title = "User List — \(session.title)"
        form.list.rows = session.client.users.map {
            ClassicRow(id:String($0.id),values:[$0.nickname,$0.info,$0.status == 0 ? "" : "Away"],userAdornment:ClassicUserAdornment(user:$0))
        }
        form.count.stringValue = String(session.client.users.count)
        let status = session.error ?? session.client.lastError ?? session.client.state
        form.server.toolTip = "\(session.endpoint.host):\(session.endpoint.port) — \(status)"
        statusItem.title = status
        var next = serverChoices?() ?? []
        if !next.contains(where: { $0.id == session.id }) { next.insert(ClassicUserServerChoice(id:session.id,title:session.title),at:0) }
        if next != choices {
            choices = next; form.server.removeAllItems()
            for choice in choices { form.server.addItem(withTitle:choice.title); form.server.lastItem?.representedObject = choice.id }
        }
        selectOwnServer()
        let invites = session.client.chatInvitations
        let selected = form.invitations.selectedItem?.representedObject as? UInt32
        if invitationIDs != invites.map(\.id) || form.invitations.itemTitles != invites.map(\.name) {
            invitationIDs = invites.map(\.id); form.invitations.removeAllItems()
            for invite in invites {
                form.invitations.addItem(withTitle:invite.name); form.invitations.lastItem?.representedObject = invite.id
                if invite.id == selected { form.invitations.select(form.invitations.lastItem) }
            }
        }
        if form.hasInvitations != !invites.isEmpty { form.hasInvitations = !invites.isEmpty }
        form.accept.isEnabled = !invites.isEmpty && session.client.isConnected
        form.decline.isEnabled = !invites.isEmpty
    }
    private func selectOwnServer() {
        if let item = form.server.itemArray.first(where: { ($0.representedObject as? UUID) == session.id }) { form.server.select(item) }
    }
    @objc func selectServer() {
        let chosen = form.server.selectedItem?.representedObject as? UUID
        selectOwnServer()
        if let chosen, chosen != session.id, choices.contains(where: { $0.id == chosen }) { openServer?(chosen) }
    }
    private var isCurrentConnection: Bool { generation == session.privateMessages.generation && session.client.isConnected }
    private var selectedUser: UInt32? {
        guard isCurrentConnection, let id = form.list.selected.flatMap({ UInt32($0.id) }), session.client.users.contains(where: { $0.id == id }) else { return nil }
        return id
    }
    func sendMessage() { if let id = selectedUser { messageUser?(id) } }
    func getInfo() {
        guard let id = selectedUser else { return }; let generation = generation
        run("info") { [weak self, session] in
            let value = try await session.client.userInformation(id:id)
            guard let self, generation == session.privateMessages.generation else { return }
            showMessage("Name: \(value.nickname)\nLogin: \(value.login)\nAddress: \(value.address)\nConnected: \(value.connectedAt?.formatted() ?? "Unknown")",title:"User Information")
        }
    }
    func invite() {
        guard let id = selectedUser else { return }; let generation = generation
        run("invite") { [weak self, session] in
            let room = try await session.client.createPrivateChatWindow()
            guard generation == session.privateMessages.generation else { return }
            try await session.client.inviteToChat(users:[id],room:room.id)
            guard generation == session.privateMessages.generation else { return }
            self?.openRoom?(room.id)
        }
    }
    func acceptInvitation() {
        guard isCurrentConnection, let id = form.invitations.selectedItem?.representedObject as? UInt32,
              let invite = session.client.chatInvitations.first(where: { $0.id == id }) else { return }
        run("invite") { [session] in try await session.client.acceptInvitation(invite) }
    }
    func declineInvitation() {
        guard let id = form.invitations.selectedItem?.representedObject as? UInt32,
              let invite = session.client.chatInvitations.first(where: { $0.id == id }) else { return }
        session.client.dismissInvitation(invite); refresh()
    }
}
