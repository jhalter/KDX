import AppKit
import KDXCore

/// Primary control rectangles from VWIN `knkt`, REZ-relative 0x11CE8.
/// Modern connection settings occupy a separate, optional extension below it.
@MainActor final class ClassicConnectForm: ClassicSurface {
    static let referenceSize = NSSize(width:390,height:192)
    let type = ClassicPopUpButton("Endpoint type")
    let name = ClassicTextField(), host = ClassicTextField(), login = ClassicTextField()
    let password = ClassicSecureTextField()
    let port = ClassicTextField(), nickname = ClassicTextField()
    let autoJoin = ClassicCheckbox("Open Public Chat on connect")
    let submit: ClassicButton
    let cancel = ClassicButton("Cancel",key:"\u{1b}",height:20) {}
    let optionsButton = ClassicButton("Options…",height:20) {}
    let optionsArea = ClassicSurface()
    private(set) var labels: [String:NSTextField] = [:]
    private(set) var optionsVisible = false
    private let initialEndpoint: ClassicEndpoint
    private var previousTracker: Bool
    var optionsChanged: (() -> Void)?
    var preferredHeight: CGFloat { optionsVisible ? 294 : Self.referenceSize.height }

    init(endpoint: ClassicEndpoint, saving: Bool) {
        initialEndpoint = endpoint; previousTracker = endpoint.tracker
        submit = ClassicButton(saving ? "Save" : "Connect",key:"\r",height:26) {}
        super.init(frame:NSRect(origin:.zero,size:Self.referenceSize))
        type.addItems(withTitles:["Server","Tracker"]); type.selectItem(at:endpoint.tracker ? 1 : 0)
        type.target = self; type.action = #selector(typeChanged)
        name.stringValue = endpoint.name; host.stringValue = endpoint.host; login.stringValue = endpoint.login
        port.stringValue = String(endpoint.port); nickname.stringValue = endpoint.nickname
        autoJoin.state = endpoint.autoJoin ? .on : .off
        password.toolTip = "Leave login and password blank for guest access. Passwords are kept in memory only."
        login.toolTip = "Leave login and password blank for guest access."
        name.toolTip = "An optional name for this connection."
        for (field,label) in [(name,"Name"),(host,"Address"),(login,"Login"),(port,"Port"),(nickname,"Nickname")] {
            field.setAccessibilityLabel(label); field.applyStyle()
        }
        password.setAccessibilityLabel("Password"); password.applyStyle()
        func place(_ view: NSView, x: CGFloat, y: CGFloat, width: CGFloat? = nil, right: CGFloat? = nil, height: CGFloat, in parent: NSView? = nil) {
            let parent = parent ?? self
            parent.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
            // AppKit anchors text fields by their alignment rectangles, inset two
            // pixels horizontally. Template rectangles describe the painted frame.
            let inset = view.alignmentRectInsets
            var constraints = [view.leadingAnchor.constraint(equalTo:parent.leadingAnchor,constant:x+inset.left),view.topAnchor.constraint(equalTo:parent.topAnchor,constant:y+inset.top),view.heightAnchor.constraint(equalToConstant:height-inset.top-inset.bottom)]
            if let width { constraints.append(view.widthAnchor.constraint(equalToConstant:width-inset.left-inset.right)) }
            if let right { constraints.append(view.trailingAnchor.constraint(equalTo:parent.trailingAnchor,constant:-right-inset.right)) }
            NSLayoutConstraint.activate(constraints)
        }
        func label(_ text: String, y: CGFloat, width: CGFloat = 90, in parent: NSView? = nil) {
            let view = classicLabel(text+":"); labels[text] = view
            place(view,x:10,y:y,width:width,height:16,in:parent)
        }
        label("Type",y:12,width:75); place(type,x:100,y:10,width:150,height:20)
        label("Name",y:41); place(name,x:100,y:36,right:10,height:26)
        label("Address",y:71); place(host,x:100,y:66,right:10,height:26)
        label("Login",y:101,width:75); place(login,x:100,y:96,right:10,height:26)
        label("Password",y:131); place(password,x:100,y:126,right:10,height:26)
        for (button,right,y,width,height) in [(submit,CGFloat(34),CGFloat(158),CGFloat(96),CGFloat(26)),(cancel,150,161,90,20)] {
            addSubview(button); button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([button.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-right),button.topAnchor.constraint(equalTo:topAnchor,constant:y),button.widthAnchor.constraint(equalToConstant:width),button.heightAnchor.constraint(equalToConstant:height)])
        }
        place(optionsButton,x:10,y:161,width:110,height:20)
        place(optionsArea,x:0,y:192,right:0,height:102)
        label("Port",y:9,in:optionsArea); place(port,x:100,y:4,width:120,height:26,in:optionsArea)
        label("Nickname",y:39,in:optionsArea); place(nickname,x:100,y:34,right:10,height:26,in:optionsArea)
        place(autoJoin,x:98,y:70,right:10,height:22,in:optionsArea)
        optionsButton.invoke = { [weak self] in guard let self else { return }; setOptionsVisible(!optionsVisible) }
        optionsArea.isHidden = true
        updateServiceControls(); updateKeyLoop()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func cancelOperation(_ sender: Any?) { cancel.performClick(sender) }

