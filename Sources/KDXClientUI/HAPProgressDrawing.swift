import AppKit

/// Data-only rasters referenced by 0x984F0; imported from the verified executable.
public struct HAPProgressArtwork: Codable, Equatable, Sendable {
    let digits: Data
    let complete: Data
    let caps: Data
    init(reference: AssetBytes) throws {
        try self.init(digits:reference.data(0x1091ac,100),complete:reference.data(0x109210,16),caps:reference.data(0x109248,40))
    }
    init(digits: Data, complete: Data, caps: Data) throws {
        self.digits = digits; self.complete = complete; self.caps = caps
        try validate()
    }
    func validate() throws {
        guard digits.count == 100, complete.count == 16, caps.count == 40,
              caps.allSatisfy({ $0 >> 4 <= 12 && $0 & 15 <= 12 }) else {
            throw AppearanceError.invalid("Invalid original progress artwork.")
        }
    }
}

struct ClassicProgressValue: Equatable {
    let fraction: Double
    init(_ fraction: Double) { self.fraction = fraction.isFinite ? min(1,max(0,fraction)) : 0 }
    // 0x98400 rounds both values to the nearest integer, but reserves 100 for
    // actual completion. The modern adapter also rejects nonfinite input.
    var percent: Int { fraction >= 1 ? 100 : min(99,Int(Double(0.5).addingProduct(100,fraction).rounded(.down))) }
    func pixels(_ width: Int) -> Int { Int(Double(0.5).addingProduct(Double(max(0,width)),fraction).rounded(.down)) }
}

@MainActor enum HAPProgressDrawing {
    static func draw(_ rect: NSRect, value: ClassicProgressValue) {
        guard !rect.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        rect.clip()
        if skin(rect,value:value) { return }
        if let art = ClassicStyle.shared.chromeArtwork?.progress { palette(rect,value:value,art:art) }
        else { recovery(rect,value:value) }
    }

    /// 0x9CAF0: native-height background 95, followed by horizontally stretched
    /// fill 96 whose placement bytes inset its available range.
    private static func skin(_ rect: NSRect, value: ClassicProgressValue) -> Bool {
        let skins = ClassicStyle.shared.artwork?.skins ?? [:]
        guard let background = skins[95] else { return false }
        let y = CGFloat(Int(rect.minY+rect.maxY-CGFloat(background.height))/2)
        let frame = NSRect(x:rect.minX,y:y,width:rect.width,height:CGFloat(background.height))
        background.draw(in:frame,stretch:true,axis:.horizontal)
        // The original draws the background before returning to palette drawing
        // if the fill is absent. Keep that ordering for partial skins.
        guard let fill = skins[96] else { return false }
        let p = fill.placement
        let available = max(0,Int(rect.width)-p[0]-p[2])
        let width = value.pixels(available)
        guard width > 0 else { return true }
        let destination = NSRect(x:rect.minX+CGFloat(p[0]),y:y+CGFloat(p[1]),
                                 width:CGFloat(width),height:max(0,frame.height-CGFloat(p[1]+p[3])))
        destination.clip()
        fill.draw(in:destination,stretch:true,axis:.horizontal)
        return true
    }

