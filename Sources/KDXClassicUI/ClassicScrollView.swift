import AppKit

/// AppKit owns the document, wheel/trackpad scrolling and accessibility. This
/// scroller supplies the original KDX pixel geometry and paired arrow controls.
@MainActor class ClassicScroller: NSScroller {
    private(set) var pressedPart = HAPScrollPart.none
    private var dispatchingValue = false
    override var isFlipped: Bool { true }
    override class var isCompatibleWithOverlayScrollers: Bool { false }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 16 }
    var horizontal: Bool { bounds.width > bounds.height }
    var geometry: HAPScrollLayout {
        // AppKit can leave the last value/proportion cached when disabling a
        // scroller. A fitted document has no travel: draw a full, stationary thumb.
        HAPScrollLayout(bounds:bounds,horizontal:horizontal,value:isEnabled ? doubleValue : 0,proportion:isEnabled ? knobProportion : 1,enabled:isEnabled,skins:ClassicStyle.shared.artwork?.skins ?? [:])
    }
    override func draw(_ dirtyRect: NSRect) { HAPScrollDrawing.draw(geometry,pressed:pressedPart) }
    override func rect(for part: NSScroller.Part) -> NSRect {
        let layout = geometry
        switch part {
        case .knob: return layout.knob
        case .knobSlot: return layout.track
        case .decrementLine: return layout.parts[.decrement] ?? .zero
        case .incrementLine: return layout.parts[.increment] ?? .zero
        case .decrementPage: return layout.parts[.pageBefore] ?? .zero
        case .incrementPage: return layout.parts[.pageAfter] ?? .zero
        default: return .zero
        }
    }
    override func testPart(_ point: NSPoint) -> NSScroller.Part { geometry.hit(convert(point,from:nil)).native }
    override var hitPart: NSScroller.Part { dispatchingValue ? .knob : pressedPart == .none ? super.hitPart : pressedPart.native }
    override var usableParts: NSScroller.UsableParts { geometry.parts.isEmpty ? .noScrollerParts : .allScrollerParts }
    override func checkSpaceForParts() { needsDisplay = true }
    func activate(_ part: HAPScrollPart) {
        guard isEnabled, part != .none else { return }
        let previous = pressedPart; pressedPart = part
        if part != .knob, let scroll = superview as? NSScrollView ?? enclosingScrollView {
            let visible = horizontal ? scroll.contentView.bounds.width : scroll.contentView.bounds.height
            let total = horizontal ? scroll.contentView.documentRect.width : scroll.contentView.documentRect.height
            let travel = total-visible
            let line = horizontal ? scroll.horizontalLineScroll : scroll.verticalLineScroll
            let overlap = horizontal ? scroll.horizontalPageScroll : scroll.verticalPageScroll
            let step = part == .pageBefore || part == .pageAfter ? max(line,visible-overlap) : line
            let backwards = part == .decrement || part == .trailingDecrement || part == .pageBefore
            if travel > 0 { doubleValue = max(0,min(1,doubleValue+Double(step/travel)*(backwards ? -1 : 1))) }
        }
        // Modern AppKit handles changes to the normalized value, not legacy arrow
        // parts. Report a value change so older AppKit cannot apply the step twice.
        dispatchingValue = true
        sendAction(action,to:target)
        dispatchingValue = false
        pressedPart = previous; needsDisplay = true
    }
    func moveKnob(to origin: CGFloat) {
        guard isEnabled else { return }
        doubleValue = geometry.value(forKnobOrigin:origin)
        activate(.knob)
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        var point = convert(event.locationInWindow,from:nil)
        let layout = geometry, part = layout.hit(point)
        guard part != .none else { return }
        pressedPart = part; needsDisplay = true
        defer { pressedPart = .none; needsDisplay = true }
        let offset = horizontal ? point.x-layout.knob.minX : point.y-layout.knob.minY
        if part != .knob { activate(part) }
        var nextRepeat = Date().addingTimeInterval(0.35)
        while self.window === window && window.isVisible {
            if let next = NSApp.nextEvent(matching:[.leftMouseDragged,.leftMouseUp],until:Date().addingTimeInterval(0.05),inMode:.eventTracking,dequeue:true) {
                if next.type == .leftMouseUp { break }
                point = convert(next.locationInWindow,from:nil)
                if part == .knob { moveKnob(to:(horizontal ? point.x : point.y)-offset) }
                else { pressedPart = geometry.hit(point) == part ? part : .none; needsDisplay = true }
            }
            if part != .knob && Date() >= nextRepeat {
                if geometry.hit(point) == part { activate(part) }
                nextRepeat = Date().addingTimeInterval(0.05)
            }
        }
    }
}

@MainActor private final class ClassicScrollCorner: ClassicSurface {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class ClassicScrollView: NSScrollView {
    private let themedCorner = ClassicScrollCorner(frame:.zero)
    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        borderType = .noBorder
        scrollerStyle = .legacy; autohidesScrollers = false
        lineScroll = 16; pageScroll = 16
        verticalScroller = ClassicScroller(frame:NSRect(x:0,y:0,width:16,height:100))
        horizontalScroller = ClassicScroller(frame:NSRect(x:0,y:0,width:100,height:16))
        themedCorner.setAccessibilityElement(false)
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func applyStyle() {
        backgroundColor = ClassicStyle.shared.color(2)
        needsDisplay = true; themedCorner.needsDisplay = true
    }
    override func tile() {
        super.tile()
        // AppKit adds a separate view for the legacy scroller intersection.
        // Cover only that unused corner, using public subview/tiling APIs.
        if hasHorizontalScroller, hasVerticalScroller,
           let horizontal = horizontalScroller, !horizontal.isHidden,
           let vertical = verticalScroller, !vertical.isHidden {
            themedCorner.frame = NSRect(x:vertical.frame.minX,y:horizontal.frame.minY,width:vertical.frame.width,height:horizontal.frame.height)
            themedCorner.isHidden = false
            if subviews.last !== themedCorner { addSubview(themedCorner,positioned:.above,relativeTo:nil) }
        } else { themedCorner.isHidden = true }
    }
}
