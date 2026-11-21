import AppKit

final class QuickOpen: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private let panel = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 560,height: 308), styleMask: [.titled,.fullSizeContentView], backing: .buffered, defer: false)
    private let input = NSTextField(), table = NSTableView()
    private var results = [String]()
    var folder: URL?
    var isVisible: Bool { panel.isVisible }
    var isLoading = false {
        didSet { input.placeholderString = isLoading ? "正在索引文件，可继续输入…" : "按名称搜索文件，可附加 :行号" }
    }
    var paths = [String]() { didSet { if panel.isVisible { filter() } } }
    var onChoose: ((String,Int?) -> Void)?
    private var targetLine: Int?
    private var version = 0, displayedVersion = -1
    private var chooseWhenReady = false
    private var pending: DispatchWorkItem?
    override init() {
        super.init()
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named:.darkAqua); panel.isMovable = false
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = true; panel.delegate = self
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        input.placeholderString = "按名称搜索文件，可附加 :行号"
        input.font = .systemFont(ofSize: 15); input.focusRingType = .none
        input.delegate = self; input.bezelStyle = .roundedBezel
        configureTable(table); table.rowHeight = 27; table.delegate = self; table.dataSource = self
        table.target = self; table.action = #selector(selectResult)
        let scrolling = resultScroll(table)
        let column = stack([input,scrolling],vertical:true,spacing:7)
        let content = NSView(); content.fill(Palette.chrome); content.place(column,inset:9)
        input.height(31); input.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        scrolling.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        panel.contentView = content
    }
    func show(in window: NSWindow) {
        if panel.isVisible { dismiss(); return }
        chooseWhenReady = false
        input.stringValue = ""
        let f = window.frame
        panel.setFrameTopLeftPoint(NSPoint(x: f.midX - panel.frame.width/2, y: f.maxY - 39))
        window.addChildWindow(panel,ordered:.above)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(input); filter()
    }
    func dismiss() {
        chooseWhenReady = false
        let owner = panel.parent
        owner?.removeChildWindow(panel); panel.orderOut(nil); owner?.makeKey()
    }
    func windowDidResignKey(_ notification: Notification) {
        if panel.parent != nil { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
    }
    func controlTextDidChange(_ obj: Notification) { filter() }
    private func filter() {
        version += 1; let token = version, list = paths
        var q = input.stringValue; targetLine = nil
        if let colon = q.lastIndex(of:":"), let n = Int(q[q.index(after:colon)...]), n > 0 {
            targetLine = n; q = String(q[..<colon])
        }
        if let folder, q.hasPrefix(folder.path + "/") { q = String(q.dropFirst(folder.path.count+1)) }
        pending?.cancel()
        let term = q
        let item = DispatchWorkItem { [weak self] in
            let matches = WorkspaceSearch.ranked(list,query:term)
            DispatchQueue.main.async {
                guard let self, self.version == token else { return }
                self.displayedVersion = token
                self.results = matches; self.table.reloadData()
                if !matches.isEmpty { self.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); self.table.scrollRowToVisible(0) }
                if self.chooseWhenReady, !self.isLoading { self.chooseWhenReady = false; self.selectResult() }
            }
        }
        pending = item; DispatchQueue.global(qos:.userInitiated).async(execute:item)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let path = results[row], icon = kindIcon(path)
        return rowView((path as NSString).lastPathComponent,icon:icon.0,color:icon.1,detail:(path as NSString).deletingLastPathComponent)
    }
    @objc private func selectResult() {
        guard panel.isVisible else { return }
        guard displayedVersion == version, !(isLoading && results.isEmpty) else { chooseWhenReady = true; return }
        let index = table.selectedRow
        guard results.indices.contains(index) else { return }
        let result = results[index], line = targetLine
        dismiss(); onChoose?(result,line)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)): selectResult()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !results.isEmpty else { return true }
            let delta = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let next = max(0,min(results.count-1,table.selectedRow+delta))
            table.selectRowIndexes(IndexSet(integer:next),byExtendingSelection:false); table.scrollRowToVisible(next)
        default: return false
        }
        return true
    }
}
