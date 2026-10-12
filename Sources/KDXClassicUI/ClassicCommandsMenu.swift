import AppKit

enum ClassicServerCommand: String, CaseIterable {
    case select = "Use This Connection", users = "User List", rooms = "Chat", files = "File Browser", transfers = "File Transfers"
    case profile = "My Profile…", away = "Away / Back", reconnect = "Reconnect…", disconnect = "Disconnect"
    func isEnabled(connected: Bool, connecting: Bool) -> Bool {
        switch self {
        case .select, .users, .transfers: true
        case .reconnect: !connected && !connecting
        case .disconnect: connected || connecting
        case .rooms, .files, .profile, .away: connected
        }
    }
    var iconID: Int? {
        switch self {
        case .users: 90
        case .rooms: 88
        case .files: 93
        case .transfers: 86
        default: nil
        }
    }
}
enum ClassicTrackerCommand: String, CaseIterable {
    case show = "Show Tracker", refresh = "Refresh", cancel = "Cancel Query", close = "Close Tracker"
}
enum ClassicCommand: Equatable {
    case connect, addressBook, appearances, smallButtonBar
    case server(UUID, ClassicServerCommand)
    case tracker(UUID, ClassicTrackerCommand)
}
struct ClassicCommandConnection {
    let id: UUID
    let title: String
    let address: String
    let connected: Bool
    let connecting: Bool
}
struct ClassicCommandTracker {
    let id: UUID
    let title: String
    let address: String
}

/// Snapshot labels and immutable target IDs when the menu opens. Dispatch never
/// consults the currently focused window or the connection picker.
@MainActor enum ClassicCommandsMenu {
    static func make(connections: [ClassicCommandConnection], trackers: [ClassicCommandTracker], selected: UUID?, compact: Bool, perform: @escaping (ClassicCommand) -> Void) -> ClassicMenu {
        let menu = ClassicMenu(title:"Commands")
        func item(_ title: String, _ command: ClassicCommand, iconID: Int? = nil) -> NSMenuItem {
            menuItem(title,iconID:iconID) { perform(command) }
        }
        menu.addItem(item("Connect…",.connect,iconID:84))
        menu.addItem(item("Address Book",.addressBook,iconID:78))
        if !connections.isEmpty || !trackers.isEmpty { menu.addItem(.separator()) }
        let connections = connections.sorted { ($0.title,$0.address,$0.id.uuidString) < ($1.title,$1.address,$1.id.uuidString) }
        for connection in connections {
            let duplicate = connections.filter { $0.title == connection.title }.count > 1
            let title = connection.title+(duplicate ? " — \(connection.address)" : "")
            let root = NSMenuItem(title:title,action:nil,keyEquivalent:"")
            root.toolTip = connection.address
            root.state = connection.id == selected ? .on : .off
            let submenu = ClassicMenu(title:title)
            for command in ClassicServerCommand.allCases {
                if command == .profile || command == .reconnect { submenu.addItem(.separator()) }
                let row = item(command.rawValue,.server(connection.id,command),iconID:command.iconID)
                row.isEnabled = command.isEnabled(connected:connection.connected,connecting:connection.connecting)
                if command == .select { row.state = root.state }
                submenu.addItem(row)
            }
            root.submenu = submenu; menu.addItem(root)
        }
        for tracker in trackers.sorted(by: { ($0.title,$0.address,$0.id.uuidString) < ($1.title,$1.address,$1.id.uuidString) }) {
            let root = NSMenuItem(title:"Tracker — \(tracker.title)",action:nil,keyEquivalent:"")
            root.toolTip = tracker.address
            let submenu = ClassicMenu(title:root.title)
            for command in ClassicTrackerCommand.allCases { submenu.addItem(item(command.rawValue,.tracker(tracker.id,command))) }
            root.submenu = submenu; menu.addItem(root)
        }
        menu.addItem(.separator())
        menu.addItem(item("Appearances…",.appearances))
        let small = item("Small Button Bar",.smallButtonBar); small.state = compact ? .on : .off; menu.addItem(small)
        return menu
    }
}

extension ClassicApplication {
    func commandsMenu() -> ClassicMenu {
        let connections = sessions.values.map {
            ClassicCommandConnection(id:$0.id,title:$0.title,address:"\($0.endpoint.host):\($0.endpoint.port)",connected:$0.client.isConnected,connecting:$0.client.isConnecting)
        }
        let trackers = utilityWindows.values.compactMap { $0 as? TrackerWindow }.map {
            ClassicCommandTracker(id:$0.commandID,title:$0.endpoint.label,address:"\($0.endpoint.host):\($0.endpoint.port)")
        }
        return ClassicCommandsMenu.make(connections:connections,trackers:trackers,selected:selectedSession,compact:preferences.smallButtonBar) { [weak self] in self?.performCommand($0) }
    }
    func showCommands(from view: NSView) {
        commandsMenu().present(positioning:nil,at:NSPoint(x:view.bounds.minX,y:view.bounds.maxY),in:view)
    }
    func performCommand(_ command: ClassicCommand) {
        switch command {
        case .connect: showConnect()
        case .addressBook: showAddressBook()
        case .appearances: showAppearances()
        case .smallButtonBar: toggleButtonBar()
        case let .server(id,action):
            guard let session = sessions[id], action.isEnabled(connected:session.client.isConnected,connecting:session.client.isConnecting) else { return }
            switch action {
            case .select: selectedSession = id; refreshBar()
            case .users: showUsers(session)
            case .rooms: showRooms(session)
            case .files: showFiles(session)
            case .transfers: showTransfers(session)
            case .profile: editProfile(session,using:bar)
            case .away: changeAwayStatus(session,using:bar)
            case .reconnect: reconnect(session,using:bar)
            case .disconnect: disconnect(session)
            }
        case let .tracker(id,action):
            guard let tracker = utilityWindows.values.compactMap({ $0 as? TrackerWindow }).first(where: { $0.commandID == id }) else { return }
            switch action {
            case .show: restore(tracker)
            case .refresh: tracker.refresh()
            case .cancel: tracker.cancelQuery()
            case .close: tracker.requestClose()
            }
        }
    }
}
