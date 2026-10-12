import AppKit

/// Original chooser conversion rules (0xC0C60 / 0xC1600). Keep the edited
/// representation intact while synchronizing the other controls.
struct ClassicColorValue {
    var rgb: UInt32
    var components: [Int] { [16,8,0].map { Int((rgb >> $0)&255) } }
    var hexadecimal: String { String(format:"%06X",rgb&0xffffff) }
    var decimal: String { components.map(String.init).joined(separator:", ") }
    mutating func setComponent(_ index: Int, _ value: Int) {
        guard (0..<3).contains(index) else { return }
        let shift = (2-index)*8, mask = UInt32(255) << shift
        rgb = (rgb & ~mask) | (UInt32(min(255,max(0,value))) << shift)
    }
    static func hexadecimal(_ text: String) -> UInt32 { unsignedPrefix(text,radix:16)&0xffffff }
    static func decimal(_ text: String) -> UInt32 {
        let tokens = text.components(separatedBy:CharacterSet(charactersIn:",. /-")).filter { !$0.isEmpty }
        var result: UInt32 = 0
        for index in 0..<3 {
            let value = index < tokens.count ? min(255,unsignedPrefix(tokens[index],radix:10)) : 0
            result |= value << ((2-index)*8)
        }
        return result
    }
    private static func unsignedPrefix(_ text: String, radix: UInt32) -> UInt32 {
        var bytes = Array(text.utf8.prefix(63))
        while let first = bytes.first, [9,10,11,12,13,32].contains(first) { bytes.removeFirst() }
        if bytes.first == 43 { bytes.removeFirst() }
        if radix == 16, bytes.starts(with:[48,120]) { bytes.removeFirst(2) }
        var value: UInt32 = 0
        for byte in bytes {
            let digit: UInt32
            switch byte { case 48...57: digit = UInt32(byte-48); case 65...70: digit = UInt32(byte-55); case 97...102: digit = UInt32(byte-87); default: return value }
            guard digit < radix else { return value }
            if value > (UInt32.max-digit)/radix { return UInt32.max }
            value = value &* radix &+ digit
        }
        return value
    }
}

@MainActor final class ClassicColorSwatch: NSView {
    var newColor: UInt32 = 0 { didSet { needsDisplay = true } }
    var oldColor: UInt32 = 0 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // 0xC0B60: literal black two-pixel frame, new color above old color.
        HAPUserRowDrawing.color(0).setFill(); bounds.fill()
        let inner = bounds.insetBy(dx:2,dy:2), top = floor(inner.height/2)
        HAPUserRowDrawing.color(newColor).setFill(); NSRect(x:inner.minX,y:inner.minY,width:inner.width,height:top).fill()
        HAPUserRowDrawing.color(oldColor).setFill(); NSRect(x:inner.minX,y:inner.minY+top,width:inner.width,height:inner.height-top).fill()
    }
}

