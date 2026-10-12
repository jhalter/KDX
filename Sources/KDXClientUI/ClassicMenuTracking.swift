import AppKit

@MainActor protocol ClassicMenuHosting: AnyObject {
    var frame: NSRect { get }
    func displayIfNeeded()
    func close()
}

@MainActor private final class ClassicMenuPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class ClassicMenuWindowHost: ClassicMenuHosting {
    private let panel: NSPanel
    private weak var owner: NSWindow?
    var frame: NSRect { panel.frame }
    init(surface: ClassicMenuSurface, frame: NSRect, owner: NSWindow?) {
        self.owner = owner
        panel = ClassicMenuPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed = false; panel.level = .popUpMenu; panel.hasShadow = false
        panel.hidesOnDeactivate = true; panel.isOpaque = true; panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.transient,.moveToActiveSpace]
        panel.contentView = surface
        owner?.addChildWindow(panel,ordered:.above)
        panel.orderFront(nil)
    }
    func displayIfNeeded() { panel.displayIfNeeded() }
    func close() {
        owner?.removeChildWindow(panel); panel.orderOut(nil); panel.close()
    }
}

/// Public AppKit windows/events, with NSMenu retained as the action model. The
/// synchronous lifetime matches NSMenu.popUp: all panels close before dispatch.
@MainActor final class ClassicMenuTracking {
    enum EventDisposition { case consumed, dispatch, repostAfterClosing }
    private struct Page {
        let surface: ClassicMenuSurface
        let host: any ClassicMenuHosting
        let parentItem: NSMenuItem?
    }
    private var pages: [Page] = []
    private(set) var result: NSMenuItem?
    private(set) var finished = false
    private var pointerPage: Int?
    private var hoverDeadline: TimeInterval?
    private var edgeDirection: CGFloat = 0
    private var nextScroll: TimeInterval = 0
    private var pendingSelection: (page: Int, origin: NSPoint, deadline: TimeInterval)?
    private var pointerMoved = false
    private var ignoreOpeningRelease = false
    private var lastPointer: NSPoint
    private let makeHost: (ClassicMenuSurface, NSRect) -> any ClassicMenuHosting
    private let screen: NSRect
    private let initialPointer: NSPoint

