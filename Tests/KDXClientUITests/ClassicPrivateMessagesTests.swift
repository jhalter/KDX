import AppKit
import XCTest
@testable import KDXClientUI
@testable import KDXCore

final class ClassicPrivateMessagesTests: XCTestCase {
    @MainActor func testAppearanceSwitchPreservesDraftAndMarkedText() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Original appearances required for live restyling checks.") }
        let appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared, oldFont = style.fontChoiceID
        defer { style.appearance = .recovery; style.configureAssets([]); style.fontChoiceID = oldFont }
        style.configureAssets(appearances); style.appearance = try XCTUnwrap(appearances.first)
        XCTAssertEqual(style.fontChoices.count,5)
        guard !style.fontChoices.isEmpty else { return XCTFail("Imported fonts are missing") }
        let suite = "KDX-private-theme-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let session = ClassicSession(endpoint:ClassicEndpoint())
        session.drafts[.privateMessage(1)] = "Draft for first recipient"
        session.drafts[.privateMessage(2)] = "Independent draft"
        let controller = PrivateMessagesWindowController(session:session,preferences:ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults),user:1)
        defer { controller.observation.stop() }
        controller.input.setMarkedText("かな",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:6,length:3))
        controller.textDidChange(Notification(name:NSText.didChangeNotification))
        let draft = controller.input.string, marked = controller.input.markedRange(), selection = controller.input.selectedRange()
        controller.transcript.string = "Earlier conversation"
        controller.transcript.setSelectedRange(NSRange(location:2,length:5))
        XCTAssertTrue(controller.input.hasMarkedText())
        XCTAssertEqual(appearances.count,16)
        for (index,appearance) in appearances.enumerated() {
            style.appearance = appearance
            style.fontChoiceID = style.fontChoices[index % style.fontChoices.count].id
            controller.applyStyle()
            XCTAssertEqual(controller.selectedUser,1)
            XCTAssertEqual(controller.recipients.selected?.id,"1")
            XCTAssertEqual(controller.input.string,draft)
            XCTAssertEqual(controller.input.markedRange(),marked)
            XCTAssertEqual(controller.input.selectedRange(),selection)
            XCTAssertEqual(controller.transcript.string,"Earlier conversation")
            XCTAssertEqual(controller.transcript.selectedRange(),NSRange(location:2,length:5))
            XCTAssertEqual(session.drafts[.privateMessage(1)],draft)
            XCTAssertEqual(session.drafts[.privateMessage(2)],"Independent draft")
            for editor in [controller.input,controller.transcript] {
                XCTAssertEqual(editor.font,style.font)
                XCTAssertEqual(editor.textColor,style.color(11))
                XCTAssertEqual(editor.backgroundColor,style.color(10))
                XCTAssertEqual(editor.insertionPointColor,style.color(14))
                XCTAssertEqual(editor.selectedTextAttributes[.backgroundColor] as? NSColor,style.color(12))
                XCTAssertEqual(editor.selectedTextAttributes[.foregroundColor] as? NSColor,style.color(13))
            }
            XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
        }
    }

    @MainActor func testUnreadDirectionSelectionDeletionAndSessionIsolation() {
        let first = ClassicPrivateMessagesState(), second = ClassicPrivateMessagesState()
        let a = ChatLine(userID:1,sender:"To misleading nickname",text:"incoming",isPrivate:true)
        let b = ChatLine(userID:2,sender:"To user",text:"outgoing",isPrivate:true,isOutgoing:true)
        let room = ChatLine(userID:3,sender:"chat",text:"room",roomID:1)
        first.update([a,b,room],activeRecipient:nil)
        XCTAssertEqual(first.recipients,[1,2]); XCTAssertEqual(first.unread,[1])
        first.update([a,b],users:[KDXUser(id:1,nickname:"Renamed peer")],activeRecipient:nil)
        first.update([a,b],users:[],activeRecipient:nil)
        XCTAssertEqual(first.profiles[1]?.nickname,"Renamed peer","Offline conversations retain the last known profile.")
        XCTAssertTrue(second.recipients.isEmpty)
        first.select(1); first.update([a,b],activeRecipient:nil); XCTAssertTrue(first.unread.isEmpty)
        let next = ChatLine(userID:1,sender:"user",text:"later",isPrivate:true)
        first.update([a,b,next],activeRecipient:nil); XCTAssertEqual(first.unread,[1])
        first.update([a,b,next],activeRecipient:1); XCTAssertTrue(first.unread.isEmpty)
        first.remove(1); first.update([b],activeRecipient:nil)
        XCTAssertEqual(first.recipients,[2]); XCTAssertNil(first.selected); XCTAssertNil(first.profiles[1])
        first.update([b,next],activeRecipient:nil); XCTAssertEqual(first.unread,[1])
        let generation = first.generation; first.reset()
        XCTAssertNotEqual(first.generation,generation); XCTAssertTrue(first.recipients.isEmpty)
        XCTAssertTrue(first.unread.isEmpty); XCTAssertNil(first.selected)
    }

    @MainActor func testDraftSwitchingAndReconnectClearSelectedIdentity() throws {
        _ = NSApplication.shared
        let suite = "KDX-private-tests-"+UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let prefs = ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
        let session = ClassicSession(endpoint:ClassicEndpoint())
        let controller = PrivateMessagesWindowController(session:session,preferences:prefs,user:1)
        defer { controller.observation.stop() }
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
        controller.input.string = "First draft"; controller.textDidChange(Notification(name:NSText.didChangeNotification))
        controller.select(2); XCTAssertEqual(controller.input.string,"")
        controller.input.string = "Second draft"; controller.textDidChange(Notification(name:NSText.didChangeNotification))
        controller.select(1); XCTAssertEqual(controller.input.string,"First draft")
        XCTAssertEqual(session.drafts[.privateMessage(2)],"Second draft")
        XCTAssertEqual(controller.recipients.rows.map(\.id),["1","2"])
        controller.deleteMessages(with:2)
        XCTAssertEqual(controller.selectedUser,1); XCTAssertNil(session.drafts[.privateMessage(2)])
        session.privateMessages.reset(); controller.refresh()
        XCTAssertNil(controller.selectedUser); XCTAssertEqual(controller.input.string,"")
        XCTAssertFalse(controller.send.isEnabled); XCTAssertFalse(controller.input.isEditable)
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
    }

    @MainActor func testSendCapturesRecipientWhileSwitchingAndDeleteIsLocal() async throws {
        _ = NSApplication.shared
        let suite = "KDX-private-send-"+UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let prefs = ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
        let table = ChallengeTable(testBytes:[UInt8](repeating:7,count:1739)), server = KDXServer(configuration:ServerConfiguration())
        let session = ClassicSession(endpoint:ClassicEndpoint()), bob = KDXClient(), carol = KDXClient()
        defer { session.disconnect(); bob.disconnect(); carol.disconnect(); server.stop() }
        for (client,name) in [(session.client,"Alice"),(bob,"Bob"),(carol,"Carol")] {
            let (a,b) = ClassicMemoryTransport.pair(); server.accept(wire:b,table:table)
            try await client.connect(wire:a,login:"",password:"",nickname:name,table:table)
        }
        _ = try await session.client.request(type:115)
        let aliceID = try XCTUnwrap(session.client.currentUser?.id), bobID = try XCTUnwrap(bob.currentUser?.id), carolID = try XCTUnwrap(carol.currentUser?.id)
        let controller = PrivateMessagesWindowController(session:session,preferences:prefs,user:bobID)
        defer { controller.observation.stop() }
        controller.input.string = "Only Bob"; controller.sendText()
        controller.select(carolID); controller.input.string = "Carol draft"; controller.textDidChange(Notification(name:NSText.didChangeNotification))
        for _ in 0..<100 where bob.privateMessages(with:aliceID).isEmpty || session.client.privateMessages(with:bobID).isEmpty { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(bob.privateMessages(with:aliceID).map(\.text),["Only Bob"])
        XCTAssertTrue(carol.privateMessages(with:aliceID).isEmpty)
        XCTAssertEqual(controller.input.string,"Carol draft"); XCTAssertEqual(controller.selectedUser,carolID)
        XCTAssertEqual(session.drafts[.privateMessage(bobID)],"")
        XCTAssertEqual(session.client.privateMessages(with:bobID).first?.isOutgoing,true)
        XCTAssertEqual(bob.privateMessages(with:aliceID).first?.isOutgoing,false)
        try await carol.sendPrivate(to:aliceID,text:"Incoming Carol")
        _ = try await session.client.request(type:115); controller.refresh()
        XCTAssertEqual(session.privateMessages.unread,[carolID],"A deferred hidden window must not mark incoming text as read.")
        controller.select(carolID); XCTAssertTrue(session.privateMessages.unread.isEmpty)
        XCTAssertTrue(controller.transcript.string.contains("Incoming Carol"))
        controller.deleteMessages(with:bobID)
        XCTAssertTrue(session.client.privateMessages(with:bobID).isEmpty)
        XCTAssertEqual(session.client.privateMessages(with:carolID).map(\.text),["Incoming Carol"])
        XCTAssertEqual(bob.privateMessages(with:aliceID).map(\.text),["Only Bob"],"Delete Messages never removes the peer's history.")
        XCTAssertTrue(session.client.isConnected)
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
    }

    @MainActor func testPrivatePaneRendersAtBothScales() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Provide the original application for imported appearance renders") }
        let themes = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery; style.configureAssets([]) }
        style.configureAssets(themes)
        let suite = "KDX-private-render-"+UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let prefs = ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
        for theme in themes.filter({ ["Mach Lavender","Amber CRT"].contains($0.name) }) {
            style.appearance = theme
            let session = ClassicSession(endpoint:ClassicEndpoint())
            let controller = PrivateMessagesWindowController(session:session,preferences:prefs,user:1)
            controller.observation.stop()
            controller.select(2); controller.select(1)
            controller.recipients.selectionChanged = nil
            controller.recipients.rows = [
                ClassicRow(id:"1",values:["Alice"],userAdornment:ClassicUserAdornment(user:KDXUser(id:1,nickname:"Alice"),unreadMessage:false)),
                ClassicRow(id:"2",values:["Bob"],userAdornment:ClassicUserAdornment(user:KDXUser(id:2,nickname:"Bob"),unreadMessage:true))
            ]
            controller.transcript.string = "<Alice> This conversation belongs to Alice.\n<To Alice> Each recipient has a separate draft."
            controller.input.string = "A draft for Alice…"
            controller.chrome.layoutSubtreeIfNeeded()
            let listRect = controller.chrome.convert(controller.recipients.bounds,from:controller.recipients)
            let historyRect = controller.chrome.convert(controller.transcript.enclosingScrollView!.bounds,from:controller.transcript.enclosingScrollView!)
            let inputRect = controller.chrome.convert(controller.input.enclosingScrollView!.bounds,from:controller.input.enclosingScrollView!)
            XCTAssertLessThan(listRect.maxX,historyRect.minX)
            XCTAssertLessThan(historyRect.maxY,inputRect.minY)
            XCTAssertGreaterThan(historyRect.height,90); XCTAssertGreaterThan(inputRect.height,40)
            XCTAssertGreaterThan(listRect.height,controller.chrome.bounds.height-90)
            XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
            for scale in [1,2] {
                let view = controller.chrome, size = view.bounds.size
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(size.width)*scale,pixelsHigh:Int(size.height)*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                bitmap.size = size; view.cacheDisplay(in:view.bounds,to:bitmap)
                XCTAssertTrue(view.bounds.contains(view.convert(controller.input.enclosingScrollView!.bounds,from:controller.input.enclosingScrollView!)))
                if let directory = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"] {
                    let url = URL(fileURLWithPath:directory,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(theme.name)-private-messages-\(scale)x.png"))
                }
            }
        }
    }

    @MainActor func testPanePositionsUseClassicPreferencesAndStayWithinBounds() throws {
        let suite = "KDX-private-panes-"+UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
        for vertical in [true,false] {
            let key = vertical ? "recipients" : "input"
            let split = ClassicPrivateSplitView(vertical:vertical,key:key,preferences:preferences,portion:0.4,minimums:(80,60))
            split.addPane(NSView()); split.addPane(NSView())
            split.frame.size = NSSize(width:600,height:350)
            split.setPosition(vertical ? 250 : 180,ofDividerAt:0)
            split.splitViewDidResizeSubviews(Notification(name:NSSplitView.didResizeSubviewsNotification,object:split))
            XCTAssertEqual(vertical ? split.subviews[0].frame.width : split.subviews[0].frame.height,vertical ? 250 : 180,accuracy:1)
            let saved = defaults.double(forKey:"split."+key)
            XCTAssertGreaterThan(saved,0.1); XCTAssertLessThan(saved,0.9)
            let restored = ClassicPrivateSplitView(vertical:vertical,key:key,preferences:preferences,portion:0.2,minimums:(80,60))
            restored.addPane(NSView()); restored.addPane(NSView())
            XCTAssertEqual(restored.portion,saved,accuracy:0.005)
            for size in [NSSize(width:450,height:210),NSSize(width:900,height:650)] {
                restored.frame.size = size; restored.resizeSubviews(withOldSize:size)
                for pane in restored.subviews { XCTAssertTrue(restored.bounds.contains(pane.frame)) }
                let first = restored.subviews[0].frame, second = restored.subviews[1].frame
                XCTAssertEqual(vertical ? second.minX-first.maxX : second.minY-first.maxY,6)
            }
        }
    }

    @MainActor func testUnreadBarOverridesClassColorAndRemainsAccessible() throws {
        var user = KDXUser(id:1,nickname:"Recipient"); user.badge = 25; user.server15 = 50; user.server16 = 75
        for unread in [false,true] {
            let adornment = ClassicUserAdornment(user:user,unreadMessage:unread)
            XCTAssertEqual(adornment.classColor,unread ? 0xff0000 : 0)
            let text = ClassicListTextField(labelWithString:user.nickname), cell = ClassicUserCell(text:text,adornment:adornment)
            XCTAssertEqual(text.accessibilityHelp(),unread ? "Unread messages" : "Messages read")
            _ = cell
        }
        XCTAssertEqual(ClassicUserAdornment(user:user).classColor,0x19324b)
    }
}
