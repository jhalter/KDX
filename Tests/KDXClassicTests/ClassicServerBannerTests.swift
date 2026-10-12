import AppKit
import XCTest
@testable import KDXClassicUI
@testable import KDXCore

final class ClassicServerBannerTests: XCTestCase {
    /// Explicit wire fixture with nonzero padding to catch accidental indexing.
    private func packet(width: Int = 7, height: Int = 3, depth: Int = 4, count: Int = 3, seed: UInt8 = 0) -> [UInt8] {
        var bytes: [UInt8] = [1,UInt8(width),UInt8(height),UInt8(depth),0xa5,UInt8(count-1)]
        for color in 0..<count { bytes += [UInt8(color) &+ seed,UInt8(255-color),UInt8(color/2)] }
        while bytes.count%4 != 0 { bytes.append(0xee) }
        let rowBytes = ((width*depth+31)/32)*4
        for y in 0..<height {
            var row = [UInt8](repeating:0xff,count:rowBytes)
            for x in 0..<width {
                let value = UInt8((x+y)%min(count,1<<depth))
                if depth == 8 { row[x] = value }
                else if x%2 == 0 { row[x/2] = (row[x/2]&15) | value<<4 }
                else { row[x/2] = (row[x/2]&0xf0) | value }
            }
            bytes += row
        }
        return bytes
    }
    func testBothDepthsPaletteAlignmentAndRowPadding() throws {
        for depth in [4,8] { for count in [1,2,3,4,16,17,256] { for width in [1,7,8,9,152,255] {
            let bytes = packet(width:width,depth:depth,count:count)
            let image = try ClassicServerBannerDecoder.decode(bytes)
            XCTAssertEqual(image.width,width); XCTAssertEqual(image.height,3)
            XCTAssertEqual(image.rgba.count,width*3*4)
            for y in 0..<3 { for x in 0..<width {
                let index = UInt8((x+y)%min(count,1<<depth)), at = (y*width+x)*4
                XCTAssertEqual(Array(image.rgba[at..<at+4]),[index,255-index,index/2,255])
            } }
            // As in 0x36090, reserved byte/padding/trailing data have no drawing meaning.
            XCTAssertEqual(try ClassicServerBannerDecoder.decode(bytes+[1,2,3,4]),image)
        } } }
        let largest = try ClassicServerBannerDecoder.decode(packet(width:255,height:255,depth:8,count:256))
        XCTAssertEqual(largest.rgba.count,255*255*4)
    }
    func testUnsupportedMalformedAndTruncatedPayloads() throws {
        let bytes = packet()
        for length in 0..<bytes.count {
            XCTAssertThrowsError(try ClassicServerBannerDecoder.decode(Array(bytes.prefix(length))),"length \(length)")
        }
        for (offset,value) in [(0,0),(0,2),(1,0),(2,0),(3,1),(3,2),(3,16),(3,255)] {
            var bad = bytes; bad[offset] = UInt8(value)
            XCTAssertThrowsError(try ClassicServerBannerDecoder.decode(bad))
        }
        for depth in [4,8] {
            var bad = packet(depth:depth)
            let pixelAt = 16 // three RGB entries plus six-byte header, rounded to four
            bad[pixelAt] = depth == 4 ? 0x30 : 3
            XCTAssertThrowsError(try ClassicServerBannerDecoder.decode(bad))
        }
    }
    func testBadReplacementPreservesLastValidBannerUntilDisconnect() throws {
        var first = ClassicServerBannerState(), second = ClassicServerBannerState()
        let a = packet(), b = packet(seed:60)
        let expectedA = try ClassicServerBannerDecoder.decode(a), expectedB = try ClassicServerBannerDecoder.decode(b)
        XCTAssertNil(first.update([],connected:true))
        XCTAssertEqual(first.update(a,connected:true),expectedA)
        XCTAssertEqual(second.update(b,connected:true),expectedB)
        for invalid in [[],[1,2,3],Array(a.dropLast())] {
            XCTAssertEqual(first.update(invalid,connected:true),expectedA)
            XCTAssertEqual(second.update(invalid,connected:true),expectedB)
        }
        XCTAssertNil(first.update(a,connected:false))
        XCTAssertNil(first.update([],connected:true))
        XCTAssertEqual(first.update(b,connected:true),expectedB)
        XCTAssertEqual(second.update(a,connected:true),expectedA)
    }
    @MainActor func testServerBannerCentersWithoutScalingAndSurvivesThemeChanges() throws {
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        let image = try ClassicServerBannerDecoder.decode(packet())
        var themes = [ClassicAppearance.recovery]
        if let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] {
            themes += try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances.filter { ["Mach Lavender","Amber CRT"].contains($0.name) }
        }
        style.configureAssets(themes)
        for compact in [false,true] {
            let picker = ClassicPopUpButton("Connection"), status = classicLabel("Connected")
            picker.addItem(withTitle:"Test peer")
            let buttons = ClassicBarAction.allCases.map { action in ClassicButton(action.title,height:action.rect(compact:compact).height) {} }
            let view = ClassicButtonBarView(compact:compact,picker:picker,status:status,buttons:buttons)
            view.updateBanner(image)
            for theme in themes {
                style.appearance = theme; view.applyStyle(); view.layoutSubtreeIfNeeded()
                XCTAssertEqual(picker.banner,image); XCTAssertTrue(status.isHidden)
                XCTAssertEqual(view.convert(picker.bounds,from:picker),NSRect(x:0,y:0,width:152,height:40))
                for enabled in [true,false] { for scale in [1,2] {
                    picker.isEnabled = enabled
                    let rendered = try helper.render(scale:scale,width:152,height:40) {
                        NSColor.magenta.setFill(); NSRect(x:0,y:0,width:152,height:40).fill()
                        picker.cell?.draw(withFrame:NSRect(x:0,y:0,width:152,height:40),in:picker)
                    }
                    // 7×3 within 152×40: signed integer centering gives (72,18).
                    for y in 0..<40 { for x in 0..<152 {
                        var rgb: UInt32 = 0xff00ff
                        if (72..<79).contains(x) && (18..<21).contains(y) {
                            let index = UInt32((x-72+y-18)%3)
                            rgb = index<<16 | (255-index)<<8 | index/2
                        }
                        for sy in 0..<scale { for sx in 0..<scale {
                            XCTAssertEqual(try helper.color(rendered,x:x*scale+sx,y:y*scale+sy),rgb)
                        } }
                    } }
                } }
            }
            view.updateBanner(nil); view.layoutSubtreeIfNeeded()
            XCTAssertEqual(picker.banner,try style.chromeArtwork?.banner?.bitmap())
        }
    }
    @MainActor func testPacketDeliveryAndBackgroundSessionsStayIsolated() async throws {
        _ = NSApplication.shared
        let table = ChallengeTable(testBytes:[UInt8](repeating:7,count:1739))
        var firstConfig = ServerConfiguration(), secondConfig = ServerConfiguration()
        firstConfig.name = "First peer"; firstConfig.settingsBlob = try RemoteServerSettings(name:firstConfig.name,icon:packet()).encode()
        secondConfig.name = "Second peer"; secondConfig.settingsBlob = try RemoteServerSettings(name:secondConfig.name,icon:packet(seed:60)).encode()
        let firstServer = KDXServer(configuration:firstConfig), secondServer = KDXServer(configuration:secondConfig)
        let first = ClassicSession(endpoint:ClassicEndpoint()), second = ClassicSession(endpoint:ClassicEndpoint())
        defer { first.disconnect(); second.disconnect(); firstServer.stop(); secondServer.stop() }
        var serverWires = [WireConnection]()
        for (session,server) in [(first,firstServer),(second,secondServer)] {
            let (clientWire,serverWire) = ClassicMemoryTransport.pair(); serverWires.append(serverWire)
            server.accept(wire:serverWire,table:table)
            try await session.client.connect(wire:clientWire,login:"",password:"",nickname:"Test",table:table)
        }
        let a = try ClassicServerBannerDecoder.decode(packet()), b = try ClassicServerBannerDecoder.decode(packet(seed:60))
        let app = ClassicApplication(); app.sessions = [first.id:first,second.id:second]; app.selectedSession = first.id
        app.refreshBar()
        XCTAssertEqual(first.serverBanner,a); XCTAssertEqual(second.serverBanner,b)
        try await serverWires[1].send(type:106,payload:[1,2,3])
        _ = try await second.client.request(type:115) // ordering barrier for the receive loop
        app.refreshBar(); app.selectedSession = second.id; app.refreshBar()
        XCTAssertEqual(second.serverBanner,b,"Malformed background updates retain that session's valid image.")
        XCTAssertEqual(first.serverBanner,a)
        let replacement = packet(seed:120)
        try await serverWires[0].send(type:106,payload:replacement)
        _ = try await first.client.request(type:115)
        app.refreshBar()
        XCTAssertEqual(first.serverBanner,try ClassicServerBannerDecoder.decode(replacement))
        XCTAssertEqual(second.serverBanner,b); XCTAssertEqual(app.selectedSession,second.id)
        second.disconnect(); app.refreshBar(); XCTAssertNil(second.serverBanner)
        var noBanner = ServerConfiguration(); noBanner.name = "Replacement peer"
        let replacementServer = KDXServer(configuration:noBanner)
        defer { replacementServer.stop() }
        let (clientWire,serverWire) = ClassicMemoryTransport.pair(); replacementServer.accept(wire:serverWire,table:table)
        try await second.client.connect(wire:clientWire,login:"",password:"",nickname:"Test",table:table)
        app.refreshBar(); XCTAssertNil(second.serverBanner,"Reconnect cannot revive the previous peer's image.")
        XCTAssertTrue(app.windows.isEmpty); XCTAssertTrue(app.utilityWindows.isEmpty)
    }
}

