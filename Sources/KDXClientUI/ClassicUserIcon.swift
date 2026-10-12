import AppKit
import KDXCore

/// Geometry in 0x429D0; row heights selected by 0x42634.
enum ClassicUserRowSize: Equatable, Sendable {
    case compact, normal
    var small: Bool { self == .compact }
    var rowHeight: CGFloat { small ? 19 : 33 }
    var iconRect: NSRect { small ? NSRect(x:14,y:1,width:16,height:16) : NSRect(x:16,y:0,width:32,height:32) }
    var classWidth: CGFloat { small ? 6 : 8 }
    var textOrigin: CGFloat { small ? 36 : 54 }
    var gradientOrigin: Int { small ? 30 : 48 }
    var outlineWidth: CGFloat { small ? 2 : 3 }
}

/// The user-profile icon is a different format from a HAP skin. Original decoder
/// 0x1F60 accepts four encodings, with a fixed 32×32 opaque indexed raster.
struct ClassicUserIcon: Equatable, Sendable {
    let palette: [UInt32]
    let indices: [UInt8]

    init?(_ bytes: [UInt8]) {
        guard (2...0x708).contains(bytes.count), (1...4).contains(bytes[0]) else { return nil }
        let packed = bytes[0] <= 2, count = Int(bytes[1])+1
        let start = 2+count*3, length = packed ? 512 : 1024
        guard bytes.count >= start+length else { return nil }
        palette = (0..<count).map { index in
            let offset = 2+index*3
            return UInt32(bytes[offset]) << 16 | UInt32(bytes[offset+1]) << 8 | UInt32(bytes[offset+2])
        }
        var pixels = [UInt8](); pixels.reserveCapacity(1024)
        for pixel in 0..<1024 {
            let index = packed ? (bytes[start+pixel/2] >> (pixel%2 == 0 ? 4 : 0)) & 15 : bytes[start+pixel]
            guard Int(index) < count else { return nil }
            pixels.append(index)
        }
        indices = pixels
    }

    func bitmap(small: Bool, selection: UInt32? = nil) -> HAPBitmap {
        // 0x6E4C0 tints each palette component before 0x427F0 reduces 2×2 blocks.
        let colors: [[Int]] = palette.map { rgb in
            [16,8,0].map { shift in
                let component = Int((rgb >> shift)&255)
                return selection.map { (component+Int(($0 >> shift)&255))/2 } ?? component
            }
        }
        let size = small ? 16 : 32, step = small ? 2 : 1
        var rgba = [UInt8](); rgba.reserveCapacity(size*size*4)
        for y in 0..<size { for x in 0..<size {
            for component in 0..<3 {
                var sum = 0
                for dy in 0..<step { for dx in 0..<step {
                    sum += colors[Int(indices[(y*step+dy)*32+x*step+dx])][component]
                } }
                rgba.append(UInt8(sum/(step*step)))
            }
            rgba.append(255)
        } }
        return HAPBitmap(width:size,height:size,rgba:Data(rgba),textColor:nil,margins:[0,0,0,0],placement:[0,0,0,0])
    }
}

struct ClassicUserAdornment: Equatable {
    let icon: [UInt8]
    let classColor: UInt32
    let foreground: UInt32?
    let background: UInt32?
    let gradient: Bool
    let unreadMessage: Bool?
    init(user: KDXUser, unreadMessage: Bool? = nil) {
        self.unreadMessage = unreadMessage
        icon = user.icon
        // The current core initializes an unspecified profile with six zeroes.
        // Keep that modern default readable; actual supplied colors are otherwise
        // reproduced, including equal nonzero foreground/background values.
        if user.colors.count == 6, user.colors.contains(where: { $0 != 0 }) {
            foreground = UInt32(user.colors[0]) << 16 | UInt32(user.colors[1]) << 8 | UInt32(user.colors[2])
            background = UInt32(user.colors[3]) << 16 | UInt32(user.colors[4]) << 8 | UInt32(user.colors[5])
        } else { foreground = nil; background = nil }
        gradient = user.flags & 4 != 0
        // Wire bytes 20–22 are RGB in 0x44904; the existing core field names
        // are retained for API compatibility. This is not an inferred role color.
        classColor = unreadMessage.map { $0 ? 0xff0000 : 0 } ?? (UInt32(user.badge) << 16 | UInt32(user.server15) << 8 | UInt32(user.server16))
    }
}

/// Native accessible text with the original user-icon and class-bar geometry.
@MainActor final class ClassicUserCell: NSView {
    let text: ClassicListTextField
    let adornment: ClassicUserAdornment
    let rowSize: ClassicUserRowSize
    private let icon: ClassicUserIcon?
    private let normalBitmap: HAPBitmap?
    private var selectedBitmap: (color: UInt32, bitmap: HAPBitmap)?
    override var isFlipped: Bool { true }

    init(text: ClassicListTextField, adornment: ClassicUserAdornment, rowSize: ClassicUserRowSize = .compact) {
        self.text = text; self.adornment = adornment; self.rowSize = rowSize
        icon = ClassicUserIcon(adornment.icon); normalBitmap = icon?.bitmap(small:rowSize.small)
        super.init(frame:.zero)
        addSubview(text)
        text.setAccessibilityHelp(adornment.unreadMessage.map { $0 ? "Unread messages" : "Messages read" } ?? String(format:"Class color #%06X",adornment.classColor))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let height = min(bounds.height,text.intrinsicContentSize.height)
        // Compensate for NSTextField's two-pixel text inset.
        let left = rowSize.textOrigin-2
        text.frame = NSRect(x:left,y:floor((bounds.height-height)/2),width:max(0,bounds.width-left),height:height)
    }

    override func draw(_ dirtyRect: NSRect) {
        var ancestor = superview
        while ancestor != nil && !(ancestor is NSTableRowView) { ancestor = ancestor?.superview }
        let row = ancestor as? NSTableRowView
        let selected = row?.isSelected == true && row?.isEmphasized == true
        let color = selected ? ClassicStyle.shared.color(17) : HAPUserRowDrawing.color(adornment.classColor)
        color.setFill(); NSRect(x:0,y:0,width:min(rowSize.classWidth,bounds.width),height:bounds.height).fill()
        var bitmap = normalBitmap
        if selected, let icon {
            let value = HAPUserRowDrawing.rgb(color)
            if selectedBitmap?.color != value { selectedBitmap = (value,icon.bitmap(small:rowSize.small,selection:value)) }
            bitmap = selectedBitmap?.bitmap
        }
        bitmap?.draw(in:rowSize.iconRect)
        if let row = row as? ClassicTableRowView, row.userAdornment != nil, row.isSelected && !row.isEmphasized {
            // The original outline is drawn after the icon; it covers the icon’s outer
            // scanlines. Native row selection draws before child views, so restore
            // that overlap here using the row's coordinates (also after reorder).
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            NSBezierPath(rect:bounds).addClip()
            HAPUserRowDrawing.inactiveSelection(convert(row.bounds,from:row),size:rowSize)
        }
    }
}
