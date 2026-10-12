import AppKit

enum ClassicListKind { case plain, users, files, transfers }

/// Exact, case-sensitive kinds from the 54-record table at file 0x114C48.
enum ClassicFileKind {
    static func iconID(_ kind: String, isDirectory: Bool = false) -> Int {
        switch kind {
        case "data", "executable/settings", "app/pdf", "app/appleworks", "app/msword", "app/msexcel", "app/mspowerpoint", "system/appearance", "url": return 17
        case "data/truncated": return 24
        case "folder", "alias/folder": return 40
        case "folder/dropbox": return 44
        case "folder/uploads": return 43
        case "alias", "alias/unattached": return 16
        case "volume", "device": return 61
        case "text/standard", "text/plain", "text/source", "text/html": return 18
        case "executable/program": return 10
        case "executable/library": return 12
        case "executable/plugin": return 11
        case "image/standard", "image/jpeg", "image/tiff", "image/gif", "image/bmp", "image/png", "image/photoshop", "image/macpict", "image/icon": return 19
        case "audio/standard", "audio/wav", "audio/aiff", "audio/midi", "audio/mpeg", "audio/mpeg4": return 20
        case "video/standard", "video/mpeg", "video/quicktime", "video/avi", "video/mpeg4": return 21
        case "archive/standard", "archive/zip", "archive/gzip", "archive/tar", "archive/stuffit", "archive/diskimage", "archive/rar": return 23
        case "font/standard", "font/ttf": return 22
        // Modern directory metadata remains useful when no recognized kind is sent.
        default: return isDirectory ? 40 : 17
        }
    }
}

/// Original file-list setup 0xDFA0; icon alignment 0xDD40 and text inset 0xDDA4.
enum ClassicFileRowSize {
    case compact, normal
    var small: Bool { self == .compact }
    var rowHeight: CGFloat { small ? 18 : 34 }
    var iconColumnWidth: CGFloat { small ? 24 : 40 }
    var textOrigin: CGFloat { iconColumnWidth+6 }
    func iconRect(_ bitmap: HAPBitmap) -> NSRect {
        // 0x5F110 centers native pixels with integer division toward zero.
        NSRect(x:Int(iconColumnWidth-CGFloat(bitmap.width))/2,
               y:1+Int(rowHeight-1-CGFloat(bitmap.height))/2,
               width:bitmap.width,height:bitmap.height)
    }
}

@MainActor final class ClassicFileCell: NSView {
    let text: ClassicListTextField
    let iconID: Int
    let rowSize: ClassicFileRowSize
    override var isFlipped: Bool { true }
    init(text: ClassicListTextField, iconID: Int, rowSize: ClassicFileRowSize) {
        self.text = text; self.iconID = iconID; self.rowSize = rowSize
        super.init(frame:.zero); addSubview(text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let height = min(bounds.height,text.intrinsicContentSize.height), left = rowSize.textOrigin-2
        text.frame = NSRect(x:left,y:floor((bounds.height-height)/2),width:max(0,bounds.width-left),height:height)
    }
    override func draw(_ dirtyRect: NSRect) {
        let style = ClassicStyle.shared
        guard let bitmap = style.artwork?.icon(iconID,small:rowSize.small) else { return }
        var ancestor = superview
        while ancestor != nil && !(ancestor is NSTableRowView) { ancestor = ancestor?.superview }
        let row = ancestor as? NSTableRowView
        let selected = row?.isSelected == true && row?.isEmphasized == true
        let selection = selected ? HAPUserRowDrawing.rgb(style.color(17)) : nil
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSRect(x:0,y:1,width:min(bounds.width,rowSize.iconColumnWidth),height:max(0,bounds.height-1)).clip()
        bitmap.tintedIcon(tint:selection,text:HAPUserRowDrawing.rgb(style.color(selected ? 18 : 16))).draw(in:rowSize.iconRect(bitmap))
        if let row, row.isSelected && !row.isEmphasized {
            // Native row selection draws before its children; restore the original
            // outline over any icon pixels intersecting it.
            HAPListDrawing.selection(convert(row.bounds,from:row),emphasized:false)
        }
    }
}