    @objc func typeChanged() {
        let tracker = type.indexOfSelectedItem == 1
        // Keep a custom port, but follow the service when the old default is present.
        if port.stringValue == String(previousTracker ? 10800 : 10700) { port.stringValue = String(tracker ? 10800 : 10700) }
        previousTracker = tracker; updateServiceControls()
    }
    private func updateServiceControls() {
        let server = type.indexOfSelectedItem == 0
        login.isEnabled = server; password.isEnabled = server; nickname.isEnabled = server; autoJoin.isEnabled = server
    }
    func setOptionsVisible(_ visible: Bool) {
        guard visible != optionsVisible else { return }
        if !visible, let responder = window?.firstResponder,
           responder === port.currentEditor() || responder === nickname.currentEditor() || responder === autoJoin {
            window?.makeFirstResponder(optionsButton)
        }
        optionsVisible = visible; optionsArea.isHidden = !visible
        optionsButton.title = visible ? "Hide Options" : "Options…"
        optionsButton.setAccessibilityLabel(optionsButton.title)
        updateKeyLoop(); optionsChanged?()
    }
    private func updateKeyLoop() {
        var controls: [NSView] = [type,name,host,login,password,optionsButton]
        if optionsVisible { controls += [port,nickname,autoJoin] }
        controls += [cancel,submit]
        for (index,control) in controls.enumerated() { control.nextKeyView = controls[(index+1)%controls.count] }
    }
    func endpoint() throws -> ClassicEndpoint {
        guard let value = UInt16(port.stringValue), value > 0 else { throw KDXError.invalid("Port must be 1–65535.") }
        var result = initialEndpoint
        result.name = name.stringValue; result.host = host.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        result.port = value; result.login = login.stringValue; result.nickname = nickname.stringValue
        result.tracker = type.indexOfSelectedItem == 1; result.autoJoin = autoJoin.state == .on
        try result.validate(); return result
    }
    func clearPassword() { password.currentEditor()?.string = ""; password.stringValue = "" }
}

@MainActor final class ClassicConnectWindow: ClassicWindowController {
    let form: ClassicConnectForm
    var submitted: ((ClassicEndpoint,String) throws -> Void)?
    init(endpoint: ClassicEndpoint, saving: Bool, preferences: ClassicPreferences) {
        form = ClassicConnectForm(endpoint:endpoint,saving:saving)
        super.init(title:saving ? "Address Book Item" : "KDX Connect",key:"connect",size:NSSize(width:402,height:220),preferences:preferences)
        form.setOptionsVisible(preferences.defaults.bool(forKey:"connect.options"))
        form.optionsChanged = { [weak self] in
            guard let self else { return }
            preferences.defaults.set(form.optionsVisible,forKey:"connect.options"); fitForm()
        }
        form.submit.invoke = { [weak self] in
            guard let self else { return }
            do {
                let endpoint = try form.endpoint()
                try submitted?(endpoint,form.password.stringValue)
                form.clearPassword(); requestClose()
            } catch { showError(error) }
        }
        form.cancel.invoke = { [weak self] in self?.requestClose() }
        install(form)
        window?.defaultButtonCell = form.submit.cell as? NSButtonCell
        window?.initialFirstResponder = form.host
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func applyStyle() { super.applyStyle(); fitForm() }
    override func maximize() { super.maximize(); fitForm() }
    private func fitForm() {
        guard let window else { return }
        let probe = NSRect(x:0,y:0,width:1000,height:1000), content = HAPWindowDrawing.contentRect(in:probe)
        let horizontal = probe.width-content.width, vertical = probe.height-content.height
        let height = form.preferredHeight+vertical, minimumWidth = ClassicConnectForm.referenceSize.width+horizontal
        // Update both bounds without leaving the old fixed height in conflict
        // with the new one when Options changes the form's height.
        window.minSize = .zero
        window.maxSize = NSSize(width:1000+horizontal,height:height)
        window.minSize = NSSize(width:minimumWidth,height:height)
        let old = window.frame
        let frame = NSRect(x:old.minX,y:old.maxY-height,width:max(minimumWidth,min(old.width,window.maxSize.width)),height:height)
        let constrained = ClassicPreferences.constrain(frame,to:NSScreen.screens.map(\.visibleFrame),fallback:frame)
        if window.frame != constrained { window.setFrame(constrained,display:false) }
    }
    override func windowWillClose(_ notification: Notification) { form.clearPassword(); super.windowWillClose(notification) }
}