    private static func palette(_ rect: NSRect, value: ClassicProgressValue, art: HAPProgressArtwork) {
        let x = rect.minX, y = CGFloat(Int(rect.minY+rect.maxY-14)/2)
        let width = max(17,Int(rect.width)), right = x+CGFloat(width), bottom = y+13
        let filled = value.pixels(width-18), remaining = max(0,width-18)-filled
        func fill(_ left: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat, _ slot: Int) {
            guard w > 0, h > 0 else { return }
            ClassicStyle.shared.color(slot).setFill(); NSRect(x:left,y:top,width:w,height:h).fill()
        }
        func horizontal(_ left: CGFloat, _ top: CGFloat, _ end: CGFloat, _ slot: Int) { fill(left,top,end-left,1,slot) }
        func vertical(_ left: CGFloat, _ top: CGFloat, _ end: CGFloat, _ slot: Int) { fill(left,top,1,end-top,slot) }
        horizontal(x,y,right-1,3); vertical(x,y+1,bottom,3)
        horizontal(x+1,bottom,right,1); vertical(right-1,y+1,bottom,1)
        fill(x+1,y+1,15,12,126)
        horizontal(x+16,y+1,right-1,126); horizontal(x+16,bottom-1,right-1,126)
        vertical(right-2,y+2,bottom-1,126)
        if value.percent < 100 {
            raster(art.digits,offset:(value.percent/10)*10,stride:1,depth:1,sourceX:0,width:6,height:10,
                   at:NSPoint(x:x+2,y:y+2),slots:[127])
            raster(art.digits,offset:(value.percent%10)*10,stride:1,depth:1,sourceX:0,width:6,height:10,
                   at:NSPoint(x:x+9,y:y+2),slots:[127])
        } else {
            raster(art.complete,offset:0,stride:2,depth:1,sourceX:0,width:9,height:8,
                   at:NSPoint(x:x+4,y:y+3),slots:[127])
        }
        NSRect(x:x+16,y:y+2,width:max(0,CGFloat(width-18)),height:10).clip()
        let end = x+CGFloat(filled)+13
        let slots = Array(113...122)+[126,125]
        if filled > 0 {
            raster(art.caps,offset:0,stride:4,depth:4,sourceX:2,width:6,height:10,at:NSPoint(x:end,y:y+2),slots:slots)
            raster(art.caps,offset:0,stride:4,depth:4,sourceX:0,width:min(2,filled),height:10,at:NSPoint(x:x+16,y:y+2),slots:slots)
        }
        for row in 0..<10 { horizontal(x+18,y+2+CGFloat(row),end,113+row) }
        if remaining > 3 {
            let start = end+(filled == 0 ? 4 : 6)
            if filled == 0 { vertical(x+16,y+2,bottom-1,125) }
            fill(start,y+3,right-3-start,8,124)
            horizontal(start,y+2,right-3,125); fill(right-3,y+2,1,1,124)
            horizontal(start,bottom-2,right-2,123); vertical(right-3,y+3,bottom-2,123)
        }
    }

    private static func raster(_ data: Data, offset: Int, stride: Int, depth: Int, sourceX: Int, width: Int, height: Int, at origin: NSPoint, slots: [Int]) {
        for y in 0..<height { for x in 0..<width {
            let bit = (sourceX+x)*depth
            let index = Int(data[offset+y*stride+bit/8] >> (8-depth-bit%8)) & ((1 << depth)-1)
            guard index > 0 else { continue }
            ClassicStyle.shared.color(slots[index-1]).setFill()
            NSRect(x:origin.x+CGFloat(x),y:origin.y+CGFloat(y),width:1,height:1).fill()
        } }
    }

    private static func recovery(_ rect: NSRect, value: ClassicProgressValue) {
        ClassicPainter.bevel(rect,pressed:true,fill:ClassicStyle.shared.color(15))
        let inside = rect.insetBy(dx:2,dy:2)
        if inside.width > 0 && inside.height > 0 {
            ClassicStyle.shared.color(17).setFill()
            NSRect(x:inside.minX,y:inside.minY,width:CGFloat(value.pixels(Int(inside.width))),height:inside.height).fill()
        }
    }
}

@MainActor final class ClassicProgressView: NSView {
    let value: ClassicProgressValue
    override var isFlipped: Bool { true }
    init(progress: Double) {
        value = ClassicProgressValue(progress)
        super.init(frame:.zero)
        setAccessibilityElement(true); setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Transfer progress"); setAccessibilityValue(value.percent)
        setAccessibilityMinValue(0); setAccessibilityMaxValue(100)
        toolTip = "\(value.percent)%"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { HAPProgressDrawing.draw(bounds,value:value) }
}
