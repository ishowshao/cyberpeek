import AppKit

enum Palette {
    static func rgb(_ value: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16) / 255, green: CGFloat(value >> 8 & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    static let canvas = rgb(0x1c1e22), rail = rgb(0x292c32), sidebar = rgb(0x22252a)
    static let chrome = rgb(0x25282d), line = rgb(0x373a40), text = rgb(0xd8dce3)
    static let muted = rgb(0x939ba7), blue = rgb(0x75baff), green = rgb(0x91c7a4), red = rgb(0xe59898)
    static let syntax = [text, rgb(0x839685), rgb(0xd9ab91), rgb(0xb6ce9c), rgb(0xcda4df), rgb(0x80c7bf), rgb(0xe3cf99), blue]
}

extension NSView {
    func fill(_ color: NSColor) { wantsLayer = true; layer?.backgroundColor = color.cgColor }
    func place(_ child: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])
    }
    @discardableResult func width(_ value: CGFloat) -> NSView { widthAnchor.constraint(equalToConstant: value).isActive = true; return self }
    @discardableResult func height(_ value: CGFloat) -> NSView { heightAnchor.constraint(equalToConstant: value).isActive = true; return self }
}

func label(_ value: String, _ size: CGFloat = 12, color: NSColor = Palette.text, weight: NSFont.Weight = .regular) -> NSTextField {
    let field = NSTextField(labelWithString: value)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingMiddle
    field.maximumNumberOfLines = 1
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}
func stack(_ views: [NSView] = [], vertical: Bool = false, spacing: CGFloat = 0) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = vertical ? .vertical : .horizontal
    s.alignment = vertical ? .leading : .centerY
    s.spacing = spacing
    s.detachesHiddenViews = true
    return s
}
func symbol(_ name: String, size: CGFloat = 15) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
}
final class ActionButton: NSButton {
    var perform: (() -> Void)?
    init(_ title: String = "", icon: String? = nil, tip: String, size: CGFloat = 15, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .accessoryBarAction
        setButtonType(.momentaryChange)
        self.image = icon.flatMap { symbol($0, size: size) }
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        contentTintColor = Palette.muted
        toolTip = tip
        setAccessibilityLabel(tip)
        perform = action
        target = self
        self.action = #selector(fire)
    }
    @objc private func fire() { perform?() }
    required init?(coder: NSCoder) { fatalError() }
}
func kindIcon(_ path: String) -> (String, NSColor) {
    switch (path as NSString).pathExtension.lowercased() {
    case let ext where ext == "svg" || RasterImage.extensions.contains(ext): return ("photo", Palette.green)
    case "swift": return ("swift", Palette.rgb(0xf19d7c))
    case "js","ts","jsx","tsx","mjs","c","cpp","h","m","py","rs","go","sh": return ("chevron.left.forwardslash.chevron.right", Palette.blue)
    case "json","yaml","yml","plist","toml": return ("curlybraces", Palette.rgb(0xd2be80))
    case "md","txt","rst": return ("text.alignleft", Palette.muted)
    default: return ("doc", Palette.muted)
    }
}
final class OverlayScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollerStyle = .overlay
        autohidesScrollers = true
    }

    required init?(coder: NSCoder) { fatalError("OverlayScrollView is created programmatically") }

    // AppKit reapplies the system style when the active pointing device changes.
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }
}

func resultScroll(_ table: NSView) -> NSScrollView {
    let scroll = OverlayScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = table
    return scroll
}
func configureTable(_ table: NSTableView) {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.headerView = nil; table.backgroundColor = .clear
    table.focusRingType = .none; table.style = .plain
    table.selectionHighlightStyle = .regular; table.rowHeight = 25
    table.intercellSpacing = .zero
}
func rowView(_ text: String, icon: String? = nil, color: NSColor = Palette.muted, detail: String? = nil,
             detailColor: NSColor? = nil, heading: Bool = false, truncatesDetail: Bool = false) -> NSView {
    var views = [NSView]()
    if let icon {
        let image = NSImageView(image: symbol(icon, size: 13) ?? NSImage())
        image.contentTintColor = color; image.width(17); views.append(image)
    }
    let title = label(text, heading ? 11 : 12, color: heading ? Palette.muted : Palette.text, weight: heading ? .semibold : .regular)
    views.append(title)
    let s = stack(views, spacing: 7)
    if let detail {
        let badge = label(detail, 10, color: detailColor ?? color)
        s.addView(badge, in: detailColor == nil ? .leading : .trailing)
        if truncatesDetail {
            badge.widthAnchor.constraint(lessThanOrEqualTo: s.widthAnchor, multiplier: 0.5).isActive = true
            badge.toolTip = detail
        } else { badge.setContentCompressionResistancePriority(.required, for: .horizontal) }
    }
    s.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 8)
    let cell = NSTableCellView()
    cell.place(s)
    cell.toolTip = text
    return cell
}
