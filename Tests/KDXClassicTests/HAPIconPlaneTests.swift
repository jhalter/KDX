import AppKit
import XCTest
@testable import KDXClassicUI

final class HAPIconPlaneTests: XCTestCase {
    private func atlas(mode: Int, depth: Int, width: Int = 17, height: Int = 3,
                       planeByte: UInt8 = 0, extraPalette: Bool = false) -> Data {
        let helper = HAPArtworkTests(), offset = 3072
        let count = extraPalette ? 5 : 2
        let planeStride = mode & 15 >= 2 ? ((width*(mode & 15)+31)/32)*4 : 0
        let colorStride = ((width*depth+31)/32)*4
        let pixels = offset+8+count*4+planeStride*height
        var bytes = [UInt8](repeating:0,count:pixels+colorStride*height)
        helper.put(offset,17*16,in:&bytes)
        bytes[offset] = UInt8(width>>8); bytes[offset+1] = UInt8(width&255)
        bytes[offset+2] = UInt8(height>>8); bytes[offset+3] = UInt8(height&255)
        bytes[offset+4] = UInt8(mode); bytes[offset+5] = UInt8(depth); bytes[offset+6] = UInt8(count-1)
        // The palette index byte is ignored outside keyed mode, even when out of range.
        bytes[offset+7] = mode & 15 == 1 ? 1 : 255
        for (i,rgb) in [0x123456,0xabcdef,0xff0000,0x00ff00,0x0000ff].prefix(count).enumerated() { helper.put(rgb,offset+8+i*4,in:&bytes) }
        for i in offset+8+count*4..<pixels { bytes[i] = planeByte }
        // Independent alternating rows cross packed-byte and padded-word boundaries.
        for y in 0..<height { for x in 0..<width {
            bytes[pixels+y*colorStride+x*depth/8] |= UInt8(((x+y)%2) << (8-depth-(x*depth)%8))
        } }
        return Data(bytes)
    }
    private func decode(_ data: Data) throws -> HAPBitmap {
        let decoded = try HAPArtwork(skins:Data(),icons:data).decode()
        return try XCTUnwrap(decoded.icon(17,small:true))
    }
    func testAuxiliaryPlanesAreSkippedForEveryColorDepthAndRowAlignment() throws {
        for mode in [2,4,8] { for depth in [1,2,4,8] { for width in [1,7,8,9,16,17,31,32,33] {
            let clear = try decode(atlas(mode:mode,depth:depth,width:width))
            let filled = try decode(atlas(mode:mode,depth:depth,width:width,planeByte:255))
            XCTAssertEqual(clear,filled,"Auxiliary samples are not alpha in the original icon renderer.")
            for y in 0..<3 { for x in 0..<width {
                let rgba: [UInt8] = (x+y)%2 == 0 ? [0x12,0x34,0x56,255] : [0xab,0xcd,0xef,255]
                let at = (y*width+x)*4
                XCTAssertEqual(Array(clear.rgba[at..<at+4]),rgba,"mode \(mode), depth \(depth), pixel \(x),\(y)")
            } }
        } } }
    }
    func testFlagsAndUnusedPaletteEntriesMatchTheReferenceReader() throws {
        for high in stride(from:0,through:0xf0,by:16) { for mode in [0,1,2,4,8] {
            let bitmap = try decode(atlas(mode:high|mode,depth:1,extraPalette:true))
            XCTAssertEqual(Array(bitmap.rgba.prefix(8)),[0x12,0x34,0x56,255,0xab,0xcd,0xef,mode == 1 ? 0 : 255])
        } }
        for mode in [3,5,6,7,9,15,0xf3] {
            var bytes = atlas(mode:0,depth:1); bytes[3076] = UInt8(mode)
            XCTAssertThrowsError(try decode(bytes))
        }
        var invalidKey = atlas(mode:1,depth:1); invalidKey[3079] = 2
        XCTAssertThrowsError(try decode(invalidKey))
    }
    func testTemplateAndControlPaletteRulesRemainIndependentOfAuxiliaryLayout() throws {
        let helper = HAPArtworkTests()
        for mode in [2,4,8] {
            var bytes = [UInt8](atlas(mode:mode,depth:1))
            helper.put(0xffffff,3080,in:&bytes); helper.put(0,3084,in:&bytes)
            let bitmap = try decode(Data(bytes))
            XCTAssertTrue(bitmap.monochromeIconTemplate)
            XCTAssertEqual(Array(bitmap.tintedIcon(tint:0xff0000,text:0x123456).rgba.prefix(8)),[0x12,0x34,0x56,0,0x12,0x34,0x56,255])
            bytes = [UInt8](atlas(mode:mode,depth:1,extraPalette:true))
            helper.put(0xffffff,3080,in:&bytes); helper.put(0,3084,in:&bytes)
            let ordinary = try decode(Data(bytes))
            XCTAssertFalse(ordinary.monochromeIconTemplate)
            XCTAssertEqual(Array(ordinary.tintedIcon(tint:nil,text:0x123456).rgba.prefix(8)),[255,255,255,255,0,0,0,255])
        }
        var control = [UInt8](helper.skinSection())
        control[2118] = 4
        control.insert(contentsOf:[0,0x22,0x33,0x44],at:2148)
        control[2116] = 0xf0
        let decoded = try HAPArtwork(skins:Data(control),icons:Data()).decode()
        let baseline = try HAPArtwork(skins:helper.skinSection(),icons:Data()).decode()
        XCTAssertEqual(decoded.skins[9],baseline.skins[9],"Unused palette entries and the high flag nibble do not change the control raster.")
    }
    func testPlanesStayInsideRecordBoundsOverlapChecksAndDecodedBudget() throws {
        let good = atlas(mode:8,depth:1)
        // Truncate in the auxiliary plane, at its end, and in the color raster.
        for count in [3088,3100,3147,3148,good.count-1] { XCTAssertThrowsError(try decode(Data(good.prefix(count)))) }
        var overlap = [UInt8](good)
        let nested = [UInt8](atlas(mode:0,depth:1,width:1,height:1).dropFirst(3072))
        // A valid second header inside the first record's auxiliary plane must not be accepted.
        overlap.replaceSubrange(3088..<3088+nested.count,with:nested)
        HAPArtworkTests().put(3088,18*16,in:&overlap)
        XCTAssertThrowsError(try decode(Data(overlap)))
        var alias = [UInt8](good); HAPArtworkTests().put(3072,18*16,in:&alias)
        let decoded = try HAPArtwork(skins:Data(),icons:Data(alias)).decode()
        XCTAssertEqual(decoded.icon(17,small:true),decoded.icon(18,small:true))
        var budget = 17*3*4-1
        XCTAssertThrowsError(try HAPBitmap.decode(AssetBytes(good),at:3072,header:8,budget:&budget))
        budget += 1
        let (_,length) = try HAPBitmap.decode(AssetBytes(good),at:3072,header:8,budget:&budget)
        XCTAssertEqual(length,good.count-3072); XCTAssertEqual(budget,0)
        var control = HAPArtworkTests().skinSection(); control[2116] = 2
        XCTAssertThrowsError(try HAPArtwork(skins:control,icons:Data()),"Do not apply the icon plane layout to a control skin.")
    }
    @MainActor func testOpaquePlaneIconsRenderAndTintAtBothScales() throws {
        let helper = HAPWindowTests()
        for mode in [2,4,8] { for scale in [1,2] {
            let original = try decode(atlas(mode:mode,depth:4,width:3,height:2)), tinted = original.tintedIcon(tint:0x224466,text:0)
            let bitmap = try helper.render(scale:scale,width:5,height:4) {
                NSColor.magenta.setFill(); NSRect(x:0,y:0,width:5,height:4).fill()
                tinted.draw(in:NSRect(x:1,y:1,width:3,height:2))
            }
            for y in 0..<2 { for x in 0..<3 { for sy in 0..<scale { for sx in 0..<scale {
                let expected: UInt32 = (x+y)%2 == 0 ? 0x1a3c5e : 0x6688aa
                XCTAssertEqual(try helper.color(bitmap,x:(x+1)*scale+sx,y:(y+1)*scale+sy),expected)
            } } } }
            XCTAssertEqual(try helper.color(bitmap,x:0,y:0),0xff00ff)
        } }
    }
    func testHAPImportCatalogRoundTripAndRejectedReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let library = AppearanceLibrary(root:root)
        var hap = [UInt8](AppearanceTests().hap()), icons = atlas(mode:8,depth:2)
        HAPArtworkTests().put(hap.count,0x44,in:&hap); HAPArtworkTests().put(icons.count,0x48,in:&hap)
        hap += icons
        let imported = try AppearanceDecoder.hap(Data(hap),name:"Plane icon")
        try library.install(imported)
        XCTAssertEqual(library.load().last,imported.appearances[0])
        let reloaded = try XCTUnwrap(library.load().last?.artwork?.decode().icon(17,small:true))
        XCTAssertEqual(reloaded,try decode(icons))
        let catalog = library.load()
        hap.removeLast()
        XCTAssertThrowsError(try AppearanceDecoder.hap(Data(hap),name:"Truncated replacement"))
        XCTAssertEqual(library.load(),catalog)
    }
    func testReferenceInstructionsForPlaneOffsetsAndOpaqueDispatch() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Set KDX_CLASSIC_REFERENCE for original icon decoder instructions.") }
        let bytes = try AssetBytes(Data(contentsOf:URL(fileURLWithPath:path)))
        for (address,instruction) in [(0x9972c,0x57c0073e),(0x9976c,0x5400f0ba),(0x99778,0x5400f87a),(0x99784,0x5400003a),
                                      (0x997a0,0x7ca50214),(0x997bc,0x7ca32a14),(0x997d0,0x90a10068),(0x99924,0x57c007ff),
                                      (0x99970,0x39200000),(0x99974,0x4bfc97bd)] {
            XCTAssertEqual(try bytes.u32(address+0x1de0),instruction)
        }
    }
}
