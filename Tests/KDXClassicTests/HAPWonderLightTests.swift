import AppKit
import XCTest
@testable import KDXClassicUI
@testable import KDXCore

final class HAPWonderLightTests: XCTestCase {
    func testBoundedArtworkAndCatalogRecovery() throws {
        let palette = Data(repeating:0,count:64), pixels = Data(repeating:0x12,count:128)
        let valid = try HAPWonderLightArtwork(palette:palette,pixels:pixels)
        for count in [0,63,65] { XCTAssertThrowsError(try HAPWonderLightArtwork(palette:Data(repeating:0,count:count),pixels:pixels)) }
        for count in [0,127,129] { XCTAssertThrowsError(try HAPWonderLightArtwork(palette:palette,pixels:Data(repeating:0,count:count))) }
        var corrupt = palette; corrupt[4] = 1
        XCTAssertThrowsError(try HAPWonderLightArtwork(palette:corrupt,pixels:pixels))
        func chrome(_ light: HAPWonderLightArtwork?) throws -> HAPChromeArtwork {
            var object: [String:Any] = [:]
            for (name,length) in [("close",98),("menu",224),("maximize",98),("minimize",98),("resize",153)] {
                object[name] = Data(repeating:0,count:length).base64EncodedString()
            }
            if let light { object["wonderLight"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(light)) }
            return try JSONDecoder().decode(HAPChromeArtwork.self,from:JSONSerialization.data(withJSONObject:object))
        }
        let old = try chrome(nil); try old.validate(); XCTAssertNil(old.wonderLight)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let library = AppearanceLibrary(root:root)
        var theme = ClassicAppearance(id:"light-test",name:"Light",colors:[UInt32](repeating:0,count:204),source:"test")
        theme.chromeArtwork = try chrome(valid)
        try library.install(AppearanceImport(appearances:[theme],assets:[:]))
        XCTAssertEqual(library.load().last?.chromeArtwork?.wonderLight,valid)
        let bad = try JSONDecoder().decode(HAPWonderLightArtwork.self,from:JSONSerialization.data(withJSONObject:["palette":corrupt.base64EncodedString(),"pixels":pixels.base64EncodedString()]))
        theme.chromeArtwork = try chrome(bad)
        XCTAssertThrowsError(try library.install(AppearanceImport(appearances:[theme],assets:[:])))
        XCTAssertEqual(library.load().last?.chromeArtwork?.wonderLight,valid)
    }

    @MainActor func testNotificationAcknowledgementIsIndependentOfUnreadAndSessions() {
        let first = ClassicPrivateMessagesState(), second = ClassicPrivateMessagesState()
        let incoming = ChatLine(userID:1,sender:"Alice",text:"Hello",isPrivate:true)
        first.update([incoming],activeRecipient:nil)
        XCTAssertTrue(first.needsAttention); XCTAssertFalse(second.needsAttention)
        first.acknowledgeAttention()
        first.update([incoming],activeRecipient:nil)
        XCTAssertFalse(first.needsAttention,"A refresh must not re-alert for acknowledged messages.")
        XCTAssertEqual(first.unread,[1],"Opening Messages does not read every conversation.")
        let background = ChatLine(userID:2,sender:"Bob",text:"New",isPrivate:true)
        first.update([incoming,background],activeRecipient:1,windowIsFront:true)
        XCTAssertFalse(first.needsAttention,"Another recipient in the front window needs a red row, not a blinking bar.")
        XCTAssertEqual(first.unread,[2])
        let hidden = ChatLine(userID:1,sender:"Alice",text:"While hidden",isPrivate:true)
        first.update([incoming,background,hidden],activeRecipient:nil)
        XCTAssertTrue(first.needsAttention)
        first.select(1); XCTAssertTrue(first.needsAttention,"Recipient read state and bar attention have separate lifetimes.")
        let reply = ChatLine(userID:1,sender:"To Alice",text:"Reply",isPrivate:true,isOutgoing:true)
        first.update([incoming,background,hidden,reply],activeRecipient:nil)
        XCTAssertFalse(first.needsAttention); XCTAssertEqual(first.unread,[2])
        second.update([incoming],activeRecipient:nil)
        first.acknowledgeAttention(); XCTAssertTrue(second.needsAttention)
        second.reset(); XCTAssertFalse(second.needsAttention)
    }

    @MainActor func testBlinkStatesPreserveNativeActionAndAccessibleUnreadCount() {
        _ = NSApplication.shared
        let actions = ClassicBarAction.allCases
        var clicks = 0
        let buttons = actions.map { action in
            let button = ClassicButton(action.title,height:action.rect(compact:true).height) { if action == .messages { clicks += 1 } }
            button.iconID = action.iconID; return button
        }
        let bar = ClassicButtonBarView(compact:true,picker:ClassicPopUpButton("Connection"),status:classicLabel(""),buttons:buttons)
        let messages = buttons[actions.firstIndex(of:.messages)!]
        XCTAssertEqual(messages.wonderLight,.idle)
        bar.updateUnreadMessages(3); bar.updateMessageAlert(true)
        XCTAssertEqual(messages.title,"Messages"); XCTAssertTrue(messages.accessibilityLabel()?.contains("3 conversations") == true)
        XCTAssertEqual(bar.lightState,.red)
        bar.advanceLight(); XCTAssertEqual(messages.wonderLight,.amber)
        bar.updateMessageAlert(true); XCTAssertEqual(bar.lightState,.amber,"Ordinary observation refreshes must not restart the cycle.")
        bar.advanceLight(); XCTAssertEqual(messages.wonderLight,.red)
        messages.performClick(nil); XCTAssertEqual(clicks,1)
        bar.updateMessageAlert(false); bar.advanceLight(); XCTAssertEqual(messages.wonderLight,.idle)
        XCTAssertTrue(messages.toolTip?.contains("3 conversations") == true)
        bar.updateUnreadMessages(0); XCTAssertEqual(messages.accessibilityLabel(),"Messages")
        XCTAssertNil(bar.window,"The state tests never present a desktop window.")
    }

