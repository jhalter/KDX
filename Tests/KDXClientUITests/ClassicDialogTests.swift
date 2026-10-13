import AppKit
import XCTest
@testable import KDXClientUI

final class ClassicDialogTests: XCTestCase {
    @MainActor func testQueuesStayIsolatedAndRejectStaleResponses() {
        let first = ClassicDialogQueue(), second = ClassicDialogQueue()
        var responses: [String] = []
        let a = ClassicDialogRequest(title:"Server A") { responses.append("A:"+($0?["name"] ?? "cancel")) }
        let b = ClassicDialogRequest(title:"Server B") { responses.append("B:"+($0?["name"] ?? "cancel")) }
        let error = ClassicDialogRequest(title:"Server A error",cancelTitle:nil) { _ in responses.append("error") }
        first.enqueue(a); first.enqueue(error); second.enqueue(b)
        first.complete(id:b.id,values:["name":"wrong"])
        XCTAssertTrue(responses.isEmpty); XCTAssertTrue(first.active === a)
        second.complete(id:b.id,values:["name":"Bob"])
        first.complete(id:a.id,values:["name":"Alice"])
        XCTAssertEqual(responses,["B:Bob","A:Alice"]); XCTAssertTrue(first.active === error)
        first.complete(id:a.id,values:["name":"duplicate"])
        XCTAssertEqual(responses.count,2)
        first.complete(id:error.id,values:[:]); XCTAssertNil(first.active)
        XCTAssertEqual(responses,["B:Bob","A:Alice","error"])
    }

    @MainActor func testClosingCancelsOnceClearsSecretsAndRejectsReentrantPrompts() {
        let queue = ClassicDialogQueue()
        var results: [Bool] = []
        let secret = ClassicDialogRequest(title:"Reconnect",fields:[ClassicDialogField(id:"password",label:"Password",value:"test-password",secure:true)]) { values in
            results.append(values != nil)
            queue.enqueue(ClassicDialogRequest(title:"Nested") { results.append($0 != nil) })
        }
        queue.enqueue(secret); queue.enqueue(ClassicDialogRequest(title:"Queued error") { results.append($0 != nil) })
        queue.invalidate(); queue.invalidate(); queue.complete(id:secret.id,values:["password":"stale"])
        XCTAssertEqual(results,[false,false,false]); XCTAssertTrue(queue.isClosed); XCTAssertNil(queue.active)
        XCTAssertEqual(secret.fields[0].value,"")
        secret.resolve(["password":"again"]); XCTAssertEqual(results.count,3)
    }

    @MainActor func testFollowupPromptKeepsExistingQueueOrder() {
        let queue = ClassicDialogQueue(); var order: [String] = []
        let third = ClassicDialogRequest(title:"Third") { _ in order.append("third") }
        let first = ClassicDialogRequest(title:"First") { _ in order.append("first"); queue.enqueue(third) }
        let second = ClassicDialogRequest(title:"Second") { _ in order.append("second") }
        queue.enqueue(first); queue.enqueue(second); queue.complete(id:first.id,values:[:])
        XCTAssertTrue(queue.active === second)
        queue.complete(id:second.id,values:nil); XCTAssertTrue(queue.active === third)
        queue.complete(id:third.id,values:[:]); XCTAssertEqual(order,["first","second","third"])
    }

    @MainActor private final class HeadlessOwner: ClassicWindowController {
        var shown: [NSWindow] = [], hidden: [NSWindow] = []
        override func showOwnedDialogWindow(_ child: NSWindow) { shown.append(child) }
        override func hideOwnedDialogWindow(_ child: NSWindow) { hidden.append(child) }
    }

    @MainActor func testSquareDialogsBlockOnlyTheirOwnerAndKeepQueueOrder() throws {
        _ = NSApplication.shared
        let suite = "KDX-dialog-owner-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
        let owner = HeadlessOwner(title:"Chat",key:"test",size:NSSize(width:600,height:400),preferences:preferences)
        let other = HeadlessOwner(title:"Other server",key:"other",size:NSSize(width:600,height:400),preferences:preferences)
        let parent = try XCTUnwrap(owner.window as? ClassicWindow)
        var topics: [String] = [], confirmations: [Bool] = []
        owner.prompt("Chat Topic",initial:"Old") { topics.append($0) }
        owner.confirm("Confirm",message:"Continue?",acceptTitle:"OK") { confirmations.append($0) }
        let topic = try XCTUnwrap(owner.ownedDialog as? ClassicDialogController)
        let child = try XCTUnwrap(topic.window)
        XCTAssertEqual(child.styleMask,.borderless)
        XCTAssertNil(child.sheetParent); XCTAssertNil(parent.attachedSheet)
        XCTAssertTrue(parent.modalChild === child)
        XCTAssertFalse(parent.canBecomeKey); XCTAssertTrue(try XCTUnwrap(other.window).canBecomeKey)
        XCTAssertEqual(owner.shown.count,1)
        XCTAssertEqual(child.frame.midX,parent.frame.midX,accuracy:1)
        topic.form.fields["value"]?.stringValue = "New"
        topic.requestResponse(true); topic.requestResponse(false)
        XCTAssertEqual(topics,["New"]); XCTAssertEqual(owner.hidden.count,1)
        XCTAssertEqual(owner.shown.count,2)
        let confirmation = try XCTUnwrap(owner.ownedDialog as? ClassicDialogController)
        XCTAssertFalse(confirmation === topic); XCTAssertFalse(parent.canBecomeKey)
        confirmation.requestClose()
        XCTAssertEqual(confirmations,[false]); XCTAssertNil(owner.ownedDialog)
        XCTAssertNil(parent.modalChild); XCTAssertTrue(parent.canBecomeKey)
        XCTAssertFalse(parent.isVisible); XCTAssertTrue(owner.shown.allSatisfy { !$0.isVisible })
    }

