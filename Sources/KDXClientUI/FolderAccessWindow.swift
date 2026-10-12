import AppKit
import KDXCore

@MainActor final class FolderAccessWindow: ClassicWindowController {
    let session: ClassicSession
    let list: ClassicList
    var items: [FolderAccessSummary] = []
    var editors: [ClassicWindowController] = []
    init(session: ClassicSession, preferences: ClassicPreferences) {
        self.session = session
        list = ClassicList(columns: ["Name","Description"], key: "folder-access", preferences: preferences, kind: .files)
        super.init(title: "Folder Access", key: "folder-access", size: NSSize(width: 600,height: 400), preferences: preferences)
        list.activate = { [weak self] _ in self?.edit() }
        install(classicColumn([classicRow([ClassicButton("New") { [weak self] in self?.edit(creating: true) },ClassicButton("Edit") { [weak self] in self?.edit() },ClassicButton("Delete") { [weak self] in self?.delete() },ClassicButton("Refresh") { [weak self] in self?.refresh() }]),list]))
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        run { [weak self] in guard let self else { return }; items = try await session.client.folderAccessList(); list.rows = items.map { ClassicRow(id: $0.name, values: [$0.name,$0.description]) } }
    }
    func edit(creating: Bool = false) {
        let name = list.selected?.id; guard creating || name != nil else { return }
        run { [weak self] in
            guard let self else { return }
            let item = creating ? FolderAccess(name: "New") : try await session.client.folderAccess(name: name!)
            try await session.client.loadAccountClasses()
            let classes = session.client.accountClasses
            let editor = FolderAccessEditor(item: item, classes: classes, creating: creating, session: session, preferences: preferences) { [weak self] in self?.refresh() }
            editors.append(editor); editor.showWindow(nil)
        }
    }
    func delete() {
        guard let name = list.selected?.id else { return }
        confirm("Delete Folder Access", message: "Delete the access rules named \(name)? Tagged folders will inherit their parent's rules.", acceptTitle: "Delete") { [weak self] accepted in
            guard accepted else { return }; self?.run { [weak self] in guard let self else { return }; try await session.client.deleteFolderAccess(name: name); refresh() }
        }
    }
}
@MainActor private final class FolderAccessEditor: ClassicWindowController {
    var item: FolderAccess
    let classes: [AccountClass]
    let selector = ClassicPopUpButton("Account class")
    let name = ClassicTextField(), ownerField = ClassicTextField(), details = ClassicTextField()
    let ownerInName = ClassicCheckbox("Read owner login from folder name")
    let checks = FolderAccess.permissions.map { ClassicCheckbox($0) }
    var selectedRule = 0
    init(item: FolderAccess, classes: [AccountClass], creating: Bool, session: ClassicSession, preferences: ClassicPreferences, saved: @escaping () -> Void) {
        self.item = item; self.classes = classes
        super.init(title: "Edit Folder Access", key: "folder-access-editor", size: NSSize(width: 540,height: 630), preferences: preferences)
        name.stringValue = item.name; ownerField.stringValue = item.owner; details.stringValue = item.description; ownerInName.state = item.flags&2 != 0 ? .on : .off
        for entry in classes { selector.addItem(withTitle: entry.name) }; selector.addItem(withTitle: "Folder owner")
        selector.target = self; selector.action = #selector(selectRule)
        let save = ClassicButton("Save") { [weak self] in
            guard let self else { return }; storeRule()
            self.item.currentName = creating ? "" : item.name; self.item.name = name.stringValue; self.item.owner = ownerField.stringValue; self.item.description = details.stringValue
            self.item.flags = (self.item.flags & ~2) | (ownerInName.state == .on ? 2 : 0)
            let snapshot = self.item
            run { [weak self] in try await session.client.saveFolderAccess(snapshot, creating: creating); saved(); self?.close() }
        }
        install(classicColumn([classicRow([classicLabel("Name"),name]),classicRow([classicLabel("Description"),details]),classicRow([classicLabel("Owner Login"),ownerField]),ownerInName,selector] + checks + [classicRow([save,ClassicButton("Cancel") { [weak self] in self?.close() }])]))
        showRule()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func storeRule() {
        let rule = checks.enumerated().reduce(UInt16(0)) { $0 | ($1.element.state == .on ? UInt16(0x8000 >> $1.offset) : 0) }
        if selectedRule < classes.count { item.classRules[Int(classes[selectedRule].id)] = rule } else { item.ownerRule = rule }
    }
    private func showRule() {
        let rule = selectedRule < classes.count ? item.classRules[Int(classes[selectedRule].id)] : item.ownerRule
        for (index,check) in checks.enumerated() { check.state = rule & (0x8000 >> index) != 0 ? .on : .off }
    }
    @objc private func selectRule() { storeRule(); selectedRule = max(0,selector.indexOfSelectedItem); showRule() }
}
