import AppKit

final class EditorFontSettings: NSObject {
    static let shared = EditorFontSettings(defaults: .standard)
    static let defaultSize = 24
    static let sizes = 9...32
    static let didChange = Notification.Name("CyberPeek.editorFontSizeDidChange")
    private static let key = "editorFontSize"

    struct Fonts {
        let size: Int
        let regular: NSFont
        let lineNumber: NSFont
        let markdown: [NSFont]

        init(size: Int) {
            self.size = size
            let points = CGFloat(size)
            let manager = NSFontManager.shared
            regular = NSFont(name: "Menlo-Regular", size: points) ?? .monospacedSystemFont(ofSize: points, weight: .regular)
            lineNumber = manager.convert(regular, toSize: points - 2)
            let bold = manager.convert(regular, toHaveTrait: .boldFontMask)
            markdown = [regular, bold, manager.convert(regular, toHaveTrait: .italicFontMask),
                        manager.convert(bold, toHaveTrait: .italicFontMask)]
        }
    }

    private let defaults: UserDefaults
    private(set) var fonts: Fonts

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let stored = defaults.integer(forKey: Self.key)
        fonts = Fonts(size: Self.sizes.contains(stored) ? stored : Self.defaultSize)
    }

    func setSize(_ requested: Int) {
        let size = min(Self.sizes.upperBound, max(Self.sizes.lowerBound, requested))
        guard size != fonts.size else { return }
        fonts = Fonts(size: size)
        defaults.set(size, forKey: Self.key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

extension EditorFontSettings: NSMenuItemValidation {
    func addMenuItems(to view: NSMenu) {
        @discardableResult func add(to menu: NSMenu, _ title: String, _ action: Selector,
                                    key: String = "", tag: Int) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            item.tag = tag
            return item
        }

        view.addItem(.separator())
        let sizes = NSMenu(title: "编辑器字号")
        view.addItem(withTitle: sizes.title, action: nil, keyEquivalent: "").submenu = sizes
        for size in Self.sizes {
            add(to: sizes, "\(size) pt", #selector(selectSize(_:)), tag: size)
        }
        add(to: view, "放大字号", #selector(stepSize(_:)), key: "+", tag: 1)
        let equals = add(to: view, "放大字号", #selector(stepSize(_:)), key: "=", tag: 1)
        equals.isHidden = true
        equals.allowsKeyEquivalentWhenHidden = true
        add(to: view, "缩小字号", #selector(stepSize(_:)), key: "-", tag: -1)
        add(to: view, "恢复默认字号", #selector(selectSize(_:)), key: "0", tag: Self.defaultSize)
    }

    @objc private func stepSize(_ item: NSMenuItem) { setSize(fonts.size + item.tag) }
    @objc private func selectSize(_ item: NSMenuItem) { setSize(item.tag) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(stepSize(_:)) { return Self.sizes.contains(fonts.size + item.tag) }
        if item.keyEquivalent.isEmpty { item.state = item.tag == fonts.size ? .on : .off }
        return true
    }
}
