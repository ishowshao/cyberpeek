import AppKit

enum Section: String { case files = "资源管理器", search = "搜索", git = "源代码管理" }

final class SideNode {
    enum Role {
        case directory(URL), file(URL), group, hit(SearchHit), change(Change), commit(Commit), message
    }
    let name: String, key: String
    let role: Role
    var children: [SideNode]?
    init(_ name: String, _ key: String, _ role: Role, children: [SideNode]? = nil) {
        self.name = name; self.key = key; self.role = role; self.children = children
    }
    var expandable: Bool {
        switch role { case .directory,.group,.commit: return true; default: return false }
    }
    func items() -> [SideNode] {
        if let children { return children }
        guard case let .directory(url) = role else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey,.isSymbolicLinkKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))) ?? []
        let nodes: [(Bool,SideNode)] = urls.compactMap { child in
            let name = child.lastPathComponent
            guard ![".git",".DS_Store",".vendor",".build","DerivedData"].contains(name) else { return nil }
            let values = try? child.resourceValues(forKeys: keys)
            let folder = values?.isDirectory == true && values?.isSymbolicLink != true
            return (folder, SideNode(name,child.path,folder ? .directory(child) : .file(child)))
        }
        children = nodes.sorted { $0.0 == $1.0 ? $0.1.name.localizedStandardCompare($1.1.name) == .orderedAscending : $0.0 }.map(\.1)
        return children ?? []
    }
}

private final class FileOutline: NSOutlineView {
    var activateSelection: (() -> Void)?
    var onCopyRelativePath: ((URL) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let node = item(atRow: row) as? SideNode else { return nil }
        let url: URL
        switch node.role {
        case let .file(file), let .directory(file): url = file
        default: return nil
        }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "复制相对路径", action: #selector(copyPath(_:)), keyEquivalent: "")
        item.target = self
        item.image = symbol("doc.on.doc", size: 13)
        item.representedObject = url
        return menu
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onCopyRelativePath?(url) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { activateSelection?() }
        else { super.keyDown(with:event) }
    }
}