/// In-memory transport: these interoperability checks never open a socket or a window.
@MainActor final class ClassicMemoryTransport: ByteTransport {
    let peerHost = "127.0.0.1", endpointDescription = "memory:banner-test"
    weak var peer: ClassicMemoryTransport?
    private var buffer = [UInt8]()
    private var pending: (Int,CheckedContinuation<[UInt8],Error>)?
    private var closed = false
    static func pair() -> (WireConnection,WireConnection) {
        let first = ClassicMemoryTransport(), second = ClassicMemoryTransport()
        first.peer = second; second.peer = first
        return (WireConnection(transport:first),WireConnection(transport:second))
    }
    func start() async throws {}
    func read(_ count: Int) async throws -> [UInt8] {
        guard !closed else { throw KDXError.disconnected }
        if buffer.count >= count { let result = Array(buffer.prefix(count)); buffer.removeFirst(count); return result }
        precondition(pending == nil)
        return try await withCheckedThrowingContinuation { pending = (count,$0) }
    }
    func write(_ bytes: [UInt8]) async throws {
        guard !closed, let peer, !peer.closed else { throw KDXError.disconnected }
        peer.buffer += bytes
        if let (count,waiter) = peer.pending, peer.buffer.count >= count {
            let result = Array(peer.buffer.prefix(count)); peer.buffer.removeFirst(count)
            peer.pending = nil; waiter.resume(returning:result)
        }
    }
    func close() {
        guard !closed else { return }; closed = true
        pending?.1.resume(throwing:KDXError.disconnected); pending = nil; peer?.close()
    }
}
