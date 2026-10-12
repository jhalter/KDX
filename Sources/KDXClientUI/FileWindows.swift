import AppKit
import KDXCore

extension ClassicApplication {
    func showFiles(_ session: ClassicSession) {
        let id = UUID()
        let c = FilesWindow(session:session,preferences:preferences) { [weak self] in self?.showTransfers(session) }
        register(c,session:session,kind:.files(id))
    }
    func showTransfers(_ session: ClassicSession) {
        guard !existing(session,.transfers) else { return }
        let c = ClassicWindowController(title:"File Transfers — \(session.title)",key:"transfers",size:NSSize(width:790,height:400),preferences:preferences)
        let list = ClassicList(columns:["File","Direction","Remote Folder","Status","Progress"],key:"transfers",preferences:preferences,kind:.transfers)
        let queue = session.transfers
        @MainActor func selected() -> ClassicTransfer? { queue.items.first { $0.id.uuidString == list.selected?.id } }
        let start: () -> Void = { if let item = selected() { queue.retry(item) } }
        let stop: () -> Void = { if let item = selected() { queue.stop(item) } }
        let up: () -> Void = { if let item = selected() { queue.move(item,by:-1) } }
        let down: () -> Void = { if let item = selected() { queue.move(item,by:1) } }
        let remove: () -> Void = { if let item = selected() { queue.remove(item) } }
        let clear: () -> Void = { queue.clearCompleted() }
        let actions = [("Start / Resume",start),("Stop",stop),("Move Up",up),("Move Down",down),("Remove",remove),("Clear Finished",clear)]
        let menu = ClassicMenu(title:""); for (name, action) in actions { menu.addItem(menuItem(name,action:action)) }; list.table.menu = menu
        list.table.command = { event in
            switch event.keyCode {
            case 36,76: start(); return true
            case 53,47: stop(); return true
            case 51: if event.modifierFlags.contains(.command) { clear() } else { remove() }; return true
            case 126 where event.modifierFlags.contains(.command): up(); return true
            case 125 where event.modifierFlags.contains(.command): down(); return true
            default: return false
            }
        }
        let detail = classicLabel("Stopped transfers retain their partial data. One active transfer per server.")
        list.selectionChanged = { _ in detail.stringValue = selected()?.error ?? "Stopped transfers retain their partial data. One active transfer per server." }
        c.install(classicColumn([classicRow(actions.map { ClassicButton($0.0,action:$0.1) }),list,detail]))
        c.observation.start { [weak c, weak list] in
            c?.title = "File Transfers — \(session.title)"
            list?.rows = queue.items.map { item in
                let progress = item.id == queue.activeID ? session.client.transferProgress : item.progress
                return ClassicRow(id:item.id.uuidString,values:[item.name,item.isUpload ? "Upload" : "Download","/"+item.folder.joined(separator:"/"),item.state.rawValue,"\(ClassicProgressValue(progress).percent)%"],progress:progress)
            }
        }
        register(c,session:session,kind:.transfers)
    }
}

