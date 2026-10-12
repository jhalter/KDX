import AppKit

/// Reimplementation of the reference's palette-driven controls, used when a HAP
/// supplies no bitmap override. Slot numbers and pixel geometry come from 0x97B20.
@MainActor enum HAPPaletteDrawing {
    static func button(_ bounds: NSRect, pressed: Bool, enabled: Bool, defaultButton: Bool = false) -> NSColor {
        if defaultButton && enabled { defaultButtonFrame(bounds) }
        // 0x97DD4 reserves the outer frame even when the default is disabled.
        let rect = defaultButton ? bounds.insetBy(dx:3,dy:3) : bounds
        let base = !enabled ? 43 : pressed ? 36 : 29
        let style = ClassicStyle.shared
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        func fill(_ left: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat, _ slot: Int) {
            guard width > 0, height > 0 else { return }
            style.color(base+slot).setFill()
            NSRect(x:x+left,y:y+top,width:width,height:height).fill()
        }
        func horizontal(_ left: CGFloat, _ top: CGFloat, _ right: CGFloat, _ slot: Int) { fill(left,top,right-left,1,slot) }
        func vertical(_ left: CGFloat, _ top: CGFloat, _ bottom: CGFloat, _ slot: Int) { fill(left,top,1,bottom-top,slot) }
        func pixel(_ left: CGFloat, _ top: CGFloat, _ slot: Int) { fill(left,top,1,1,slot) }
        fill(3,3,w-6,h-6,2)
        horizontal(2,0,w-2,5); pixel(1,1,5); horizontal(2,1,w-3,0)
        pixel(w-3,1,3); pixel(w-2,1,5); pixel(2,2,0)
        horizontal(3,2,w-3,1); pixel(w-3,2,2); pixel(w-2,2,3)
        pixel(1,h-3,3); pixel(2,h-3,2); horizontal(3,h-3,w-3,3)
        pixel(1,h-2,5); pixel(2,h-2,3); horizontal(3,h-2,w-2,4)
        horizontal(2,h-1,w-2,5)
        vertical(0,2,h-2,5); vertical(1,2,h-3,0); vertical(2,3,h-3,1)
        pixel(w-4,h-4,3); vertical(w-3,3,h-3,3); pixel(w-3,h-3,4)
        vertical(w-2,3,h-2,4); pixel(w-2,h-2,5); vertical(w-1,2,h-2,5)
        return style.color(base+6)
    }

    private static func defaultButtonFrame(_ rect: NSRect) {
        let style = ClassicStyle.shared
        func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ slot: Int) {
            guard w > 0, h > 0 else { return }
            style.color(slot).setFill()
            NSRect(x:rect.minX+x,y:rect.minY+y,width:w,height:h).fill()
        }
        // 0x97B74: the 10x10 raster contains four 5x5 corners, with a
        // six-byte row stride. Index zero is transparent; 1...4 use 50...53.
        if let data = style.chromeArtwork?.defaultButtonCorners, data.count == 60 {
            let bytes = [UInt8](data)
            for cy in 0..<2 { for cx in 0..<2 {
                let x = cx == 0 ? CGFloat(0) : rect.width-5
                let y = cy == 0 ? CGFloat(0) : rect.height-5
                for row in 0..<5 { for column in 0..<5 {
                    let sourceX = cx*5+column, sourceY = cy*5+row
                    let index = Int(bytes[sourceY*6+sourceX/2] >> (sourceX.isMultiple(of:2) ? 4 : 0) & 15)
                    if (1...4).contains(index) { fill(x+CGFloat(column),y+CGFloat(row),1,1,49+index) }
                } }
            } }
        } else {
            // A palette-only import or older catalog may lack the corner asset.
            // Keep a minimal visible default marker until the app is reimported.
            style.color(53).setStroke()
            let path = NSBezierPath(roundedRect:rect.insetBy(dx:1.5,dy:1.5),xRadius:3.5,yRadius:3.5)
            path.lineWidth = 3; path.stroke()
        }
        for (row,slot) in [53,50,51].enumerated() {
            fill(5,CGFloat(row),rect.width-10,1,slot)
            fill(CGFloat(row),5,1,rect.height-10,slot)
        }
        for (row,slot) in [51,52,53].enumerated() {
            fill(5,rect.height-3+CGFloat(row),rect.width-10,1,slot)
            fill(rect.width-3+CGFloat(row),5,1,rect.height-10,slot)
        }
    }
}