    @MainActor func testTimerRunsAttachedAndStopsWhenDetached() async throws {
        _ = NSApplication.shared
        let buttons = ClassicBarAction.allCases.map { ClassicButton($0.title,height:$0.rect(compact:true).height) {} }
        let bar = ClassicButtonBarView(compact:true,picker:ClassicPopUpButton("Connection"),status:classicLabel(""),buttons:buttons)
        let window = NSWindow(contentRect:bar.bounds,styleMask:.borderless,backing:.buffered,defer:true)
        window.isReleasedWhenClosed = false
        window.contentView = bar
        defer { window.contentView = nil }
        bar.updateMessageAlert(true)
        let deadline = ContinuousClock.now.advanced(by:.seconds(3))
        while bar.lightState == .red && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertEqual(bar.lightState,.amber)
        window.contentView = nil
        XCTAssertNil(bar.window)
        try await Task.sleep(for:.milliseconds(1100))
        XCTAssertEqual(bar.lightState,.amber,"A detached bar must not keep an animation task running.")
        XCTAssertFalse(window.isVisible,"This test creates a deferred window without presenting it.")
        bar.updateMessageAlert(false); XCTAssertEqual(bar.lightState,.idle)
    }

    @MainActor func testOriginalArtworkStatesAndBothBarLayoutsAtBothScales() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Provide the original application for WonderLight checks") }
        let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
        let source = try HAPWonderLightArtwork(reference:bytes)
        XCTAssertEqual(source.palette,try bytes.data(0x109400,64)); XCTAssertEqual(source.pixels,try bytes.data(0x109440,128))
        // Independent golden hashes from the original tint routine, including
        // highlight spill into the other channels and transparent index zero.
        let hashes = ["9a24a61106d93e0ef87d7d811d4ba64b9feb900a27838dc961428f9199cad0e7",
                      "d09d95ad4611c45f639a4aaf9a1d2b3c02a451bb2ac22c0f974b25d56fb1e04e",
                      "3ed47727a6929edffeafcf5488cfff97df395e716ee72312625a11b8b1a1df09"]
        for (state,hash) in zip(HAPWonderLightState.allCases,hashes) {
            XCTAssertEqual(AppearanceDecoder.digest(try source.bitmap(state).rgba),hash)
        }
        let themes = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery; style.configureAssets([]) }
        style.configureAssets(themes)
        let helper = HAPWindowTests()
        for theme in themes.filter({ ["Mach Lavender","Amber CRT"].contains($0.name) }) {
            style.appearance = theme
            XCTAssertEqual(theme.chromeArtwork?.wonderLight,source)
            for compact in [false,true] {
                let buttons = ClassicBarAction.allCases.map { action in
                    let button = ClassicButton(action.title,height:action.rect(compact:compact).height) {}
                    button.iconID = action.iconID; return button
                }
                let bar = ClassicButtonBarView(compact:compact,picker:ClassicPopUpButton("Connection"),status:classicLabel(""),buttons:buttons)
                bar.layoutSubtreeIfNeeded()
                let button = buttons[ClassicBarAction.allCases.firstIndex(of:.messages)!]
                let local = HAPWonderLightDrawing.rect(in:button.bounds)
                XCTAssertEqual(local,NSRect(x:compact ? 7 : 110,y:compact ? 7 : 3,width:16,height:16))
                let rect = bar.convert(local,from:button)
                for state in HAPWonderLightState.allCases {
                    button.wonderLight = state
                    let expected = [UInt8](try source.bitmap(state).rgba)
                    for scale in [1,2] {
                        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(bar.frame.width)*scale,pixelsHigh:Int(bar.frame.height)*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                        bitmap.size = bar.bounds.size; bar.cacheDisplay(in:bar.bounds,to:bitmap)
                        for y in 0..<16 { for x in 0..<16 {
                            let offset = (y*16+x)*4
                            guard expected[offset+3] != 0 else { continue }
                            let rgb = UInt32(expected[offset])<<16 | UInt32(expected[offset+1])<<8 | UInt32(expected[offset+2])
                            for sy in 0..<scale { for sx in 0..<scale {
                                XCTAssertEqual(try helper.color(bitmap,x:(Int(rect.minX)+x)*scale+sx,y:(Int(rect.minY)+y)*scale+sy),rgb)
                            } }
                        } }
                        if let folder = ProcessInfo.processInfo.environment["KDX_CLASSIC_RENDER_DIR"] {
                            let root = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("\(theme.name)-wonder-\(compact ? "compact" : "vertical")-\(state.rawValue)-\(scale)x.png"))
                        }
                    }
                }
            }
        }
    }
}
