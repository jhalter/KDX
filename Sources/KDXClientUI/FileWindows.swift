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
    var path = RemotePath([])
    var entries: [RemoteFile] = []
    var generation = UUID()
    var auxiliaryWindows: [ClassicWindowController] = []
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
        list.activate = { [weak self] row in guard let self, let file = entries.first(where: { $0.id == row.id }) else { return }; if file.isDirectory { navigate(path.appending(file)) } else { download() } }
        folders.activate = { [weak self] row in guard let self else { return }; if row.id == ".." { navigate(path.parent) } else if let file = entries.first(where: { $0.id == row.id }) { navigate(path.appending(file)) } }
        let refresh: () -> Void = { [weak self] in guard let self else { return }; navigate(path) }
        let upload: () -> Void = { [weak self] in self?.upload() }
        let download: () -> Void = { [weak self] in self?.download() }
        let info: () -> Void = { [weak self] in self?.info() }
        let menu = ClassicMenu(title:"")
        let actions: [(String, () -> Void)] = [("Download",download),("Get Info",info),("Upload…",upload),("Refresh",refresh),
            ("New Folder…", { [weak self] in self?.newFolder() }), ("Rename…", { [weak self] in self?.renameSelected() }),
            ("Move To…", { [weak self] in self?.moveSelected() }), ("Move to Trash…", { [weak self] in self?.trashSelected() }),
            ("Empty Server Trash…", { [weak self] in self?.emptyServerTrash() }), ("Volume Information", { [weak self] in self?.volumeInfo() }),
            ("Generate Catalog", { [weak self] in self?.generateCatalog() }),
            ("Cancel Catalog", { [weak self] in self?.run { [weak self] in try await self?.session.client.generateCatalog(cancel: true) } }), ("Search…", { [weak self] in self?.search() }),
            ("Folder Access…", { [weak self] in self?.manageAccess() })]
        for (title,action) in actions { menu.addItem(menuItem(title,action:action)); windowMenu.addItem(menuItem(title,action:action)) }; list.table.menu = menu
        install(classicColumn([classicRow([ClassicButton("New Folder…") { [weak self] in self?.newFolder() },ClassicButton("Search…") { [weak self] in self?.search() },ClassicButton("Back") { [weak self] in guard let self else { return }; navigate(path.parent) },ClassicButton("Refresh",action:refresh),pathMenu,ClassicButton("Upload…",action:upload),ClassicButton("Download…",action:download),ClassicButton("Info",action:info)]),split,status]))
        navigate(RemotePath([]))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func selectPath() { navigate(path.prefix(max(0,pathMenu.indexOfSelectedItem))) }
    func navigate(_ destination: RemotePath) {
        generation = UUID(); let token = generation; status.stringValue = "Loading /"+destination.names.joined(separator:"/")
        run("listing") { [weak self] in
            guard let self else { return }
            do {
                let files = try await session.client.files(at:destination)
                guard token == generation, !Task.isCancelled else { return }
                path = destination; entries = files
                pathMenu.removeAllItems(); pathMenu.addItem(withTitle:"/"); for component in path.names { pathMenu.addItem(withTitle:component) }; pathMenu.selectItem(at:path.components.count)
                list.rows = files.map { ClassicRow(id:$0.id,values:[$0.name,$0.isDirectory ? "" : String($0.size),$0.isDirectory ? "Folder" : $0.kind,$0.modified.formatted()],iconID:ClassicFileKind.iconID($0.kind,isDirectory:$0.isDirectory)) }
                folders.rows = (path.components.isEmpty ? [] : [ClassicRow(id:"..",values:[".. (Parent)"],iconID:40)]) + files.filter(\.isDirectory).map { ClassicRow(id:$0.id,values:[$0.name],iconID:ClassicFileKind.iconID($0.kind,isDirectory:true)) }
                title = "Files — \(session.title) — /\(path.names.joined(separator:"/"))"; status.stringValue = "[\(files.count)] items"
            } catch { if token == generation { status.stringValue = error.localizedDescription }; throw error }
        }
    }
    func info() {
        guard let row = list.selected, let file = entries.first(where: { $0.id == row.id }) else { return }
        let captured = path.appending(file)
        run("info") { [weak self, session] in
            let info = try await session.client.itemInformation(path: captured)
            self?.showInformation(info)
        }
    }
    func download() {
        let selected = list.table.selectedRowIndexes.compactMap { index -> RemoteFile? in guard list.visible.indices.contains(index) else { return nil }; return entries.first { $0.id == list.visible[index].id } }
        guard !selected.isEmpty else { return }
        guard !selected.contains(where: \.isDirectory) else { showMessage("Open a folder and select files to download. Recursive folder transfer is not yet supported."); return }
        let captured = path
        if selected.count == 1 {
            let file = selected[0], panel = NSSavePanel(); panel.nameFieldStringValue = file.name; panel.canCreateDirectories = true
            panel.begin { [weak self] response in guard response == .OK, let url = panel.url, let self else { return }; session.transfers.enqueue(ClassicTransfer(remoteFolder:captured,localURL:url,file:file)); showTransfers() }
        } else {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "Download Here"
            panel.begin { [weak self] response in guard response == .OK, let destination = panel.url, let self else { return }
                for file in selected { session.transfers.enqueue(ClassicTransfer(remoteFolder:captured,localURL:destination.appendingPathComponent(file.name),file:file)) }; showTransfers()
            }
        }
    }
    func upload() {
        let captured = path, panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.begin { [weak self] result in guard result == .OK, let self else { return }
            for url in panel.urls { session.transfers.enqueue(ClassicTransfer(remoteFolder:captured,localURL:url)) }; showTransfers()
        }
    }
}


