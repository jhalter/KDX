import AppKit
import KDXCore

@MainActor final class ClassicServerAccountsWindow: ClassicServerFormWindow {
    private let model: ClassicServerModel
    private let base: ServerConfiguration
    private var draft: ServerConfiguration
    let list: ClassicList
    let login = ClassicTextField(), password = ClassicSecureTextField()
    let administrator = ClassicCheckbox("Administrator")
    let add = ClassicButton("Add Account") {}, remove = ClassicButton("Remove Account") {}
    let save = ClassicButton("Save",key:"\r") {}
    init(model: ClassicServerModel, preferences: ClassicPreferences) {
        self.model = model; base = model.configuration; draft = base
        list = ClassicList(columns:["Login","Class"],key:"server-accounts",preferences:preferences)
        super.init(title:"KDX Server Accounts",key:"server-accounts",size:NSSize(width:480,height:400),preferences:preferences)
        list.heightAnchor.constraint(equalToConstant:170).isActive = true
        add.invoke = { [weak self] in self?.addAccount() }
        remove.invoke = { [weak self] in
            guard let self, model.editable, let id = list.selected?.id else { return }
            draft.accounts.removeAll { $0.id == id }; reload()
        }
        save.invoke = { [weak self] in
            guard let self else { return }
            do { try model.save(draft,replacing:base); requestClose() } catch { showError(error) }
        }
        let cancel = ClassicButton("Cancel",key:"\u{1b}") { [weak self] in self?.requestClose() }
        list.selectionChanged = { [weak self] _ in self?.updateEnabled() }
        setRows([list,serverFieldRow("Login:",login),serverFieldRow("Password:",password),administrator,classicRow([add,remove]),
                 serverNote("Passwords are stored as KDX account keys. Stop the server to edit accounts. Save applies all additions and removals."),classicRow([save,cancel])])
        clearSecrets = { [weak self] in self?.password.stringValue = "" }
        window?.defaultButtonCell = save.cell as? NSButtonCell; window?.initialFirstResponder = login
        reload(); observation.start { [weak self] in self?.updateEnabled() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func addAccount() {
        guard model.editable else { return }
        let name = login.stringValue
        guard !name.isEmpty, name.utf8.count <= 31, !name.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              !draft.accounts.contains(where:{ $0.login == name }), !password.stringValue.isEmpty else {
            showMessage("Enter a unique login of 1–31 UTF-8 bytes without control characters and a nonempty password."); return
        }
        draft.accounts.append(ServerAccount(login:name,password:password.stringValue,isAdmin:administrator.state == .on))
        login.stringValue = ""; password.stringValue = ""; administrator.state = .off; reload()
    }
    private func reload() {
        list.rows = draft.accounts.map { account in
            ClassicRow(id:account.id,values:[account.login,account.effective(in:draft.accountClasses).contains(0) ? "Administrator" : draft.accountClasses.first { $0.id == account.classID }?.name ?? "Member"])
        }; updateEnabled()
    }
    private func updateEnabled() {
        for control in [login,password,administrator,add,save] as [NSControl] { control.isEnabled = model.editable }
        remove.isEnabled = model.editable && list.selected != nil
    }
}

@MainActor final class ClassicServerUsersWindow: ClassicWindowController {
    let form: ClassicUsersForm
    private let disconnect = ClassicButton("Disconnect") {}
    private let model: ClassicServerModel
    init(model: ClassicServerModel, preferences: ClassicPreferences) {
        self.model = model; form = ClassicUsersForm(preferences:preferences)
        super.init(title:"User List — KDX Server",key:"server-users",size:serverWindowSize(NSSize(width:400,height:400)),preferences:preferences)
        form.server.addItem(withTitle:model.configuration.name); form.server.isEnabled = false
        disconnect.invoke = { [weak self] in self?.disconnectSelected() }
        form.list.selectionChanged = { [weak self] _ in self?.updateEnabled() }
        let menu = ClassicMenu(title:"")
        menu.addItem(menuItem("Disconnect") { [weak self] in self?.disconnectSelected() })
        form.list.table.menu = menu
        install(classicColumn([form,disconnect])); window?.initialFirstResponder = form.list.table
        observation.start { [weak self] in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func updateEnabled() { disconnect.isEnabled = model.server.isRunning && form.list.selected != nil }
    private func refresh() {
        form.server.item(at:0)?.title = model.configuration.name
        form.count.stringValue = String(model.server.users.count)
        form.list.rows = model.server.users.map { user in
            ClassicRow(id:String(user.id),values:[user.nickname,user.info,user.isAdmin ? "Administrator" : "Member"],userAdornment:ClassicUserAdornment(user:user))
        }
        updateEnabled()
    }
    private func disconnectSelected() {
        guard let id = form.list.selected?.id, let value = UInt32(id), model.server.users.contains(where:{ $0.id == value }) else { return }
        model.server.disconnectUser(value)
    }
}
