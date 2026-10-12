import AppKit
import XCTest
@testable import KDXClassicUI

final class HAPFallbackTests: XCTestCase {
    private func pixel(_ value: UInt8) -> HAPBitmap {
        HAPBitmap(width:1,height:1,rgba:Data([value,0,0,255]),textColor:nil,margins:[0,0,0,0],placement:[0,0,0,0])
    }

    func testOriginalAtlasFallbackOrderDoesNotMergeSmallOverrides() {
        let referenceSmall = pixel(10), referenceLarge = pixel(20), overrideSmall = pixel(30), overrideLarge = pixel(40)
        var artwork = HAPDecodedArtwork(skins:[:],icons:[17*4:overrideSmall],referenceIcons:[17*4:referenceSmall,17*4+1:referenceLarge])
        XCTAssertEqual(artwork.icon(17,small:true),overrideSmall)
        XCTAssertEqual(artwork.icon(17,small:false),referenceLarge)
        artwork.referenceIcons = [17*4:referenceSmall]
        XCTAssertEqual(artwork.icon(17,small:false),referenceSmall,"A missing large override falls back to the reference's small icon, not the override's small icon.")
        artwork.referenceIcons = [:]
        XCTAssertNil(artwork.icon(17,small:false),"An explicitly empty reference slot must not select another override size.")
        artwork.referenceIcons = nil
        XCTAssertEqual(artwork.icon(17,small:false),overrideSmall,"Without the original assets, standalone themes retain the recovery fallback.")
        artwork = HAPDecodedArtwork(skins:[:],icons:[17*4+1:overrideLarge],referenceIcons:[17*4:referenceSmall,17*4+1:referenceLarge])
        XCTAssertEqual(artwork.icon(17,small:true),referenceSmall)
        XCTAssertEqual(artwork.icon(17,small:false),overrideLarge)
        XCTAssertNil(artwork.icon(-1,small:true)); XCTAssertNil(artwork.icon(192,small:false))
    }

    private func overrideAppearance(name: String = "Partial theme") throws -> ClassicAppearance {
        var bytes = [UInt8](repeating:0,count:3072+8+8+16*4)
        let helper = HAPArtworkTests(), offset = 3072
        helper.put(offset,17*16,in:&bytes)
        bytes[offset+1] = 16; bytes[offset+3] = 16; bytes[offset+5] = 1; bytes[offset+6] = 1
        helper.put(0xff0000,offset+8,in:&bytes); helper.put(0x0000ff,offset+12,in:&bytes)
        for y in 0..<16 { bytes[offset+16+y*4] = 0x55; bytes[offset+17+y*4] = 0x55 }
        return ClassicAppearance(id:"partial",name:name,colors:(0..<221).map { UInt32($0)*0x010101 },source:"Imported HAP v1",artwork:try HAPArtwork(skins:helper.skinSection(),icons:Data(bytes)))
    }

    @MainActor func testUnrelatedThemeCannotBecomeReferenceByItsNameOrSource() throws {
        let style = ClassicStyle.shared
        defer { style.appearance = .recovery; style.configureAssets([]) }
        var fake = try overrideAppearance(name:"Mach Lavender")
        fake = ClassicAppearance(id:fake.id,name:fake.name,colors:fake.colors,source:"KDX Client 1.600",artwork:fake.artwork)
        let empty = try XCTUnwrap(AppearanceDecoder.hap(AppearanceTests().hap(),name:"Palette only").appearances.first)
        style.appearance = empty; style.configureAssets([fake,empty])
        XCTAssertNil(style.artwork?.icon(17,small:true))
        XCTAssertTrue(style.artwork?.skins.isEmpty == true,"Skins must not leak from another appearance.")
    }

