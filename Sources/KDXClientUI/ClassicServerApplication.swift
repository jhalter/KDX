import AppKit
import KDXCore

@MainActor public final class ClassicServerApplication: NSObject, NSApplicationDelegate {
    let model: ClassicServerModel
    let preferences: ClassicPreferences
    private let bundledAppearancesURL: URL?
    private(set) var appearances: [ClassicAppearance] = []
    private(set) var console: ClassicServerConsole!
    private var windows: [String:ClassicWindowController] = [:]
    private var docked = ClassicDockState()
    private var dock: ClassicDockWindow?
    private let observation = ClassicObservation()
    private var startItems: [NSMenuItem] = [], stopItems: [NSMenuItem] = []
    private var quitting = false

    public override convenience init() {
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.init(model:ClassicServerModel(configurationURL:support.appendingPathComponent("macOS-KDX/server.json")))
    }
    init(model: ClassicServerModel, preferences: ClassicPreferences? = nil, bundledAppearancesURL: URL? = nil) {
        self.model = model
        self.preferences = preferences ?? ClassicPreferences(defaults:UserDefaults(suiteName:"org.macos-kdx.KDXServer.Classic"))
        self.bundledAppearancesURL = bundledAppearancesURL ?? Bundle.main.url(forResource:"OriginalAppearances",withExtension:"json")
        super.init()
    }
    func loadAppearanceSettings() {
        let bundled = bundledAppearancesURL.flatMap { try? ClassicBundledAppearances.load(from:$0) } ?? []
        appearances = AppearanceLibrary(root:preferences.root.appendingPathComponent("ServerAppearances")).load(bundled:bundled)
        ClassicStyle.shared.configureAssets(appearances)
        ClassicStyle.shared.appearance = appearances.first { $0.id == preferences.appearanceID }
            ?? appearances.first { $0.name == "Mach Lavender" } ?? .recovery
        ClassicStyle.shared.fontChoiceID = preferences.defaults.string(forKey:"font")
    }
    public func applicationDidFinishLaunching(_ notification: Notification) {
        loadAppearanceSettings(); model.load()
        console = ClassicServerConsole(preferences:preferences); wire(console)
        installMenus()
        let original = makeServerMenu()
        console.windowMenu.insertItem(.separator(),at:0)
        for item in original.items.reversed() { original.removeItem(item); console.windowMenu.insertItem(item,at:0) }
        console.transcript.menu = makeServerMenu()
        console.present()
        observation.start { [weak self] in self?.refresh() }
        if appearances.allSatisfy({ $0.id == "recovery" }) { showAppearances() }
    }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let console { restore(console) }; return true
    }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateLater }
        guard model.server.isRunning || model.starting else { model.shutdown(); return .terminateNow }
        quitting = true
        restore(console)
        console.confirm("Exit Server?",message:"The server will stop and connected users will be disconnected.",acceptTitle:"Exit Server") { [weak self] accepted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                quitting = false
                if accepted { model.shutdown() }
                sender.reply(toApplicationShouldTerminate:accepted)
            }
        }
        return .terminateLater
    }
    public func applicationWillTerminate(_ notification: Notification) { model.shutdown(); observation.stop() }
    private func refresh() {
        console.update(model)
        for item in startItems { item.title = model.starting ? "Starting…" : "Start Server"; item.isEnabled = model.editable }
        for item in stopItems { item.isEnabled = model.server.isRunning || model.starting }
        if let error = model.error { model.error = nil; console.showMessage(error,title:"KDX Server") }
    }
    private func installMenus() {
        let main = NSMenu(), app = NSMenu()
        app.addItem(menuItem("About KDX Server") { [weak self] in self?.showAbout() })
        app.addItem(menuItem("Appearances…") { [weak self] in self?.showAppearances() })
        app.addItem(.separator())
        let hide = NSMenuItem(title:"Hide KDX Server",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        hide.target = NSApplication.shared; app.addItem(hide)
        app.addItem(menuItem("Exit Server",key:"q") { NSApplication.shared.terminate(nil) })
        let edit = NSMenu()
        for (title,selector,key) in [("Undo",Selector(("undo:")),"z"),("Cut",#selector(NSText.cut(_:)),"x"),("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] {
            edit.addItem(NSMenuItem(title:title,action:selector,keyEquivalent:key))
        }
        let window = NSMenu()
        window.addItem(menuItem("KDX Server") { [weak self] in if let self { restore(console) } })
        window.addItem(menuItem("Window Switcher",key:String(UnicodeScalar(NSF1FunctionKey)!)) { [weak self] in self?.showSwitcher() })
        window.items.last?.keyEquivalentModifierMask = []
        window.addItem(menuItem("Close Window",key:"w") { (NSApplication.shared.keyWindow?.windowController as? ClassicWindowController)?.requestClose() })
        for (title,menu) in [("KDX Server",app),("Server",makeServerMenu()),("Edit",edit),("Window",window)] {
            let item = NSMenuItem(); item.title = title; item.submenu = menu; main.addItem(item)
        }
        NSApplication.shared.mainMenu = main
    }
    func makeServerMenu() -> ClassicMenu {
        let menu = ClassicMenu(title:""); menu.autoenablesItems = false
        // Original 0x401100 menu order.
        menu.addItem(menuItem("Copy Address To Clipboard") { [weak self] in
            guard let self else { return }
            let host = Host.current().localizedName.map { $0+".local" } ?? "localhost"
            let address = "\(Host.current().name ?? host):\(model.server.port ?? model.configuration.port)"
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address,forType:.string)
        })
        menu.addItem(menuItem("Show Info",iconID:73) { [weak self] in self?.showInfo() })
        menu.addItem(menuItem("Settings") { [weak self] in self?.showLocalSettings() })
        menu.addItem(menuItem("About") { [weak self] in self?.showAbout() })
        menu.addItem(.separator())
        menu.addItem(menuItem("Exit Server",iconID:81) { NSApplication.shared.terminate(nil) })
        menu.addItem(.separator())
        let start = menuItem("Start Server") { [weak self] in self?.model.start() }; startItems.append(start); menu.addItem(start)
        let stop = menuItem("Stop Server") { [weak self] in self?.stopServer() }; stopItems.append(stop); menu.addItem(stop)
        menu.addItem(menuItem("Server Settings…") { [weak self] in self?.showSettings() })
        menu.addItem(menuItem("Tracker…") { [weak self] in self?.showTracker() })
        menu.addItem(menuItem("Accounts…") { [weak self] in self?.showAccounts() })
        menu.addItem(menuItem("User List") { [weak self] in self?.showUsers() })
        menu.addItem(menuItem("Appearances…") { [weak self] in self?.showAppearances() })
        return menu
    }
    private func stopServer() {
        if model.server.users.isEmpty { model.stop(); return }
        console.confirm("Stop Server?",message:"Connected users will be disconnected.",acceptTitle:"Stop Server") { [weak self] yes in if yes { self?.model.stop() } }
    }
    private func wire(_ c: ClassicWindowController) {
        c.onMinimize = { [weak self] c in self?.docked.add(c); self?.refreshDock() }
    }
    private func show(_ key: String, make: () -> ClassicWindowController) {
        if let c = windows[key] { restore(c); return }
        let c = make(); windows[key] = c; wire(c)
        c.onClosed = { [weak self, weak c] in
            self?.windows.removeValue(forKey:key); if let c { self?.docked.remove(c) }; self?.refreshDock()
        }
        c.present()
    }
    private func restore(_ c: ClassicWindowController) { docked.remove(c); c.present(); refreshDock() }
    private func refreshDock() {
        guard !docked.isEmpty else { dock?.window?.orderOut(nil); return }
        if dock == nil { dock = ClassicDockWindow(preferences:preferences) }
        dock?.update(docked.controllers) { [weak self] in self?.restore($0) }; dock?.window?.orderFront(nil)
    }
    private func showSwitcher() {
        let menu = ClassicMenu(title:"")
        for c in [console!]+windows.values.sorted(by:{ $0.title < $1.title }) {
            menu.addItem(menuItem(c.title) { [weak self, weak c] in if let c { self?.restore(c) } })
        }
        menu.present(positioning:nil,at:NSPoint(x:4,y:22),in:console.chrome)
    }
    private func showAbout() {
        console.showMessage("KDX Server\nOriginal KDX 1.600 interface and artwork, with the modern KDXCore server.\nOriginal artwork: Haxial Software.",title:"About KDX Server")
    }
    private func showInfo() {
        var message = "\(model.status)\n\(model.server.users.count) users are connected.\n\(model.configuration.name)\n\(model.configuration.description)"
        if model.configuration.tracker.enabled {
            message += "\n\(model.server.trackerStatus)"
            if let date = model.server.lastTrackerAdvertisement { message += "\nLast advertisement: \(date.formatted())" }
        }
        console.showMessage(message,title:"KDX Server Info")
    }
    private func showLocalSettings() { show("local") { ClassicServerLocalWindow(model:model,preferences:preferences) } }

    private func form(_ title: String, key: String, height: CGFloat) -> ClassicServerFormWindow {
        ClassicServerFormWindow(title:title,key:"server-"+key,size:NSSize(width:520,height:height),preferences:preferences)
    }
    private func saveButtons(_ c: ClassicServerFormWindow, base: ServerConfiguration, controls: [NSControl], editors: [ClassicServerEditor] = [], candidate: @escaping () throws -> ServerConfiguration) -> NSView {
        let save = ClassicButton("Save",key:"\r") { [weak self, weak c] in
            guard let self, let c else { return }
            do { try model.save(candidate(),replacing:base); c.requestClose() } catch { c.showError(error) }
        }
        let cancel = ClassicButton("Cancel",key:"\u{1b}") { [weak c] in c?.requestClose() }
        c.observation.start { [weak self] in
            let enabled = self?.model.editable == true
            for control in controls+[save] { control.isEnabled = enabled }
            for editor in editors { editor.text.isEditable = enabled }
        }
        c.window?.defaultButtonCell = save.cell as? NSButtonCell
        return classicRow([save,cancel])
    }
    private func showSettings() { show("settings") { makeSettingsWindow() } }
    func makeSettingsWindow() -> ClassicServerFormWindow {
        let base = model.configuration, c = form("KDX Server Settings",key:"settings",height:460)
        let name = classicField(base.name), description = classicField(base.description), limit = classicField(String(base.downloadLimit)), folder = classicField(base.sharedFolder)
        let guests = ClassicCheckbox("Guest access allowed"), greetingEnabled = ClassicCheckbox("Show greeting on login")
        guests.state = base.allowGuests ? .on : .off; greetingEnabled.state = base.greetingEnabled ? .on : .off
        let greeting = ClassicServerEditor(base.greeting,label:"Greeting",height:90)
        let choose = ClassicButton("Choose…") { [weak c] in
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.begin { result in if result == .OK, let url = panel.url, c?.window != nil { folder.stringValue = url.path } }
        }
        let buttons = saveButtons(c,base:base,controls:[name,description,limit,folder,choose,guests,greetingEnabled],editors:[greeting]) {
            guard let bytes = UInt32(limit.stringValue) else { throw KDXError.invalid("Enter a download limit from 0 to 4294967295 bytes/sec.") }
            var value = base; value.name = name.stringValue; value.description = description.stringValue
            value.downloadLimit = bytes; value.greeting = greeting.text.string; value.greetingEnabled = greetingEnabled.state == .on
            value.allowGuests = guests.state == .on; value.sharedFolder = folder.stringValue; return value
        }
        c.setRows([serverFieldRow("Name:",name),serverFieldRow("Description:",description),guests,greetingEnabled,greeting,
                   serverFieldRow("Download limit:",limit),serverNote("Bytes per second; 0 means unlimited."),
                   serverFieldRow("Shared folder:",folder),choose,serverNote("Stop the server to edit settings. Changes apply the next time it starts."),buttons])
        return c
    }
    private func showTracker() { show("tracker") { makeTrackerWindow() } }
    func makeTrackerWindow() -> ClassicServerFormWindow {
        let base = model.configuration, c = form("KDX Tracker",key:"tracker",height:400)
        let enabled = ClassicCheckbox("Advertise this server"); enabled.state = base.tracker.enabled ? .on : .off
        let host = classicField(base.tracker.host), port = classicField(String(base.tracker.port)), advertised = classicField(String(base.tracker.advertisedPort))
        let groups = ClassicServerEditor(base.tracker.groups.joined(separator:"\n"),label:"Tracker groups",height:110)
        let buttons = saveButtons(c,base:base,controls:[enabled,host,port,advertised],editors:[groups]) {
            guard let p = UInt16(port.stringValue), p > 0, let a = UInt16(advertised.stringValue) else { throw KDXError.invalid("Use a tracker port between 1 and 65535 and an advertised port between 0 and 65535.") }
            var value = base; value.tracker.enabled = enabled.state == .on; value.tracker.host = host.stringValue
            value.tracker.port = p; value.tracker.advertisedPort = a
            value.tracker.groups = groups.text.string.components(separatedBy:.newlines).filter { !$0.isEmpty }; return value
        }
        c.setRows([enabled,serverFieldRow("Tracker address:",host),serverFieldRow("UDP port:",port),serverFieldRow("Advertised port:",advertised),
                   serverNote("Advertised port 0 uses the listening port. Groups: one per line, up to six."),groups,
                   serverNote("Publishes the name, description and user count every five minutes while running. Removed listings expire at the tracker."),buttons])
        return c
    }
    private func showAccounts() {
        show("accounts") { ClassicServerAccountsWindow(model:model,preferences:preferences) }
    }
    private func showUsers() {
        show("users") { ClassicServerUsersWindow(model:model,preferences:preferences) }
    }
    private func showAppearances() { show("appearance") { makeAppearancesWindow() } }
    func makeAppearancesWindow() -> ClassicServerFormWindow {
        let c = form("Appearance",key:"appearance",height:250)
        let picker = ClassicPopUpButton("Appearance"), font = ClassicPopUpButton("Font")
        for a in appearances { picker.addItem(withTitle:a.name); picker.lastItem?.representedObject = a.id }
        picker.selectItem(at:appearances.firstIndex { $0.id == ClassicStyle.shared.appearance.id } ?? 0)
        font.addItem(withTitle:"Default — Myoklonika 15")
        for choice in ClassicStyle.shared.fontChoices { font.addItem(withTitle:choice.title); font.lastItem?.representedObject = choice.id }
        if let id = ClassicStyle.shared.fontChoiceID, let item = font.itemArray.first(where:{ ($0.representedObject as? String) == id }) { font.select(item) }
        let apply: () -> Void = { [weak self] in
            guard let self, let id = picker.selectedItem?.representedObject as? String, let a = appearances.first(where:{ $0.id == id }) else { return }
            preferences.appearanceID = id; ClassicStyle.shared.appearance = a
            let fontID = font.selectedItem?.representedObject as? String
            preferences.defaults.set(fontID,forKey:"font"); ClassicStyle.shared.fontChoiceID = fontID
            for c in [console].compactMap({ $0 })+Array(windows.values) { c.applyStyle() }; dock?.applyStyle()
        }
        let save = ClassicButton("Save",key:"\r") { [weak c] in apply(); c?.requestClose() }
        let applyButton = ClassicButton("Apply",action:apply)
        let cancel = ClassicButton("Cancel",key:"\u{1b}") { [weak c] in c?.requestClose() }
        c.setRows([serverFieldRow("Appearance:",picker),serverFieldRow("Font:",font),serverNote("Original server palettes, bitmap controls and fonts. Server appearance and window locations are saved separately from the client."),classicRow([save,applyButton,cancel])])
        c.window?.defaultButtonCell = save.cell as? NSButtonCell
        return c
    }
}
