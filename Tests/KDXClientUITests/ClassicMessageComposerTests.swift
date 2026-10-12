import AppKit
import XCTest
@testable import KDXClientUI
@testable import KDXCore

final class ClassicMessageComposerTests: XCTestCase {
    @MainActor func testOriginalConstructorGeometryAndResizing() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Provide the original application for composer geometry") }
        let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
        func immediate(_ address: Int) throws -> Int { Int(try bytes.u32(address+0x1de0)&0xffff) }
        let form = ClassicMessageComposerForm(); form.layoutSubtreeIfNeeded()
        XCTAssertEqual(ClassicMessageComposerForm.referenceSize,try NSSize(width:immediate(0x265b8),height:immediate(0x265d0)))
        let records: [(NSView,[Int])] = [(form.heading,[0x2667c,0x2667c,0x26680,0x26684]),
            (form.recipient,[0x26738,0x2673c,0x26740,0x26748]),
            (form.serverLabel,[0x266bc,0x266c0,0x266c4,0x266c8]),
            (form.server,[0x26770,0x26774,0x26778,0x26780]),
            (form.entry,[0x267b0,0x267b4,0x267b8,0x267c0]),
            (form.send,[0x26804,0x26808,0x2680c,0x26810]),
            (form.cancel,[0x26844,0x26848,0x2684c,0x26854])]
        for (view,addresses) in records {
            let p = try addresses.map(immediate)
            XCTAssertEqual(view.frame,NSRect(x:p[0],y:p[1],width:p[2]-p[0],height:p[3]-p[1]))
        }
        for size in [NSSize(width:280,height:200),NSSize(width:600,height:500)] {
            form.frame.size = size; form.needsLayout = true; form.layoutSubtreeIfNeeded()
            for view in records.map(\.0) { XCTAssertTrue(form.bounds.contains(view.frame)) }
            XCTAssertEqual(form.entry.frame.maxX,size.width-10); XCTAssertEqual(form.entry.frame.maxY,size.height-46)
            XCTAssertEqual(form.send.frame.maxX,size.width-44); XCTAssertEqual(form.send.frame.maxY,size.height-10)
        }
    }

    @MainActor func testMultilineKeysAndSeparateDrafts() throws {
        _ = NSApplication.shared
        let prefs = try preferences(), session = ClassicSession(endpoint:ClassicEndpoint())
        session.drafts[.privateMessage(4)] = "Inline draft"
        session.drafts[.composeMessage(4)] = "Long draft"
        let controller = ClassicMessageComposerWindow(session:session,user:4,preferences:prefs)
        defer { controller.observation.stop(); prefs.defaults.removePersistentDomain(forName:prefsSuite(prefs)) }
        let form = controller.form
        XCTAssertEqual(form.input.string,"Long draft")
        var sent = 0, canceled = 0
        form.send.invoke = { sent += 1 }; form.cancel.invoke = { canceled += 1 }; form.send.isEnabled = true
        func key(_ code: UInt16, _ text: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code))
        }
        controller.chrome.layoutSubtreeIfNeeded(); form.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.window?.makeFirstResponder(form.input) == true)
        form.input.setSelectedRange(NSRange(location:form.input.string.utf16.count,length:0))
        let enter = try key(76,"\u{3}"), newline = try key(36,"\r"), escape = try key(53,"\u{1b}")
        XCTAssertFalse(form.send.performKeyEquivalent(with:newline))
        form.input.keyDown(with:newline)
        XCTAssertEqual(form.input.string,"Long draft\n"); XCTAssertEqual(sent,0)
        form.send.isEnabled = true
        form.input.keyDown(with:enter); XCTAssertEqual(sent,1)
        form.input.setMarkedText("かな",selectedRange:NSRange(location:2,length:0),replacementRange:form.input.selectedRange())
        XCTAssertTrue(form.input.hasMarkedText()); form.send.isEnabled = true
        form.input.keyDown(with:enter); XCTAssertEqual(sent,1,"Enter must not send while the input method has marked text.")
        form.input.unmarkText()
        form.input.keyDown(with:escape); XCTAssertEqual(canceled,1)
        XCTAssertEqual(session.drafts[.privateMessage(4)],"Inline draft")
        form.input.string = "Another long draft"; controller.textDidChange(Notification(name:NSText.didChangeNotification))
        XCTAssertEqual(session.drafts[.composeMessage(4)],"Another long draft")
        let reopened = ClassicMessageComposerWindow(session:session,user:4,preferences:prefs)
        defer { reopened.observation.stop() }
        XCTAssertEqual(reopened.form.input.string,"Another long draft")
        controller.cancelMessage()
        XCTAssertNil(session.drafts[.composeMessage(4)]); XCTAssertEqual(session.drafts[.privateMessage(4)],"Inline draft")
        XCTAssertFalse(try XCTUnwrap(reopened.window).isVisible)
    }

    @MainActor func testSendCapturesServerRecipientAndPreservesNewerDraft() async throws {
        let first = ComposerPeers(), second = ComposerPeers()
        try await first.connect(); try await second.connect()
        defer { first.close(); second.close() }
        let prefs = try preferences(); defer { prefs.defaults.removePersistentDomain(forName:prefsSuite(prefs)) }
        let bob = try XCTUnwrap(first.bob.currentUser?.id), alice = try XCTUnwrap(first.session.client.currentUser?.id)
        XCTAssertEqual(bob,second.bob.currentUser?.id,"Independent servers intentionally reuse IDs.")
        let controller = ClassicMessageComposerWindow(session:first.session,user:bob,preferences:prefs)
        let other = ClassicMessageComposerWindow(session:second.session,user:bob,preferences:prefs)
        defer { controller.observation.stop(); other.observation.stop() }
        first.session.drafts[.privateMessage(bob)] = "Inline stays"
        other.form.input.string = "Other server draft"; other.textDidChange(Notification(name:NSText.didChangeNotification))
        controller.form.input.string = "First line\nSecond line 日本語"; controller.textDidChange(Notification(name:NSText.didChangeNotification))
        first.gate.holdNext = true
        let task = Task { @MainActor in try await controller.sendMessage() }
        for _ in 0..<100 where !first.gate.waiting { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertTrue(first.gate.waiting); XCTAssertTrue(controller.isSending); XCTAssertFalse(controller.form.send.isEnabled)
        controller.form.input.string = "New draft while sending"; controller.textDidChange(Notification(name:NSText.didChangeNotification))
        first.session.privateMessages.select(999)
        first.gate.release()
        let shouldClose = try await task.value
        XCTAssertFalse(shouldClose)
        _ = try await first.bob.request(type:115)
        XCTAssertEqual(first.bob.privateMessages(with:alice).map(\.text),["First line\nSecond line 日本語"])
        XCTAssertTrue(second.bob.privateMessages(with:alice).isEmpty)
        XCTAssertEqual(first.session.drafts[.composeMessage(bob)],"New draft while sending")
        XCTAssertEqual(first.session.drafts[.privateMessage(bob)],"Inline stays")
        XCTAssertEqual(other.form.input.string,"Other server draft")
        let sentCurrentDraft = try await controller.sendMessage()
        XCTAssertTrue(sentCurrentDraft)
        XCTAssertTrue(controller.form.input.string.isEmpty); XCTAssertNil(first.session.drafts[.composeMessage(bob)])
        XCTAssertFalse(controller.isSending); XCTAssertFalse(first.session.privateMessages.needsAttention)
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
    }

    @MainActor func testFailedAndOversizedMessagesRetainDraftAndStaleRecipientIsRejected() async throws {
        let peers = ComposerPeers(); try await peers.connect(); defer { peers.close() }
        let prefs = try preferences(); defer { prefs.defaults.removePersistentDomain(forName:prefsSuite(prefs)) }
        let bob = try XCTUnwrap(peers.bob.currentUser?.id)
        let controller = ClassicMessageComposerWindow(session:peers.session,user:bob,preferences:prefs)
        defer { controller.observation.stop() }
        controller.form.input.string = String(repeating:"界",count:1366)
        controller.textDidChange(Notification(name:NSText.didChangeNotification))
        XCTAssertFalse(controller.form.send.isEnabled); XCTAssertTrue(controller.form.send.toolTip?.contains("4098") == true)
        do { _ = try await controller.sendMessage(); XCTFail("Oversized text must be rejected without truncation.") } catch {}
        XCTAssertEqual(peers.session.drafts[.composeMessage(bob)],controller.form.input.string)
        controller.form.input.string = "Retain after transport failure"; controller.textDidChange(Notification(name:NSText.didChangeNotification))
        peers.gate.holdNext = true
        let task = Task { @MainActor in try await controller.sendMessage() }
        for _ in 0..<100 where !peers.gate.waiting { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertTrue(peers.gate.waiting); peers.gate.close()
        do { _ = try await task.value; XCTFail("Closed transport must fail.") } catch {}
        XCTAssertEqual(controller.form.input.string,"Retain after transport failure")
        XCTAssertEqual(peers.session.drafts[.composeMessage(bob)],controller.form.input.string)
        peers.session.privateMessages.reset(); peers.session.drafts.removeValue(forKey:.composeMessage(bob)); controller.refresh()
        XCTAssertFalse(controller.isCurrentConnection); XCTAssertFalse(controller.form.input.isEditable)
        XCTAssertFalse(controller.form.send.isEnabled); XCTAssertEqual(controller.form.server.stringValue,"Connection changed")
        do { _ = try await controller.sendMessage(); XCTFail("Old recipient ID must not be reused.") } catch {}
        controller.textDidChange(Notification(name:NSText.didChangeNotification))
        XCTAssertNil(peers.session.drafts[.composeMessage(bob)],"A stale editor cannot repopulate the new connection's draft.")
    }

    @MainActor func testClosePendingSendPreservesConnectionAndReconnectClearsDrafts() async throws {
        let peers = ComposerPeers(); try await peers.connect(); defer { peers.close() }
        let prefs = try preferences(); defer { prefs.defaults.removePersistentDomain(forName:prefsSuite(prefs)) }
        let bob = try XCTUnwrap(peers.bob.currentUser?.id), alice = try XCTUnwrap(peers.session.client.currentUser?.id)
        let controller = ClassicMessageComposerWindow(session:peers.session,user:bob,preferences:prefs)
        defer { controller.observation.stop() }
        controller.form.input.string = "Submitted message"; controller.textDidChange(Notification(name:NSText.didChangeNotification))
        peers.gate.holdNext = true; controller.sendText()
        for _ in 0..<100 where !peers.gate.waiting { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertTrue(peers.gate.waiting)
        controller.requestClose(); peers.gate.release()
        for _ in 0..<100 where controller.isSending { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertFalse(controller.isSending); XCTAssertTrue(controller.form.input.string.isEmpty)
        XCTAssertNil(peers.session.drafts[.composeMessage(bob)])
        _ = try await peers.bob.request(type:115)
        XCTAssertEqual(peers.bob.privateMessages(with:alice).map(\.text),["Submitted message"])
        XCTAssertTrue(peers.session.client.isConnected,"Closing a composer preserves its server connection.")
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
        peers.session.drafts[.privateMessage(bob)] = "Inline"
        peers.session.drafts[.composeMessage(bob)] = "Composer"
        peers.session.drafts[.chat(1)] = "Room draft"
        // connect resets identity/drafts synchronously. Cancel its task before
        // yielding, so this check never attempts a socket connection.
        peers.session.connect(password:"",table:ChallengeTable(testBytes:[UInt8](repeating:7,count:1739)))
        peers.session.disconnect()
        XCTAssertNil(peers.session.drafts[.privateMessage(bob)])
        XCTAssertNil(peers.session.drafts[.composeMessage(bob)])
        XCTAssertEqual(peers.session.drafts[.chat(1)],"Room draft")
        XCTAssertFalse(controller.isCurrentConnection)
    }

    @MainActor func testClosingInlineMessageWindowAlsoFinishesSubmittedFrame() async throws {
        let peers = ComposerPeers(); try await peers.connect(); defer { peers.close() }
        let prefs = try preferences(); defer { prefs.defaults.removePersistentDomain(forName:prefsSuite(prefs)) }
        let bob = try XCTUnwrap(peers.bob.currentUser?.id), alice = try XCTUnwrap(peers.session.client.currentUser?.id)
        let pane = PrivateMessagesWindowController(session:peers.session,preferences:prefs,user:bob)
        defer { pane.observation.stop() }
        pane.input.string = "Inline submitted"; peers.gate.holdNext = true; pane.sendText()
        for _ in 0..<100 where !peers.gate.waiting { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertTrue(peers.gate.waiting); pane.requestClose(); peers.gate.release()
        for _ in 0..<100 where peers.session.drafts[.privateMessage(bob)] != "" { try await Task.sleep(for:.milliseconds(5)) }
        _ = try await peers.bob.request(type:115)
        XCTAssertEqual(peers.bob.privateMessages(with:alice).map(\.text),["Inline submitted"])
        XCTAssertEqual(peers.session.drafts[.privateMessage(bob)],"")
        XCTAssertTrue(peers.session.client.isConnected); XCTAssertFalse(try XCTUnwrap(pane.window).isVisible)
    }

    @MainActor func testPrivatePaneDoubleClickUsesComposerCallback() throws {
        let prefs = try preferences(); defer { prefs.defaults.removePersistentDomain(forName:prefsSuite(prefs)) }
        let session = ClassicSession(endpoint:ClassicEndpoint())
        let pane = PrivateMessagesWindowController(session:session,preferences:prefs,user:7)
        defer { pane.observation.stop() }
        var recipient: UInt32?
        pane.compose = { recipient = $0 }
        pane.recipients.activate?(ClassicRow(id:"8",values:["Bob"]))
        XCTAssertEqual(recipient,8); XCTAssertEqual(pane.selectedUser,8)
        XCTAssertFalse(try XCTUnwrap(pane.window).isVisible)
    }

    @MainActor func testOffscreenComposerInOriginalAppearances() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Provide the original application for composer renders") }
        let themes = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared; style.configureAssets(themes)
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for theme in themes.filter({ ["Mach Lavender","Amber CRT"].contains($0.name) }) {
            style.appearance = theme
            let form = ClassicMessageComposerForm(), chrome = ClassicChrome()
            chrome.title = "Message To: Alice"; chrome.frame = NSRect(x:0,y:0,width:352,height:364)
            chrome.layoutSubtreeIfNeeded(); form.frame = chrome.content.bounds; chrome.content.addSubview(form)
            var user = KDXUser(id:3,nickname:"Alice"); user.badge = 0; user.server15 = 80; user.server16 = 255
            user.icon = [1,1,0xff,0xcc,0x33,0x22,0x33,0x44]+[UInt8](repeating:0x01,count:512)
            form.recipient.update(user); form.server.stringValue = "Example server"
            form.input.string = "Hello Alice,\n\nHere is a longer private message.\nReturn starts a new line."
            form.layoutSubtreeIfNeeded(); chrome.layoutSubtreeIfNeeded()
            XCTAssertEqual(form.bounds.size,ClassicMessageComposerForm.referenceSize)
            XCTAssertTrue(form.bounds.contains(form.entry.frame)); XCTAssertTrue(form.entry.bounds.contains(form.scroll.frame))
            for scale in [1,2] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:352*scale,pixelsHigh:364*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                bitmap.size = chrome.bounds.size; chrome.cacheDisplay(in:chrome.bounds,to:bitmap)
                if let folder = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"] {
                    let root = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("\(theme.name)-send-message-\(scale)x.png"))
                }
            }
        }
    }

    @MainActor private func preferences() throws -> ClassicPreferences {
        let suite = "KDX-composer-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite)); defaults.set(suite,forKey:"testSuite")
        return ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
    }
    @MainActor private func prefsSuite(_ prefs: ClassicPreferences) -> String { prefs.defaults.string(forKey:"testSuite")! }
}

