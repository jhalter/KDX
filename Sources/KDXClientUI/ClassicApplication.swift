import AppKit
import KDXCore

@MainActor public final class ClassicApplication: NSObject, NSApplicationDelegate {
    let applicationName: String
    let preferences: ClassicPreferences
    private let bundledAppearancesURL: URL?
    var sessions: [UUID: ClassicSession] = [:]
    var sessionObservers: [UUID: ClassicObservation] = [:]
    var windows: [ClassicWindowKey: ClassicWindowController] = [:]
    var utilityWindows: [String: ClassicWindowController] = [:]
    var docked = ClassicDockState()
    var selectedSession: UUID?
    var appearances = [ClassicAppearance.recovery]
    var bar: ClassicWindowController!
    private var buttonBarView: ClassicButtonBarView?
    let sessionPicker = ClassicPopUpButton("Connection")
    let status = classicLabel("Disconnected")
    private var awaitingQuitConfirmation = false
    var library: AppearanceLibrary { AppearanceLibrary(root: preferences.root.appendingPathComponent("Appearances")) }
    private var availableAppearances: [ClassicAppearance] {
        let bundled = bundledAppearancesURL.flatMap { try? ClassicBundledAppearances.load(from:$0) } ?? []
        return library.load(bundled:bundled)
    }
    public override convenience init() { self.init(applicationName: "KDX Client") }
    public init(applicationName: String, preferences: ClassicPreferences? = nil, bundledAppearancesURL: URL? = nil) {
        self.applicationName = applicationName
        self.preferences = preferences ?? ClassicPreferences()
        self.bundledAppearancesURL = bundledAppearancesURL ?? Bundle.main.url(forResource:"OriginalAppearances",withExtension:"json")
        super.init()
    }
    public func applicationDidFinishLaunching(_ notification: Notification) {
        let needsImport = loadAppearanceSettings()
        installMenus(); showBar(); showConnect()
        if needsImport { showAppearances() }
    }
    /// Returns true when setup is needed. This stage does not present windows.
    func loadAppearanceSettings() -> Bool {
        appearances = availableAppearances
        ClassicStyle.shared.configureAssets(appearances)
        ClassicStyle.shared.fontChoiceID = preferences.defaults.string(forKey:"font")
        ClassicStyle.shared.appearance = appearances.first { $0.id == preferences.appearanceID }
            ?? appearances.first { $0.name == "Mach Lavender" }
            ?? appearances.first { $0.id != "recovery" }
            ?? .recovery
        return appearances.allSatisfy { $0.id == "recovery" }
    }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if awaitingQuitConfirmation { return .terminateLater }
        if sessions.values.contains(where: { $0.transfers.hasPending }) {
            guard let owner = confirmationOwner() else { return .terminateCancel }
            awaitingQuitConfirmation = true
            owner.confirm("Stop transfers and quit?",message:"Partial files are retained for resume. Queued items are kept only while \(applicationName) is running.",acceptTitle:"Stop and Quit") { [weak self] accepted in
                // A closing owner can cancel synchronously. Reply only after
                // applicationShouldTerminate has returned .terminateLater.
                Task { @MainActor [weak self] in
                    self?.awaitingQuitConfirmation = false
                    if accepted { self?.sessions.values.forEach { $0.disconnect() } }
                    sender.reply(toApplicationShouldTerminate:accepted)
                }
            }
            return .terminateLater
        }
        sessions.values.forEach { $0.disconnect() }; return .terminateNow
    }
    func installMenus() {
        let main = NSMenu()
        let app = NSMenu(); app.addItem(menuItem("About \(applicationName)") { [weak self] in self?.showAbout() })
        app.addItem(menuItem("Appearances…") { [weak self] in self?.showAppearances() })
        app.addItem(.separator())
        let hide = NSMenuItem(title:"Hide \(applicationName)",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        hide.keyEquivalentModifierMask = .command
        hide.target = NSApplication.shared
        app.addItem(hide)
        app.addItem(.separator()); app.addItem(menuItem("Quit \(applicationName)", key: "q") { NSApplication.shared.terminate(nil) })
        let file = NSMenu(); file.addItem(menuItem("Connect…",key:"k") { [weak self] in self?.showConnect() }); file.addItem(menuItem("Address Book…",key:"b") { [weak self] in self?.showAddressBook() })
        file.addItem(menuItem("Close Window",key:"w") { [weak self] in self?.activeController?.requestClose() })
        let edit = NSMenu()
        for (name, selector, key) in [("Undo",Selector(("undo:")),"z"),("Cut",#selector(NSText.cut(_:)),"x"),("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(NSMenuItem(title:name,action:selector,keyEquivalent:key)) }
        let window = NSMenu(); let switcher = menuItem("Window Switcher",key:"W") { [weak self] in self?.showSwitcher() }; window.addItem(switcher)
        let f1 = menuItem("Window Switcher",key:String(UnicodeScalar(NSF1FunctionKey)!)) { [weak self] in self?.showSwitcher() }; f1.keyEquivalentModifierMask = []; window.addItem(f1)
        window.addItem(menuItem("Button Bar") { [weak self] in if let self, let bar = self.bar { self.restore(bar) } })
        for (name, menu) in [(applicationName,app),("File",file),("Edit",edit),("Window",window)] { let item = NSMenuItem(); item.title = name; item.submenu = menu; main.addItem(item) }
        NSApplication.shared.mainMenu = main
    }
    func showAbout() {
        // A standalone borderless window keeps the HAP frame square; AppKit's
        // attached sheet presentation adds its own rounded frame.
        showUtility("about") {
            let request = ClassicDialogRequest(title:applicationName,message:"""
                \(applicationName) v1.0.0
                https://github.com/jhalter/kdx

                Based on protocol reverse engineering work by Scott Anderson
                https://github.com/scottanderson/kdx
                """,cancelTitle:nil)
            let dialog = ClassicDialogController(request:request,preferences:preferences)
            dialog.responseRequested = { [weak dialog] _ in dialog?.window?.close() }
            return dialog
        }
    }
    var activeController: ClassicWindowController? { NSApplication.shared.keyWindow?.windowController as? ClassicWindowController }
    private func confirmationOwner() -> ClassicWindowController? {
        var parent = NSApplication.shared.keyWindow
        while let owner = parent?.sheetParent ?? parent?.parent { parent = owner }
        if let controller = parent?.windowController as? ClassicWindowController { return controller }
        guard let bar else { return nil }
        restore(bar); return bar
    }
    func wire(_ controller: ClassicWindowController) {
        controller.onMinimize = { [weak self] controller in self?.docked.add(controller); self?.refreshDock() }
    }
    func showUtility(_ key: String, create: () -> ClassicWindowController) {
        if let existing = utilityWindows[key] { restore(existing); return }
        let controller = create(); utilityWindows[key] = controller; wire(controller)
        controller.onClosed = { [weak self, weak controller] in self?.utilityWindows.removeValue(forKey:key); if let controller { self?.docked.remove(controller) }; self?.refreshDock() }
        controller.present()
    }
    func register(_ controller: ClassicWindowController, session: ClassicSession, kind: ClassicWindowKind) {
        let key = ClassicWindowKey(session: session.id,kind:kind); windows[key] = controller; wire(controller)
        controller.onFocus = { [weak self, weak session] in guard let self, let session else { return }; self.selectedSession = session.id; self.refreshBar(); if case .chat(let room) = kind { session.client.selectRoom(room) } }
        controller.onBlur = { [weak session] in if case .chat(let room) = kind, session?.client.joinedRoom == room { session?.client.selectRoom(nil) } }
        controller.onClosed = { [weak self, weak controller] in self?.windows.removeValue(forKey:key); if let controller { self?.docked.remove(controller) }; self?.refreshDock() }
        controller.present()
    }
    func existing(_ session: ClassicSession, _ kind: ClassicWindowKind) -> Bool {
        if let controller = windows[ClassicWindowKey(session:session.id,kind:kind)] { restore(controller); return true }; return false
    }
    func restore(_ controller: ClassicWindowController) { docked.remove(controller); controller.present(); refreshDock() }
    func refreshDock() {
        guard !docked.isEmpty else { utilityWindows.removeValue(forKey:"dock")?.window?.orderOut(nil); return }
        if utilityWindows["dock"] == nil {
            utilityWindows["dock"] = ClassicDockWindow(preferences:preferences)
        }
        guard let dock = utilityWindows["dock"] as? ClassicDockWindow else { return }
        dock.update(docked.controllers) { [weak self] in self?.restore($0) }
        dock.window?.orderFront(nil)
    }
    func showSwitcher() {
        let menu = ClassicMenu(title:"")
        for controller in ([bar].compactMap { $0 } + Array(windows.values)+Array(utilityWindows.values)).sorted(by: { $0.title < $1.title }) { menu.addItem(menuItem(controller.title) { [weak self, weak controller] in if let controller { self?.restore(controller) } }) }
        menu.present(positioning:nil,at:NSPoint(x:4,y:25),in:activeController?.chrome ?? bar.chrome)
    }
    func showBar() {
        let compact = preferences.smallButtonBar
        bar = ClassicButtonBarWindow(title:"KDX",compact:compact,preferences:preferences); wire(bar)
        let mode = menuItem("Small Button Bar") { [weak self] in self?.toggleButtonBar() }
        mode.state = compact ? .on : .off
        bar.windowMenu.addItem(.separator()); bar.windowMenu.addItem(mode)
        sessionPicker.target = self; sessionPicker.action = #selector(pickSession)
        let buttons = ClassicBarAction.allCases.map { action in
            let button = ClassicButton(action.title,height:action.rect(compact:compact).height) {}
            button.iconID = action.iconID
            button.invoke = { [weak self, weak button] in
                guard let self else { return }
                switch action {
                case .commands: if let button { showCommands(from:button) }
                case .connect: showConnect()
                case .addressBook: showAddressBook()
                case .messages: withSession { showMessages($0) }
                case .transfers: withSession { showTransfers($0) }
                case .files: withSession { showFiles($0) }
                case .chat: withSession { showRooms($0) }
                case .users: withSession { showUsers($0) }
                case .news: break // Reserved for the custom news window.
                case .exit: NSApplication.shared.terminate(nil)
                }
            }
            if action == .news {
                button.isEnabled = false
                button.toolTip = "News is not available yet."
                button.setAccessibilityHelp(button.toolTip)
            }
            return button
        }
        let view = ClassicButtonBarView(compact:compact,picker:sessionPicker,status:status,buttons:buttons)
        buttonBarView = view; bar.install(view); refreshBar(); bar.present()
    }
    func toggleButtonBar() {
        if let bar {
            docked.remove(bar)
            bar.saveFrame(); bar.window?.close()
        }
        preferences.smallButtonBar.toggle()
        showBar(); refreshDock()
    }
    @objc func pickSession() { selectedSession = (sessionPicker.selectedItem?.representedObject as? UUID); refreshBar() }
    func withSession(_ operation: (ClassicSession) -> Void) {
        if let id = selectedSession, let session = sessions[id] { operation(session) } else { showConnect() }
    }
    func refreshBar() {
        sessionPicker.removeAllItems()
        sessionPicker.isEnabled = !sessions.isEmpty
        if sessions.isEmpty { sessionPicker.addItem(withTitle:"No connections") }
        for session in sessions.values.sorted(by: { $0.title < $1.title }) {
            // Observe background banners too, preserving their last valid image
            // if a later malformed update arrives before the session is selected.
            _ = session.serverBanner
            let messages = windows[ClassicWindowKey(session:session.id,kind:.privateMessages)] as? PrivateMessagesWindowController
            session.privateMessages.update(session.client.chat,users:session.client.users,activeRecipient:messages?.window?.isKeyWindow == true ? messages?.selectedUser : nil,windowIsFront:messages?.window?.isKeyWindow == true)
            let state = session.client.lastError ?? session.error ?? session.client.state
            sessionPicker.addItem(withTitle: "\(session.title) — \(state)")
            sessionPicker.lastItem?.representedObject = session.id
            if selectedSession == session.id { sessionPicker.select(sessionPicker.lastItem) }
        }
        let connected = sessions.values.filter { $0.client.isConnected }.count
        let transfers = sessions.values.filter { $0.transfers.activeID != nil }.count
        buttonBarView?.updateCounts(connections:connected,transfers:transfers)
        buttonBarView?.updateUnreadMessages(sessions.values.reduce(0) { $0+$1.privateMessages.unread.count })
        buttonBarView?.updateMessageAlert(sessions.values.contains { $0.privateMessages.needsAttention })
        let selected = selectedSession.flatMap { sessions[$0] }
        buttonBarView?.updateBanner(selected?.serverBanner)
        status.stringValue = selected?.client.lastError ?? selected?.error ?? selected?.client.state ?? "Disconnected"
        status.toolTip = status.stringValue
        sessionPicker.toolTip = "\(sessionPicker.titleOfSelectedItem ?? "No connections")\n[\(connected)] connections   [\(transfers)] transfers"
    }
    func connect(endpoint: ClassicEndpoint, password: String) throws {
        try endpoint.validate()
        if endpoint.tracker { showTracker(endpoint); return }
        let table = try KDXStorage.loadTable(), session = ClassicSession(endpoint:endpoint)
        sessions[session.id] = session; selectedSession = session.id
        let observer = ClassicObservation(); sessionObservers[session.id] = observer
        observer.start { [weak self, weak session] in
            guard let self, let session else { return }
            refreshBar()
            for room in session.client.joinedRooms.keys where windows[ClassicWindowKey(session:session.id,kind:.chat(room))] == nil { showChat(session,room:room) }
        }
        session.connect(password:password,table:table); showUsers(session)
    }
    func disconnect(_ session: ClassicSession) {
        if session.transfers.hasPending {
            confirmationOwner()?.confirm("Disconnect from \(session.title)?",message:"Active transfers will stop. Partial files are retained. Reconnect to resume transfers.",acceptTitle:"Disconnect") { [weak self, weak session] accepted in
                guard accepted, let self, let session, self.sessions[session.id] === session else { return }
                session.disconnect(); self.refreshBar()
            }
            return
        }
        session.disconnect(); refreshBar()
    }
    func showAppearances() {
        showUtility("appearances") { makeAppearanceWindow() }
    }
    /// Build without presenting, so appearance changes can also be checked offscreen.
    func makeAppearanceWindow() -> ClassicWindowController {
        let c = ClassicWindowController(title:"Appearance",key:"appearance",size:NSSize(width:430,height:320),preferences:preferences)
        let picker = ClassicPopUpButton("Appearance"); for appearance in appearances { picker.addItem(withTitle: appearance.name); picker.lastItem?.representedObject = appearance.id }
        picker.selectItem(at:appearances.firstIndex { $0.id == ClassicStyle.shared.appearance.id } ?? 0)
        let needsImport = appearances.allSatisfy { $0.id == "recovery" }
        let detail = classicLabel(needsImport ? "Classic Recovery is a setup fallback.\nImport the original client or a .hap below." : "Original palettes, bitmap skins, icons, and fonts.")
        detail.maximumNumberOfLines = 2
        let fontPicker = ClassicPopUpButton("Font")
        @MainActor func refreshFontPicker() {
            fontPicker.removeAllItems()
            fontPicker.isEnabled = !ClassicStyle.shared.fontChoices.isEmpty
            fontPicker.addItem(withTitle:fontPicker.isEnabled ? "Default — Myoklonika 15" : "System font — import original fonts")
            for choice in ClassicStyle.shared.fontChoices { fontPicker.addItem(withTitle:choice.title); fontPicker.lastItem?.representedObject = choice.id }
            if let selected = ClassicStyle.shared.fontChoiceID, let item = fontPicker.itemArray.first(where: { ($0.representedObject as? String) == selected }) { fontPicker.select(item) }
        }
        refreshFontPicker()
        let smallUsers = ClassicCheckbox("Use Small Icons In User Lists")
        smallUsers.state = preferences.smallUserIcons ? .on : .off
        let smallFiles = ClassicCheckbox("Use Small Icons In File Lists")
        smallFiles.state = preferences.smallFileIcons ? .on : .off
        let applySelection: @MainActor () -> Bool = { [weak self, weak picker] in
            guard let self, let id = picker?.selectedItem?.representedObject as? String, let appearance = self.appearances.first(where: { $0.id == id }) else { return false }
            self.preferences.appearanceID = id; ClassicStyle.shared.appearance = appearance
            let fontID = fontPicker.selectedItem?.representedObject as? String
            self.preferences.defaults.set(fontID,forKey:"font"); ClassicStyle.shared.fontChoiceID = fontID
            self.preferences.smallUserIcons = smallUsers.state == .on
            self.preferences.smallFileIcons = smallFiles.state == .on
            for window in Array(self.windows.values)+Array(self.utilityWindows.values)+[self.bar!] { window.applyStyle() }
            return true
        }
        let save = ClassicButton("Save",key:"\r") { [weak c] in
            if applySelection() { c?.requestClose() }
        }
        let apply = ClassicButton("Apply") { _ = applySelection() }
        let cancel = ClassicButton("Cancel",key:"\u{1b}") { [weak c] in c?.requestClose() }
        let actions = classicRow([save,apply,cancel]); actions.distribution = .fillEqually
        let cancelImport = ClassicButton("Cancel Import") { [weak c] in
            detail.stringValue = "Canceling import…"
            c?.cancelTask("appearance-import")
        }
        cancelImport.isEnabled = false
        let importButton = ClassicButton("Import Original Application / Appearance…") {}
        importButton.invoke = { [weak self, weak c, weak picker, weak importButton] in
            let panel = NSOpenPanel(); panel.message = "Select KDXClient.app, a .hap file, or the supplied MacBinary/StuffIt archive."
            panel.begin { result in guard result == .OK, let url = panel.url, let self else { return }
                c?.run("appearance-import") {
                    importButton?.isEnabled = false; cancelImport.isEnabled = true
                    detail.stringValue = "Importing appearance…"
                    defer { importButton?.isEnabled = true; cancelImport.isEnabled = false }
                    do {
                        let imported = try await ClassicAssetImporter.load(url)
                        try Task.checkCancellation()
                        try self.library.install(imported)
                        self.appearances = self.availableAppearances; picker?.removeAllItems()
                        ClassicStyle.shared.configureAssets(self.appearances); refreshFontPicker()
                        for a in self.appearances { picker?.addItem(withTitle:a.name); picker?.lastItem?.representedObject = a.id }
                        let preferred = imported.appearances.first { $0.name == "Mach Lavender" } ?? imported.appearances[0]
                        self.preferences.appearanceID = preferred.id; ClassicStyle.shared.appearance = preferred
                        picker?.selectItem(at:self.appearances.firstIndex { $0.id == preferred.id } ?? 0)
                        for window in Array(self.windows.values)+Array(self.utilityWindows.values)+[self.bar!] { window.applyStyle() }
                        detail.stringValue = "Imported \(preferred.name)."
                    } catch {
                        detail.stringValue = Task.isCancelled ? "Import canceled." : "Import failed."
                        throw error
                    }
                }
            }
        }
        c.install(classicColumn([picker,fontPicker,smallUsers,smallFiles,detail,importButton,cancelImport,actions]))
        c.window?.defaultButtonCell = save.cell as? NSButtonCell
        c.window?.initialFirstResponder = needsImport ? importButton : picker
        return c
    }
}
