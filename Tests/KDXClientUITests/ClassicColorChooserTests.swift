import AppKit
import XCTest
@testable import KDXClientUI
@testable import KDXCore

final class ClassicColorChooserTests: XCTestCase {
    func testOriginalNumericConversionsAndBounds() {
        XCTAssertEqual(ClassicColorValue.hexadecimal("  +0xA0b1C2tail"),0xa0b1c2)
        XCTAssertEqual(ClassicColorValue.hexadecimal("12345678"),0x345678)
        XCTAssertEqual(ClassicColorValue.hexadecimal("100000000"),0xffffff)
        XCTAssertEqual(ClassicColorValue.hexadecimal("#123456"),0)
        XCTAssertEqual(ClassicColorValue.decimal("12, 34, 56"),0x0c2238)
        XCTAssertEqual(ClassicColorValue.decimal("256 / 99999999999999 - 12"),0xffff0c)
        XCTAssertEqual(ClassicColorValue.decimal("12.34 56 99"),0x0c2238)
        XCTAssertEqual(ClassicColorValue.decimal("12"),0x0c0000)
        XCTAssertEqual(ClassicColorValue.decimal(""),0)
        var value = ClassicColorValue(rgb:0x123456)
        value.setComponent(1,300); XCTAssertEqual(value.rgb,0x12ff56)
        value.setComponent(0,-1); XCTAssertEqual(value.hexadecimal,"00FF56")
        XCTAssertEqual(value.decimal,"0, 255, 86")
    }
    @MainActor func testSynchronizedRepresentationsAndCancelDraft() throws {
        let form = ClassicColorChooserForm(rgb:0x123456)
        XCTAssertEqual(form.hexadecimal.stringValue,"123456"); XCTAssertEqual(form.decimal.stringValue,"18, 52, 86")
        XCTAssertEqual(form.percentages.map(\.stringValue),["7%","20%","33%"])
        form.hexadecimal.stringValue = "abCD01"; form.controlTextDidChange(Notification(name:NSText.didChangeNotification,object:form.hexadecimal))
        XCTAssertEqual(form.hexadecimal.stringValue,"abCD01","Do not rewrite the active editor or move its insertion point.")
        XCTAssertEqual(form.decimal.stringValue,"171, 205, 1")
        XCTAssertEqual(form.sliders.map { Int($0.doubleValue) },[171,205,1])
        form.decimal.stringValue = "1/2/3"; form.controlTextDidChange(Notification(name:NSText.didChangeNotification,object:form.decimal))
        XCTAssertEqual(form.hexadecimal.stringValue,"010203"); XCTAssertEqual(form.decimal.stringValue,"1/2/3")
        form.sliders[0].doubleValue = 255; form.sliderChanged(form.sliders[0])
        XCTAssertEqual(form.hexadecimal.stringValue,"FF0203"); XCTAssertEqual(form.decimal.stringValue,"255, 2, 3")
        XCTAssertEqual(form.preview.oldColor,0x123456); XCTAssertEqual(form.preview.newColor,0xff0203)
        XCTAssertEqual(form.channels.map(\.newColor),[0xff0000,0x200,3])
        var responses = [Bool](); form.respond = { responses.append($0) }
        form.cancel.performClick(nil); XCTAssertEqual(responses,[false]); XCTAssertEqual(form.original,0x123456)
        let right = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"\u{f703}",charactersIgnoringModifiers:"\u{f703}",isARepeat:false,keyCode:124))
        let previous = form.value.components[1]
        form.sliders[1].keyDown(with:right)
        XCTAssertGreaterThan(form.value.components[1],previous,"Native keyboard adjustment must send the slider action to the form.")
        XCTAssertEqual(form.value.components[1],Int(form.sliders[1].doubleValue))
        XCTAssertTrue(form.sliders[1].accessibilityPerformIncrement()); XCTAssertEqual(form.value.components[1],previous+2)
        XCTAssertTrue(form.sliders[1].accessibilityPerformDecrement()); XCTAssertEqual(form.value.components[1],previous+1)
        form.sliders[1].isEnabled = false
        form.sliders[1].keyDown(with:right); XCTAssertFalse(form.sliders[1].accessibilityPerformIncrement())
        XCTAssertEqual(form.value.components[1],previous+1)
    }
    @MainActor func testSliderTrackingAndNativeActions() throws {
        let style = ClassicStyle.shared; style.appearance = .recovery
        let slider = ClassicColorSlider("Red"); slider.frame = NSRect(x:0,y:0,width:280,height:28)
        let cell = try XCTUnwrap(slider.cell as? NSSliderCell)
        slider.doubleValue = 128
        let initial = cell.knobRect(flipped:true), point = NSPoint(x:initial.minX+3,y:initial.midY)
        XCTAssertTrue(cell.startTracking(at:point,in:slider)); XCTAssertEqual(Int(slider.doubleValue),128,accuracy:1)
        XCTAssertTrue(cell.continueTracking(last:point,current:NSPoint(x:1000,y:point.y),in:slider)); XCTAssertEqual(slider.doubleValue,255)
        XCTAssertTrue(cell.continueTracking(last:point,current:NSPoint(x:-100,y:point.y),in:slider)); XCTAssertEqual(slider.doubleValue,0)
        slider.isEnabled = false; XCTAssertFalse(cell.startTracking(at:point,in:slider))
        XCTAssertEqual(slider.accessibilityLabel(),"Red")
    }
    @MainActor func testGeometryAndOriginalConstructorInstructions() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Original application required") }
        let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
        func immediate(_ address: Int) throws -> Int { try bytes.u32(address+0x1de0)&0xffff }
        let form = ClassicColorChooserForm(rgb:0); form.layoutSubtreeIfNeeded()
        XCTAssertEqual(form.bounds.size,try NSSize(width:immediate(0xc0fcc),height:immediate(0xc0fec)))
        let records: [(NSView,[Int])] = [(form.sliders[0],[0xc11b8,0xc11bc,0xc11c0,0xc11c4]),
            (form.sliders[1],[0xc1270,0xc1274,0xc1278,0xc1280]),(form.sliders[2],[0xc132c,0xc1330,0xc1334,0xc133c]),
            (form.hexadecimal,[0xc13e8,0xc13ec,0xc13f0,0xc13f8]),(form.decimal,[0xc142c,0xc1430,0xc1434,0xc143c]),
            (form.preview,[0xc14e4,0xc14e8,0xc14ec,0xc14f0]),(form.accept,[0xc1518,0xc151c,0xc1520,0xc1528]),
            (form.cancel,[0xc1558,0xc155c,0xc1560,0xc1564])]
        for (view,addresses) in records {
            let p = try addresses.map(immediate)
            XCTAssertEqual(view.frame,NSRect(x:p[0],y:p[1],width:p[2]-p[0],height:p[3]-p[1]))
        }
        for view in form.subviews { XCTAssertTrue(form.bounds.contains(view.frame)) }
        for (address,opcode) in [(0x970e0,0x808302a0),(0x97114,0x80830298),(0x9737c,0x38deffe9),
            (0x973e8,0x38a0000d),(0x97408,0x397dfffc),(0x9ced4,0x3860006e),(0x9ced8,0x3be00072),
            (0x9d1e8,0x800801f8),(0xc0ba8,0x39000002),(0xc1818,0x38c01006)] {
            XCTAssertEqual(try bytes.u32(address+0x1de0),opcode)
        }
    }
    @MainActor func testChooserOwnsOnlyItsProfileDraftAndRejectsStaleResponses() async throws {
        let table = ChallengeTable(testBytes:[UInt8](repeating:7,count:1739))
        let session = ClassicSession(endpoint:ClassicEndpoint()), server = KDXServer(configuration:ServerConfiguration())
        defer { session.disconnect(); server.stop() }
        let (a,b) = ClassicMemoryTransport.pair(); server.accept(wire:b,table:table)
        try await session.client.connect(wire:a,login:"",password:"",nickname:"Alice",table:table)
        let suite = "KDX-color-chooser-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite)); defer { defaults.removePersistentDomain(forName:suite) }
        let owner = ClassicProfileWindow(session:session,user:try XCTUnwrap(session.client.currentUser),preferences:ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults))
        defer { owner.observation.stop() }
        let chooser = try XCTUnwrap(owner.makeColorChooser(background:false))
        XCTAssertNil(owner.makeColorChooser(background:true)); XCTAssertFalse(owner.form.save.isEnabled)
        chooser.form.hexadecimal.stringValue = "ABCDEF"; chooser.form.controlTextDidChange(Notification(name:NSText.didChangeNotification,object:chooser.form.hexadecimal))
        chooser.requestResponse(true)
        XCTAssertEqual(owner.form.draft.color(false),0xabcdef); XCTAssertNil(owner.colorChooser)
        XCTAssertEqual(session.client.currentUser?.colors,[0,0,0,0,0,0],"Chooser only edits a profile draft until Apply.")
        let before = owner.form.draft, canceled = try XCTUnwrap(owner.makeColorChooser(background:true))
        canceled.form.sliders[0].doubleValue = 255; canceled.form.sliderChanged(canceled.form.sliders[0]); canceled.requestClose()
        XCTAssertEqual(owner.form.draft,before); canceled.requestResponse(true); XCTAssertEqual(owner.form.draft,before)
        let stale = try XCTUnwrap(owner.makeColorChooser(background:true))
        session.privateMessages.reset(); owner.refresh(); XCTAssertTrue(stale.responded); XCTAssertNil(owner.colorChooser)
        stale.requestResponse(true); XCTAssertEqual(owner.form.draft,before)
        let reopened = ClassicProfileWindow(session:session,user:try XCTUnwrap(session.client.currentUser),preferences:owner.preferences)
        defer { reopened.observation.stop() }
        let child = try XCTUnwrap(reopened.makeColorChooser(background:true))
        reopened.requestClose(); XCTAssertTrue(child.responded); XCTAssertNil(reopened.colorChooser)
        child.requestResponse(true); XCTAssertEqual(reopened.form.draft.colors,[0,0,0,0,0,0])
        XCTAssertFalse(try XCTUnwrap(chooser.window).isVisible)
        XCTAssertFalse(try XCTUnwrap(owner.window).isVisible)
    }
    @MainActor func testOffscreenChooserAtBothScales() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Original application required") }
        let themes = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared; style.configureAssets(themes)
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for theme in themes.filter({ ["Mach Lavender","Amber CRT"].contains($0.name) }) {
            style.appearance = theme
            let form = ClassicColorChooserForm(rgb:0x123456), chrome = ClassicChrome()
            chrome.title = "Color Chooser"; chrome.isDialog = true; chrome.allowsResize = false
            chrome.frame = NSRect(x:0,y:0,width:492,height:264); chrome.layoutSubtreeIfNeeded()
            form.frame = chrome.content.bounds; chrome.content.addSubview(form)
            form.sliders[0].doubleValue = 200; form.sliderChanged(form.sliders[0]); form.layoutSubtreeIfNeeded(); chrome.layoutSubtreeIfNeeded()
            for scale in [1,2] {
                let bitmap = try HAPTextFieldTests().raster(chrome,scale:scale)
                let helper = HAPWindowTests()
                XCTAssertEqual(try helper.color(bitmap,x:370*scale,y:160*scale),0xc83456)
                XCTAssertEqual(try helper.color(bitmap,x:370*scale,y:200*scale),0x123456)
                if let folder = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"] {
                    let root = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("\(theme.name)-color-chooser-\(scale)x.png"))
                }
            }
        }
    }
}