@MainActor private final class ComposerPeers {
    let server = KDXServer(configuration:ServerConfiguration())
    let session = ClassicSession(endpoint:ClassicEndpoint()), bob = KDXClient()
    let gate: ComposerWriteGate
    private let serverWire: WireConnection
    init() {
        let first = ClassicMemoryTransport(), second = ClassicMemoryTransport()
        first.peer = second; second.peer = first
        gate = ComposerWriteGate(first); serverWire = WireConnection(transport:second)
    }
    func connect() async throws {
        let table = ChallengeTable(testBytes:[UInt8](repeating:7,count:1739))
        server.accept(wire:serverWire,table:table)
        try await session.client.connect(wire:WireConnection(transport:gate),login:"",password:"",nickname:"Alice",table:table)
        let (a,b) = ClassicMemoryTransport.pair(); server.accept(wire:b,table:table)
        try await bob.connect(wire:a,login:"",password:"",nickname:"Bob",table:table)
        _ = try await session.client.request(type:115)
    }
    func close() { session.disconnect(); bob.disconnect(); server.stop() }
}

@MainActor private final class ComposerWriteGate: ByteTransport {
    let base: ClassicMemoryTransport
    var holdNext = false
    private(set) var waiting = false
    private var waiter: CheckedContinuation<Void,Error>?
    var peerHost: String { base.peerHost }
    var endpointDescription: String { base.endpointDescription }
    init(_ base: ClassicMemoryTransport) { self.base = base }
    func start() async throws { try await base.start() }
    func read(_ count: Int) async throws -> [UInt8] { try await base.read(count) }
    func write(_ bytes: [UInt8]) async throws {
        if holdNext { holdNext = false; waiting = true; try await withCheckedThrowingContinuation { waiter = $0 } }
        try Task.checkCancellation(); try await base.write(bytes)
    }
    func release() { let pending = waiter; waiter = nil; waiting = false; pending?.resume() }
    func close() { let pending = waiter; waiter = nil; waiting = false; pending?.resume(throwing:KDXError.disconnected); base.close() }
}
