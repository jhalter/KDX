import AppKit
import XCTest
@testable import KDXClassicUI

final class HAPProfileControlTests: XCTestCase {
    @MainActor func testColorWellPaletteEdgesPressedRingAndDisabledState() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        style.appearance = ClassicAppearance(id:"profile-controls",name:"Profile controls",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test")
        let rect = NSRect(x:0,y:0,width:40,height:20)
        for scale in [1,2] { for enabled in [false,true] { for pressed in [false,true] { for focused in [false,true] {
            let bitmap = try helper.render(scale:scale,width:40,height:20) {
                HAPProfileDrawing.colorWell(rect,rgb:0x123456,pressed:pressed,focused:focused,enabled:enabled)
            }
            for y in 0..<20 { for x in 0..<40 {
                let distance = min(x,39-x,y,19-y)
                let expected: UInt32
                switch distance {
                case 0:
                    if (y == 0 && x < 39) || (x == 0 && y < 19) { expected = 0x030303 }
                    else if (y == 19 && x > 0) || (x == 39 && y > 0) { expected = 0x010101 }
                    else { expected = 0x020202 }
                case 1: expected = enabled ? 0x040404 : 0x060606
                case 2: expected = pressed && enabled ? 0 : 0xffffff
                case 3: expected = 0xffffff
                default: expected = 0x123456
                }
                for dy in 0..<scale { for dx in 0..<scale {
                    XCTAssertEqual(try helper.color(bitmap,x:x*scale+dx,y:y*scale+dy),expected,"\(x),\(y); enabled=\(enabled), pressed=\(pressed), focused=\(focused)")
                } }
            } }
        } } } }
    }

    @MainActor func testFieldSkinOverridesAndMissingVariantFallback() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for scale in [1,2] { for (pressed,focused,enabled,id) in [(false,false,true,85),(true,false,true,86),(false,true,true,86),(true,true,false,87)] {
            style.appearance = ClassicAppearance(id:"profile-skins",name:"Profile skins",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test")
            var bytes = [UInt8](HAPArtworkTests().skinSection())
            bytes.replaceSubrange((64+id*4)..<(68+id*4),with:bytes[100..<104])
            style.appearance.artwork = try HAPArtwork(skins:Data(bytes),icons:Data())
            let rect = NSRect(x:0,y:0,width:40,height:20)
            let bitmap = try helper.render(scale:scale,width:40,height:20) {
                HAPProfileDrawing.colorWell(rect,rgb:0xabcdef,pressed:pressed,focused:focused,enabled:enabled)
            }
            for (x,y,color) in [(0,0,UInt32(0xff0000)),(20,0,0x00ff00),(1,1,0x0000ff),(20,2,pressed && enabled ? 0 : 0xffffff),(20,3,0xffffff),(20,4,0xabcdef)] {
                XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),color)
            }
            if id == 86 {
                bytes.replaceSubrange((64+85*4)..<(68+85*4),with:bytes[100..<104])
                bytes.replaceSubrange((64+86*4)..<(68+86*4),with:[0,0,0,0])
                style.appearance.artwork = try HAPArtwork(skins:Data(bytes),icons:Data())
                let fallback = try helper.render(scale:scale,width:40,height:20) {
                    HAPProfileDrawing.colorWell(rect,rgb:0xabcdef,pressed:pressed,focused:focused,enabled:enabled)
                }
                XCTAssertEqual(try helper.color(fallback,x:20*scale,y:0),0x030303,"Absent focused skin uses compact palette drawing, not normal skin or text-field focus ring.")
            }
        } }
    }

    @MainActor func testIconCanvasIsWhiteAndCenteredInAllStates() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        style.appearance = ClassicAppearance(id:"icon-well",name:"Icon well",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test")
        let bytes: [UInt8] = [1,0,0x12,0x34,0x56]+[UInt8](repeating:0,count:512)
        for scale in [1,2] { for enabled in [false,true] { for focused in [false,true] { for icon in [[],bytes] {
            let bitmap = try helper.render(scale:scale,width:42,height:42) {
                HAPProfileDrawing.iconWell(NSRect(x:0,y:0,width:42,height:42),bytes:icon,focused:focused,enabled:enabled)
            }
            for y in 3..<39 { for x in 3..<39 {
                let expected: UInt32 = !icon.isEmpty && (5..<37).contains(x) && (5..<37).contains(y) ? 0x123456 : 0xffffff
                XCTAssertEqual(try helper.color(bitmap,x:x*scale,y:y*scale),expected)
            } }
            XCTAssertEqual(try helper.color(bitmap,x:20*scale,y:2*scale),enabled ? 0x040404 : 0x060606)
        } } } }
    }

    @MainActor func testNativeWellsUseRendererAndSuppressDisabledActions() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests(), raster = HAPTextFieldTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        style.appearance = ClassicAppearance(id:"native-wells",name:"Native wells",colors:(0..<221).map { UInt32($0)*0x010101 },source:"test")
        let well = ClassicProfileColorWell("Foreground color"); well.frame = NSRect(x:0,y:0,width:40,height:20); well.rgb = 0x123456
        var actions = 0; well.invoke = { actions += 1 }
        well.performClick(nil); XCTAssertEqual(actions,1)
        for enabled in [false,true] { for pressed in [false,true] { for scale in [1,2] {
            well.isEnabled = enabled; well.highlight(pressed)
            let bitmap = try raster.raster(well,scale:scale)
            XCTAssertEqual(try helper.color(bitmap,x:20*scale,y:2*scale),pressed && enabled ? 0 : 0xffffff)
            XCTAssertEqual(try helper.color(bitmap,x:20*scale,y:4*scale),0x123456)
        } } }
        well.isEnabled = false; well.performClick(nil); XCTAssertEqual(actions,1)
        XCTAssertEqual(well.accessibilityLabel(),"Foreground color"); XCTAssertEqual(well.accessibilityValue() as? String,"#123456")
        let icon = ClassicProfileIconWell(); icon.frame = NSRect(x:0,y:0,width:42,height:42)
        icon.highlight(true)
        let bitmap = try raster.raster(icon,scale:2)
        XCTAssertEqual(try helper.color(bitmap,x:40,y:2),0x030303,"Mouse-down alone must not substitute the focused field border.")
        XCTAssertEqual(try helper.color(bitmap,x:40,y:40),0xffffff)
    }

    func testOriginalDrawingInstructions() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Original application required") }
        let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
        // KOLR calls the common field frame with flag 0x40, uses literal white,
        // then insets twice by two and overlays black only on bit-0 press.
        for (address,opcode) in [(0xa5504,0x601f0040),(0xa550c,0x4bff04a5),(0xa5514,0x3c800100),
            (0xa5524,0x3884ffff),(0xa5520,0x38e50002),(0xa5564,0x38a00002),(0xa557c,0x38040002),
            (0xa55b4,0x57e007ff),(0xa55c4,0x38800000),(0xa560c,0x38a00001),
            (0x95a00,0x72a00042),(0x95af4,0x56a00673),(0x9c73c,0x38000056),
            (0x91448,0x48004569),(0xaca78,0x3c800100),(0xaca80,0x3884ffff),(0xacaf4,0x4bfb256d)] {
            XCTAssertEqual(try bytes.u32(address+0x1de0),opcode,"PPC \(String(address,radix:16))")
        }
    }
}
