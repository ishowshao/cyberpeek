import AppKit

final class SearchControls: NSView, NSSearchFieldDelegate {
    let query = NSSearchField()
    var onChange: (() -> Void)?

    private let caseMenu = NSPopUpButton()
    private let wholeWord = NSButton(title: "全词", target: nil, action: nil)
    private let regex = NSButton(title: ".*", target: nil, action: nil)
    private let scopeButton = NSButton(title: "范围", target: nil, action: nil)
    private let details = stack([], vertical: true, spacing: 5)
    private let types = NSTextField(), include = NSTextField(), exclude = NSTextField()
    private let presetButtons = ["md", "py", "ts"].map { NSButton(title: "." + $0, target: nil, action: nil) }
    private let folderLabel = label("", 11)
    private let summary = label("", 10, color: Palette.blue)
    private lazy var clear = ActionButton(icon: "xmark.circle.fill", tip: "清除搜索范围", size: 12) { [weak self] in
        self?.clearScope()
    }
    private var folderRow = NSView()
    private var directory: String?

    var options: SearchOptions {
        var value = SearchOptions()
        value.caseMode = SearchOptions.CaseMode.allCases[caseMenu.indexOfSelectedItem]
        value.wholeWord = wholeWord.state == .on
        value.regex = regex.state == .on
        value.directory = directory
        let separators = CharacterSet(charactersIn: ",，;；/").union(.whitespacesAndNewlines)
        for token in types.stringValue.components(separatedBy: separators) where !token.isEmpty {
            var ext = token.lowercased()
            if ext.hasPrefix("*.") { ext.removeFirst(2) }
            else if ext.hasPrefix(".") { ext.removeFirst() }
            if !value.extensions.contains(ext) { value.extensions.append(ext) }
        }
        value.includes = patterns(in: include)
        value.excludes = patterns(in: exclude)
        return value
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        query.placeholderString = "搜索工作区"
        query.sendsSearchStringImmediately = true
        query.delegate = self

        caseMenu.addItems(withTitles: SearchOptions.CaseMode.allCases.map { "Aa " + $0.rawValue })
        caseMenu.controlSize = .small
        caseMenu.font = .systemFont(ofSize: 11)
        caseMenu.toolTip = "大小写匹配：智能模式在搜索词含有大写字母时区分大小写"
        caseMenu.setAccessibilityLabel("大小写匹配")
        caseMenu.target = self
        caseMenu.action = #selector(changed)
        configureToggle(wholeWord, tip: "全词匹配", action: #selector(changed))
        configureToggle(regex, tip: "正则表达式", action: #selector(changed))
        configureToggle(scopeButton, tip: "搜索范围", action: #selector(toggleDetails))
        query.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let searchRow = stack([query, scopeButton, clear], spacing: 4)
        let modes = stack([caseMenu, wholeWord, regex, NSView()], spacing: 2)

        let presets = stack([label("类型", 11), NSView()], spacing: 2)
        for button in presetButtons {
            configureToggle(button, tip: "搜索 " + button.title + " 文件", action: #selector(toggleType(_:)))
            presets.addArrangedSubview(button)
        }
        configure(types, name: "文件扩展名", hint: "例如 .md, .py, .ts", tip: "可输入任意扩展名，多个用逗号或空格分隔")
        configure(include, name: "包含文件", hint: "例如 Sources/**", tip: "匹配工作区相对路径，多个通配模式用分号分隔")
        configure(exclude, name: "排除文件", hint: "例如 Tests/**", tip: "匹配工作区相对路径，多个通配模式用分号分隔")
        let clearFolder = ActionButton(icon: "xmark", tip: "移除目录限制", size: 10) { [weak self] in self?.setDirectory(nil) }
        folderRow = stack([label("目录", 11), folderLabel, NSView(), clearFolder], spacing: 4)
        for row in [folderRow, presets, types, patternRow("包含", include), patternRow("排除", exclude)] {
            details.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        }
        let column = stack([searchRow, modes, details, summary], vertical: true, spacing: 5)
        place(column, inset: 7)
        for row in [searchRow, modes, details, summary] {
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        details.isHidden = true
        updateScope()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureToggle(_ button: NSButton, tip: String, action: Selector) {
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.target = self
        button.action = action
    }

    private func configure(_ field: NSTextField, name: String, hint: String, tip: String) {
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11)
        field.placeholderString = hint
        field.toolTip = tip
        field.setAccessibilityLabel(name)
        field.delegate = self
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func patternRow(_ title: String, _ field: NSTextField) -> NSView {
        stack([label(title, 11), field], spacing: 6)
    }

    private func patterns(in field: NSTextField) -> [String] {
        field.stringValue.components(separatedBy: CharacterSet(charactersIn: ";；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    func reset() {
        query.stringValue = ""
        caseMenu.selectItem(at: 0)
        wholeWord.state = .off
        regex.state = .off
        scopeButton.state = .off
        details.isHidden = true
        clearScope(notify: false)
    }

    func setDirectory(_ path: String?) {
        directory = path
        changed()
    }

    private func clearScope(notify: Bool = true) {
        directory = nil
        types.stringValue = ""
        include.stringValue = ""
        exclude.stringValue = ""
        updateScope()
        if notify { onChange?() }
    }

    @objc private func toggleType(_ sender: NSButton) {
        let ext = String(sender.title.dropFirst())
        var selected = options.extensions
        if sender.state == .on { selected.append(ext) }
        else { selected.removeAll { $0 == ext } }
        types.stringValue = selected.map { "." + $0 }.joined(separator: ", ")
        changed()
    }

    @objc private func toggleDetails() {
        details.isHidden = scopeButton.state != .on
        updateScope()
    }

    private func updateScope() {
        let value = options
        folderLabel.stringValue = directory ?? ""
        folderLabel.toolTip = directory
        folderRow.isHidden = directory == nil
        for button in presetButtons {
            button.state = value.extensions.contains(String(button.title.dropFirst())) ? .on : .off
        }
        var parts = [String]()
        if let directory { parts.append(directory + "/") }
        if !value.extensions.isEmpty { parts.append(value.extensions.map { "." + $0 }.joined(separator: ", ")) }
        if !value.includes.isEmpty { parts.append("包含 " + value.includes.joined(separator: "; ")) }
        if !value.excludes.isEmpty { parts.append("排除 " + value.excludes.joined(separator: "; ")) }
        summary.stringValue = parts.joined(separator: " · ")
        summary.toolTip = summary.stringValue
        summary.isHidden = parts.isEmpty || !details.isHidden
        clear.isHidden = parts.isEmpty
        scopeButton.contentTintColor = parts.isEmpty ? nil : Palette.blue
    }

    @objc private func changed() {
        updateScope()
        onChange?()
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === query { onChange?() }
        else { changed() }
    }
}
