import AppKit

@MainActor final class ClassicWindow: NSWindow {
    weak var modalChild: NSWindow?
    override var canBecomeKey: Bool { modalChild == nil }
    override var canBecomeMain: Bool { true }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let previous = firstResponder as? NSView
        let changed = super.makeFirstResponder(responder)
        for view in [previous,firstResponder as? NSView].compactMap({ $0 }) {
            var ancestor: NSView? = view
            while let current = ancestor { current.needsDisplay = true; ancestor = current.superview }
        }
        return changed
    }
}

@MainActor private final class ChromeButtonCell: NSButtonCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let button = controlView as? ChromeButton, let chrome = button.superview as? ClassicChrome else { return }
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.translateX(by:-button.frame.minX,yBy:-button.frame.minY); transform.concat()
        HAPWindowDrawing.control(button.kind,in:chrome.bounds,active:chrome.isActive,pressed:isHighlighted)
        NSGraphicsContext.restoreGraphicsState()
    }
}
@MainActor final class ChromeButton: NSButton {
    let kind: HAPWindowControl
    override var isFlipped: Bool { true }
    var invoke: (() -> Void)?
    init(_ kind: HAPWindowControl) {
        self.kind = kind
        super.init(frame:.zero)
        cell = ChromeButtonCell(textCell:""); isBordered = false; setButtonType(.momentaryChange)
        target = self; action = #selector(performAction); setAccessibilityLabel(kind.label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func performAction() { invoke?() }
}
@MainActor private final class ChromeResizeGrip: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let chrome = superview as? ClassicChrome else { return }
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.translateX(by:-frame.minX,yBy:-frame.minY); transform.concat()
        HAPWindowDrawing.resize(in:chrome.bounds,active:chrome.isActive)
        NSGraphicsContext.restoreGraphicsState()
    }
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with:event) }
}
@MainActor final class ClassicChrome: ClassicSurface {
    // Forward the activating press to mouseDown so an inactive window can be
    // dragged in the same gesture, just like a native title bar.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    weak var controller: ClassicWindowController?
    let content = ClassicSurface()
    var title = "" { didSet { needsDisplay = true } }
    var allowsResize = true { didSet { needsLayout = true } }
    var isDialog = false { didSet { needsLayout = true } }
    var showsTitleControls = true { didSet { needsLayout = true; needsDisplay = true } }
    let buttons = HAPWindowControl.allCases.map { ChromeButton($0) }
    private let grip = ChromeResizeGrip()
    var isActive: Bool { window?.isKeyWindow == true }
    init() {
        super.init(frame:.zero)
        addSubview(content)
        for button in buttons {
            addSubview(button)
            button.invoke = { [weak self, weak button] in
                guard let self, let button else { return }
                switch button.kind {
                case .close: controller?.requestClose()
                case .menu: controller?.showWindowMenu()
                case .maximize: controller?.maximize()
                case .minimize: controller?.minimize()
                }
            }
        }
        addSubview(grip)
        grip.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        content.frame = HAPWindowDrawing.contentRect(in:bounds)
        for button in buttons {
            button.frame = HAPWindowDrawing.hitRect(button.kind,in:bounds,active:isActive)
            button.isHidden = !showsTitleControls || button.frame.isEmpty || (isDialog && button.kind != .close) || (!allowsResize && button.kind == .maximize)
        }
        grip.frame = HAPWindowDrawing.resizeHitRect(in:bounds,active:isActive)
        grip.isHidden = isDialog || !allowsResize
    }
    func refreshAppearance() {
        needsLayout = true; needsDisplay = true
        buttons.forEach { $0.needsDisplay = true }; grip.needsDisplay = true
        func refreshFocus(_ view: NSView) {
            if view is ClassicFieldFrame || view is ClassicTextField || view is ClassicSecureTextField { view.needsDisplay = true }
            view.subviews.forEach(refreshFocus)
        }
        refreshFocus(content)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        HAPWindowDrawing.frame(bounds,active:isActive)
        HAPWindowDrawing.title(title,in:bounds,active:isActive,controls:showsTitleControls)
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), ClassicMenu.showContext(for:event,in:self) { return }
        guard let window else { return }; let p = convert(event.locationInWindow, from:nil)
        if p.y < HAPWindowDrawing.contentRect(in:bounds).minY {
            if event.clickCount == 2 && !isDialog && showsTitleControls { controller?.minimize() } else { window.performDrag(with:event) }; return
        }
        if !isDialog && allowsResize && grip.frame.contains(p) {
            let start = window.frame, origin = NSEvent.mouseLocation
            while let next = window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                let position = NSEvent.mouseLocation
                let size = NSSize(width:min(window.maxSize.width,max(window.minSize.width,start.width+position.x-origin.x)),height:min(window.maxSize.height,max(window.minSize.height,start.height-position.y+origin.y)))
                window.setFrame(NSRect(x:start.minX,y:start.maxY-size.height,width:size.width,height:size.height),display:true)
            }
        } else { window.performDrag(with:event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        if !ClassicMenu.showContext(for:event,in:self) { super.rightMouseDown(with:event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { isDialog ? nil : controller?.windowMenu }
}

@MainActor class ClassicWindowController: NSWindowController, NSWindowDelegate {
    let preferences: ClassicPreferences
    let persistenceKey: String
    let chrome = ClassicChrome()
    let observation = ClassicObservation()
    let windowMenu = ClassicMenu(title:"")
    var onClosed: (() -> Void)?
    var onMinimize: ((ClassicWindowController) -> Void)?
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?
    var beforeClose: (() async throws -> Void)?
    private var closing = false
    private var tasks: [String: Task<Void, Never>] = [:]
    private var activeDialog: ClassicDialogController?
    private(set) var ownedDialog: ClassicWindowController?
    private var dialogEventMonitor: Any?
    private weak var dialogPreviousResponder: NSResponder?
    private lazy var dialogQueue: ClassicDialogQueue = {
        let queue = ClassicDialogQueue()
        queue.changed = { [weak self] in self?.presentNextDialog() }
        return queue
    }()
    var title: String { get { window?.title ?? "" } set { window?.title = newValue; chrome.title = newValue } }
    init(title: String, key: String, size: NSSize, preferences: ClassicPreferences, minimumFrameSize: NSSize = NSSize(width:180,height:60)) {
        self.preferences = preferences; self.persistenceKey = key
        let fallback = NSRect(origin: NSPoint(x: 140,y: 200),size: size)
        let rect = preferences.frame(key: key, fallback: fallback, screens: NSScreen.screens.map(\.visibleFrame),minimumSize:minimumFrameSize)
        let window = ClassicWindow(contentRect: rect, styleMask: [.borderless,.resizable], backing: .buffered, defer: true)
        super.init(window: window)
        // Position is restored explicitly; AppKit must not cascade it on display.
        shouldCascadeWindows = false
        window.isReleasedWhenClosed = false; window.hasShadow = true; window.minSize = NSSize(width: min(size.width,320), height: min(size.height,180))
        window.delegate = self; window.contentView = chrome; chrome.controller = self; self.title = title
        windowMenu.addItem(menuItem("Save Window Location/Size") { [weak self] in self?.saveFrame() })
        windowMenu.addItem(menuItem("Minimize") { [weak self] in self?.minimize() })
        windowMenu.addItem(menuItem("Maximize / Restore") { [weak self] in self?.maximize() })
        windowMenu.addItem(menuItem("Close Window", key: "w") { [weak self] in self?.requestClose() })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit {
        if let monitor = dialogEventMonitor { NSEvent.removeMonitor(monitor) }
    }
    func install(_ view: NSView) {
        chrome.content.subviews.forEach { $0.removeFromSuperview() }
        // Establish the themed content bounds before child controls lay out.
        // A newly created borderless window may still have a zero-sized pane.
        chrome.layoutSubtreeIfNeeded()
        view.translatesAutoresizingMaskIntoConstraints = false; chrome.content.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: chrome.content.leadingAnchor), view.trailingAnchor.constraint(equalTo: chrome.content.trailingAnchor), view.topAnchor.constraint(equalTo: chrome.content.topAnchor), view.bottomAnchor.constraint(equalTo: chrome.content.bottomAnchor)])
        applyStyle()
    }
    func present() {
        closing = false
        if dialogQueue.isClosed {
            dialogQueue = ClassicDialogQueue()
            dialogQueue.changed = { [weak self] in self?.presentNextDialog() }
        }
        showWindow(nil); (ownedDialog?.window ?? window)?.makeKeyAndOrderFront(nil)
    }
    func run(_ key: String = "operation", operation: @escaping @MainActor () async throws -> Void) {
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
            do { try Task.checkCancellation(); try await operation() }
            catch { if !Task.isCancelled { self?.showError(error) } }
        }
    }
    func cancelTask(_ key: String) { tasks[key]?.cancel() }
    func showError(_ error: Error) { showMessage(error.localizedDescription, title: "KDX") }
    func showMessage(_ text: String, title: String = "KDX") {
        presentDialog(ClassicDialogRequest(title:title,message:text,cancelTitle:nil))
    }
    func prompt(_ message: String, initial: String = "", secure: Bool = false, acceptTitle: String = "OK", completion: @escaping (String) -> Void) {
        presentDialog(ClassicDialogRequest(title:message,fields:[ClassicDialogField(id:"value",label:secure ? "Password (blank for guest)" : message,value:initial,secure:secure)],acceptTitle:acceptTitle) { result in
            if let value = result?["value"] { completion(value) }
        })
    }
    func confirm(_ title: String, message: String, acceptTitle: String, completion: @escaping (Bool) -> Void) {
        presentDialog(ClassicDialogRequest(title:title,message:message,acceptTitle:acceptTitle) { completion($0 != nil) })
    }
    func presentDialog(_ request: ClassicDialogRequest) {
        guard !closing, window != nil else { request.resolve(nil); return }
        dialogQueue.enqueue(request)
    }
    // AppKit sheets add a rounded system frame even to borderless windows.
    // Use a square themed child window, with input blocked only for its owner.
    @discardableResult func presentOwnedDialog(_ dialog: ClassicWindowController) -> Bool {
        guard !closing, ownedDialog == nil, let parent = window as? ClassicWindow, parent.attachedSheet == nil,
              let child = dialog.window else { return false }
        dialogPreviousResponder = parent.firstResponder
        _ = parent.makeFirstResponder(nil)
        ownedDialog = dialog; parent.modalChild = child
        let frame = NSRect(x:parent.frame.midX-child.frame.width/2,
                           y:parent.frame.midY-child.frame.height/2,
                           width:child.frame.width,height:child.frame.height)
        child.setFrame(ClassicPreferences.constrain(frame,to:NSScreen.screens.map(\.visibleFrame),fallback:frame),display:false)
        child.contentView?.layoutSubtreeIfNeeded()
        showOwnedDialogWindow(child)
        return true
    }
    func dismissOwnedDialog(_ dialog: ClassicWindowController, completion: () -> Void = {}) {
        if ownedDialog === dialog {
            ownedDialog = nil; (window as? ClassicWindow)?.modalChild = nil
            if let child = dialog.window { hideOwnedDialogWindow(child) }
        }
        completion()
        presentNextDialog()
    }
    // Presentation is kept separate so lifecycle tests never display windows.
    func showOwnedDialogWindow(_ child: NSWindow) {
        window?.addChildWindow(child,ordered:.above)
        dialogEventMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.leftMouseUp,.leftMouseDragged,
            .rightMouseDown,.rightMouseUp,.rightMouseDragged,.otherMouseDown,.otherMouseUp,.otherMouseDragged,
            .keyDown,.keyUp,.flagsChanged,.scrollWheel,.magnify,.rotate,.swipe,.pressure]) { [weak self] event in
            guard let self, event.window === self.window, let child = self.ownedDialog?.window else { return event }
            child.makeKeyAndOrderFront(nil)
            return nil
        }
        child.makeKeyAndOrderFront(nil)
    }
    func hideOwnedDialogWindow(_ child: NSWindow) {
        if let monitor = dialogEventMonitor { NSEvent.removeMonitor(monitor); dialogEventMonitor = nil }
        let restoreFocus = child.isKeyWindow
        window?.removeChildWindow(child); child.orderOut(nil)
        if !closing {
            if let responder = dialogPreviousResponder { window?.makeFirstResponder(responder) }
            if restoreFocus { window?.makeKeyAndOrderFront(nil) }
        }
        dialogPreviousResponder = nil
    }
    private func presentNextDialog() {
        guard !closing, activeDialog == nil, ownedDialog == nil, window?.attachedSheet == nil, let request = dialogQueue.active else { return }
        let dialog = ClassicDialogController(request:request,preferences:preferences)
        activeDialog = dialog
        dialog.responseRequested = { [weak self, weak dialog] accepted in
            guard let self, let dialog, self.activeDialog === dialog else { return }
            let values = accepted && !self.closing ? dialog.form.values : nil
            dialog.form.clearSensitiveValues()
            self.dismissOwnedDialog(dialog) {
                self.activeDialog = nil
                self.dialogQueue.complete(id:request.id,values:values)
            }
        }
        guard presentOwnedDialog(dialog) else {
            activeDialog = nil; dialogQueue.complete(id:request.id,values:nil); return
        }
        dialog.window?.makeFirstResponder(dialog.form.firstEditor ?? dialog.form.accept)
        dialog.form.firstEditor?.selectText(nil)
    }
    func requestClose() {
        guard !closing else { return }
        if let beforeClose {
            closing = true
            run("closing") { [weak self] in
                do { try await beforeClose(); self?.finishClose() }
                catch { self?.closing = false; throw error }
            }
        } else { finishClose() }
    }
    private func finishClose() { closing = true; window?.close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if closing { return true }; requestClose(); return false }
    func windowWillClose(_ notification: Notification) {
        closing = true
        let dialog = activeDialog; activeDialog = nil
        dialogQueue.invalidate(); dialog?.form.clearSensitiveValues()
        if let child = ownedDialog { dismissOwnedDialog(child) { child.requestClose() } }
        saveFrame(); observation.stop(); tasks.values.forEach { $0.cancel() }; tasks.removeAll(); onClosed?()
    }
    func windowDidEndSheet(_ notification: Notification) { presentNextDialog() }
    func windowDidBecomeKey(_ notification: Notification) { chrome.refreshAppearance(); onFocus?() }
    func windowDidResignKey(_ notification: Notification) { chrome.refreshAppearance(); onBlur?() }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
    func saveFrame() { if let window { preferences.save(frame: window.frame, key: persistenceKey) } }
    func minimize() { window?.orderOut(nil); onMinimize?(self) }
    private var unzoomed: NSRect?
    func maximize() {
        guard let window else { return }
        if let unzoomed { window.setFrame(unzoomed, display: true); self.unzoomed = nil }
        else if let screen = window.screen { unzoomed = window.frame; window.setFrame(screen.visibleFrame, display: true) }
    }
    func showWindowMenu() { windowMenu.present(positioning: nil, at: NSPoint(x: 23,y: HAPWindowDrawing.contentRect(in: chrome.bounds).minY), in: chrome) }
    func applyStyle() {
        chrome.refreshAppearance()
        func refresh(_ view: NSView) {
            view.needsDisplay = true
            (view as? NSControl)?.font = ClassicStyle.shared.font
            (view as? NSControl)?.invalidateIntrinsicContentSize()
            (view as? NSTextView)?.font = ClassicStyle.shared.font
            if let field = view as? NSTextField {
                field.textColor = ClassicStyle.shared.color(field.drawsBackground ? 11 : 5)
                if field.drawsBackground { field.backgroundColor = ClassicStyle.shared.color(10) }
            }
            (view as? ClassicServerEditor)?.applyStyle()
            (view as? ClassicButtonBarView)?.applyStyle()
            (view as? ClassicPopUpButton)?.applyStyle()
            (view as? ClassicScrollView)?.applyStyle()
            (view as? ClassicTextField)?.applyStyle()
            (view as? ClassicSecureTextField)?.applyStyle()
            (view as? ClassicList)?.applyStyle()
            for child in view.subviews { refresh(child) }
        }
        refresh(chrome)
        activeDialog?.applyStyle()
    }
}
