import AppKit
import CoreText
import XCTest
@testable import KDXClassicUI

final class HaxialFontTests: XCTestCase {
    func referenceFonts() throws -> [Data] {
        guard let path = ProcessInfo.processInfo.environment["KDX_CLASSIC_REFERENCE"] else { throw XCTSkip("Provide the original KDX application for font verification.") }
        return try XCTUnwrap(ClassicAssetImporter.loadSync(URL(fileURLWithPath:path)).appearances[0].fonts)
    }
    @MainActor func testOriginalFontMetricsAndEveryGlyphOutline() throws {
        let fonts = try referenceFonts()
        XCTAssertEqual(try fonts.map { try HaxialFont(data:$0).name },["Myoklonika","Grand Mal","Panitaka","Tonik-klonik"])
        for data in fonts {
            let family = try HaxialFont(data:data)
            for (index,strike) in family.strikes.enumerated() {
                let font = try HaxialNativeFonts.shared.font(data:data,strike:index)
                let ct = font as CTFont
                XCTAssertEqual(font.pointSize,CGFloat(strike.height))
                for glyph in strike.glyphs where glyph.advance > 0 && glyph.codepoint <= 65535 {
                    var character = UniChar(glyph.codepoint), native = CGGlyph()
                    XCTAssertTrue(CTFontGetGlyphsForCharacters(ct,&character,&native,1))
                    var advance = CGSize.zero
                    CTFontGetAdvancesForGlyphs(ct,.horizontal,&native,&advance,1)
                    XCTAssertEqual(advance.width,CGFloat(glyph.advance),accuracy:0.001)
                    let path = CTFontCreatePathForGlyph(ct,native,nil)
                    for y in 0..<glyph.height { for x in 0..<glyph.width {
                        let point = CGPoint(x:CGFloat(glyph.x+x)+0.5,y:CGFloat(strike.height-glyph.y-y)-0.5)
                        XCTAssertEqual(path?.contains(point) ?? false,glyph.isSet(x:x,y:y),"\(family.name) glyph \(glyph.codepoint) at \(x),\(y)")
                    } }
                }
            }
        }
        let strike = try HaxialFont(data:fonts[0]).strikes[0], a = strike.glyphs[65]
        XCTAssertEqual([a.width,a.height,a.x,a.y,a.advance],[8,9,1,3,10])
    }
    func testCorruptAndUnsupportedFonts() throws {
        let good = try referenceFonts()[0]
        for length in [0,4,183,268,good.count-1] { XCTAssertThrowsError(try HaxialFont(data:Data(good.prefix(length)))) }
        for (offset,value) in [(5,3),(7,255),(24,64),(195,255),(196,255),(0x10c+16,255),(0x124+65*16+4,255)] {
            var bad = good; bad[offset] = UInt8(value)
            XCTAssertThrowsError(try HaxialFont(data:bad),"corrupt offset \(offset)")
        }
    }

    @MainActor func testAppKitTextLayoutAndFontPickerRestoration() throws {
        let fonts = try referenceFonts(), style = ClassicStyle.shared
        defer { style.fontChoiceID = nil; style.configureFonts([]) }
        style.configureFonts(fonts)
        XCTAssertEqual(style.fontChoices.count,5)
        XCTAssertEqual(style.font.pointSize,15)
        let selected = try XCTUnwrap(style.fontChoices.first { $0.title == "Myoklonika 15" })
        style.fontChoiceID = selected.id; style.configureFonts(fonts)
        XCTAssertEqual(style.fontChoiceID,selected.id); XCTAssertNil(style.fontError)
        XCTAssertEqual(style.font.pointSize,15)
        let text = NSTextStorage(string:"Aab 123\nSecond line",attributes:[.font:style.font])
        let layout = NSLayoutManager(), container = NSTextContainer(size:NSSize(width:300,height:200))
        layout.addTextContainer(container); text.addLayoutManager(layout); layout.ensureLayout(for:container)
        XCTAssertEqual(layout.numberOfGlyphs,text.length)
        var lines = 0
        layout.enumerateLineFragments(forGlyphRange:NSRange(location:0,length:layout.numberOfGlyphs)) { _, _, _, _, _ in lines += 1 }
        XCTAssertEqual(lines,2)
        // Keep this metric check within the imported repertoire. Unicode fallback
        // fonts can require taller lines; the render sheet below includes those.
        XCTAssertLessThanOrEqual(layout.usedRect(for:container).height,2 * layout.defaultLineHeight(for:style.font))
        for scale in [1,2] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:540*scale,pixelsHigh:230*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
            bitmap.size = NSSize(width:540,height:230)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep:bitmap))
            let transform = NSAffineTransform(); transform.translateX(by:0,yBy:230); transform.scaleX(by:1,yBy:-1); transform.concat()
            NSGraphicsContext.current = NSGraphicsContext(cgContext:NSGraphicsContext.current!.cgContext,flipped:true)
            NSGraphicsContext.current?.shouldAntialias = false
            NSColor.white.setFill(); NSRect(x:0,y:0,width:540,height:230).fill()
            for (row,choice) in style.fontChoices.enumerated() {
                style.fontChoiceID = choice.id
                (choice.title+" — KDX Connect Chat Files 0123 Ω→" as NSString).draw(at:NSPoint(x:8,y:8+row*40),withAttributes:[.font:style.font,.foregroundColor:NSColor.black])
            }
            NSGraphicsContext.restoreGraphicsState()
            if let directory = ProcessInfo.processInfo.environment["KDX_CLASSIC_RENDER_DIR"] {
                let url = URL(fileURLWithPath:directory,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("Haxial-fonts-\(scale)x.png"))
            }
        }
    }
}