    @MainActor func testClosingOwnerCancelsChildAndQueuedRequestsWithoutPresentingMore() throws {
        _ = NSApplication.shared
        let suite = "KDX-dialog-owner-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
        let owner = HeadlessOwner(title:"Chat",key:"test",size:NSSize(width:600,height:400),preferences:preferences)
        var results: [Bool] = []
        owner.presentDialog(ClassicDialogRequest(title:"Password",fields:[ClassicDialogField(id:"password",label:"Password",value:"secret",secure:true)]) { results.append($0 != nil) })
        owner.presentDialog(ClassicDialogRequest(title:"Next") { results.append($0 != nil) })
        let dialog = try XCTUnwrap(owner.ownedDialog as? ClassicDialogController)
        owner.windowWillClose(Notification(name:NSWindow.willCloseNotification,object:owner.window))
        dialog.requestResponse(true)
        XCTAssertEqual(results,[false,false]); XCTAssertEqual(owner.shown.count,1)
        XCTAssertEqual(owner.hidden.count,1); XCTAssertNil(owner.ownedDialog)
        XCTAssertNil((owner.window as? ClassicWindow)?.modalChild)
        XCTAssertEqual(dialog.form.fields["password"]?.stringValue,"")
        owner.showMessage("Too late"); XCTAssertEqual(owner.shown.count,1)
    }

    @MainActor func testOtherOwnedDialogsDeferQueuedPrompts() throws {
        _ = NSApplication.shared
        let suite = "KDX-dialog-owner-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
        let owner = HeadlessOwner(title:"Profile",key:"test",size:NSSize(width:600,height:400),preferences:preferences)
        let chooser = ClassicColorChooserWindow(rgb:0x123456,preferences:preferences)
        XCTAssertTrue(owner.presentOwnedDialog(chooser))
        owner.showMessage("Queued error")
        XCTAssertTrue(owner.ownedDialog === chooser); XCTAssertEqual(owner.shown.count,1)
        XCTAssertFalse(owner.presentOwnedDialog(chooser))
        owner.dismissOwnedDialog(chooser)
        XCTAssertEqual(owner.shown.count,2)
        let message = try XCTUnwrap(owner.ownedDialog as? ClassicDialogController)
        XCTAssertEqual(message.form.message.stringValue,"Queued error")
        message.requestClose(); XCTAssertNil(owner.ownedDialog)
        XCTAssertTrue(try XCTUnwrap(owner.window).canBecomeKey)
    }

    @MainActor func testNativeFormFieldsActionsAndBoundedMessageLayout() throws {
        _ = NSApplication.shared
        let request = ClassicDialogRequest(title:"Reconnect",message:String(repeating:"A long server message wraps and remains selectable.\n",count:100),fields:[
            ClassicDialogField(id:"name",label:"Nickname",value:"Guest"),
            ClassicDialogField(id:"password",label:"Password",secure:true)
        ],acceptTitle:"Connect")
        let form = ClassicDialogContent(request:request)
        form.frame = NSRect(origin:.zero,size:form.preferredSize); form.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(form.frame.height,400)
        XCTAssertGreaterThan(form.message.frame.height,form.messageScroll.frame.height)
        XCTAssertLessThan(form.messageScroll.frame.maxY,try XCTUnwrap(form.fields["name"]).frame.minY)
        XCTAssertLessThan(try XCTUnwrap(form.fields["password"]).frame.maxY,form.accept.frame.minY)
        XCTAssertTrue(form.message.isSelectable); XCTAssertTrue(form.fields["password"] is NSSecureTextField)
        XCTAssertEqual(form.firstEditor?.accessibilityLabel(),"Nickname")
        XCTAssertTrue(form.firstEditor?.nextKeyView === form.fields["password"])
        XCTAssertEqual(form.accept.keyEquivalent,"\r"); XCTAssertEqual(form.cancel?.keyEquivalent,"\u{1b}")
        form.fields["name"]?.stringValue = "Changed"; form.fields["password"]?.stringValue = "test-password"
        XCTAssertEqual(form.values,["name":"Changed","password":"test-password"])
        var responses: [Bool] = []; form.respond = { responses.append($0) }
        form.accept.performClick(nil); form.cancel?.performClick(nil)
        XCTAssertEqual(responses,[true,false])
        form.clearSensitiveValues()
        XCTAssertEqual(form.fields["password"]?.stringValue,""); XCTAssertEqual(form.fields["name"]?.stringValue,"Changed")
        let message = ClassicDialogContent(request:ClassicDialogRequest(title:"Info",message:"Ready",cancelTitle:nil))
        XCTAssertNil(message.cancel); XCTAssertNil(message.firstEditor)
        message.respond = { responses.append($0) }; message.cancelOperation(nil)
        XCTAssertEqual(responses,[true,false,false])
        let profile = ClassicDialogContent(request:ClassicDialogRequest(title:"Profile",fields:[ClassicDialogField(id:"name",label:"Nickname")]))
        profile.frame = NSRect(origin:.zero,size:profile.preferredSize); profile.layoutSubtreeIfNeeded()
        XCTAssertTrue(profile.messageScroll.isHidden)
        XCTAssertTrue(profile.bounds.contains(try XCTUnwrap(profile.fields["name"]).frame))
    }

