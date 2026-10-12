import AppKit

/// Native radio buttons retain AppKit tracking, keyboard navigation and accessibility.
/// The shared checkbox renderer's round variant supplies the original HAP treatment.
@MainActor final class ClassicRadioButton: NSButton {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { HAPCheckboxDrawing.size(title:title,radio:true) }
    init(_ title: String) {
        super.init(frame:.zero)
        let cell = ClassicCheckboxCell(textCell:title); cell.radio = true; self.cell = cell
        setButtonType(.radio); self.title = title
        font = ClassicStyle.shared.font; focusRingType = .none
        setAccessibilityRole(.radioButton); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor final class ClassicRadioGroup: NSStackView {
    let buttons: [ClassicRadioButton]
    private(set) var indexOfSelectedItem = 0
    var selectionChanged: ((Int) -> Void)?

    init(_ label: String, titles: [String]) {
        buttons = titles.map(ClassicRadioButton.init)
        super.init(frame:.zero)
        orientation = .horizontal; alignment = .centerY; spacing = 6
        setAccessibilityRole(.radioGroup); setAccessibilityLabel(label)
        for button in buttons {
            addArrangedSubview(button)
            button.target = self; button.action = #selector(choose(_:))
        }
        selectItem(at:0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func selectItem(at index: Int) {
        guard buttons.indices.contains(index) else { return }
        indexOfSelectedItem = index
        for (i,button) in buttons.enumerated() { button.state = i == index ? .on : .off }
    }
    @objc private func choose(_ sender: NSButton) {
        guard sender.isEnabled, let index = buttons.firstIndex(where: { $0 === sender }) else { return }
        selectItem(at:index); selectionChanged?(index)
    }
}
