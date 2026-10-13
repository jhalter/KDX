import AppKit
import XCTest
@testable import KDXClientUI

final class ClassicChatLayoutTests: XCTestCase {
    @MainActor func testChatPanesFillWindowWhileActionsStayAtBottom() throws {
        _ = NSApplication.shared
        let suite = "KDX-chat-layout-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
        var themes = [ClassicAppearance.recovery]
        if let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] {
            themes += try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances.filter { ["Mach Lavender","Amber CRT"].contains($0.name) }
        }
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for theme in themes {
            style.configureAssets([theme]); style.appearance = theme
            let controller = ChatWindowController(session:ClassicSession(endpoint:ClassicEndpoint()),room:0,preferences:preferences)
            defer { controller.observation.stop() }
            let window = try XCTUnwrap(controller.window)
            let history = try XCTUnwrap(controller.transcript.enclosingScrollView)
            let entry = try XCTUnwrap(controller.input.enclosingScrollView)
            let actions = try XCTUnwrap(controller.send.superview)
            let panes = try XCTUnwrap(controller.members.superview)
            for topic in ["",String(repeating:"A long chat topic ",count:40)] {
                controller.topic.stringValue = topic
                for size in [NSSize(width:800,height:490),NSSize(width:1200,height:800),window.minSize,NSSize(width:900,height:650)] {
                    window.setContentSize(size); controller.chrome.layoutSubtreeIfNeeded()
                    let content = controller.chrome.content
                    func rect(_ view: NSView) -> NSRect { content.convert(view.bounds,from:view) }
                    let historyRect = rect(history), entryRect = rect(entry), membersRect = rect(controller.members)
                    let panesRect = rect(panes), actionsRect = rect(actions)
                    XCTAssertEqual(actionsRect.height,24,accuracy:1)
                    XCTAssertEqual(actionsRect.maxY,content.bounds.maxY,accuracy:1)
                    XCTAssertEqual(panesRect.minY,0,accuracy:1)
                    XCTAssertEqual(actionsRect.minY-panesRect.maxY,6,accuracy:1)
                    XCTAssertEqual(panesRect.width,content.bounds.width,accuracy:1)
                    XCTAssertGreaterThanOrEqual(historyRect.height,130)
                    XCTAssertGreaterThanOrEqual(entryRect.height,48)
                    XCTAssertEqual(historyRect.width,entryRect.width,accuracy:1)
                    XCTAssertGreaterThanOrEqual(membersRect.width,170)
                    XCTAssertEqual(controller.input.frame.width,entry.contentSize.width,accuracy:1)
                    XCTAssertLessThan(entryRect.maxX,membersRect.minX)
                    XCTAssertLessThan(historyRect.maxY,entryRect.minY)
                    XCTAssertEqual(membersRect.maxY,panesRect.maxY,accuracy:1)
                    for button in actions.subviews.compactMap({ $0 as? ClassicButton }) where !button.isHidden {
                        XCTAssertTrue(content.bounds.contains(rect(button)),"Action clipped at \(size): \(button.title)")
                        XCTAssertGreaterThanOrEqual(button.frame.width,button.intrinsicContentSize.width-1)
                    }
                    XCTAssertFalse(window.isVisible)
                }
            }
            XCTAssertTrue(window.initialFirstResponder === controller.input)
            XCTAssertEqual(controller.input.autoresizingMask,[.width])
            XCTAssertFalse(controller.input.isHorizontallyResizable)
        }
    }

    @MainActor func testChatDividerChoicesSurviveShrinkingGrowingAndReopening() throws {
        _ = NSApplication.shared
        let suite = "KDX-chat-dividers-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
        let session = ClassicSession(endpoint:ClassicEndpoint())
        let controller = ChatWindowController(session:session,room:0,preferences:preferences)
        defer { controller.observation.stop() }
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width:1000,height:700)); controller.chrome.layoutSubtreeIfNeeded()
        let users = try XCTUnwrap(controller.members.superview as? ClassicPaneSplitView)
        let conversation = try XCTUnwrap(users.subviews.first as? ClassicPaneSplitView)
        for (split,position) in [(users,CGFloat(600)),(conversation,CGFloat(180))] {
            split.setPosition(position,ofDividerAt:0)
            split.splitViewDidResizeSubviews(Notification(name:NSSplitView.didResizeSubviewsNotification,object:split))
        }
        let userPortion = users.portion, inputPortion = conversation.portion
        for size in [window.minSize,NSSize(width:1200,height:800),window.minSize,NSSize(width:1000,height:700)] {
            window.setContentSize(size); controller.chrome.layoutSubtreeIfNeeded()
            XCTAssertEqual(users.portion,userPortion,accuracy:0.001)
            XCTAssertEqual(conversation.portion,inputPortion,accuracy:0.001)
            XCTAssertGreaterThanOrEqual(users.subviews[0].frame.width,260)
            XCTAssertGreaterThanOrEqual(users.subviews[1].frame.width,170)
            XCTAssertGreaterThanOrEqual(conversation.subviews[0].frame.height,136)
            XCTAssertGreaterThanOrEqual(conversation.subviews[1].frame.height,54)
            for split in [users,conversation] {
                for pane in split.subviews { XCTAssertTrue(split.bounds.contains(pane.frame)) }
            }
        }
        let reopened = ChatWindowController(session:session,room:0,preferences:preferences)
        defer { reopened.observation.stop() }
        reopened.chrome.layoutSubtreeIfNeeded()
        let restoredUsers = try XCTUnwrap(reopened.members.superview as? ClassicPaneSplitView)
        let restoredConversation = try XCTUnwrap(restoredUsers.subviews.first as? ClassicPaneSplitView)
        XCTAssertEqual(restoredUsers.portion,userPortion,accuracy:0.001)
        XCTAssertEqual(restoredConversation.portion,inputPortion,accuracy:0.001)
        XCTAssertFalse(window.isVisible); XCTAssertFalse(try XCTUnwrap(reopened.window).isVisible)
    }

}
