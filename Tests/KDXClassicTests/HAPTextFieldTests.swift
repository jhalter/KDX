import AppKit
import XCTest
@testable import KDXClassicUI

final class HAPTextFieldTests: XCTestCase {
    @MainActor func testFramedScrollViewKeepsNativeViewport() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery }
        style.appearance = ClassicAppearance(id:"viewport",name:"Viewport",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test")
        let scroll = ClassicScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.documentView = NSView(frame:NSRect(x:0,y:0,width:1000,height:1000))
        let frame = ClassicFieldFrame(scroll); frame.frame = NSRect(x:0,y:0,width:240,height:180)
        frame.layoutSubtreeIfNeeded(); scroll.tile()
        XCTAssertEqual(scroll.frame,NSRect(x:3,y:3,width:234,height:174))
        XCTAssertEqual(scroll.borderType,.noBorder)
        XCTAssertEqual(scroll.contentSize,NSSize(width:218,height:158))
        for scale in [1,2] {
            let bitmap = try raster(frame,scale:scale)
            for (x,y,slot) in [(0,0,2),(100,1,3),(100,2,4),(100,177,4),(100,178,1)] {
                XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),UInt32(slot)*0x010101)
            }
        }
    }
    @MainActor func testOriginalFieldFrameStatesAndHAPOverrides() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery }
        for scale in [1,2] { for (focused,enabled) in [(false,true),(true,true),(false,false),(true,false)] {
            style.appearance = ClassicAppearance(id:"fields",name:"Fields",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test")
            let frame = NSRect(x:0,y:0,width:100,height:24)
            let bitmap = try helper.render(scale:scale,width:100,height:24) { HAPFieldDrawing.frame(frame,focused:focused,enabled:enabled) }
            let focus = focused && enabled
            for (x,y,slot) in [(0,0,2),(40,0,focus ? 9 : 2),(40,1,focus ? 9 : 3),(40,2,enabled ? 4 : 6),(40,3,10),(40,21,enabled ? 4 : 6),(40,22,focus ? 9 : 1),(99,8,focus ? 9 : 2)] {
                XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),UInt32(slot)*0x010101,"\(x),\(y) focused=\(focused),enabled=\(enabled)")
            }
            var bytes = [UInt8](HAPArtworkTests().skinSection())
            let id = !enabled ? 87 : focused ? 86 : 85
            bytes.replaceSubrange((64+id*4)..<(68+id*4),with:bytes[100..<104])
            style.appearance.artwork = try HAPArtwork(skins:Data(bytes),icons:Data())
            let skin = try helper.render(scale:scale,width:100,height:24) { HAPFieldDrawing.frame(frame,focused:focused,enabled:enabled) }
            XCTAssertEqual(try helper.color(skin,x:0,y:0),0xff0000)
            XCTAssertEqual(try helper.color(skin,x:20*scale,y:2*scale),0x0000ff)
            XCTAssertEqual(try helper.color(skin,x:20*scale,y:3*scale),0x0a0a0a) // Skin text color never replaces the editor fill.
        } }
    }

    @MainActor func testNativeEditingSelectionAndSecureCell() throws {
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery }
        style.appearance = ClassicAppearance(id:"edit",name:"Edit",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test")
        let field = ClassicTextField(frame:NSRect(x:0,y:0,width:240,height:24))
        let cell = try XCTUnwrap(field.cell as? ClassicTextFieldCell)
        XCTAssertTrue(field.isEditable); XCTAssertTrue(field.isSelectable)
        XCTAssertFalse(field.isBezeled); XCTAssertFalse(field.isBordered)
        XCTAssertEqual(cell.drawingRect(forBounds:field.bounds),NSRect(x:4,y:4,width:232,height:16))
        let editor = try XCTUnwrap(cell.fieldEditor(for:field)); editor.frame = NSRect(x:0,y:0,width:232,height:40)
        XCTAssertTrue(cell.setUpFieldEditorAttributes(editor) === editor)
        XCTAssertEqual(editor.backgroundColor,style.color(10)); XCTAssertEqual(editor.textColor,style.color(11))
        XCTAssertEqual(editor.insertionPointColor,style.color(14))
        XCTAssertEqual(editor.selectedTextAttributes[.backgroundColor] as? NSColor,style.color(12))
        XCTAssertEqual(editor.selectedTextAttributes[.foregroundColor] as? NSColor,style.color(13))
        editor.string = "Guest"; editor.setSelectedRange(NSRange(location:0,length:5))
        editor.insertText("日本語",replacementRange:editor.selectedRange())
        XCTAssertEqual(editor.string,"日本語")
        editor.setMarkedText("かな",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:3,length:0))
        XCTAssertTrue(editor.hasMarkedText()); editor.unmarkText(); XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string,"日本語かな")
        field.stringValue = "Guest"
        cell.select(withFrame:field.bounds,in:field,editor:editor,delegate:nil,start:1,length:2)
        XCTAssertEqual(editor.selectedRange(),NSRange(location:1,length:2))
        XCTAssertEqual(editor.convert(editor.bounds.origin,to:field),NSPoint(x:2,y:4))
        XCTAssertEqual(editor.textContainer?.lineFragmentPadding,2)
        cell.endEditing(editor)
        let secure = ClassicSecureTextField(frame:field.frame)
        XCTAssertTrue(secure.cell is NSSecureTextFieldCell)
        XCTAssertEqual(secure.cell?.drawingRect(forBounds:secure.bounds),cell.drawingRect(forBounds:field.bounds))
        secure.stringValue = "secret"
        let first = try raster(secure,scale:1)
        secure.stringValue = "abcdef"
        let second = try raster(secure,scale:1)
        XCTAssertEqual(first.representation(using:.png,properties:[:]),second.representation(using:.png,properties:[:]),"Same-length secrets must draw identical native masking glyphs")
        XCTAssertFalse(HAPFieldDrawing.focused(field)) // No desktop window or application is created by this test.
    }

    @MainActor func raster(_ view: NSView, scale: Int) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(view.bounds.width)*scale,pixelsHigh:Int(view.bounds.height)*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        bitmap.size = view.bounds.size; view.cacheDisplay(in:view.bounds,to:bitmap); return bitmap
    }

    @MainActor func testReferenceFieldsAtBothScales() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Set KDX_CLASSIC_REFERENCE for original field rendering") }
        let appearances = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        let oldChoice = style.fontChoiceID
        defer { style.appearance = .recovery; style.configureAssets([]); style.fontChoiceID = oldChoice }
        style.fontChoiceID = nil
        style.configureAssets(appearances)
        let fontData = try XCTUnwrap(appearances.first?.fonts?.first)
        let font = try HaxialFont(data:fontData)
        XCTAssertEqual(font.name,"Myoklonika")
        let glyph = try XCTUnwrap(font.strikes.first?.glyphs.first { $0.codepoint == 65 })
        XCTAssertEqual(appearances.count,16)
        for appearance in appearances {
            style.appearance = appearance
            let surface = ClassicSurface(frame:NSRect(x:0,y:0,width:360,height:180))
            let plain = ClassicTextField(frame:NSRect(x:8,y:8,width:344,height:24)); plain.stringValue = "KDX server address"
            let empty = ClassicTextField(frame:NSRect(x:8,y:42,width:344,height:24)); empty.placeholderString = "Type in the list to filter"
            let disabled = ClassicTextField(frame:NSRect(x:8,y:76,width:344,height:24)); disabled.stringValue = "Disabled"; disabled.isEnabled = false
            let secure = ClassicSecureTextField(frame:NSRect(x:8,y:110,width:344,height:24)); secure.stringValue = "private"
            [plain,empty,disabled,secure].forEach(surface.addSubview)
            for scale in [1,2] {
                let bitmap = try raster(surface,scale:scale)
                for (x,y,slot) in [(8,8,2),(24,9,3),(24,10,4),(340,12,10),(24,78,6)] {
                    let rgb = appearance.colors[slot]
                    XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),rgb)
                }
                let letter = ClassicTextField(frame:NSRect(x:0,y:0,width:60,height:23)); letter.stringValue = "A"
                for enabled in [true,false] {
                    letter.isEnabled = enabled
                    let letterBitmap = try raster(letter,scale:scale)
                    for y in 0..<15 { for x in 0..<10 {
                    let expected = glyph.isSet(x:x-glyph.x,y:y-glyph.y) ? appearance.colors[11] : appearance.colors[10]
                    XCTAssertEqual(try helper.color(letterBitmap,x:(x+4)*scale,y:(y+4)*scale),expected,"Native field glyph at \(x),\(y), \(scale)x")
                    } }
                    XCTAssertEqual(letter.isEnabled,enabled,"Rendering must not enable the live control")
                }
                letter.isEnabled = true
                let editor = try XCTUnwrap(letter.cell?.fieldEditor(for:letter))
                letter.cell?.select(withFrame:letter.bounds,in:letter,editor:editor,delegate:nil,start:1,length:0)
                let editingBitmap = try raster(letter,scale:scale)
                for y in 0..<15 { for x in 0..<10 {
                    let expected = glyph.isSet(x:x-glyph.x,y:y-glyph.y) ? appearance.colors[11] : appearance.colors[10]
                    XCTAssertEqual(try helper.color(editingBitmap,x:(x+4)*scale,y:(y+4)*scale),expected,"Editing glyph at \(x),\(y), \(scale)x")
                } }
                letter.cell?.endEditing(editor)
                // Placeholders are a modern affordance: AppKit's system hint
                // color can disappear against a HAP background. Both field
                // classes must use the imported text color without changing
                // their empty value or caller-provided placeholder.
                for placeholder in [ClassicTextField(frame:letter.frame),ClassicSecureTextField(frame:letter.frame)] as [NSTextField] {
                    let originalHint = NSAttributedString(string:"A",attributes:[.foregroundColor:NSColor.magenta,.font:NSFont.systemFont(ofSize:24)])
                    if placeholder is NSSecureTextField { placeholder.placeholderAttributedString = originalHint }
                    else { placeholder.placeholderString = "A" }
                    let originalString = placeholder.placeholderString
                    for enabled in [true,false] {
                        placeholder.isEnabled = enabled
                        let hintBitmap = try raster(placeholder,scale:scale)
                        for y in 0..<15 { for x in 0..<10 {
                            let expected = glyph.isSet(x:x-glyph.x,y:y-glyph.y) ? appearance.colors[11] : appearance.colors[10]
                            XCTAssertEqual(try helper.color(hintBitmap,x:(x+4)*scale,y:(y+4)*scale),expected,"Placeholder in \(appearance.name), enabled=\(enabled), \(scale)x at \(x),\(y)")
                        } }
                        XCTAssertEqual(placeholder.stringValue,"")
                        XCTAssertEqual(placeholder.placeholderString,originalString)
                        if placeholder is NSSecureTextField { XCTAssertEqual(placeholder.placeholderAttributedString,originalHint) }
                        XCTAssertEqual(placeholder.isEnabled,enabled)
                    }
                }
                if let directory = ProcessInfo.processInfo.environment["KDX_CLASSIC_RENDER_DIR"] {
                    let folder = URL(fileURLWithPath:directory,isDirectory:true); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent("\(appearance.name)-fields-\(scale)x.png"))
                }
            }
        }
    }
}
