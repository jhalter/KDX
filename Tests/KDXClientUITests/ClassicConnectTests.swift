import AppKit
import XCTest
@testable import KDXClientUI

final class ClassicConnectTests: XCTestCase {
    @MainActor func testPrimaryControlFramesMatchOriginalTemplate() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Set KDX_REFERENCE for the original Connect template.") }
        let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
        let base = 0xd7a30+0x11ce8
        XCTAssertEqual(try bytes.data(base,4),Data("%VUU".utf8))
        XCTAssertEqual(try bytes.data(base+0xd8,4),Data("BPMN".utf8))
        let size = NSSize(width:try bytes.u16(base+16),height:try bytes.u16(base+18))
        let form = ClassicConnectForm(endpoint:ClassicEndpoint(),saving:false)
        XCTAssertEqual(ClassicConnectForm.referenceSize,size)
        form.frame = NSRect(origin:.zero,size:size); form.layoutSubtreeIfNeeded()
        let fields: [(NSView,Int)] = [(form.type,0xd8),(form.name,0x148),(form.host,0x1ac),(form.login,0x210),(form.password,0x2f0),(form.submit,0x278),(form.cancel,0x2b4),
            (try XCTUnwrap(form.labels["Type"]),0x9c),(try XCTUnwrap(form.labels["Name"]),0x10c),(try XCTUnwrap(form.labels["Address"]),0x170),(try XCTUnwrap(form.labels["Login"]),0x1d4),(try XCTUnwrap(form.labels["Password"]),0x238)]
        for (view,offset) in fields {
            let left = try bytes.u16(base+offset+4), top = try bytes.u16(base+offset+6)
            let right = try bytes.u16(base+offset+8), bottom = try bytes.u16(base+offset+10)
            XCTAssertEqual(view.frame,NSRect(x:left,y:top,width:right-left,height:bottom-top),"Template control at \(String(offset,radix:16))")
        }
        form.frame.size.width = 620; form.layoutSubtreeIfNeeded()
        for field in [form.name,form.host,form.login,form.password] {
            XCTAssertEqual(field.frame.minX,100); XCTAssertEqual(field.frame.maxX,610)
        }
        XCTAssertEqual(form.submit.frame.maxX,586); XCTAssertEqual(form.cancel.frame.maxX,470)
        XCTAssertEqual(form.type.frame,NSRect(x:100,y:10,width:150,height:20))
        XCTAssertTrue(form.optionsArea.isHidden)
    }

    @MainActor func testOptionsPreserveFieldsAndServiceDefaults() throws {
        var endpoint = ClassicEndpoint(); endpoint.host = "first.example"; endpoint.name = "First"
        endpoint.login = "account"; endpoint.nickname = "Nick"; endpoint.autoJoin = false
        let form = ClassicConnectForm(endpoint:endpoint,saving:false)
        var changes = 0; form.optionsChanged = { changes += 1 }
        form.password.stringValue = "test-only-password"
        XCTAssertEqual(try form.endpoint(),endpoint)
        XCTAssertEqual(form.preferredHeight,192)
        XCTAssertTrue(form.optionsButton.nextKeyView === form.cancel)
        form.optionsButton.performClick(nil)
        XCTAssertTrue(form.optionsVisible); XCTAssertFalse(form.optionsArea.isHidden)
        XCTAssertTrue(form.optionsButton.nextKeyView === form.port)
        XCTAssertTrue(form.port.nextKeyView === form.nickname)
        XCTAssertTrue(form.autoJoin.nextKeyView === form.cancel)
        XCTAssertEqual(form.preferredHeight,294)
        form.port.stringValue = "12345"; form.nickname.stringValue = "Changed"
        form.optionsButton.performClick(nil)
        XCTAssertFalse(form.optionsVisible); XCTAssertTrue(form.optionsButton.nextKeyView === form.cancel)
        XCTAssertEqual(form.port.stringValue,"12345"); XCTAssertEqual(form.nickname.stringValue,"Changed")
        XCTAssertEqual(form.password.stringValue,"test-only-password"); XCTAssertEqual(changes,2)
        form.setOptionsVisible(false); XCTAssertEqual(changes,2)
        form.type.selectItem(at:1); form.type.sendAction(form.type.action,to:form.type.target)
        XCTAssertEqual(form.port.stringValue,"12345","A custom port survives changing service type.")
        XCTAssertFalse(form.login.isEnabled); XCTAssertFalse(form.password.isEnabled)
        XCTAssertFalse(form.nickname.isEnabled); XCTAssertFalse(form.autoJoin.isEnabled)
        XCTAssertEqual(form.login.stringValue,"account"); XCTAssertEqual(form.password.stringValue,"test-only-password")
        XCTAssertTrue(try form.endpoint().tracker)
        form.port.stringValue = "10800"
        form.type.selectItem(at:0); form.type.sendAction(form.type.action,to:form.type.target)
        XCTAssertEqual(form.port.stringValue,"10700"); XCTAssertTrue(form.login.isEnabled)
        form.type.selectItem(at:1); form.type.sendAction(form.type.action,to:form.type.target)
        XCTAssertEqual(form.port.stringValue,"10800")
        form.host.stringValue = "  tracker.example  "
        XCTAssertEqual(try form.endpoint().host,"tracker.example")
        XCTAssertEqual(try form.endpoint().id,endpoint.id)
        for invalid in ["0","65536","abc",""] { form.port.stringValue = invalid; XCTAssertThrowsError(try form.endpoint()) }
        form.port.stringValue = "10700"; form.host.stringValue = ""; XCTAssertThrowsError(try form.endpoint())
        form.clearPassword(); XCTAssertTrue(form.password.stringValue.isEmpty)
        let other = ClassicConnectForm(endpoint:ClassicEndpoint(),saving:true)
        XCTAssertTrue(other.host.stringValue.isEmpty); XCTAssertEqual(other.submit.title,"Save")
        XCTAssertEqual(other.port.stringValue,"10700"); XCTAssertEqual(other.autoJoin.state,.on)
        XCTAssertEqual(form.submit.keyEquivalent,"\r"); XCTAssertEqual(form.cancel.keyEquivalent,"\u{1b}")
        XCTAssertEqual(form.host.accessibilityLabel(),"Address"); XCTAssertEqual(form.password.accessibilityLabel(),"Password")
        var canceled = 0; form.cancel.invoke = { canceled += 1 }
        form.cancelOperation(nil); XCTAssertEqual(canceled,1)
    }

    @MainActor func testOffscreenConnectFormsInOriginalAppearances() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Set KDX_REFERENCE for Connect rendering.") }
        let appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.configureAssets([]); style.appearance = .recovery }
        style.configureAssets(appearances)
        XCTAssertEqual(appearances.count,16)
        for appearance in appearances {
            style.appearance = appearance
            for expanded in [false,true] {
                let form = ClassicConnectForm(endpoint:ClassicEndpoint(),saving:false)
                form.setOptionsVisible(expanded)
                let chrome = ClassicChrome(); chrome.title = "KDX Connect"
                chrome.frame = NSRect(x:0,y:0,width:402,height:form.preferredHeight+28); chrome.layoutSubtreeIfNeeded()
                form.frame = chrome.content.bounds; chrome.content.addSubview(form); form.layoutSubtreeIfNeeded()
                XCTAssertEqual(form.bounds.size,NSSize(width:390,height:form.preferredHeight))
                for control in [form.type,form.name,form.host,form.login,form.password,form.submit,form.cancel,form.optionsButton] {
                    XCTAssertTrue(form.bounds.contains(control.frame))
                    XCTAssertFalse(control.hasAmbiguousLayout)
                }
                if expanded {
                    XCTAssertTrue(form.bounds.contains(form.optionsArea.frame))
                    for control in [form.port,form.nickname,form.autoJoin] {
                        XCTAssertTrue(form.optionsArea.bounds.contains(control.frame))
                        XCTAssertFalse(control.hasAmbiguousLayout)
                    }
                }
                for scale in [1,2] {
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(chrome.frame.width)*scale,pixelsHigh:Int(chrome.frame.height)*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                    bitmap.size = chrome.bounds.size; chrome.cacheDisplay(in:chrome.bounds,to:bitmap)
                    // Check actual composed field/background/button pixels, with the
                    // original form coordinates nested inside the custom chrome.
                    for (x,y,slot) in [(200,28,2),(200,66,10),(200,96,10),(200,126,10),(200,156,10),(180,183,34),(300,181,50)] {
                        XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),appearance.colors[slot],"\(x),\(y) in \(appearance.name), \(scale)x")
                    }
                    if let directory = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"] {
                        let folder = URL(fileURLWithPath:directory,isDirectory:true)
                        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent("\(appearance.name)-connect-\(expanded ? "options" : "basic")-\(scale)x.png"))
                    }
                }
            }
        }
    }
}