    @MainActor func testOffscreenThemedDialogForms() throws {
        var appearances = [ClassicAppearance.recovery]
        if let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] {
            appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances.filter { ["Mach Lavender","Amber CRT"].contains($0.name) }
        }
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for appearance in appearances {
            style.configureAssets([appearance]); style.appearance = appearance
            for (name,request) in [
                ("profile",ClassicDialogRequest(title:"My Profile",fields:[ClassicDialogField(id:"name",label:"Nickname",value:"Guest"),ClassicDialogField(id:"info",label:"Description",value:"KDX user")],acceptTitle:"Save")),
                ("reconnect",ClassicDialogRequest(title:"Reconnect",fields:[ClassicDialogField(id:"password",label:"Password (blank for guest)",value:"test",secure:true)],acceptTitle:"Connect")),
                ("message",ClassicDialogRequest(title:"File Information",message:"Name: Read Me\nKind: Text\nSize: 1200 bytes",cancelTitle:nil)),
                ("confirm",ClassicDialogRequest(title:"Disconnect?",message:"Active transfers will stop. Partial files are retained for resume.",acceptTitle:"Disconnect"))
            ] {
                let form = ClassicDialogContent(request:request), chrome = ClassicChrome()
                chrome.title = request.title; chrome.isDialog = true
                let size = form.preferredSize
                chrome.frame = NSRect(x:0,y:0,width:size.width+12,height:size.height+28); chrome.layoutSubtreeIfNeeded()
                form.frame = chrome.content.bounds; chrome.content.addSubview(form); form.layoutSubtreeIfNeeded()
                XCTAssertEqual(chrome.buttons.filter { !$0.isHidden }.map(\.kind),[.close])
                XCTAssertTrue(form.bounds.contains(form.accept.frame))
                for scale in [1,2] {
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(chrome.frame.width)*scale,pixelsHigh:Int(chrome.frame.height)*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                    bitmap.size = chrome.bounds.size; chrome.cacheDisplay(in:chrome.bounds,to:bitmap)
                    if let folder = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"] {
                        let url = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(appearance.name)-dialog-\(name)-\(scale)x.png"))
                    }
                }
                form.clearSensitiveValues()
            }
        }
    }

    @MainActor func testHiddenControllerWiresDefaultButtonAndNeverPersistsForm() throws {
        _ = NSApplication.shared
        let suite = "KDX-dialog-tests-"+UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
        let request = ClassicDialogRequest(title:"Reconnect",fields:[ClassicDialogField(id:"password",label:"Password",value:"test-password",secure:true)])
        // Deferred window, never presented, activated or attached as a sheet.
        let dialog = ClassicDialogController(request:request,preferences:preferences)
        let window = try XCTUnwrap(dialog.window)
        XCTAssertFalse(window.isVisible); XCTAssertFalse(window.isKeyWindow)
        XCTAssertEqual(window.accessibilitySubrole(),.dialog)
        XCTAssertTrue(window.defaultButtonCell === dialog.form.accept.cell)
        XCTAssertTrue(window.initialFirstResponder === dialog.form.firstEditor)
        dialog.chrome.layoutSubtreeIfNeeded(); dialog.form.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(dialog.form.frame.width,dialog.form.preferredSize.width)
        XCTAssertGreaterThanOrEqual(dialog.form.frame.height,dialog.form.preferredSize.height)
        var accepted: [Bool] = []
        dialog.responseRequested = { accepted.append($0) }
        dialog.requestResponse(true); dialog.requestClose(); dialog.requestResponse(true)
        XCTAssertEqual(accepted,[true],"Duplicate button/close events must not complete a dialog twice.")
        dialog.form.clearSensitiveValues(); dialog.saveFrame()
        XCTAssertNil(defaults.object(forKey:"frame.dialog"))
        XCTAssertEqual(dialog.form.fields["password"]?.stringValue,"")
        XCTAssertFalse(window.isVisible)
    }
}