final class Sidebar: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    let view = NSView(), query = NSSearchField()
    private let outline = FileOutline()
    let header = label("资源管理器", 12, weight: .semibold), count = label("",10,color: Palette.muted)
    var onOpen: ((SideNode, Bool) -> Void)?
    var onCopyRelativePath: ((URL) -> Void)? {
        didSet { outline.onCopyRelativePath = onCopyRelativePath }
    }
    var onQuery: ((String) -> Void)?
    var onCommit: ((SideNode, Commit) -> Void)?
    var onFolder: (() -> Void)?
    var onRefresh: (() -> Void)?
    private(set) var section = Section.files
    var folder: URL?
    var git: GitState?
    var gitMessage = "正在读取仓库…"
    var hits: [SearchHit] = []
    var searchInfo = ""
    private var roots: [SideNode] = []
    private var states: [Section: Set<String>] = [:]
    private var reloading = false
    private var commitCache: [String:[SideNode]] = [:]
    private let controls = NSView(), searchBox = NSView()
    private var refresh: ActionButton!
    override init() {
        super.init()
        view.fill(Palette.sidebar)
        refresh = ActionButton(icon: "arrow.clockwise", tip: "刷新") { [weak self] in self?.onRefresh?() }
        let folderButton = ActionButton(icon: "folder.badge.plus", tip: "打开文件夹…") { [weak self] in self?.onFolder?() }
        let heading = stack([header, NSView(), folderButton, refresh], spacing: 9)
        controls.place(heading, inset: 9)
        query.placeholderString = "搜索工作区"; query.delegate = self
        query.sendsSearchStringImmediately = true
        searchBox.place(query, inset: 7)
        outline.activateSelection = { [weak self] in self?.activate(pin:true, keyboard:true) }
        configureTable(outline); outline.outlineTableColumn = outline.tableColumns.first
        outline.indentationPerLevel = 11; outline.indentationMarkerFollowsCell = false
        outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.action = #selector(click); outline.doubleAction = #selector(doubleClick)
        let scroller = resultScroll(outline)
        let foot = NSView()
        foot.place(count,inset: 6)
        let column = stack([controls,searchBox,scroller,foot], vertical: true)
        view.place(column); controls.height(39); searchBox.height(38); foot.height(26)
        for child in [controls,searchBox,scroller,foot] { child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        searchBox.isHidden = true
    }
    func reset(_ url: URL) {
        folder = url; git = nil; gitMessage = "正在读取仓库…"; query.stringValue = ""; hits = []; searchInfo = ""
        states = [:]; roots = []; commitCache = [:]
        switchTo(.files)
    }
    func switchTo(_ next: Section) {
        remember()
        section = next; roots = []; header.stringValue = section.rawValue
        searchBox.isHidden = section != .search
        reload(rememberCurrent: false)
    }
    private func remember() {
        guard !roots.isEmpty else { return }
        states[section] = Set((0..<outline.numberOfRows).compactMap { row in
            guard let node = outline.item(atRow: row) as? SideNode, outline.isItemExpanded(node) else { return nil }
            return node.key
        })
    }
    func reload(rememberCurrent: Bool = true) {
        if rememberCurrent { remember() }
        let selected = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? SideNode)?.key : nil
        reloading = true
        switch section {
        case .files:
            roots = folder.map { [SideNode($0.lastPathComponent,$0.path,.directory($0))] } ?? []
            count.stringValue = ""
        case .git:
            roots = []
            if let git {
                for area in [Change.Area.staged,.working,.untracked] {
                    let changes = git.changes.filter { $0.area == area }
                    if !changes.isEmpty {
                        roots.append(SideNode("\(area.rawValue)  ·  \(changes.count)",area.rawValue,.group,children:changes.map(changeNode)))
                    }
                }
                if git.changes.isEmpty { roots.append(SideNode("工作区干净","clean",.message)) }
                if !git.commits.isEmpty {
                    roots.append(SideNode("最近提交","history",.group,children:git.commits.map {
                        SideNode($0.title,$0.id,.commit($0),children:commitCache[$0.id])
                    }))
                }
                count.stringValue = git.branch
            } else { roots = [SideNode(gitMessage,"git-message",.message)]; count.stringValue = "" }
        case .search:
            let groups = Dictionary(grouping: hits, by: \.path)
            roots = groups.keys.sorted().map { path in
                SideNode(path,path,.group,children:groups[path]!.map { SideNode("\($0.line)   \($0.excerpt)","\(path):\($0.line):\($0.column)",.hit($0)) })
            }
            count.stringValue = searchInfo
        }
        outline.reloadData()
        func expand(_ nodes: [SideNode], depth: Int) {
            for node in nodes where node.expandable {
                let initiallyOpen = depth == 0 && (section != .git || node.key != "history")
                let open = states[section]?.contains(node.key) ?? initiallyOpen
                if open || (section == .search && depth == 0 && groupsNew.contains(node.key)) {
                    outline.expandItem(node); expand(node.items(),depth:depth+1)
                }
            }
        }
        let groupsNew = Set(roots.map(\.key)).subtracting(previousSearchGroups)
        if section == .search { previousSearchGroups = Set(roots.map(\.key)) }
        expand(roots,depth:0)
        if let selected, let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow:$0) as? SideNode)?.key == selected }) {
            outline.selectRowIndexes(IndexSet(integer: row),byExtendingSelection:false)
        }
        reloading = false
    }
    func reveal(_ url: URL) {
        guard section == .files, let top = roots.first, url.path.hasPrefix(top.key + "/") else { return }
        var node = top
        for component in url.path.dropFirst(top.key.count+1).split(separator:"/") {
            outline.expandItem(node)
            guard let child = node.items().first(where:{ $0.name == component }) else { return }
            node = child
        }
        let row = outline.row(forItem:node)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
            outline.scrollRowToVisible(row)
        }
    }
    private var previousSearchGroups = Set<String>()
    private func changeNode(_ change: Change) -> SideNode {
        SideNode(change.path,"\(change.area.rawValue)|\(change.revision ?? "")|\(change.path)",.change(change))
    }
    func loadedCommit(_ id: String, changes: [Change]) {
        commitCache[id] = changes.map(changeNode)
        if section == .git { reload() }
    }
    func controlTextDidChange(_ obj: Notification) { onQuery?(query.stringValue) }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? SideNode)?.items().count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? SideNode)?.items() ?? roots)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? SideNode)?.expandable == true }
    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? SideNode, case let .commit(commit) = node.role, node.children == nil { onCommit?(node,commit) }
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SideNode else { return nil }
        switch node.role {
        case .directory: return rowView(node.name,icon:"folder",color:Palette.muted)
        case .file: let icon = kindIcon(node.name); return rowView(node.name,icon:icon.0,color:icon.1)
        case .group: return rowView(node.name,heading:true)
        case .message: return rowView(node.name,color:Palette.muted)
        case .hit: return rowView(node.name)
        case let .change(c): return rowView(node.name,icon:"doc",color:c.flag == "D" ? Palette.red : Palette.green,detail:c.flag)
        case let .commit(c): return rowView(c.title, icon:"clock", color:Palette.blue,detail:String(c.id.prefix(7)))
        }
    }
    @objc func click() { activate(pin:false) }
    @objc func doubleClick() { activate(pin:true) }
    private func activate(pin: Bool, keyboard: Bool = false) {
        let row = !keyboard && outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard !reloading, row >= 0, let node = outline.item(atRow: row) as? SideNode else { return }
        if node.expandable {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else { onOpen?(node,pin) }
    }
}