    init(screen: NSRect, initialPointer: NSPoint, openingMouseDown: Bool,
         makeHost: @escaping (ClassicMenuSurface, NSRect) -> any ClassicMenuHosting) {
        self.screen = screen; self.initialPointer = initialPointer; self.makeHost = makeHost
        lastPointer = initialPointer; ignoreOpeningRelease = openingMouseDown
    }
    func start(menu: ClassicMenu, positioning item: NSMenuItem? = nil, at point: NSPoint) {
        guard pages.isEmpty, !finished else { return }
        open(menu:menu,topLeft:point,positioning:item,parentItem:nil)
    }
    func close() { close(from:0); finished = true }
    static func selection(menu: ClassicMenu, positioning item: NSMenuItem?, at point: NSPoint, in view: NSView?) -> NSMenuItem? {
        guard let owner = view?.window ?? NSApp.keyWindow else { return nil }
        let anchor = view.map { owner.convertPoint(toScreen:$0.convert(point,to:nil)) } ?? point
        let screen = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? owner.screen ?? NSScreen.main)?.visibleFrame ?? owner.frame
        let openingMouseDown = [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(NSApp.currentEvent?.type ?? .applicationDefined)
        let tracking = ClassicMenuTracking(screen:screen,initialPointer:NSEvent.mouseLocation,openingMouseDown:openingMouseDown) { [weak owner] surface, frame in
            ClassicMenuWindowHost(surface:surface,frame:frame,owner:owner)
        }
        tracking.start(menu:menu,positioning:item,at:anchor)
        guard !tracking.pages.isEmpty else { return nil }
        var repost: NSEvent?
        defer {
            tracking.close()
            if let repost { NSApp.postEvent(repost,atStart:true) }
        }
        let wasActive = NSApp.isActive
        while !tracking.finished && owner.isVisible && (!wasActive || NSApp.isActive) {
            autoreleasepool {
                if let event = NSApp.nextEvent(matching:.any,until:Date(timeIntervalSinceNow:0.04),inMode:.eventTracking,dequeue:true) {
                    let pointer = event.window?.convertPoint(toScreen:event.locationInWindow) ?? event.locationInWindow
                    switch tracking.handle(event,pointer:pointer,time:ProcessInfo.processInfo.systemUptime) {
                    case .consumed: break
                    case .dispatch: NSApp.sendEvent(event)
                    case .repostAfterClosing: repost = event
                    }
                }
                tracking.tick(pointer:NSEvent.mouseLocation,time:ProcessInfo.processInfo.systemUptime)
            }
        }
        // Revalidate the selected item's complete ancestor chain and identity.
        guard let selected = tracking.result, canActivate(selected,in:menu) else { return nil }
        return selected
    }
    private func open(menu: ClassicMenu, topLeft: NSPoint, positioning item: NSMenuItem?, parentItem: NSMenuItem?) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.delegate?.menuWillOpen?(menu)
        menu.prepareForDisplay()
        guard menu.items.filter({ !$0.isHidden }).allSatisfy({ $0.view is ClassicMenuItemView }) else {
            menu.delegate?.menuDidClose?(menu); return
        }
        let surface = ClassicMenuSurface(menu:menu,maximumHeight:screen.height)
        guard !surface.items.isEmpty else { menu.delegate?.menuDidClose?(menu); return }
        var point = topLeft
        if let item, let index = surface.items.firstIndex(where: { $0 === item }) {
            surface.select(index,reveal:true)
            point.y += surface.rows[index].menuOffset-surface.scrollOffset
        }
        let frame: NSRect
        if let parent = pages.last, parentItem != nil {
            frame = ClassicMenuSurface.submenuFrame(size:surface.frame.size,parent:parent.host.frame,rowTop:point.y,screen:screen)
        } else { frame = ClassicMenuSurface.frame(size:surface.frame.size,topLeft:point,screen:screen) }
        surface.cancel = { [weak self] in self?.finished = true }
        surface.activateItem = { [weak self, weak surface] item in
            guard let self, let surface, let page = pages.firstIndex(where: { $0.surface === surface }),
                  let index = surface.items.firstIndex(where: { $0 === item }), surface.eligible(index) else { return false }
            select(index,in:page)
            if item.submenu != nil { openSubmenu(of:page,selectFirst:true) }
            else { result = item; finished = true }
            return true
        }
        let host = makeHost(surface,frame)
        pages.append(Page(surface:surface,host:host,parentItem:parentItem))
        host.displayIfNeeded()
        if surface.window != nil {
            NSAccessibility.post(element:surface,notification:.created)
            NSAccessibility.post(element:surface,notification:.focusedUIElementChanged)
        }
    }
    private func close(from index: Int) {
        guard index < pages.count else { return }
        let closing = Array(pages[index...]); pages.removeSubrange(index...)
        for page in closing.reversed() {
            page.host.close()
            page.surface.source.delegate?.menuDidClose?(page.surface.source)
        }
        hoverDeadline = nil
        pendingSelection = nil
    }
    private func select(_ index: Int?, in page: Int, reveal: Bool = false) {
        guard pages.indices.contains(page) else { return }
        let surface = pages[page].surface, old = surface.selectedItem
        surface.select(index,reveal:reveal)
        if old !== surface.selectedItem {
            close(from:page+1)
            surface.source.delegate?.menu?(surface.source,willHighlight:surface.selectedItem)
        }
    }
    private func openSubmenu(of index: Int, selectFirst: Bool) {
        guard pages.indices.contains(index), let item = pages[index].surface.selectedItem,
              item.isEnabled, !item.isHidden, let submenu = item.submenu as? ClassicMenu else { return }
        if pages.indices.contains(index+1), pages[index+1].parentItem === item { return }
        close(from:index+1)
        // Reject a cyclic menu graph even if one was constructed programmatically.
        guard !pages.contains(where: { $0.surface.source === submenu }) else { return }
        let page = pages[index], row = page.surface.rows[page.surface.selectedIndex!]
        open(menu:submenu,topLeft:NSPoint(x:page.host.frame.maxX,y:page.host.frame.maxY-row.frame.minY),positioning:nil,parentItem:item)
        if selectFirst, pages.count > index+1 { pages.last?.surface.edge(last:false) }
    }
    private func updatePointer(_ point: NSPoint, time: TimeInterval, allowDeferral: Bool = true) {
        let previousPoint = lastPointer
        lastPointer = point
        pointerMoved = pointerMoved || hypot(point.x-initialPointer.x,point.y-initialPointer.y) > 3
        guard let index = pages.indices.reversed().first(where: { pages[$0].host.frame.contains(point) }) else {
            pointerPage = nil; edgeDirection = 0; hoverDeadline = nil; pendingSelection = nil; return
        }
        let page = pages[index], local = NSPoint(x:point.x-page.host.frame.minX,y:page.host.frame.maxY-point.y)
        let row = page.surface.index(at:local), previous = page.surface.selectedIndex
        if allowDeferral, row != previous, pages.indices.contains(index+1) {
            let pending = pendingSelection.flatMap { $0.page == index ? $0 : nil }
                ?? (page:index,origin:previousPoint,deadline:time+0.25)
            if time < pending.deadline, Self.aimsAtSubmenu(from:pending.origin,through:point,parent:page.host.frame,child:pages[index+1].host.frame) {
                pendingSelection = pending; pointerPage = index; edgeDirection = 0; hoverDeadline = nil
                return
            }
        }
        pendingSelection = nil
        let enteredPage = pointerPage != index
        pointerPage = index
        select(row,in:index)
        if row != previous || enteredPage { hoverDeadline = time+0.2 }
        edgeDirection = page.surface.contentHeight > page.surface.bounds.height ? (local.y < 8 ? -1 : local.y > page.surface.bounds.height-8 ? 1 : 0) : 0
    }
    func tick(pointer: NSPoint, time: TimeInterval) {
        guard !finished else { return }
        if pointer != lastPointer || pendingSelection.map({ time >= $0.deadline }) == true { updatePointer(pointer,time:time) }
        if let page = pointerPage, pages.indices.contains(page) {
            if let deadline = hoverDeadline, time >= deadline { hoverDeadline = nil; openSubmenu(of:page,selectFirst:false) }
            if edgeDirection != 0, time >= nextScroll {
                scroll(by:edgeDirection*16,in:page,pointer:pointer,time:time)
                nextScroll = time+0.08
            }
        }
        for page in pages { page.host.displayIfNeeded() }
    }
    private func scroll(by delta: CGFloat, in page: Int, pointer: NSPoint, time: TimeInterval) {
        let surface = pages[page].surface, previous = surface.scrollOffset
        surface.scroll(by:delta)
        guard surface.scrollOffset != previous else { return }
        close(from:page+1)
        // Rows move beneath a stationary pointer during edge/wheel scrolling.
        // Recompute selection before an old row's hover timer can open it.
        updatePointer(pointer,time:time,allowDeferral:false)
    }
    @discardableResult func handle(_ event: NSEvent, pointer: NSPoint, time: TimeInterval) -> EventDisposition {
        guard !finished else { return .consumed }
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            updatePointer(pointer,time:time)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            ignoreOpeningRelease = false
            updatePointer(pointer,time:time,allowDeferral:false)
            if pointerPage == nil { finished = true }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            updatePointer(pointer,time:time,allowDeferral:false)
            let skip = ignoreOpeningRelease && !pointerMoved
            ignoreOpeningRelease = false
            guard !skip else { return .consumed }
            guard let page = pointerPage, pages.indices.contains(page) else {
                if pointerMoved { finished = true }
                return .consumed
            }
            if let item = pages[page].surface.selectedItem {
                if item.submenu != nil { openSubmenu(of:page,selectFirst:false) }
                else { result = item; finished = true }
            }
        case .scrollWheel:
            updatePointer(pointer,time:time,allowDeferral:false)
            if let page = pointerPage {
                scroll(by:-event.scrollingDeltaY*(event.hasPreciseScrollingDeltas ? 1 : 16),in:page,pointer:pointer,time:time)
            }
        case .keyDown: return key(event,time:time)
        case .flagsChanged: break
        default: return .dispatch
        }
        return .consumed
    }
    private func key(_ event: NSEvent, time: TimeInterval) -> EventDisposition {
        guard let page = pages.last else { return .consumed }
        pointerPage = nil; hoverDeadline = nil; edgeDirection = 0; pendingSelection = nil
        let surface = page.surface
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first?.value
        let functionKey = scalar.map { (UInt32(NSF1FunctionKey)...UInt32(NSF35FunctionKey)).contains($0) } ?? false
        if flags.contains(.command) || flags.contains(.control) || functionKey {
            finished = true
            if let item = Self.keyEquivalent(event,in:pages.first!.surface.source) { result = item; return .consumed }
            return .repostAfterClosing
        }
        switch event.keyCode {
        case 53: finished = true
        case 125: surface.move(1)
        case 126: surface.move(-1)
        case 115: surface.edge(last:false)
        case 119: surface.edge(last:true)
        case 116: surface.movePage(-1)
        case 121: surface.movePage(1)
        case 123: if pages.count > 1 { close(from:pages.count-1) } else { finished = true }
        case 124: openSubmenu(of:pages.count-1,selectFirst:true)
        case 36,76,49:
            if let item = surface.selectedItem {
                if item.submenu != nil { openSubmenu(of:pages.count-1,selectFirst:true) }
                else { result = item; finished = true }
            }
        default:
            if let text = event.characters, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                surface.typeSelect(text,time:time)
            }
        }
        return .consumed
    }
    /// Delay a parent-row change while the pointer traverses the triangle from
    /// its last position toward the open submenu. No delay when moving away,
    /// or when display confinement makes the two menus overlap horizontally.
    static func aimsAtSubmenu(from origin: NSPoint, through point: NSPoint, parent: NSRect, child: NSRect) -> Bool {
        let edge: CGFloat
        if child.minX >= parent.maxX {
            guard point.x > origin.x, point.x <= child.minX else { return false }
            edge = child.minX
        } else if child.maxX <= parent.minX {
            guard point.x < origin.x, point.x >= child.maxX else { return false }
            edge = child.maxX
        } else { return false }
        let fraction = (point.x-origin.x)/(edge-origin.x)
        let lower = origin.y+(child.minY-origin.y)*fraction
        let upper = origin.y+(child.maxY-origin.y)*fraction
        return point.y >= lower && point.y <= upper
    }
    static func canActivate(_ item: NSMenuItem, in root: NSMenu) -> Bool {
        var visited = Set<ObjectIdentifier>()
        func contains(_ menu: NSMenu) -> Bool {
            guard visited.insert(ObjectIdentifier(menu)).inserted else { return false }
            for candidate in menu.items where candidate.isEnabled && !candidate.isHidden && !candidate.isSeparatorItem {
                if candidate === item { return candidate.submenu == nil }
                if let submenu = candidate.submenu, contains(submenu) { return true }
            }
            return false
        }
        return contains(root)
    }
    static func keyEquivalent(_ event: NSEvent, in menu: NSMenu) -> NSMenuItem? {
        var visited = Set<ObjectIdentifier>()
        func find(_ menu: NSMenu) -> NSMenuItem? {
            guard visited.insert(ObjectIdentifier(menu)).inserted else { return nil }
            for item in menu.items where item.isEnabled && !item.isHidden && !item.isSeparatorItem {
                if let submenu = item.submenu { if let found = find(submenu) { return found }; continue }
                let mask: NSEvent.ModifierFlags = [.command,.control,.option,.shift]
                if !item.keyEquivalent.isEmpty, item.keyEquivalentModifierMask.intersection(mask) == event.modifierFlags.intersection(mask),
                   item.keyEquivalent.lowercased() == event.charactersIgnoringModifiers?.lowercased() { return item }
            }
            return nil
        }
        return find(menu)
    }
}