    func testPackedParametersSurviveInstallReloadAndFailedReplacement() throws {
        var data = [UInt8](AppearanceTests().hap())
        let helper = HAPArtworkTests()
        let parameters = [0x12345678,0x90abcdef,0xff102030,0xffffffff]
        for (index,value) in parameters.enumerated() { helper.put(value,0x88+(21+index)*4,in:&data) }
        let imported = try AppearanceDecoder.hap(Data(data),name:"Packed parameters")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let library = AppearanceLibrary(root:root)
        try library.install(imported)
        XCTAssertEqual(library.load().last,imported.appearances.first)
        XCTAssertEqual(Array(try XCTUnwrap(library.load().last).colors[21...24]),parameters.map(UInt32.init))
        let catalog = try Data(contentsOf:root.appendingPathComponent("catalog.json"))
        for slot in [0,20,25,203] {
            var badData = data; helper.put(0x01000000,0x88+slot*4,in:&badData)
            XCTAssertThrowsError(try AppearanceDecoder.hap(Data(badData),name:"Invalid color"))
            var colors = imported.appearances[0].colors; colors[slot] = 0x01000000
            let invalid = ClassicAppearance(id:"invalid",name:"Invalid",colors:colors,source:"test")
            XCTAssertThrowsError(try library.install(AppearanceImport(appearances:[invalid],assets:[:])))
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("catalog.json")),catalog)
        }
    }

    @MainActor func testReferenceCatalogProvidesFallbackAcrossImportsSwitchesAndReload() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Set KDX_CLASSIC_REFERENCE to verify the imported reference fallback.") }
        let imported = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path))
        let source = try XCTUnwrap(imported.appearances.first?.artwork), reference = try source.decode()
        XCTAssertEqual(AppearanceDecoder.digest(source.icons),AppearanceDecoder.referenceIconAtlasSHA256)
        let partial = try overrideAppearance(), empty = try XCTUnwrap(AppearanceDecoder.hap(AppearanceTests().hap(),name:"Palette only").appearances.first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let library = AppearanceLibrary(root:root), style = ClassicStyle.shared
        defer { style.appearance = .recovery; style.configureAssets([]) }
        try library.install(AppearanceImport(appearances:[partial,empty],assets:[:]))
        style.configureAssets(library.load()); style.appearance = partial
        let ownSmall = try XCTUnwrap(partial.artwork?.decode().icon(17,small:true))
        XCTAssertEqual(style.artwork?.icon(17,small:false),ownSmall)
        try library.install(imported)
        // An application imported after a selected external theme must update it
        // immediately, even when the selected appearance value does not change.
        style.configureAssets(library.load())
        XCTAssertEqual(style.appearance,partial)
        XCTAssertEqual(style.artwork?.icon(17,small:true),ownSmall)
        XCTAssertEqual(style.artwork?.icon(17,small:false),reference.icon(17,small:false))
        XCTAssertEqual(style.artwork?.icon(40,small:true),reference.icon(40,small:true))
        for appearances in [library.load(),Array(library.load().reversed())] {
            style.configureAssets(appearances)
            for selected in [empty,partial,empty] {
                style.appearance = selected
                for id in 0..<192 { for small in [false,true] {
                    let expected = selected.id == partial.id && id == 17 && small ? ownSmall : reference.icon(id,small:small)
                    XCTAssertEqual(style.artwork?.icon(id,small:small),expected,"\(selected.name), icon \(id), small=\(small)")
                } }
                XCTAssertEqual(style.artwork?.skins,try selected.artwork?.decode().skins)
                XCTAssertNotNil(style.chromeArtwork); XCTAssertFalse(style.fontChoices.isEmpty)
            }
        }
        // Removing the original catalog clears its fallback, without destroying
        // the active standalone theme's own icons and skins.
        style.appearance = partial; style.configureAssets([partial])
        XCTAssertEqual(style.artwork?.icon(17,small:false),ownSmall)
        XCTAssertNil(style.artwork?.icon(40,small:true))
        XCTAssertEqual(style.artwork?.skins,try partial.artwork?.decode().skins)
        XCTAssertNil(style.chromeArtwork); XCTAssertTrue(style.fontChoices.isEmpty)
    }

    @MainActor func testPartialThemeRendersOriginalFallbackIconsAtBothScales() throws {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Set KDX_CLASSIC_REFERENCE for partial-theme offscreen checks.") }
        let imported = try ClassicAssetImporter.loadSync(URL(fileURLWithPath:path))
        let reference = try XCTUnwrap(imported.appearances.first?.artwork).decode(), partial = try overrideAppearance()
        let style = ClassicStyle.shared, helper = HAPWindowTests()
        defer { style.appearance = .recovery; style.configureAssets([]) }
        style.configureAssets(imported.appearances+[partial]); style.appearance = partial
        for size: ClassicFileRowSize in [.compact,.normal] { for iconID in [17,40] { for scale in [1,2] {
            let source = try XCTUnwrap(iconID == 17 && size.small ? partial.artwork?.decode().icon(17,small:true) : reference.icon(iconID,small:size.small))
            let cell = ClassicFileCell(text:ClassicListTextField(labelWithString:""),iconID:iconID,rowSize:size)
            cell.frame = NSRect(x:0,y:0,width:80,height:size.rowHeight)
            let actual = try helper.render(scale:scale,width:80,height:Int(size.rowHeight)) {
                NSColor.black.setFill(); cell.bounds.fill(); cell.draw(cell.bounds)
            }
            let expected = try helper.render(scale:scale,width:80,height:Int(size.rowHeight)) {
                NSColor.black.setFill(); cell.bounds.fill()
                source.tintedIcon(tint:nil,text:HAPUserRowDrawing.rgb(style.color(16))).draw(in:size.iconRect(source))
            }
            for y in 0..<Int(size.rowHeight)*scale { for x in 0..<80*scale {
                XCTAssertEqual(try helper.color(actual,x:x,y:y),try helper.color(expected,x:x,y:y),"id \(iconID), small=\(size.small), \(scale)x, (\(x),\(y))")
            } }
        } } }
    }
}