@MainActor final class ClassicColorChooserForm: ClassicSurface, NSTextFieldDelegate {
    static let referenceSize = NSSize(width:480,height:236)
    let message = classicLabel("Please choose a color.")
    let sliders = [ClassicColorSlider("Red"),ClassicColorSlider("Green"),ClassicColorSlider("Blue")]
    let percentages = (0..<3).map { _ in classicLabel("") }
    let channels = (0..<3).map { _ in ClassicColorSwatch() }
    let hexadecimal = ClassicTextField(), decimal = ClassicTextField(), preview = ClassicColorSwatch()
    let accept = ClassicButton("OK",key:"\r",height:26) {}, cancel = ClassicButton("Cancel",key:"\u{1b}",height:20) {}
    private(set) var value: ClassicColorValue
    let original: UInt32
    private(set) var labels: [String:NSTextField] = [:]
    var respond: ((Bool) -> Void)?
    init(rgb: UInt32) {
        original = rgb&0xffffff; value = ClassicColorValue(rgb:original)
        super.init(frame:NSRect(origin:.zero,size:Self.referenceSize))
        for title in ["Red:","Green:","Blue:","Hexadecimal:","Decimal:","New Color:","Old Color:"] { labels[title] = classicLabel(title) }
        for (index,slider) in sliders.enumerated() { slider.tag = index; slider.target = self; slider.action = #selector(sliderChanged) }
        hexadecimal.delegate = self; hexadecimal.setAccessibilityLabel("Hexadecimal RGB")
        decimal.delegate = self; decimal.setAccessibilityLabel("Decimal RGB")
        preview.oldColor = original; preview.setAccessibilityLabel("New and old color")
        accept.invoke = { [weak self] in self?.respond?(true) }; cancel.invoke = { [weak self] in self?.respond?(false) }
        layout()
        let views: [NSView] = [message,hexadecimal,decimal,preview,accept,cancel]+sliders+percentages+channels+Array(labels.values)
        for view in views { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = true }
        let keys: [NSView] = sliders+[hexadecimal,decimal,accept,cancel]
        for index in keys.indices { keys[index].nextKeyView = keys[(index+1)%keys.count] }
        synchronize(); applyStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func sliderChanged(_ sender: NSSlider) {
        guard (0..<3).contains(sender.tag) else { return }
        value.setComponent(sender.tag,Int(sender.doubleValue)); synchronize()
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        if field === hexadecimal { value.rgb = ClassicColorValue.hexadecimal(field.stringValue) }
        else if field === decimal { value.rgb = ClassicColorValue.decimal(field.stringValue) }
        else { return }
        synchronize(except:field)
    }
    private func synchronize(except editor: NSTextField? = nil) {
        for (index,component) in value.components.enumerated() {
            sliders[index].doubleValue = Double(component); sliders[index].needsDisplay = true
            percentages[index].stringValue = "\(component*100/255)%"
            let color = UInt32(component) << ((2-index)*8)
            channels[index].newColor = color; channels[index].oldColor = color
        }
        if editor !== hexadecimal { hexadecimal.stringValue = value.hexadecimal }
        if editor !== decimal { decimal.stringValue = value.decimal }
        preview.newColor = value.rgb
        preview.setAccessibilityValue("New #\(value.hexadecimal), old #\(String(format:"%06X",original))")
    }
    override func layout() {
        super.layout()
        message.frame = NSRect(x:10,y:10,width:460,height:16)
        for index in 0..<3 {
            let y = CGFloat(index*30)
            sliders[index].frame = NSRect(x:120,y:36+y,width:280,height:28)
            channels[index].frame = NSRect(x:410,y:40+y,width:20,height:20)
            percentages[index].frame = NSRect(x:435,y:42+y,width:45,height:16)
            labels[["Red:","Green:","Blue:"][index]]?.frame = NSRect(x:10,y:42+y,width:70,height:16)
        }
        hexadecimal.frame = NSRect(x:120,y:130,width:100,height:26)
        decimal.frame = NSRect(x:120,y:160,width:130,height:26)
        labels["Hexadecimal:"]?.frame = NSRect(x:10,y:136,width:110,height:16)
        labels["Decimal:"]?.frame = NSRect(x:10,y:166,width:75,height:16)
        labels["New Color:"]?.frame = NSRect(x:260,y:136,width:90,height:16)
        labels["Old Color:"]?.frame = NSRect(x:260,y:166,width:90,height:16)
        preview.frame = NSRect(x:350,y:130,width:70,height:56)
        accept.frame = NSRect(x:344,y:200,width:86,height:26)
        cancel.frame = NSRect(x:240,y:203,width:80,height:20)
    }
    func applyStyle() {
        hexadecimal.applyStyle(); decimal.applyStyle()
        for label in [message]+percentages+Array(labels.values) { label.font = ClassicStyle.shared.font; label.textColor = ClassicStyle.shared.color(5) }
        subviews.forEach { $0.needsDisplay = true }; needsDisplay = true
    }
    override func cancelOperation(_ sender: Any?) { respond?(false) }
}

@MainActor final class ClassicColorChooserWindow: ClassicWindowController {
    let form: ClassicColorChooserForm
    var responseRequested: ((Bool) -> Void)?
    private(set) var responded = false
    init(rgb: UInt32, preferences: ClassicPreferences) {
        form = ClassicColorChooserForm(rgb:rgb)
        super.init(title:"Color Chooser",key:"colorChooser",size:NSSize(width:492,height:264),preferences:preferences)
        chrome.isDialog = true; chrome.allowsResize = false; windowMenu.removeAllItems()
        window?.styleMask = [.borderless]; window?.setAccessibilitySubrole(.dialog)
        chrome.layoutSubtreeIfNeeded(); install(form)
        window?.defaultButtonCell = form.accept.cell as? NSButtonCell
        window?.initialFirstResponder = form.hexadecimal
        form.respond = { [weak self] accepted in self?.requestResponse(accepted) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func requestResponse(_ accepted: Bool) {
        guard !responded else { return }; responded = true
        window?.makeFirstResponder(nil); responseRequested?(accepted)
    }
    override func requestClose() { requestResponse(false) }
    override func saveFrame() {}
    override func applyStyle() {
        super.applyStyle(); form.applyStyle()
        let probe = NSRect(x:0,y:0,width:1000,height:1000), content = HAPWindowDrawing.contentRect(in:probe)
        window?.setContentSize(NSSize(width:480+probe.width-content.width,height:236+probe.height-content.height))
    }
}
