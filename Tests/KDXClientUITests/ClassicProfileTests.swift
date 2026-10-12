import AppKit
import XCTest
import ImageIO
@testable import KDXClientUI
@testable import KDXCore

final class ClassicProfileTests: XCTestCase {
    func testIndexedEncodingAndQuantizationBounds() throws {
        for count in [1,16,17,256,1024] {
            let pixels = (0..<1024).flatMap { index -> [UInt8] in
                let value = index % count
                return [UInt8(value & 255),UInt8(value >> 8),UInt8((value*7)&255),255]
            }
            let encoded = try ClassicProfileImage.encode(rgba:pixels)
            let icon = try XCTUnwrap(ClassicUserIcon(encoded))
            XCTAssertLessThanOrEqual(encoded.count,0x708)
            XCTAssertEqual(encoded[0],count <= 16 ? 1 : 3)
            let decoded = Array(icon.bitmap(small:false).rgba)
            if count <= 256 { XCTAssertEqual(decoded,pixels) }
            else {
                for offset in stride(from:0,to:4096,by:4) {
                    XCTAssertLessThanOrEqual(abs(Int(decoded[offset])-Int(pixels[offset])),36)
                    XCTAssertLessThanOrEqual(abs(Int(decoded[offset+1])-Int(pixels[offset+1])),36)
                    XCTAssertLessThanOrEqual(abs(Int(decoded[offset+2])-Int(pixels[offset+2])),84)
                    XCTAssertEqual(decoded[offset+3],255)
                }
            }
        }
        XCTAssertThrowsError(try ClassicProfileImage.encode(rgba:[]))
        XCTAssertThrowsError(try ClassicProfileImage.encode(rgba:[UInt8](repeating:0,count:4097)))
    }

