import AppKit

/// Frame-based pane layout avoids mixing NSSplitView's transient zero-size
/// constraints with the required insets of its themed field frames. Positions
/// use the Classic preferences suite rather than AppKit's global autosave store.
@MainActor final class ClassicPaneSplitView: NSSplitView, NSSplitViewDelegate {
    private let preferences: ClassicPreferences
    private let key: String
    private let minimums: (CGFloat,CGFloat)
    private(set) var portion: CGFloat
    private var resizing = false
    private var automaticFrames: [NSRect] = []
    override var isFlipped: Bool { true }
    override var dividerThickness: CGFloat { 6 }
    init(vertical: Bool, key: String, preferences: ClassicPreferences, portion: CGFloat, minimums: (CGFloat,CGFloat)) {
        self.preferences = preferences; self.key = "split."+key; self.minimums = minimums
        let saved = preferences.defaults.object(forKey:"split."+key) as? Double
        self.portion = saved.flatMap { $0.isFinite && (0.05...0.95).contains($0) ? CGFloat($0) : nil } ?? portion
        super.init(frame:NSRect(x:0,y:0,width:600,height:350))
        isVertical = vertical; delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func addPane(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = bounds; view.autoresizingMask = []
        addSubview(view)
        if subviews.count == 2 { resizeSubviews(withOldSize:bounds.size) }
    }
    override func drawDivider(in rect: NSRect) { HAPBackgroundDrawing.fill(rect,in:self) }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard subviews.count == 2, bounds.width > 12, bounds.height > 12 else { return }
        resizing = true; defer { resizing = false }
        let available = (isVertical ? bounds.width : bounds.height)-dividerThickness
        let limits = dividerLimits
        let first = min(limits.upperBound,max(limits.lowerBound,floor(available*portion)))
        if isVertical {
            subviews[0].frame = NSRect(x:0,y:0,width:first,height:bounds.height)
            subviews[1].frame = NSRect(x:first+dividerThickness,y:0,width:available-first,height:bounds.height)
        } else {
            subviews[0].frame = NSRect(x:0,y:0,width:bounds.width,height:first)
            subviews[1].frame = NSRect(x:0,y:first+dividerThickness,width:bounds.width,height:available-first)
        }
        automaticFrames = subviews.map(\.frame)
    }
    private var dividerLimits: ClosedRange<CGFloat> {
        let available = max(0,(isVertical ? bounds.width : bounds.height)-dividerThickness)
        // Honor both minima whenever they fit. A temporarily undersized view
        // scales them together instead of allowing a pane to leave its bounds.
        let scale = min(1,available/max(1,minimums.0+minimums.1))
        let lower = minimums.0*scale
        return lower...max(lower,available-minimums.1*scale)
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerLimits.lowerBound
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerLimits.upperBound
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        // AppKit can notify after resizeSubviews has returned. Preserve the
        // chosen ratio when shrinking temporarily clamps a pane to its minimum.
        guard !resizing, subviews.count == 2, subviews.map(\.frame) != automaticFrames else { return }
        let available = (isVertical ? bounds.width : bounds.height)-dividerThickness
        guard available > 0 else { return }
        let first = isVertical ? subviews[0].frame.width : subviews[0].frame.height
        portion = min(0.95,max(0.05,first/available))
        preferences.defaults.set(Double(portion),forKey:key)
    }
}
