import AppKit
import XCTest
@testable import KDXClassicUI

private final class ScrollTestDocument: NSView { override var isFlipped: Bool { true } }
/// A headless test has no NSApplication action dispatcher. Deliver the scroller's
/// actual AppKit-installed target/action directly, without opening an application.
@MainActor private final class HeadlessScroller: ClassicScroller {
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        guard let action, let target = target as? NSObject, target.responds(to:action) else { return false }
        target.perform(action,with:self)
        return true
    }
}
final class HAPScrollerTests: XCTestCase {
    func testReferenceGeometryAndDragLimits() {
        for horizontal in [false,true] {
            func make(_ length: CGFloat, _ value: Double = 0.5, _ proportion: CGFloat = 0.25) -> HAPScrollLayout {
                HAPScrollLayout(bounds:NSRect(x:0,y:0,width:horizontal ? length : 16,height:horizontal ? 16 : length),horizontal:horizontal,value:value,proportion:proportion,enabled:true)
            }
            XCTAssertTrue(make(30).parts.isEmpty)
            XCTAssertFalse(make(128).paired); XCTAssertTrue(make(129).paired)
            let layout = make(200)
            XCTAssertEqual(layout.track,layout.slice(30,170))
            XCTAssertEqual(layout.knob,layout.slice(82,117))
            for (position,part) in [(8,HAPScrollPart.decrement),(23,.leadingIncrement),(177,.trailingDecrement),(192,.increment),(40,.pageBefore),(145,.pageAfter),(100,.knob)] {
                XCTAssertEqual(layout.hit(NSPoint(x:horizontal ? position : 8,y:horizontal ? 8 : position)),part)
            }
            XCTAssertEqual(layout.value(forKnobOrigin:-100),0)
            XCTAssertEqual(layout.value(forKnobOrigin:1000),1)
            XCTAssertEqual(layout.value(forKnobOrigin:82.5),0.5)
            XCTAssertEqual(make(200,0).knob,layout.slice(30,65))
            XCTAssertEqual(make(200,1).knob,layout.slice(135,170))
            XCTAssertEqual(make(200,.nan,.nan).knob,layout.track)
            XCTAssertEqual(make(200,0,0).knob,layout.slice(30,47))
        }
    }
    func skins(omit: Set<Int> = [], pressedMargins: Int = 1) throws -> HAPArtwork {
        var bytes = [UInt8](repeating:0,count:2112)
        func put(_ value: Int, _ at: Int) { for i in 0..<4 { bytes[at+i] = UInt8(truncatingIfNeeded:value >> (24-i*8)) } }
        for offset in [0,19] {
            for id in [146,147,148,149,150,151,153,154,156,157,158,159,160,161] {
                if omit.contains(id+offset) { continue }
                let thumb = id == 150 || id == 151, grip = id == 153 || id == 154, background = id < 150
                let length = background ? 65 : thumb ? max(17,pressedMargins*2+1) : grip ? 3 : 16
                let width = offset == 0 ? length : (grip ? 3 : 16), height = offset == 0 ? (grip ? 3 : 16) : length
                let stride = ((width+31)/32)*4, at = bytes.count
                put(at,64+(id+offset)*4)
                bytes += [UInt8](repeating:0,count:24+stride*height)
                bytes[at+1] = UInt8(width); bytes[at+3] = UInt8(height); bytes[at+5] = 1
                let axis = offset == 0 ? 0 : 1
                bytes[at+12+axis] = 1; bytes[at+14+axis] = 1
                if id == 151 { bytes[at+12+axis] = UInt8(pressedMargins); bytes[at+14+axis] = UInt8(pressedMargins) }
                if background { bytes[at+16+axis] = 30; bytes[at+18+axis] = 30 }
                else if !thumb && !grip { bytes[at+16] = 0; bytes[at+17] = 0 }
                put((id+offset)*0x010101,at+20)
            }
        }
        return try HAPArtwork(skins:Data(bytes),icons:Data())
    }
    @MainActor func testMissingPressedAndDisabledSkinsUsePalette() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery }
        style.appearance = ClassicAppearance(id:"partial",name:"Partial",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test",artwork:try skins(omit:[151,170,148,167]))
        for horizontal in [false,true] { for enabled in [false,true] { for scale in [1,2] {
            let bounds = NSRect(x:0,y:0,width:horizontal ? 240 : 16,height:horizontal ? 16 : 240)
            let layout = HAPScrollLayout(bounds:bounds,horizontal:horizontal,value:0.5,proportion:0.2,enabled:enabled,skins:style.artwork!.skins)
            let bitmap = try helper.render(scale:scale,width:Int(bounds.width),height:Int(bounds.height)) { HAPScrollDrawing.draw(layout,pressed:.knob) }
            func pixel(_ along: Int, _ cross: Int) throws -> UInt32 { try helper.color(bitmap,x:(horizontal ? along : cross)*scale,y:(horizontal ? cross : along)*scale) }
            // The whole control falls back: arrows and thumb use palette slots.
            XCTAssertEqual(try pixel(0,0),UInt32(enabled ? 128 : 156)*0x010101)
            let start = Int(horizontal ? layout.knob.minX : layout.knob.minY)
            XCTAssertEqual(try pixel(start+4,8),UInt32(enabled ? 141 : 154)*0x010101)
            XCTAssertEqual(layout.hit(NSPoint(x:8,y:8)),enabled ? .decrement : .none)
        } } }
    }
    @MainActor func testPressedThumbUsesOwnMarginsWithoutChangingHitGeometry() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery }
        style.appearance = ClassicAppearance(id:"wide",name:"Wide thumb",colors:[UInt32](repeating:0,count:221),source:"test",artwork:try skins(pressedMargins:20))
        for horizontal in [false,true] {
            let offset = horizontal ? 0 : 19
            let bounds = NSRect(x:0,y:0,width:horizontal ? 240 : 16,height:horizontal ? 16 : 240)
            let layout = HAPScrollLayout(bounds:bounds,horizontal:horizontal,value:0.5,proportion:0,enabled:true,skins:style.artwork!.skins)
            XCTAssertEqual(layout.knob,layout.slice(112,128))
            XCTAssertEqual(layout.drawingKnob(using:style.artwork!.skins[151+offset]!),layout.slice(100,140))
            for scale in [1,2] {
                let bitmap = try helper.render(scale:scale,width:Int(bounds.width),height:Int(bounds.height)) { HAPScrollDrawing.draw(layout,pressed:.knob) }
                XCTAssertEqual(try helper.color(bitmap,x:(horizontal ? 102 : 8)*scale,y:(horizontal ? 8 : 102)*scale),UInt32(151+offset)*0x010101)
            }
            let short = HAPScrollLayout(bounds:NSRect(x:0,y:0,width:horizontal ? 100 : 16,height:horizontal ? 16 : 100),horizontal:horizontal,value:0.5,proportion:0,enabled:true,skins:style.artwork!.skins)
            XCTAssertFalse(short.knob.isEmpty)
            XCTAssertTrue(short.drawingKnob(using:style.artwork!.skins[151+offset]!).isEmpty)
        }
        style.appearance.artwork = try skins(omit:[150,169])
        for horizontal in [false,true] {
            let bounds = NSRect(x:0,y:0,width:horizontal ? 240 : 16,height:horizontal ? 16 : 240)
            let layout = HAPScrollLayout(bounds:bounds,horizontal:horizontal,value:0.5,proportion:0.25,enabled:true,skins:style.artwork!.skins)
            XCTAssertFalse(layout.usesSkins,"Normal hit layout falls back when its thumb is missing.")
            let bitmap = try helper.render(scale:1,width:Int(bounds.width),height:Int(bounds.height)) { HAPScrollDrawing.draw(layout,pressed:.knob) }
            XCTAssertEqual(try helper.color(bitmap,x:horizontal ? 103 : 8,y:horizontal ? 8 : 103),UInt32(horizontal ? 151 : 170)*0x010101,"Pressed drawing still uses its available bitmap.")
        }
    }
    @MainActor func testSkinGeometryStatesAndBothAxes() throws {
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery }
        style.appearance = ClassicAppearance(id:"scroll",name:"Scroll skins",colors:[UInt32](repeating:0,count:221),source:"test",artwork:try skins())
        for horizontal in [false,true] {
            let bounds = NSRect(x:0,y:0,width:horizontal ? 200 : 16,height:horizontal ? 16 : 200)
            let offset = horizontal ? 0 : 19
            let layout = HAPScrollLayout(bounds:bounds,horizontal:horizontal,value:0.5,proportion:0.25,enabled:true,skins:style.artwork!.skins)
            XCTAssertEqual(layout.skinID,146+offset); XCTAssertEqual(layout.knob,layout.slice(82,117))
            for pressed in [HAPScrollPart.none,.knob,.decrement] { for scale in [1,2] {
                let helper = HAPWindowTests()
                let bitmap = try helper.render(scale:scale,width:Int(bounds.width),height:Int(bounds.height)) { HAPScrollDrawing.draw(layout,pressed:pressed) }
                func pixel(_ along: Int, _ cross: Int = 8) throws -> UInt32 { try helper.color(bitmap,x:(horizontal ? along : cross)*scale,y:(horizontal ? cross : along)*scale) }
                XCTAssertEqual(try pixel(40),UInt32(146+offset)*0x010101)
                XCTAssertEqual(try pixel(84),UInt32((pressed == .knob ? 151 : 150)+offset)*0x010101)
                XCTAssertEqual(try pixel(99),UInt32((pressed == .knob ? 154 : 153)+offset)*0x010101)
                if pressed == .decrement { XCTAssertEqual(try pixel(8),UInt32(156+offset)*0x010101) }
            } }
            let disabled = HAPScrollLayout(bounds:bounds,horizontal:horizontal,value:0,proportion:1,enabled:false,skins:style.artwork!.skins)
            XCTAssertEqual(disabled.skinID,148+offset); XCTAssertEqual(disabled.hit(NSPoint(x:8,y:8)),.none)
        }
    }
    @MainActor func testNativeScrollingThroughAppKit() throws {
        ClassicStyle.shared.appearance = .recovery
        let scroll = ClassicScrollView(frame:NSRect(x:0,y:0,width:240,height:180))
        scroll.verticalScroller = HeadlessScroller(frame:NSRect(x:0,y:0,width:16,height:100))
        scroll.horizontalScroller = HeadlessScroller(frame:NSRect(x:0,y:0,width:100,height:16))
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        let document = ScrollTestDocument(frame:NSRect(x:0,y:0,width:1000,height:1000))
        scroll.documentView = document; scroll.tile(); scroll.reflectScrolledClipView(scroll.contentView)
        let vertical = try XCTUnwrap(scroll.verticalScroller as? ClassicScroller), horizontal = try XCTUnwrap(scroll.horizontalScroller as? ClassicScroller)
        XCTAssertEqual(vertical.frame.width,16); XCTAssertEqual(horizontal.frame.height,16)
        XCTAssertEqual(scroll.scrollerStyle,.legacy)
        for (scroller,isHorizontal) in [(vertical,false),(horizontal,true)] {
            func origin() -> CGFloat { isHorizontal ? scroll.contentView.bounds.minX : scroll.contentView.bounds.minY }
            let initial = origin()
            scroller.activate(.increment)
            let afterLine = origin(); XCTAssertGreaterThan(afterLine,initial)
            scroller.activate(.leadingIncrement); XCTAssertGreaterThan(origin(),afterLine)
            scroller.activate(.decrement); XCTAssertEqual(origin(),afterLine,accuracy:0.01)
            scroller.activate(.trailingDecrement); XCTAssertEqual(origin(),initial,accuracy:0.01)
            scroller.activate(.pageAfter); XCTAssertGreaterThan(origin(),afterLine)
            let geometry = scroller.geometry
            scroller.moveKnob(to:(isHorizontal ? geometry.track.maxX-geometry.knob.width : geometry.track.maxY-geometry.knob.height))
            XCTAssertEqual(origin(),1000-(isHorizontal ? scroll.contentSize.width : scroll.contentSize.height),accuracy:0.01)
            scroller.moveKnob(to:-100); XCTAssertEqual(origin(),0,accuracy:0.01)
        }
    }
    @MainActor func testOriginalPaletteScrollbarsAtBothScales() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Provide the original application for scrollbar artwork.") }
        let catalog = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared; style.configureAssets(catalog)
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for name in ["Mach Lavender","Amber CRT"] {
            style.appearance = try XCTUnwrap(catalog.first { $0.name == name })
            XCTAssertEqual(style.chromeArtwork?.horizontalScrollGrip?.count,16)
            XCTAssertEqual(style.chromeArtwork?.verticalScrollGrip?.count,16)
            for scale in [1,2] {
                let helper = HAPWindowTests()
                let bitmap = try helper.render(scale:scale,width:360,height:300) {
                    for (index,part) in [HAPScrollPart.none,.knob,.decrement,.pageAfter].enumerated() {
                        HAPScrollDrawing.draw(HAPScrollLayout(bounds:NSRect(x:8,y:8+index*26,width:280,height:16),horizontal:true,value:0.35,proportion:0.3,enabled:true),pressed:part)
                        HAPScrollDrawing.draw(HAPScrollLayout(bounds:NSRect(x:8+index*28,y:122,width:16,height:170),horizontal:false,value:0.6,proportion:0.3,enabled:true),pressed:part)
                    }
                    HAPScrollDrawing.draw(HAPScrollLayout(bounds:NSRect(x:310,y:8,width:16,height:280),horizontal:false,value:0,proportion:1,enabled:false))
                }
                XCTAssertEqual(try helper.color(bitmap,x:8*scale,y:8*scale),style.appearance.colors[128])
                XCTAssertEqual(try helper.color(bitmap,x:10*scale,y:10*scale),style.appearance.colors[130])
                XCTAssertEqual(try helper.color(bitmap,x:310*scale,y:8*scale),style.appearance.colors[156])
                if let folder = ProcessInfo.processInfo.environment["KDX_CLASSIC_RENDER_DIR"] {
                    let url = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(name)-scrollbars-\(scale)x.png"))
                }
            }
        }
    }
}
