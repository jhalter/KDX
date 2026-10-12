import AppKit
import XCTest
@testable import KDXClientUI

final class HAPWindowTests: XCTestCase {
    @MainActor func render(scale: Int, width: Int = 360, height: Int = 180, _ draw: () -> Void) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width*scale,pixelsHigh:height*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        bitmap.size = NSSize(width:width,height:height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep:bitmap))
        let transform = NSAffineTransform(); transform.translateX(by:0,yBy:CGFloat(height)); transform.scaleX(by:1,yBy:-1); transform.concat()
        NSGraphicsContext.current = NSGraphicsContext(cgContext:NSGraphicsContext.current!.cgContext,flipped:true)
        NSGraphicsContext.current?.shouldAntialias = false
        NSColor.white.setFill(); NSRect(x:0,y:0,width:width,height:height).fill()
        draw()
        return bitmap
    }
    func color(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> UInt32 {
        let c = try XCTUnwrap(bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB))
        return UInt32((c.redComponent*255).rounded()) << 16 | UInt32((c.greenComponent*255).rounded()) << 8 | UInt32((c.blueComponent*255).rounded())
    }
    @MainActor func testOriginalWindowEdgesGradientAndContentGeometry() throws {
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery; style.configureAssets([]) }
        style.appearance = ClassicAppearance(id:"fixture",name:"Fixture",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test")
        let rect = NSRect(x:0,y:0,width:360,height:180)
        XCTAssertEqual(HAPWindowDrawing.contentRect(in:rect),NSRect(x:6,y:22,width:348,height:152))
        XCTAssertEqual(HAPWindowControl.close.defaultHitRect(in:rect),NSRect(x:3,y:0,width:16,height:22))
        XCTAssertEqual(HAPWindowControl.menu.defaultImageRect(in:rect),NSRect(x:27,y:4,width:32,height:14))
        XCTAssertEqual(HAPWindowControl.maximize.defaultImageRect(in:rect).minX,323)
        XCTAssertEqual(HAPWindowControl.minimize.defaultImageRect(in:rect).minX,341)
        for active in [false,true] { for scale in [1,2] {
            let bitmap = try render(scale:scale) { HAPWindowDrawing.frame(rect,active:active) }
            let base = active ? 79 : 54
            for (x,y,slot) in [(0,0,5),(100,1,0),(2,30,2),(4,30,4),(5,30,5),(355,30,0),(358,30,4),(100,174,5),(100,175,0),(100,176,2),(100,178,4),(100,179,5)] {
                for sy in 0..<scale { for sx in 0..<scale {
                    XCTAssertEqual(try color(bitmap,x:x*scale+sx,y:y*scale+sy),UInt32(base+slot)*0x010101,"\(x),\(y), active=\(active), scale=\(scale)")
                } }
            }
            for row in 0..<18 { XCTAssertEqual(try color(bitmap,x:100*scale,y:(row+2)*scale),UInt32(base+7+row)*0x010101) }
        } }
    }

    func syntheticSkins() throws -> HAPArtwork {
        var data = [UInt8](repeating:0,count:2112)
        func put(_ n: Int, at: Int) { for i in 0..<4 { data[at+i] = UInt8(truncatingIfNeeded:n >> (24-8*i)) } }
        for id in [204,205,207,208,209,212,213,214,217,218,219,222,223,224,227,228] {
            let at = data.count
            put(at,at:64+id*4)
            data += [UInt8](repeating:0,count:36)
            data[at+1] = 3; data[at+3] = 3; data[at+5] = 1
            for i in 12..<16 { data[at+i] = 1 }
            let placement: [UInt8]
            if id < 207 { placement = [7,26,8,9] }
            else if id >= 227 { placement = [0,0,5,6] }
            else if id < 212 { placement = [9,4,0,0] }
            else if id < 217 { placement = [0,5,11,0] }
            else if id < 222 { placement = [0,6,21,0] }
            else { placement = [30,4,0,0] }
            for (index,n) in placement.enumerated() { data[at+16+index] = n }
            put(id*0x010101,at:at+20)
        }
        return try HAPArtwork(skins:Data(data),icons:Data())
    }
    @MainActor func testHAPWindowOverridesControlStatesAndPlacement() throws {
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery }
        style.appearance = ClassicAppearance(id:"skins",name:"Skins",colors:[UInt32](repeating:0,count:221),source:"test",artwork:try syntheticSkins())
        let rect = NSRect(x:0,y:0,width:360,height:180)
        XCTAssertEqual(HAPWindowDrawing.contentRect(in:rect),NSRect(x:7,y:26,width:345,height:145))
        XCTAssertEqual(HAPWindowDrawing.hitRect(.close,in:rect,active:true),NSRect(x:9,y:4,width:3,height:3))
        XCTAssertEqual(HAPWindowDrawing.hitRect(.minimize,in:rect,active:true),NSRect(x:346,y:5,width:3,height:3))
        XCTAssertEqual(HAPWindowDrawing.resizeHitRect(in:rect,active:true),NSRect(x:352,y:171,width:3,height:3))
        for active in [false,true] { for pressed in [false,true] { for scale in [1,2] {
            let bitmap = try render(scale:scale) {
                HAPWindowDrawing.frame(rect,active:active)
                for control in HAPWindowControl.allCases { HAPWindowDrawing.control(control,in:rect,active:active,pressed:pressed) }
                HAPWindowDrawing.resize(in:rect,active:active)
            }
            XCTAssertEqual(try color(bitmap,x:100*scale,y:100*scale),UInt32(active ? 205 : 204)*0x010101)
            for control in HAPWindowControl.allCases {
                let position = HAPWindowDrawing.hitRect(control,in:rect,active:active)
                XCTAssertEqual(try color(bitmap,x:Int(position.midX)*scale,y:Int(position.midY)*scale),UInt32(control.skinBase+(pressed ? 2 : active ? 1 : 0))*0x010101)
            }
            XCTAssertEqual(try color(bitmap,x:353*scale,y:172*scale),UInt32(active ? 228 : 227)*0x010101)
        } } }
        // Native hit targets and content use the same theme geometry as the painter.
        let chrome = ClassicChrome(); chrome.frame = rect; chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(chrome.content.frame,HAPWindowDrawing.contentRect(in:rect))
        for button in chrome.buttons {
            XCTAssertEqual(button.frame,HAPWindowDrawing.hitRect(button.kind,in:rect,active:false))
            XCTAssertEqual(button.accessibilityLabel(),button.kind.label)
        }
        var skins = try syntheticSkins().skins
        skins.replaceSubrange((64+209*4)..<(68+209*4),with:[0,0,0,0])
        style.appearance.artwork = try HAPArtwork(skins:skins,icons:Data())
        XCTAssertEqual(HAPWindowDrawing.controlSkin(.close,active:true,pressed:true),HAPWindowDrawing.controlSkin(.close,active:true,pressed:false),"Without a pressed variant the original keeps the normal control visible.")
    }

    @MainActor func testReferenceArtworkCatalogRoundTripAndWindowRenders() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Provide the original application to verify imported window artwork.") }
        let imported = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let library = AppearanceLibrary(root:root); try library.install(imported)
        let catalog = library.load()
        XCTAssertEqual(catalog.count,17)
        XCTAssertEqual(catalog.filter { $0.id != "recovery" },imported.appearances)
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery; style.configureAssets([]) }
        style.configureAssets(catalog)
        for appearance in catalog where appearance.id != "recovery" {
            let name = appearance.name
            style.appearance = appearance
            let art = try XCTUnwrap(style.chromeArtwork); try art.validate()
            XCTAssertEqual(art.close.count,98); XCTAssertEqual(art.menu.count,224)
            for scale in [1,2] {
                let bitmap = try render(scale:scale,width:400,height:360) {
                    for (index,active) in [true,false].enumerated() {
                        let rect = NSRect(x:10,y:10+index*175,width:380,height:160)
                        style.color(105).setFill(); rect.fill()
                        HAPWindowDrawing.frame(rect,active:active)
                        for control in HAPWindowControl.allCases { HAPWindowDrawing.control(control,in:rect,active:active,pressed:false) }
                        HAPWindowDrawing.resize(in:rect,active:active)
                        HAPWindowDrawing.title("KDX — \(name)",in:rect,active:active)
                        ClassicPainter.button(NSRect(x:24,y:rect.minY+40,width:110,height:24),title:"Connect",pressed:false,enabled:true,defaultButton:false)
                    }
                }
                // The close bitmap's black X uses title foreground; the bevel uses the frame palette.
                XCTAssertEqual(try color(bitmap,x:17*scale,y:16*scale),style.appearance.colors[85])
                XCTAssertEqual(try color(bitmap,x:17*scale,y:191*scale),style.appearance.colors[60])
                if let folder = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"] {
                    let url = URL(fileURLWithPath:folder,isDirectory:true)
                    try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("\(name)-windows-\(scale)x.png"))
                }
            }
        }
        style.appearance = ClassicAppearance(id:"native",name:"Native view fixture",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test",chromeArtwork:try XCTUnwrap(style.chromeArtwork))
        let chrome = ClassicChrome(); chrome.frame = NSRect(x:0,y:0,width:360,height:180)
        chrome.title = "Native AppKit window"
        chrome.layoutSubtreeIfNeeded()
        for scale in [1,2] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:360*scale,pixelsHigh:180*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
            bitmap.size = chrome.bounds.size
            chrome.cacheDisplay(in:chrome.bounds,to:bitmap)
            // Check actual NSButtonCell drawing in the native view coordinate system.
            // The top and bottom bevel colors must not be vertically exchanged.
            for (x,y,slot) in [(7,5,54),(7,6,60),(7,16,58),(100,2,61),(100,179,59)] {
                XCTAssertEqual(try color(bitmap,x:x*scale,y:y*scale),UInt32(slot)*0x010101,"native view pixel \(x),\(y) at \(scale)x")
            }
        }
    }
    @MainActor func testInactiveChromeAcceptsTheActivatingMouseDown() throws {
        _ = NSApplication.shared
        let old = ClassicStyle.shared.appearance
        ClassicStyle.shared.appearance = .recovery
        defer { ClassicStyle.shared.appearance = old }
        let chrome = ClassicChrome()
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:240),styleMask:.borderless,backing:.buffered,defer:true)
        window.isReleasedWhenClosed = false; window.contentView = chrome
        defer { window.contentView = nil; window.close() }
        chrome.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible); XCTAssertFalse(window.isKeyWindow)
        let grip = HAPWindowDrawing.resizeHitRect(in:chrome.bounds,active:false)
        for point in [NSPoint(x:200,y:10),NSPoint(x:grip.midX,y:grip.midY)] {
            let hit = try XCTUnwrap(chrome.hitTest(chrome.convert(point,to:chrome.superview)))
            let event = try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:chrome.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1))
            XCTAssertTrue(hit.acceptsFirstMouse(for:event),"The first press must reach title dragging / resizing")
        }
        XCTAssertFalse(window.isVisible)
    }

}
