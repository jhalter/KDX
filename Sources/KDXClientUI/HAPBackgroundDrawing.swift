import AppKit

/// Window fill: 0x96080 / 0x9BF60. Skin 1 replaces palette slot 2.
/// The original tile blitter (0x61D40) is opaque, including keyed source pixels.
@MainActor enum HAPBackgroundDrawing {
    static func tile(_ bitmap: HAPBitmap, in rect: NSRect) {
        guard !rect.isEmpty, bitmap.width > 0, bitmap.height > 0,
              let context = NSGraphicsContext.current?.cgContext else { return }
        // 0x61D6C…0x61D88 intersects with the drawing clip before iterating.
        // A menu row supplies the entire menu background under a row-sized clip;
        // visiting every offscreen tile would make long patterned menus expensive.
        // The clip bounds are in the current user space, preserving tile phase
        // after a nested surface or menu row translates the drawing origin.
        let rect = rect.intersection(context.boundingBoxOfClipPath)
        guard !rect.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        rect.clip()
        let w = CGFloat(bitmap.width), h = CGFloat(bitmap.height)
        if bitmap.width == 1 {
            // Match the original one-column fast path, avoiding one image draw per pixel.
            let pixels = [UInt8](bitmap.rgba)
            func color(_ row: Int) -> NSColor {
                let at = row*4
                return NSColor(srgbRed:Double(pixels[at])/255,green:Double(pixels[at+1])/255,blue:Double(pixels[at+2])/255,alpha:1)
            }
            if bitmap.height == 1 { color(0).setFill(); rect.fill(); return }
            for y in stride(from:floor(rect.minY),to:rect.maxY,by:1) {
                let row = (Int(y)%bitmap.height+bitmap.height)%bitmap.height
                color(row).setFill(); NSRect(x:rect.minX,y:y,width:rect.width,height:1).fill()
            }
            return
        }
        guard let cgImage = bitmap.cgImage(opaque:true) else { return }
        let image = NSImage(cgImage:cgImage,size:NSSize(width:w,height:h))
        for y in stride(from:floor(rect.minY/h)*h,to:rect.maxY,by:h) {
            for x in stride(from:floor(rect.minX/w)*w,to:rect.maxX,by:w) {
                image.draw(in:NSRect(x:x,y:y,width:w,height:h),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.none.rawValue])
            }
        }
    }
    static func fill(_ rect: NSRect) {
        guard !rect.isEmpty else { return }
        if let bitmap = ClassicStyle.shared.artwork?.skins[1] { tile(bitmap,in:rect) }
        else { ClassicStyle.shared.color(2).setFill(); rect.fill() }
    }
    static func fill(_ rect: NSRect, in view: NSView) {
        // Classic drawing surfaces are flipped. Keep the pattern in the outermost
        // Classic surface's coordinates, including nested split views and dialogs.
        var root = view, ancestor = view.superview
        while let current = ancestor {
            if current is ClassicSurface { root = current }
            ancestor = current.superview
        }
        let origin = view.convert(NSPoint.zero,to:root)
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        rect.clip()
        let transform = NSAffineTransform(); transform.translateX(by:-origin.x,yBy:-origin.y); transform.concat()
        fill(rect.offsetBy(dx:origin.x,dy:origin.y))
    }
}

/// Native pane resizing, persistence and accessibility, with themed space between panes.
@MainActor final class ClassicSplitView: NSSplitView {
    override var isFlipped: Bool { true }
    // Window layout remains an adaptation; six points matches the surrounding stack spacing.
    override var dividerThickness: CGFloat { 6 }
    override func drawDivider(in rect: NSRect) { HAPBackgroundDrawing.fill(rect,in:self) }
}
