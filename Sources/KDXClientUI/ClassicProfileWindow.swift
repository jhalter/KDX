import AppKit
import KDXCore
import UniformTypeIdentifiers

/// Identity panel positions from VWIN klns. Preview and gradient/default-color
/// controls fill the original panel's unused lower/right area.
@MainActor final class ClassicProfileForm: ClassicSurface, NSTextFieldDelegate, NSTextViewDelegate {
    static let referenceSize = NSSize(width:450,height:330)
    let panel = classicLabel("Identity")
    let save = ClassicButton("Save",key:"\u{3}",height:26) {}
    let apply = ClassicButton("Apply",height:20) {}
    let cancel = ClassicButton("Cancel",key:"\u{1b}",height:20) {}
    let name = ClassicTextField(), info = ClassicMessageInput()
    let infoScroll = ClassicScrollView()
    let infoFrame: ClassicFieldFrame
    let foreground = ClassicProfileColorWell("Foreground color"), background = ClassicProfileColorWell("Background color")
    let icon = ClassicProfileIconWell()
    let chooseImage = ClassicButton("Choose Image…",height:20) {}
    let gradient = ClassicCheckbox("Gradient"), appearanceColors = ClassicCheckbox("Use Appearance Colors")
    let preview = ClassicMessageRecipientView()
    private(set) var labels: [String:NSTextField] = [:]
    private var stored: ClassicProfileDraft
    private var profile: KDXUser
    var changed: (() -> Void)?
    var draft: ClassicProfileDraft {
        var result = stored; result.nickname = name.stringValue; result.info = info.string
        result.gradient = gradient.state == .on; return result
    }
    init(user: KDXUser) {
        profile = user; stored = ClassicProfileDraft(user)
        infoScroll.documentView = info; infoScroll.hasVerticalScroller = true
        infoScroll.automaticallyAdjustsContentInsets = false; infoFrame = ClassicFieldFrame(infoScroll)
        super.init(frame:NSRect(origin:.zero,size:Self.referenceSize))
        name.delegate = self; name.setAccessibilityLabel("Name")
        info.delegate = self; info.isRichText = false; info.allowsUndo = true
        info.isVerticallyResizable = true; info.isHorizontallyResizable = false; info.autoresizingMask = [.width]
        info.minSize = .zero; info.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        info.textContainer?.widthTracksTextView = true; info.setAccessibilityLabel("Description")
        info.send = { [weak self] in self?.save.performClick(nil) }; info.cancel = { [weak self] in self?.cancel.performClick(nil) }
        for title in ["Name:","Description:","Foreground Color:","Background Color:","Icon:","Preview:"] { labels[title] = classicLabel(title) }
        gradient.target = self; gradient.action = #selector(controlChanged)
        appearanceColors.target = self; appearanceColors.action = #selector(defaultColorsChanged)
        layout()
        for view in [panel,save,apply,cancel,name,infoFrame,foreground,background,icon,chooseImage,gradient,appearanceColors,preview]+Array(labels.values) {
            addSubview(view); view.translatesAutoresizingMaskIntoConstraints = true
        }
        let controls: [NSView] = [name,info,foreground,background,icon,chooseImage,gradient,appearanceColors,save,apply,cancel]
        for index in controls.indices { controls[index].nextKeyView = controls[(index+1)%controls.count] }
        load(user); applyStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func load(_ user: KDXUser) {
        profile = user; stored = ClassicProfileDraft(user)
        name.stringValue = user.nickname; info.string = user.info; gradient.state = stored.gradient ? .on : .off
        appearanceColors.state = stored.usesAppearanceColors ? .on : .off
        updatePreview()
    }
    func setColor(_ rgb: UInt32, background isBackground: Bool) {
        if stored.usesAppearanceColors {
            stored.setColor(HAPUserRowDrawing.rgb(ClassicStyle.shared.color(16)),background:false)
            stored.setColor(HAPUserRowDrawing.rgb(ClassicStyle.shared.color(15)),background:true)
        }
        stored.setColor(rgb,background:isBackground); appearanceColors.state = .off
        updatePreview(); changed?()
    }
    func setIcon(_ bytes: [UInt8]) throws {
        guard bytes.isEmpty || ClassicUserIcon(bytes) != nil else { throw AppearanceError.invalid("Invalid KDX profile icon.") }
        stored.icon = bytes; updatePreview(); changed?()
    }
    @objc private func defaultColorsChanged() {
        if appearanceColors.state == .on { stored.colors = [UInt8](repeating:0,count:6) }
        else {
            stored.setColor(HAPUserRowDrawing.rgb(ClassicStyle.shared.color(16)),background:false)
            stored.setColor(HAPUserRowDrawing.rgb(ClassicStyle.shared.color(15)),background:true)
        }
        updatePreview(); changed?()
    }
    @objc private func controlChanged() { updatePreview(); changed?() }
    func controlTextDidChange(_ notification: Notification) { controlChanged() }
    func textDidChange(_ notification: Notification) { controlChanged() }
    func updatePreview() {
        let value = draft
        var user = profile; user.nickname = value.nickname; user.info = value.info
        user.colors = value.colors; user.icon = value.icon; user.flags = value.gradient ? 4 : 0
        preview.update(user); icon.bytes = value.icon
        preview.setAccessibilityLabel("Profile preview: \(value.nickname)")
        foreground.rgb = value.usesAppearanceColors ? HAPUserRowDrawing.rgb(ClassicStyle.shared.color(16)) : value.color(false)
        background.rgb = value.usesAppearanceColors ? HAPUserRowDrawing.rgb(ClassicStyle.shared.color(15)) : value.color(true)
    }
    func setEditable(_ editable: Bool) {
        name.isEnabled = editable; info.isEditable = editable
        for control in [foreground,background,icon,chooseImage,gradient,appearanceColors] { control.isEnabled = editable }
    }
    override func layout() {
        super.layout()
        panel.frame = NSRect(x:5,y:8,width:170,height:20)
        save.frame = NSRect(x:359,y:5,width:86,height:26)
        apply.frame = NSRect(x:283,y:8,width:70,height:20); cancel.frame = NSRect(x:197,y:8,width:80,height:20)
        name.frame = NSRect(x:165,y:55,width:250,height:26)
        infoFrame.frame = NSRect(x:165,y:85,width:250,height:70)
        foreground.frame = NSRect(x:165,y:165,width:40,height:20); background.frame = NSRect(x:375,y:165,width:40,height:20)
        icon.frame = NSRect(x:165,y:195,width:42,height:42)
        for (title,rect) in [("Name:",NSRect(x:15,y:60,width:75,height:16)),("Description:",NSRect(x:15,y:90,width:100,height:16)),
            ("Foreground Color:",NSRect(x:15,y:166,width:140,height:16)),("Background Color:",NSRect(x:225,y:166,width:140,height:16)),("Icon:",NSRect(x:15,y:197,width:75,height:16)),("Preview:",NSRect(x:15,y:288,width:100,height:16))] { labels[title]?.frame = rect }
        gradient.frame = NSRect(x:225,y:195,width:190,height:20); chooseImage.frame = NSRect(x:225,y:222,width:190,height:20)
        appearanceColors.frame = NSRect(x:165,y:250,width:250,height:20); preview.frame = NSRect(x:165,y:280,width:250,height:32)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        ClassicStyle.shared.color(3).setFill(); NSRect(x:2,y:37,width:445,height:1).fill()
        ClassicStyle.shared.color(1).setFill(); NSRect(x:2,y:38,width:445,height:1).fill()
    }
    func applyStyle() {
        name.applyStyle(); HAPFieldDrawing.configureEditor(info); infoScroll.applyStyle(); preview.applyStyle()
        for label in [panel]+Array(labels.values) { label.font = ClassicStyle.shared.font; label.textColor = ClassicStyle.shared.color(5) }
        updatePreview(); needsDisplay = true
    }
    override func cancelOperation(_ sender: Any?) { cancel.performClick(sender) }
}

@MainActor final class ClassicProfileWindow: ClassicWindowController {
    let session: ClassicSession
    let generation: UUID
    let form: ClassicProfileForm
    private(set) var isApplying = false
    private(set) var colorChooser: ClassicColorChooserWindow?
    var isCurrentConnection: Bool { generation == session.privateMessages.generation }
    init(session: ClassicSession, user: KDXUser, preferences: ClassicPreferences) {
        self.session = session; generation = session.privateMessages.generation; form = ClassicProfileForm(user:user)
        super.init(title:"My Profile — \(session.title)",key:"profile",size:NSSize(width:462,height:358),preferences:preferences)
        chrome.allowsResize = false
        if let item = windowMenu.item(withTitle:"Maximize / Restore") { windowMenu.removeItem(item) }
        form.save.invoke = { [weak self] in self?.submit(close:true) }
        form.apply.invoke = { [weak self] in self?.submit(close:false) }
        form.cancel.invoke = { [weak self] in self?.requestClose() }
        form.foreground.invoke = { [weak self] in self?.chooseColor(background:false) }
        form.background.invoke = { [weak self] in self?.chooseColor(background:true) }
        form.chooseImage.invoke = { [weak self] in self?.chooseImage() }
        form.icon.choose = form.chooseImage.invoke
        form.icon.removeIcon = { [weak self] in try? self?.form.setIcon([]) }
        form.icon.pasteIcon = { [weak self] in self?.pasteIcon() }
        form.icon.copyIcon = { [weak self] in
            guard let self, let data = ClassicProfileImage.png(form.draft.icon) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data,forType:.png)
        }
        form.changed = { [weak self] in self?.refresh() }
        chrome.layoutSubtreeIfNeeded(); install(form); window?.initialFirstResponder = form.name
        observation.start { [weak self] in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        let valid = isCurrentConnection && session.client.isConnected
        if !valid { colorChooser?.requestResponse(false) }
        title = "My Profile — \(session.title)"+(isCurrentConnection ? "" : " (connection changed)")
        let editable = valid && !isApplying && colorChooser == nil
        form.setEditable(editable); form.save.isEnabled = editable; form.apply.isEnabled = editable
        form.panel.toolTip = valid ? session.title : "Reconnect and reopen My Profile to edit this identity."
    }
    func submit(close: Bool) {
        guard form.save.isEnabled, !isApplying else { return }
        run("profile") { [weak self] in
            guard let self else { return }
            if try await applyProfile(), close, !Task.isCancelled { requestClose() }
        }
    }
    func applyProfile() async throws -> Bool {
        try Task.checkCancellation()
        guard isCurrentConnection, session.client.isConnected else { throw KDXError.disconnected }
        guard !isApplying, colorChooser == nil else { return false }
        let captured = form.draft
        let nicknameChanged = captured.nickname != session.client.currentUser?.nickname
        isApplying = true; refresh(); defer { isApplying = false; refresh() }
        let session = session, generation = generation, preferences = preferences
        // Finish the authenticated update independently of the window's lifetime.
        let operation = Task { @MainActor in
            guard generation == session.privateMessages.generation else { throw KDXError.disconnected }
            try await session.client.updateProfile(nickname:captured.nickname,info:captured.info,colors:captured.colors,icon:captured.icon,gradient:captured.gradient)
            // Persist the user's choice, not a name imposed by this server.
            if nicknameChanged, generation == session.privateMessages.generation {
                session.rememberNickname(captured.nickname,preferences:preferences)
            }
        }
        try await operation.value
        guard isCurrentConnection, captured == form.draft else { return false }
        if let actual = session.client.currentUser { form.load(actual) }
        return true
    }
    func makeColorChooser(background: Bool) -> ClassicColorChooserWindow? {
        guard isCurrentConnection, session.client.isConnected, !isApplying, colorChooser == nil else { return nil }
        let value = background ? form.background.rgb : form.foreground.rgb
        let chooser = ClassicColorChooserWindow(rgb:value,preferences:preferences)
        colorChooser = chooser
        chooser.responseRequested = { [weak self, weak chooser] accepted in
            guard let self, let chooser, colorChooser === chooser else { return }
            colorChooser = nil
            dismissOwnedDialog(chooser) {
                if accepted, isCurrentConnection, session.client.isConnected, !isApplying { form.setColor(chooser.form.value.rgb,background:background) }
                refresh()
            }
        }
        refresh(); return chooser
    }
    private func chooseColor(background: Bool) {
        guard window?.attachedSheet == nil, ownedDialog == nil,
              let chooser = makeColorChooser(background:background) else { return }
        guard presentOwnedDialog(chooser) else { chooser.requestResponse(false); return }
        chooser.window?.makeFirstResponder(chooser.form.hexadecimal); chooser.form.hexadecimal.selectText(nil)
    }
    private func chooseImage() {
        guard let window, isCurrentConnection, !isApplying else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png,.jpeg,.tiff,.bmp,.gif]; panel.message = "Choose an image to convert to a 32×32 KDX user icon."
        panel.beginSheetModal(for:window) { [weak self] response in
            guard let self, response == .OK, isCurrentConnection, !isApplying, let url = panel.url else { return }
            do { try form.setIcon(ClassicProfileImage.load(url,background:form.background.rgb)) } catch { showError(error) }
        }
    }
    private func pasteIcon() {
        guard isCurrentConnection, !isApplying else { return }
        guard let data = NSPasteboard.general.data(forType:.png) ?? NSPasteboard.general.data(forType:.tiff) else { return }
        do { try form.setIcon(ClassicProfileImage.decode(data,background:form.background.rgb)) } catch { showError(error) }
    }
    override func applyStyle() { super.applyStyle(); form.applyStyle(); colorChooser?.applyStyle(); fitForm() }
    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification); colorChooser?.requestResponse(false)
    }
    override func maximize() { fitForm() }
    private func fitForm() {
        guard let window else { return }
        let probe = NSRect(x:0,y:0,width:1000,height:1000), content = HAPWindowDrawing.contentRect(in:probe)
        let size = NSSize(width:450+probe.width-content.width,height:330+probe.height-content.height)
        window.minSize = .zero; window.maxSize = size; window.minSize = size
        let old = window.frame, frame = NSRect(x:old.minX,y:old.maxY-size.height,width:size.width,height:size.height)
        window.setFrame(ClassicPreferences.constrain(frame,to:NSScreen.screens.map(\.visibleFrame),fallback:frame),display:false)
    }
}