extension FilesWindow {
    private var selectedFiles: [RemoteFile] {
        list.table.selectedRowIndexes.compactMap { index in
            guard list.visible.indices.contains(index) else { return nil }
            return entries.first { $0.id == list.visible[index].id }
        }
    }
    func newFolder() {
        let folder = path
        presentDialog(ClassicDialogRequest(title: "New Folder", fields: [
            ClassicDialogField(id: "name", label: "Name"), ClassicDialogField(id: "access", label: "Folder access tag (optional)"),
            ClassicDialogField(id: "owner", label: "Owner login (optional)")], acceptTitle: "Create") { [weak self] values in
            guard let self, let values else { return }
            run { try await self.session.client.createFolder(name: values["name"] ?? "", at: folder, access: values["access"] ?? "", owner: values["owner"] ?? ""); self.navigate(folder) }
        })
    }
    func renameSelected() {
        guard selectedFiles.count == 1, let file = selectedFiles.first else { showMessage("Select one item to rename."); return }
        let folder = path
        prompt("Rename", initial: file.name, acceptTitle: "Rename") { [weak self] name in
            self?.run { [weak self] in guard let self else { return }; try await session.client.renameFile(file, at: folder, to: name); navigate(folder) }
        }
    }
    func moveSelected() {
        let files = selectedFiles, folder = path; guard !files.isEmpty else { return }
        prompt("Destination folder from shared root", initial: "/", acceptTitle: "Move") { [weak self] value in
            let destination = RemotePath(value.split(separator: "/").map(String.init))
            self?.run { [weak self] in guard let self else { return }; try await session.client.moveFiles(files, from: folder, to: destination); navigate(folder) }
        }
    }
    func trashSelected() {
        let files = selectedFiles, folder = path; guard !files.isEmpty else { return }
        confirm("Move to Server Trash", message: "Move \(files.count) selected items to the server's trash?", acceptTitle: "Move to Trash") { [weak self] accepted in
            guard accepted else { return }
            self?.run { [weak self] in guard let self else { return }; try await session.client.trashFiles(files, at: folder); navigate(folder) }
        }
    }
    func emptyServerTrash() {
        confirm("Empty Server Trash", message: "Permanently delete every item in the server's trash?", acceptTitle: "Empty Trash") { [weak self] accepted in
            guard accepted else { return }; self?.run { [weak self] in guard let self else { return }; try await session.client.emptyTrash() }
        }
    }
    func showInformation(_ information: FileOrVolumeInformation) {
        switch information {
        case .file(let info): showMessage("Name: \(info.name)\nKind: \(info.kind)\nSize: \(info.size) bytes\nCreated: \(info.created?.formatted() ?? "Unknown")\nModified: \(info.modified?.formatted() ?? "Unknown")",title:"File Information")
        case .volume(let volume): showMessage("Name: \(volume.name)\nFormat: \(volume.format)\nTotal: \(volume.totalSize == .max ? "Unknown" : String(volume.totalSize)) bytes\nFree: \(volume.freeSpace == .max ? "Unknown" : String(volume.freeSpace)) bytes\nComments: \(volume.comments)", title: "Volume Information")
        }
    }
    func volumeInfo() {
        run { [weak self] in guard let self else { return }; showInformation(try await session.client.itemInformation(path: RemotePath([]))) }
    }
    func generateCatalog() {
        run { [weak self] in guard let self else { return }; try await session.client.generateCatalog(); status.stringValue = "Catalog requested" }
        observation.start { [weak self] in
            guard let self, let progress = session.client.catalogProgress else { return }
            status.stringValue = progress.complete ? "Catalog ready: \(progress.count) items" : "Indexing: \(progress.count) items"
        }
    }
    func search() {
        prompt("Search files", acceptTitle: "Search") { [weak self] query in
            self?.run { [weak self] in guard let self else { return }
                let results = try await session.client.searchFiles(query)
                let controller = ClassicWindowController(title: "Search — \(query)", key: "file-search", size: NSSize(width: 650,height: 420), preferences: preferences)
                let list = ClassicList(columns: ["Name","Folder","Size"], key: "file-search", preferences: preferences, kind: .files)
                list.rows = results.enumerated().map { ClassicRow(id: String($0.offset), values: [$0.element.file.name, "/"+$0.element.path.parent.names.joined(separator: "/"), String($0.element.file.size)]) }
                list.activate = { [weak self] row in guard let index = Int(row.id), results.indices.contains(index) else { return }; self?.navigate(results[index].file.isDirectory ? results[index].path : results[index].path.parent) }
                controller.install(classicColumn([classicLabel("Double-click a result to open its folder."),list])); auxiliaryWindows.append(controller); controller.showWindow(nil)
            }
        }
    }
    func manageAccess() {
        let controller = FolderAccessWindow(session: session, preferences: preferences)
        auxiliaryWindows.append(controller); controller.showWindow(nil)
    }
}
