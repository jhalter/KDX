import AppKit
import KDXCore

extension ClassicApplication {
    func showConnect(_ endpoint: ClassicEndpoint = .defaultTracker, saving: ((ClassicEndpoint) throws -> Void)? = nil) {
        let key = "connect-"+UUID().uuidString
        showUtility(key) {
            let c = ClassicConnectWindow(endpoint:endpoint,saving:saving != nil,preferences:preferences)
            c.submitted = { [weak self] endpoint,password in
                if let saving { try saving(endpoint) }
                else { try self?.connect(endpoint:endpoint,password:password) }
            }
            c.form.challengeTable.invoke = { [weak self] in self?.importTable() }
            return c
        }
    }
    func showAddressBook() {
        showUtility("address-book") {
            let c = ClassicAddressBookWindow(preferences:preferences)
            c.createEndpoint = { [weak self, weak c] in
                guard let c else { return }
                self?.showConnect(ClassicEndpoint(),saving: { endpoint in try c.save(endpoint) })
            }
            c.editEndpoint = { [weak self, weak c] endpoint in
                guard let c else { return }
                self?.showConnect(endpoint,saving: { updated in try c.save(updated) })
            }
            c.connectEndpoint = { [weak self] endpoint in self?.showConnect(endpoint) }
            return c
        }
    }
    func showTracker(_ endpoint: ClassicEndpoint) {
        showUtility("tracker-"+endpoint.id.uuidString) { TrackerWindow(endpoint:endpoint,preferences:preferences) { [weak self] selected in self?.showConnect(selected) } }
    }
}

@MainActor struct ClassicTrackerQueries {
    var groups: () async throws -> [TrackerGroup]
    var servers: (TrackerGroup) async throws -> [TrackerServer]
    static func live(_ endpoint: ClassicEndpoint) -> Self {
        Self(groups: {
            try await KDXTrackerClient(host:endpoint.host,port:endpoint.port).groups(table:KDXStorage.loadTable())
        },servers: { group in
            try await KDXTrackerClient(host:endpoint.host,port:endpoint.port).servers(in:group,table:KDXStorage.loadTable())
        })
    }
}

@MainActor class TrackerWindow: ClassicWindowController {
    let commandID = UUID()
    let endpoint: ClassicEndpoint
    let groups: ClassicList
    let servers: ClassicList
    let state = classicLabel("Ready")
    var groupRecords: [TrackerGroup] = []
    var serverRecords: [TrackerServer] = []
    var generation = UUID()
    private let queries: ClassicTrackerQueries
    init(endpoint: ClassicEndpoint, preferences: ClassicPreferences, queries: ClassicTrackerQueries? = nil, connect: @escaping (ClassicEndpoint) -> Void) {
        self.endpoint = endpoint
        self.queries = queries ?? .live(endpoint)
        groups = ClassicList(columns:["Group","Servers"],key:"tracker-groups",preferences:preferences)
        servers = ClassicList(columns:["Server","Description","Address"],key:"tracker-servers",preferences:preferences)
        super.init(title:"Tracker — \(endpoint.host)",key:"tracker",size:NSSize(width:780,height:480),preferences:preferences)
        let split = ClassicSplitView(); split.isVertical = true; split.addArrangedSubview(groups); split.addArrangedSubview(servers)
        split.autosaveName = "org.macos-kdx.KDXClassic.tracker-panes"
        groups.widthAnchor.constraint(greaterThanOrEqualToConstant:160).isActive = true; servers.widthAnchor.constraint(greaterThanOrEqualToConstant:300).isActive = true
        let select: () -> Void = { [weak self] in
            guard let self, let selected = servers.selected, let record = serverRecords.first(where: { String($0.id) == selected.id }), let host = record.host, let port = record.port else { return }
            var item = ClassicEndpoint(); item.name = record.name; item.host = host; item.port = port; item.tracker = record.isTracker; connect(item)
        }
        groups.selectionChanged = { [weak self] row in guard let self, let row, let group = groupRecords.first(where: { String($0.id) == row.id }) else { return }; load(group) }
        servers.activate = { _ in select() }
        install(classicColumn([classicRow([ClassicButton("Refresh") { [weak self] in self?.refresh() },ClassicButton("Cancel") { [weak self] in self?.cancelQuery() },ClassicButton("Connect…",action:select)]),split,state]))
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func cancelQuery() { generation = UUID(); cancelTask("query"); state.stringValue = "Cancelled" }
    func refresh() {
        generation = UUID(); let token = generation; state.stringValue = "Loading groups…"; groupRecords = []; groups.rows = []; serverRecords = []; servers.rows = []
        run("query") { [weak self] in
            guard let self else { return }
            do { let records = try await queries.groups()
                guard generation == token, !Task.isCancelled else { return }; groupRecords = records; groups.rows = records.map { ClassicRow(id:String($0.id),values:[$0.name,String($0.serverCount)]) }; state.stringValue = "Select a group."
            } catch { if generation == token { state.stringValue = error.localizedDescription }; throw error }
        }
    }
    func load(_ group: TrackerGroup) {
        generation = UUID(); let token = generation; state.stringValue = "Loading \(group.name)…"; serverRecords = []; servers.rows = []
        run("query") { [weak self] in
            guard let self else { return }
            do { let records = try await queries.servers(group)
                guard generation == token, !Task.isCancelled else { return }
                serverRecords = records
                servers.rows = records.map { record in
                    let address = record.host.flatMap { host in record.port.map { "\(host):\($0)" } } ?? "Unsupported address"
                    return ClassicRow(id:String(record.id),values:[record.name,record.description,address])
                }
                state.stringValue = "\(records.count) servers"
            } catch { if generation == token { state.stringValue = error.localizedDescription }; throw error }
        }
    }
}
