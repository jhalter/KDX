import AppKit

/// The original constructor (0xAA70) creates a 270×200 list-only window.
@MainActor class ClassicAddressBookWindow: ClassicWindowController {
    let list: ClassicList
    private(set) var endpoints: [ClassicEndpoint] = []
    var createEndpoint: (() -> Void)?
    var editEndpoint: ((ClassicEndpoint) -> Void)?
    var connectEndpoint: ((ClassicEndpoint) -> Void)?
    private var selectionCommands: [NSMenuItem] = []

    init(preferences: ClassicPreferences) {
        list = ClassicList(columns:["Name","Address","Login","Type"],key:"address-book",preferences:preferences)
        let probe = NSRect(x:0,y:0,width:1000,height:1000)
        let content = HAPWindowDrawing.contentRect(in:probe)
        let insets = NSSize(width:probe.width-content.width,height:probe.height-content.height)
        let minimum = NSSize(width:100+insets.width,height:80+insets.height)
        super.init(title:"KDX Address Book",key:"address-book",size:NSSize(width:270+insets.width,height:200+insets.height),preferences:preferences,minimumFrameSize:minimum)
        window?.minSize = minimum
        window?.initialFirstResponder = list.table
        list.table.nextKeyView = list.table
        list.activate = { [weak self] _ in self?.connectSelected() }
        list.selectionChanged = { [weak self] _ in self?.refreshCommands() }
        let context = ClassicMenu(title:"")
        addCommands(to:context)
        list.table.menu = context
        windowMenu.addItem(.separator())
        addCommands(to:windowMenu)
        install(list)
        onFocus = { [weak self] in self?.reload() }
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var selectedEndpoint: ClassicEndpoint? {
        endpoints.first { $0.id.uuidString == list.selected?.id }
    }
    private func addCommands(to menu: NSMenu) {
        menu.addItem(menuItem("New…") { [weak self] in self?.createEndpoint?() })
        for (title,action): (String,() -> Void) in [
            ("Edit…",{ [weak self] in self?.editSelected() }),
            ("Connect…",{ [weak self] in self?.connectSelected() }),
            ("Delete",{ [weak self] in self?.deleteSelected() })
        ] {
            let item = menuItem(title,action:action)
            menu.addItem(item); selectionCommands.append(item)
        }
    }
    private func refreshCommands() {
        let enabled = selectedEndpoint != nil
        selectionCommands.forEach { $0.isEnabled = enabled }
    }
    private func refresh() {
        list.rows = endpoints.map { ClassicRow(id:$0.id.uuidString,values:[$0.label,"\($0.host):\($0.port)",$0.login,$0.tracker ? "Tracker" : "Server"]) }
        refreshCommands()
    }
    func reload() {
        do { endpoints = try preferences.endpoints() }
        catch { showError(error) }
        refresh()
    }
    /// Update storage first so a failed write cannot change the displayed book.
    func save(_ endpoint: ClassicEndpoint) throws {
        try endpoint.validate()
        var updated = try preferences.endpoints()
        if let index = updated.firstIndex(where:{ $0.id == endpoint.id }) { updated[index] = endpoint }
        else { updated.append(endpoint) }
        try preferences.save(endpoints:updated)
        endpoints = updated; refresh()
    }
    func editSelected() {
        if let endpoint = selectedEndpoint { editEndpoint?(endpoint) }
    }
    func connectSelected() {
        if let endpoint = selectedEndpoint { connectEndpoint?(endpoint) }
    }
    func deleteSelected() {
        guard let endpoint = selectedEndpoint else { return }
        do {
            let updated = try preferences.endpoints().filter { $0.id != endpoint.id }
            try preferences.save(endpoints:updated)
            endpoints = updated; refresh()
        } catch { showError(error) }
    }
}
