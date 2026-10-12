import AppKit
import XCTest
@testable import KDXClassicUI

final class ClassicFieldEditorLifetimeTests: XCTestCase {
    @MainActor func testDrawingCopiesDoNotReleaseFieldEditor() throws {
        let field = ClassicTextField(frame:NSRect(x:0,y:0,width:240,height:26))
        let cell = try XCTUnwrap(field.cell as? ClassicTextFieldCell)
        weak var originalEditor: NSTextView?
        autoreleasepool { originalEditor = cell.fieldEditor(for:field) }
        XCTAssertNotNil(originalEditor)

        // Empty placeholders and disabled fields draw temporary NSCell copies.
        // Previously, releasing a copy over-released the cell's Swift editor ivar.
        field.placeholderString = "Server address"
        for enabled in [true,false,true] {
            field.isEnabled = enabled
            try autoreleasepool {
                _ = try HAPTextFieldTests().raster(field,scale:1)
            }
            guard let editor = originalEditor else {
                XCTFail("Drawing a temporary cell copy destroyed the live field editor")
                return
            }
            XCTAssertTrue(cell.fieldEditor(for:field) === editor)
            editor.string = "tracker.example"
            XCTAssertEqual(editor.string,"tracker.example")
        }
        field.isEnabled = true
        field.stringValue = "tracker.example"
        XCTAssertEqual(field.stringValue,"tracker.example")
    }

    @MainActor func testCopiedCellUsesItsControlEditor() throws {
        let first = ClassicTextField(frame:.zero)
        let second = ClassicTextField(frame:.zero)
        let cell = try XCTUnwrap(first.cell as? ClassicTextFieldCell)
        let firstEditor = try XCTUnwrap(cell.fieldEditor(for:first))
        second.cell = try XCTUnwrap(cell.copy() as? ClassicTextFieldCell)
        let secondEditor = try XCTUnwrap(second.cell?.fieldEditor(for:second))
        XCTAssertFalse(firstEditor === secondEditor)
        XCTAssertTrue(firstEditor.isFieldEditor)
        XCTAssertTrue(secondEditor.isFieldEditor)
        firstEditor.string = "first"
        secondEditor.string = "second"
        XCTAssertEqual(firstEditor.string,"first")
        XCTAssertEqual(secondEditor.string,"second")
    }

    @MainActor func testTrackerSubmissionAfterEditingAndDisabledFieldDrawing() throws {
        let form = ClassicConnectForm(endpoint:ClassicEndpoint(),saving:false)
        form.frame = NSRect(origin:.zero,size:ClassicConnectForm.referenceSize)
        let window = NSWindow(contentRect:form.bounds,styleMask:.borderless,backing:.buffered,defer:true)
        window.isReleasedWhenClosed = false
        window.contentView = form
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        form.layoutSubtreeIfNeeded()

        // No window is ordered on screen. Exercise AppKit's real editor lookup
        // and stringValue validation, as in the user's Connect crash stack.
        for field in [form.host,form.login,form.nickname] {
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.string = field === form.host ? "tracker.example" : "Guest"
            editor.didChangeText()
            XCTAssertTrue(window.makeFirstResponder(nil))
        }
        form.type.selectItem(at:1)
        form.type.sendAction(form.type.action,to:form.type.target)
        XCTAssertFalse(form.login.isEnabled)
        try autoreleasepool { _ = try HAPTextFieldTests().raster(form,scale:1) }
        let endpoint = try form.endpoint()
        XCTAssertTrue(endpoint.tracker)
        XCTAssertEqual(endpoint.host,"tracker.example")
        XCTAssertEqual(endpoint.port,10800)
        XCTAssertEqual(form.login.stringValue,"Guest")
        XCTAssertFalse(window.isVisible)
    }

}