    @MainActor func testImageOrientationTransparencyAndFailedImport() throws {
        // Top red, bottom blue: catches a vertical flip hidden by symmetric icons.
        let pixels = (0..<1024).flatMap { $0 < 512 ? [UInt8](arrayLiteral:255,0,0,255) : [UInt8](arrayLiteral:0,0,255,255) }
        let original = try ClassicProfileImage.encode(rgba:pixels)
        let png = try XCTUnwrap(ClassicProfileImage.png(original))
        let decoded = try ClassicProfileImage.decode(png,background:0x123456)
        XCTAssertEqual(Array(try XCTUnwrap(ClassicUserIcon(decoded)).bitmap(small:false).rgba),pixels)
        let transparent = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:32,pixelsHigh:16,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:128,bitsPerPixel:32))
        try XCTUnwrap(transparent.bitmapData).initialize(repeating:0,count:2048)
        let flattened = try ClassicProfileImage.decode(XCTUnwrap(transparent.representation(using:.png,properties:[:])),background:0x123456)
        XCTAssertEqual(Array(try XCTUnwrap(ClassicUserIcon(flattened)).bitmap(small:false).rgba),Array(repeating:[UInt8](arrayLiteral:0x12,0x34,0x56,255),count:1024).flatMap { $0 })
        var user = KDXUser(nickname:"Alice"); user.icon = original
        let form = ClassicProfileForm(user:user), before = form.draft
        XCTAssertThrowsError(try form.setIcon([1,0,255]))
        for invalid in [Data(),Data([1,2,3]),Data(repeating:0,count:ClassicProfileImage.maximumBytes+1)] {
            XCTAssertThrowsError(try form.setIcon(ClassicProfileImage.decode(invalid,background:0)))
        }
        XCTAssertEqual(form.draft,before)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        XCTAssertThrowsError(try ClassicProfileImage.load(root,background:0))
        let file = root.appendingPathComponent("icon.png"); try png.write(to:file)
        XCTAssertEqual(try ClassicProfileImage.load(file,background:0),decoded)
    }

    @MainActor func testOversizedAnimatedAndLetterboxedImages() throws {
        func bitmap(_ width: Int, _ height: Int) throws -> NSBitmapImageRep {
            let result = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:width*4,bitsPerPixel:32))
            try XCTUnwrap(result.bitmapData).initialize(repeating:255,count:width*height*4)
            return result
        }
        let wide = try bitmap(32,16)
        let png = try XCTUnwrap(wide.representation(using:.png,properties:[:]))
        let icon = try XCTUnwrap(ClassicUserIcon(ClassicProfileImage.decode(png,background:0)))
        let rgba = Array(icon.bitmap(small:false).rgba)
        for y in 0..<32 { for x in 0..<32 {
            let offset = (y*32+x)*4
            XCTAssertEqual(rgba[offset],(8..<24).contains(y) ? 255 : 0)
            XCTAssertEqual(rgba[offset+3],255)
        } }
        let tooWide = try bitmap(4097,1)
        XCTAssertThrowsError(try ClassicProfileImage.decode(XCTUnwrap(tooWide.representation(using:.png,properties:[:])),background:0))
        let animated = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(animated,"com.compuserve.gif" as CFString,2,nil))
        let image = try XCTUnwrap(wide.cgImage)
        CGImageDestinationAddImage(destination,image,nil); CGImageDestinationAddImage(destination,image,nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertThrowsError(try ClassicProfileImage.decode(animated as Data,background:0))
    }

    @MainActor func testDraftColorAndPreviewState() throws {
        var user = KDXUser(nickname:"Alice",info:"Description"); user.colors = [0x12,0x34,0x56,0xde,0xad,0xbe]
        let form = ClassicProfileForm(user:user)
        XCTAssertEqual(form.foreground.rgb,0x123456); XCTAssertEqual(form.background.rgb,0xdeadbe)
        form.setColor(0xabcdef,background:false)
        XCTAssertEqual(form.draft.colors,[0xab,0xcd,0xef,0xde,0xad,0xbe])
        form.gradient.state = .on; form.name.stringValue = "Renamed"; form.updatePreview()
        XCTAssertEqual(form.preview.profile.nickname,"Renamed"); XCTAssertEqual(form.preview.profile.flags,4)
        XCTAssertEqual(form.preview.profile.colors,form.draft.colors)
        form.appearanceColors.performClick(nil)
        XCTAssertTrue(form.draft.usesAppearanceColors)
        form.setColor(0xabcdef,background:true)
        XCTAssertEqual(form.draft.color(false),HAPUserRowDrawing.rgb(ClassicStyle.shared.color(16)))
        XCTAssertEqual(form.draft.color(true),0xabcdef)
        form.load(user); XCTAssertEqual(form.draft,ClassicProfileDraft(user))
        form.setEditable(false)
        XCTAssertFalse(form.name.isEnabled); XCTAssertFalse(form.info.isEditable); XCTAssertFalse(form.icon.isEnabled)
        var pasted = false; form.icon.pasteIcon = { pasted = true }; form.icon.paste(nil)
        XCTAssertFalse(pasted,"Disabled icon cannot mutate the draft through its contextual action.")
    }

    @MainActor func testIdentityPanelGeometryFromOriginalResource() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Original application required") }
        let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
        let form = ClassicProfileForm(user:KDXUser(nickname:"Alice")); form.layoutSubtreeIfNeeded()
        let base = 0xd7a30+0x10578
        for (view,offset,paneY) in [(form.save as NSView,0xd0,0),(form.apply,0x108,0),(form.cancel,0x144,0),
            (form.name,0x218,40),(form.infoFrame,0x280,40),(form.foreground,0x310,40),(form.background,0x380,40),(form.icon,0x3e4,40)] {
            let p = try (0..<4).map { Int(try bytes.u16(base+offset+4+$0*2)) }
            XCTAssertEqual(view.frame,NSRect(x:p[0],y:p[1]+paneY,width:p[2]-p[0],height:p[3]-p[1]))
        }
        for view in form.subviews { XCTAssertTrue(form.bounds.contains(view.frame)) }
    }

    @MainActor func testProfileApplyStaysWithItsSessionAndHonorsServerPolicy() async throws {
        let table = ChallengeTable(testBytes:[UInt8](repeating:7,count:1739))
        var account = ServerAccount(login:"member",password:"pw"); account.name = "Account Name"
        account.privilegeMask.set(60,true); account.privileges.set(60,false)
        var config = ServerConfiguration(); config.accounts = [account]
        let first = ClassicSession(endpoint:ClassicEndpoint()), second = ClassicSession(endpoint:ClassicEndpoint())
        let servers = [KDXServer(configuration:config),KDXServer(configuration:config)]
        defer { first.disconnect(); second.disconnect(); servers.forEach { $0.stop() } }
        for (session,server) in zip([first,second],servers) {
            let (a,b) = ClassicMemoryTransport.pair(); server.accept(wire:b,table:table)
            try await session.client.connect(wire:a,login:"member",password:"pw",nickname:"Original",table:table)
        }
        let suite = "KDX-profile-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite)); defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults)
        let controller = ClassicProfileWindow(session:first,user:try XCTUnwrap(first.client.currentUser),preferences:preferences)
        defer { controller.observation.stop() }
        controller.form.name.stringValue = "Forbidden name"; controller.form.info.string = "Updated description"
        controller.form.setColor(0x123456,background:false); controller.form.setColor(0xabcdef,background:true)
        controller.form.gradient.state = .on
        let icon = try ClassicProfileImage.encode(rgba:[UInt8](repeating:255,count:4096)); try controller.form.setIcon(icon)
        let applied = try await controller.applyProfile(); XCTAssertTrue(applied)
        XCTAssertEqual(first.client.currentUser?.nickname,"Account Name")
        XCTAssertEqual(controller.form.name.stringValue,"Account Name","Show the server's accepted identity after Apply.")
        XCTAssertEqual(first.client.currentUser?.colors,[0x12,0x34,0x56,0xab,0xcd,0xef]); XCTAssertEqual(first.client.currentUser?.icon,icon)
        XCTAssertEqual(first.client.currentUser?.flags,4); XCTAssertEqual(first.client.currentUser?.info,"Updated description")
        XCTAssertEqual(second.client.currentUser?.colors,[0,0,0,0,0,0]); XCTAssertEqual(second.client.currentUser?.icon,[])
        controller.form.name.stringValue = ""; let invalid = controller.form.draft
        do { _ = try await controller.applyProfile(); XCTFail("Empty nickname should fail") } catch {}
        XCTAssertEqual(controller.form.draft,invalid); XCTAssertFalse(controller.isApplying)
        controller.form.name.stringValue = "Unsaved"; controller.requestClose()
        XCTAssertEqual(first.client.currentUser?.nickname,"Account Name"); XCTAssertTrue(first.client.isConnected)
        first.privateMessages.reset(); controller.refresh()
        XCTAssertFalse(controller.form.save.isEnabled); XCTAssertFalse(controller.form.name.isEnabled)
        do { _ = try await controller.applyProfile(); XCTFail("Stale connection should fail") } catch {}
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
    }

    @MainActor func testClosingPendingApplyFinishesFrameWithoutDiscardingNewerDraft() async throws {
        let table = ChallengeTable(testBytes:[UInt8](repeating:7,count:1739))
        let session = ClassicSession(endpoint:ClassicEndpoint()), server = KDXServer(configuration:ServerConfiguration())
        defer { session.disconnect(); server.stop() }
        let first = ClassicMemoryTransport(), second = ClassicMemoryTransport(); first.peer = second; second.peer = first
        let gate = ProfileWriteGate(first)
        server.accept(wire:WireConnection(transport:second),table:table)
        try await session.client.connect(wire:WireConnection(transport:gate),login:"",password:"",nickname:"Original",table:table)
        let suite = "KDX-profile-tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite)); defer { defaults.removePersistentDomain(forName:suite) }
        let controller = ClassicProfileWindow(session:session,user:try XCTUnwrap(session.client.currentUser),preferences:ClassicPreferences(root:FileManager.default.temporaryDirectory,defaults:defaults))
        defer { controller.observation.stop() }
        controller.chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.form.bounds.size,ClassicProfileForm.referenceSize)
        XCTAssertFalse(controller.chrome.allowsResize)
        controller.form.name.stringValue = "Submitted"; gate.holdNext = true
        let operation = Task { @MainActor in try await controller.applyProfile() }
        for _ in 0..<100 where !gate.waiting { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertTrue(gate.waiting); XCTAssertFalse(controller.form.name.isEnabled)
        // A programmatic draft update during an outstanding request must survive.
        controller.form.name.stringValue = "Newer draft"
        gate.release()
        let shouldClose = try await operation.value
        XCTAssertFalse(shouldClose); XCTAssertEqual(controller.form.name.stringValue,"Newer draft")
        XCTAssertEqual(session.client.currentUser?.nickname,"Submitted")
        controller.form.name.stringValue = "Applied while closing"; gate.holdNext = true
        controller.submit(close:false)
        for _ in 0..<100 where !gate.waiting { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertTrue(gate.waiting); controller.requestClose(); gate.release()
        for _ in 0..<100 where controller.isApplying { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertFalse(controller.isApplying); XCTAssertTrue(session.client.isConnected)
        XCTAssertEqual(session.client.currentUser?.nickname,"Applied while closing")
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
    }

    @MainActor func testOffscreenProfileAndStandalonePreviewForeground() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_REFERENCE"] else { throw XCTSkip("Original application required") }
        let themes = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances
        let style = ClassicStyle.shared; style.configureAssets(themes)
        defer { style.appearance = .recovery; style.configureAssets([]) }
        for theme in themes.filter({ ["Mach Lavender","Amber CRT"].contains($0.name) }) {
            style.appearance = theme
            var user = KDXUser(nickname:"Alice",info:"A KDX user"); user.colors = [0x90,0x20,0x30,0xe0,0xd0,0xff]
            user.icon = try ClassicProfileImage.encode(rgba:[UInt8](repeating:255,count:4096))
            let form = ClassicProfileForm(user:user), chrome = ClassicChrome()
            chrome.title = "My Profile"; chrome.allowsResize = false; chrome.frame = NSRect(x:0,y:0,width:462,height:358)
            chrome.layoutSubtreeIfNeeded(); form.frame = chrome.content.bounds; chrome.content.addSubview(form)
            form.layoutSubtreeIfNeeded(); chrome.layoutSubtreeIfNeeded()
            XCTAssertEqual(form.bounds.size,ClassicProfileForm.referenceSize)
            for scale in [1,2] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:462*scale,pixelsHigh:358*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                bitmap.size = chrome.bounds.size; chrome.cacheDisplay(in:chrome.bounds,to:bitmap)
                let cell = try XCTUnwrap(form.preview.subviews.first as? ClassicUserCell)
                XCTAssertEqual(HAPUserRowDrawing.rgb(try XCTUnwrap(cell.text.textColor)),0x902030)
                if let folder = ProcessInfo.processInfo.environment["KDX_RENDER_DIR"] {
                    let root = URL(fileURLWithPath:folder,isDirectory:true); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("\(theme.name)-profile-\(scale)x.png"))
                }
            }
        }
    }
}

@MainActor private final class ProfileWriteGate: ByteTransport {
    let base: ClassicMemoryTransport
    var holdNext = false
    private(set) var waiting = false
    private var waiter: CheckedContinuation<Void,Error>?
    var peerHost: String { base.peerHost }
    var endpointDescription: String { base.endpointDescription }
    init(_ base: ClassicMemoryTransport) { self.base = base }
    func start() async throws { try await base.start() }
    func read(_ count: Int) async throws -> [UInt8] { try await base.read(count) }
    func write(_ bytes: [UInt8]) async throws {
        if holdNext { holdNext = false; waiting = true; try await withCheckedThrowingContinuation { waiter = $0 } }
        try Task.checkCancellation(); try await base.write(bytes)
    }
    func release() { let pending = waiter; waiter = nil; waiting = false; pending?.resume() }
    func close() { let pending = waiter; waiter = nil; waiting = false; pending?.resume(throwing:KDXError.disconnected); base.close() }
}