@MainActor final class FilesWindow: ClassicWindowController {
    let session: ClassicSession
    let list: ClassicList
    let folders: ClassicList
    let pathMenu = ClassicPopUpButton("Folder")
    let status = classicLabel("Ready")
    var path: [String] = []
    var entries: [RemoteFile] = []
    var generation = UUID()
    let showTransfers: () -> Void
    init(session: ClassicSession, preferences: ClassicPreferences, showTransfers: @escaping () -> Void) {
        self.session = session; self.showTransfers = showTransfers
        list = ClassicList(columns:["Name","Size","Kind","Modified"],key:"files",preferences:preferences,kind:.files)
        folders = ClassicList(columns:["Folders"],key:"file-folders",preferences:preferences,kind:.files)
        super.init(title:"Files — \(session.title)",key:"files",size:NSSize(width:800,height:480),preferences:preferences)
        pathMenu.target = self; pathMenu.action = #selector(selectPath)
        list.table.allowsMultipleSelection = true
        let split = ClassicSplitView(); split.isVertical = true; split.addArrangedSubview(folders); split.addArrangedSubview(list); split.autosaveName = "org.macos-kdx.KDXClassic.files-panes"
        folders.widthAnchor.constraint(greaterThanOrEqualToConstant:140).isActive = true; list.widthAnchor.constraint(greaterThanOrEqualToConstant:340).isActive = true
        list.activate = { [weak self] row in guard let self, let file = entries.first(where: { $0.id == row.id }) else { return }; if file.isDirectory { navigate(path+[file.name]) } else { download() } }
        folders.activate = { [weak self] row in guard let self else { return }; if row.id == ".." { navigate(Array(path.dropLast())) } else { navigate(path+[row.id]) } }
        let refresh: () -> Void = { [weak self] in guard let self else { return }; navigate(path) }
        let upload: () -> Void = { [weak self] in self?.upload() }
        let download: () -> Void = { [weak self] in self?.download() }
        let info: () -> Void = { [weak self] in self?.info() }
        let menu = ClassicMenu(title:""); for (title,action) in [("Download",download),("Get Info",info),("Upload…",upload),("Refresh",refresh)] { menu.addItem(menuItem(title,action:action)); windowMenu.addItem(menuItem(title,action:action)) }; list.table.menu = menu
        install(classicColumn([classicRow([ClassicButton("Back") { [weak self] in guard let self else { return }; navigate(Array(path.dropLast())) },ClassicButton("Refresh",action:refresh),pathMenu,ClassicButton("Upload…",action:upload),ClassicButton("Download…",action:download),ClassicButton("Info",action:info)]),split,status]))
        navigate([])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func selectPath() { navigate(Array(path.prefix(max(0,pathMenu.indexOfSelectedItem)))) }
    func navigate(_ destination: [String]) {
        generation = UUID(); let token = generation; status.stringValue = "Loading /"+destination.joined(separator:"/")
        run("listing") { [weak self] in
            guard let self else { return }
            do {
                let files = try await session.client.files(at:destination)
                guard token == generation, !Task.isCancelled else { return }
                path = destination; entries = files
                pathMenu.removeAllItems(); pathMenu.addItem(withTitle:"/"); for component in path { pathMenu.addItem(withTitle:component) }; pathMenu.selectItem(at:path.count)
                list.rows = files.map { ClassicRow(id:$0.id,values:[$0.name,$0.isDirectory ? "" : String($0.size),$0.isDirectory ? "Folder" : $0.kind,$0.modified.formatted()],iconID:ClassicFileKind.iconID($0.kind,isDirectory:$0.isDirectory)) }
                folders.rows = (path.isEmpty ? [] : [ClassicRow(id:"..",values:[".. (Parent)"],iconID:40)]) + files.filter(\.isDirectory).map { ClassicRow(id:$0.name,values:[$0.name],iconID:ClassicFileKind.iconID($0.kind,isDirectory:true)) }
                title = "Files — \(session.title) — /\(path.joined(separator:"/"))"; status.stringValue = "[\(files.count)] items"
            } catch { if token == generation { status.stringValue = error.localizedDescription }; throw error }
        }
    }
    func info() {
        guard let row = list.selected, let file = entries.first(where: { $0.id == row.id }) else { return }
        let captured = path+[file.name]
        run("info") { [weak self, session] in
            let info = try await session.client.fileInformation(path:captured)
            self?.showMessage("Name: \(info.name)\nKind: \(info.kind)\nSize: \(info.size) bytes\nCreated: \(info.created?.formatted() ?? "Unknown")\nModified: \(info.modified?.formatted() ?? "Unknown")",title:"File Information")
        }
    }
    func download() {
        let selected = list.table.selectedRowIndexes.compactMap { index -> RemoteFile? in guard list.visible.indices.contains(index) else { return nil }; return entries.first { $0.id == list.visible[index].id } }
        guard !selected.isEmpty else { return }
        guard !selected.contains(where: \.isDirectory) else { showMessage("Open a folder and select files to download. Recursive folder transfer is not yet supported."); return }
        let captured = path
        if selected.count == 1 {
            let file = selected[0], panel = NSSavePanel(); panel.nameFieldStringValue = file.name; panel.canCreateDirectories = true
            panel.begin { [weak self] response in guard response == .OK, let url = panel.url, let self else { return }; session.transfers.enqueue(ClassicTransfer(folder:captured,localURL:url,file:file)); showTransfers() }
        } else {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "Download Here"
            panel.begin { [weak self] response in guard response == .OK, let destination = panel.url, let self else { return }
                for file in selected { session.transfers.enqueue(ClassicTransfer(folder:captured,localURL:destination.appendingPathComponent(file.name),file:file)) }; showTransfers()
            }
        }
    }
    func upload() {
        let captured = path, panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.begin { [weak self] result in guard result == .OK, let self else { return }
            for url in panel.urls { session.transfers.enqueue(ClassicTransfer(folder:captured,localURL:url)) }; showTransfers()
        }
    }
}
