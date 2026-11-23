import AppKit

enum Section: String { case files = "资源管理器", search = "搜索", git = "源代码管理" }

final class SideNode {
    enum Role {
        case directory(URL), file(URL, deletion: Change? = nil), group, repository(String), hit(SearchHit), change(URL, Change), commit(URL, Commit), message
        case untrackedDirectory(URL, URL), changeRange(URL, [Change], Range<Int>, Bool)
    }
    let name: String, key: String
    let role: Role
    var children: [SideNode]?
    init(_ name: String, _ key: String, _ role: Role, children: [SideNode]? = nil) {
        self.name = name; self.key = key; self.role = role; self.children = children
    }
    var expandable: Bool {
        switch role { case .directory,.untrackedDirectory,.changeRange,.group,.repository,.commit: return true; default: return false }
    }
    func items(in tree: GitFileTree?) -> [SideNode] {
        if let children { return children }
        switch role {
        case let .untrackedDirectory(repo, url):
            if let changes = tree?.untrackedChildren[url.path] {
                children = Self.changeNodes(changes, repo: repo, shortNames: true)
            } else {
                children = [SideNode("正在读取…", key + "|loading", .message)]
            }
            return children ?? []
        case let .changeRange(repo, changes, range, shortNames):
            children = Self.changeNodes(changes, repo: repo, range: range, shortNames: shortNames)
            return children ?? []
        default: break
        }
        guard case let .directory(url) = role else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey,.isSymbolicLinkKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))) ?? []
        let hidden: Set<String> = [".git",".DS_Store",".vendor",".build","DerivedData"]
        var nodes: [SideNode] = urls.compactMap { child in
            guard !hidden.contains(child.lastPathComponent) else { return nil }
            let values = try? child.resourceValues(forKeys: keys)
            let folder = values?.isDirectory == true && values?.isSymbolicLink != true
            return SideNode(child.lastPathComponent,child.path,folder ? .directory(child) : .file(child))
        }
        if let tree, let deleted = tree.deletedChildren[url.path] {
            let missing = deleted.subtracting(nodes.map(\.name)).subtracting(hidden)
            for name in missing {
                let child = url.appendingPathComponent(name, isDirectory: false)
                if let deletion = tree.changes[child.path]?.last(where: { $0.flag == "D" }) {
                    nodes.append(SideNode(name,child.path,.file(child, deletion: deletion)))
                } else {
                    nodes.append(SideNode(name,child.path,.directory(child)))
                }
            }
        }
        nodes.sort { $0.expandable == $1.expandable ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.expandable }
        children = nodes
        return nodes
    }

    static func changeNodes(_ changes: [Change], repo: URL, range: Range<Int>? = nil, shortNames: Bool = false) -> [SideNode] {
        let range = range ?? changes.indices
        // Keep even a flat directory with thousands of siblings out of a single outline expansion.
        let limit = 200
        if range.count > limit {
            var size = limit
            while (range.count - 1) / size >= limit { size *= limit }
            return stride(from: range.lowerBound, to: range.upperBound, by: size).map { start in
                let end = min(start + size, range.upperBound)
                let first = changes[start], last = changes[end-1]
                let title = "\((first.path as NSString).lastPathComponent) … \((last.path as NSString).lastPathComponent)"
                return SideNode(title, "\(repo.path)|\(first.area.rawValue)|\(first.revision ?? "")|range|\(first.path)|\(size)",
                                .changeRange(repo, changes, start..<end, shortNames))
            }
        }
        return changes[range].map { change in
            let name = shortNames ? (change.path as NSString).lastPathComponent : change.path
            let key = "\(repo.path)|\(change.area.rawValue)|\(change.revision ?? "")|\(change.path)"
            if change.isUntrackedDirectory {
                return SideNode(name, key, .untrackedDirectory(repo, repo.appendingPathComponent(change.path, isDirectory: true)))
            }
            return SideNode(name, key, .change(repo, change))
        }
    }
}

private final class FileOutline: NSOutlineView {
    var activateSelection: (() -> Void)?
    var onCopyRelativePath: ((URL) -> Void)?
    var onTrashFile: ((URL) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let node = item(atRow: row) as? SideNode else { return nil }
        let url: URL
        switch node.role {
        case let .file(file, _), let .directory(file): url = file
        default: return nil
        }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "复制相对路径", action: #selector(copyPath(_:)), keyEquivalent: "")
        item.target = self
        item.image = symbol("doc.on.doc", size: 13)
        item.representedObject = url
        if case .file(_, deletion: nil) = node.role {
            menu.addItem(.separator())
            let trash = menu.addItem(withTitle: "移到废纸篓", action: #selector(trashFile(_:)), keyEquivalent: "")
            trash.target = self
            trash.image = symbol("trash", size: 13)
            trash.representedObject = url
        }
        return menu
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onCopyRelativePath?(url) }
    }
    @objc private func trashFile(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onTrashFile?(url) }
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
    var onTrashFile: ((URL) -> Void)? {
        didSet { outline.onTrashFile = onTrashFile }
    }
    var onQuery: ((String) -> Void)?
    var onCommit: ((URL, Commit) -> Void)?
    var onFolder: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onExpandDirectory: (() -> Void)?
    private(set) var section = Section.files
    var folder: URL?
    var git: WorkspaceGit?
    var gitMessage = "正在读取仓库…"
    var hits: [SearchHit] = []
    var searchInfo = ""
    private var roots: [SideNode] = []
    private var states: [Section: Set<String>] = [:]
    private var gitExpansion = [String: Bool]()
    private var reloading = false
    private var commitCache: [String:[SideNode]] = [:]
    private let controls = NSView(), searchBox = NSView()
    private lazy var collapseButton = ActionButton(icon: "rectangle.stack.badge.minus", tip: "折叠所有文件夹") { [weak self] in
        self?.collapseFolders()
    }
    override init() {
        super.init()
        view.fill(Palette.sidebar)
        let refresh = ActionButton(icon: "arrow.clockwise", tip: "刷新") { [weak self] in self?.onRefresh?() }
        let folderButton = ActionButton(icon: "folder.badge.plus", tip: "打开文件夹…") { [weak self] in self?.onFolder?() }
        collapseButton.isHidden = true
        let heading = stack([header, NSView(), folderButton, refresh, collapseButton], spacing: 9)
        controls.place(heading, inset: 9)
        query.placeholderString = "搜索工作区"; query.delegate = self
        query.sendsSearchStringImmediately = true
        searchBox.place(query, inset: 7)
        outline.activateSelection = { [weak self] in self?.activate(pin:true, keyboard:true) }
        configureTable(outline); outline.outlineTableColumn = outline.tableColumns.first
        outline.autoresizesOutlineColumn = false
        outline.autoresizingMask = [.width]
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
        states = [:]; gitExpansion = [:]; roots = []; commitCache = [:]
        switchTo(.files)
    }
    func switchTo(_ next: Section) {
        remember()
        section = next; roots = []; header.stringValue = section.rawValue
        searchBox.isHidden = section != .search
        collapseButton.isHidden = section != .files || folder == nil
        reload(rememberCurrent: false)
    }
    private func collapseFolders() {
        guard section == .files, let root = roots.first else { return }
        states[.files] = outline.isItemExpanded(root) ? [root.key] : []
        reload(rememberCurrent: false)
    }
    private func remember() {
        guard !roots.isEmpty else { return }
        if section == .git {
            for row in 0..<outline.numberOfRows {
                if let node = outline.item(atRow: row) as? SideNode, node.expandable {
                    gitExpansion[node.key] = outline.isItemExpanded(node)
                }
            }
            return
        }
        states[section] = Set((0..<outline.numberOfRows).compactMap { row in
            guard let node = outline.item(atRow: row) as? SideNode, outline.isItemExpanded(node) else { return nil }
            return node.key
        })
    }
    private func visibleRowOffsets(in rect: NSRect) -> [String: CGFloat] {
        var offsets = [String: CGFloat]()
        for row in Range(outline.rows(in: rect)) ?? 0..<0 {
            if let node = outline.item(atRow: row) as? SideNode {
                offsets[node.key] = outline.rect(ofRow: row).minY - rect.minY
            }
        }
        return offsets
    }
    func reload(rememberCurrent: Bool = true) {
        if rememberCurrent { remember() }
        let viewport = outline.visibleRect
        let offsets = rememberCurrent && section == .files ? visibleRowOffsets(in: viewport) : [:]
        let selected = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? SideNode)?.key : nil
        reloading = true
        switch section {
        case .files:
            roots = folder.map { [SideNode($0.lastPathComponent,$0.path,.directory($0))] } ?? []
            count.stringValue = ""
        case .git:
            roots = []
            count.stringValue = ""
            if let git, let folder {
                for state in git.repositories {
                    let groups = gitGroups(for: state)
                    if state.contains(folder.path) {
                        roots += groups
                        count.stringValue = state.branch
                    } else {
                        roots.append(SideNode(workspaceRelativePath(of: state.repo, from: folder), state.repo.path,
                                              .repository(state.branch), children: groups))
                    }
                }
                for error in git.errors { roots.append(SideNode(error, error, .message)) }
                if roots.isEmpty { roots = [SideNode("当前文件夹没有 Git 仓库", "git-message", .message)] }
            } else { roots = [SideNode(gitMessage, "git-message", .message)] }
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
                let open: Bool
                if section == .git {
                    switch node.role {
                    case .repository: open = gitExpansion[node.key] ?? true
                    case .group: open = gitExpansion[node.key] ?? !node.key.hasSuffix("|history")
                    default: open = gitExpansion[node.key] ?? false
                    }
                } else { open = states[section]?.contains(node.key) ?? (depth == 0) }
                if open || (section == .search && depth == 0 && groupsNew.contains(node.key)) {
                    outline.expandItem(node); expand(node.items(in: git?.fileTree),depth:depth+1)
                }
            }
        }
        let groupsNew = Set(roots.map(\.key)).subtracting(previousSearchGroups)
        if section == .search { previousSearchGroups = Set(roots.map(\.key)) }
        expand(roots,depth:0)
        if let selected, let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow:$0) as? SideNode)?.key == selected }) {
            outline.selectRowIndexes(IndexSet(integer: row),byExtendingSelection:false)
        }
        if !offsets.isEmpty {
            var origin = viewport.origin
            // Keep the first surviving visible file or folder at its previous height on screen.
            for row in 0..<outline.numberOfRows {
                guard let node = outline.item(atRow: row) as? SideNode, let offset = offsets[node.key] else { continue }
                origin.y = outline.rect(ofRow: row).minY - offset
                break
            }
            outline.scroll(origin)
        }
        reloading = false
    }
    func reveal(_ url: URL, centerSelectedRow: Bool = false) {
        guard section == .files, let top = roots.first, url.path.hasPrefix(top.key + "/") else { return }
        var node = top
        for component in url.path.dropFirst(top.key.count+1).split(separator:"/") {
            outline.expandItem(node)
            guard let child = node.items(in: git?.fileTree).first(where:{ $0.name == component }) else { return }
            node = child
        }
        let row = outline.row(forItem:node)
        guard row >= 0 else { return }
        if row == outline.selectedRow && !centerSelectedRow {
            outline.scrollRowToVisible(row)
            return
        }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard let scroll = outline.enclosingScrollView else { return }
        outline.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        var viewport = clip.bounds
        let rowRect = clip.convert(outline.rect(ofRow: row), from: outline)
        viewport.origin.y = rowRect.midY - viewport.height / 2
        clip.scroll(to: clip.constrainBoundsRect(viewport).origin)
        scroll.reflectScrolledClipView(clip)
    }
    var expandedDirectoryPaths: Set<String> {
        Set((0..<outline.numberOfRows).compactMap { row in
            guard let node = outline.item(atRow: row) as? SideNode, outline.isItemExpanded(node) else { return nil }
            switch node.role {
            case let .directory(url), let .untrackedDirectory(_, url): return url.path
            default: return nil
            }
        })
    }
    private var previousSearchGroups = Set<String>()
    private func gitGroups(for state: GitState) -> [SideNode] {
        let repo = state.repo
        var groups = [SideNode]()
        for area in [Change.Area.staged, .working, .untracked] {
            let changes = state.changes.filter { $0.area == area }
            if !changes.isEmpty {
                let unit = changes.contains(where: \.isUntrackedDirectory) ? " 项" : ""
                groups.append(SideNode("\(area.rawValue)  ·  \(changes.count)\(unit)", "\(repo.path)|\(area.rawValue)", .group,
                                       children: SideNode.changeNodes(changes, repo: repo)))
            }
        }
        if state.changes.isEmpty { groups.append(SideNode("工作区干净", "\(repo.path)|clean", .message)) }
        if !state.commits.isEmpty {
            let commits = state.commits.map { commit in
                let key = "\(repo.path)|\(commit.id)"
                return SideNode(commit.title, key, .commit(repo, commit), children: commitCache[key])
            }
            groups.append(SideNode("最近提交", "\(repo.path)|history", .group, children: commits))
        }
        return groups
    }

    func loadedCommit(_ id: String, repo: URL, changes: [Change]) {
        commitCache["\(repo.path)|\(id)"] = SideNode.changeNodes(changes, repo: repo)
        if section == .git { reload() }
    }
    func controlTextDidChange(_ obj: Notification) { onQuery?(query.stringValue) }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? SideNode)?.items(in: git?.fileTree).count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? SideNode)?.items(in: git?.fileTree) ?? roots)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? SideNode)?.expandable == true }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SideNode else { return }
        switch node.role {
        case let .commit(repo, commit) where node.children == nil: onCommit?(repo, commit)
        case let .directory(url), let .untrackedDirectory(_, url):
            if let tree = git?.fileTree, tree.untrackedChildren[url.path] == nil, tree.coversUntrackedDirectory(url.path) {
                onExpandDirectory?()
            }
        default: break
        }
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SideNode else { return nil }
        switch node.role {
        case .directory, .file:
            let icon = node.expandable ? ("folder", Palette.muted) : kindIcon(node.name)
            let changes = git?.fileTree.changes[node.key] ?? []
            if let change = changes.last {
                let flags = changes.map(\.flag).joined()
                let color: NSColor
                switch change.flag {
                case "A": color = Palette.green
                case "U": color = change.area == .untracked ? Palette.green : Palette.red
                case "D": color = Palette.red
                default: color = Palette.blue
                }
                let row = rowView(node.name, icon: icon.0, color: icon.1, detail: flags, detailColor: color)
                row.toolTip = ([node.name] + changes.map { "\($0.area.rawValue) \($0.flag)" }).joined(separator: " · ")
                return row
            }
            let changed = git?.fileTree.changedDirectories.contains(node.key) == true
            let row = rowView(node.name, icon: icon.0, color: icon.1, detail: changed ? "•" : nil, detailColor: Palette.blue)
            if changed { row.toolTip = "\(node.name) · 包含 Git 变更" }
            return row
        case let .repository(branch): return rowView(node.name, icon: "folder", detail: branch, truncatesDetail: true)
        case .untrackedDirectory: return rowView(node.name, icon: "folder", detail: "U", detailColor: Palette.green)
        case .changeRange: return rowView(node.name, icon: "list.bullet", color: Palette.muted)
        case .group: return rowView(node.name,heading:true)
        case .message: return rowView(node.name,color:Palette.muted)
        case .hit: return rowView(node.name)
        case let .change(_, c): return rowView(node.name,icon:"doc",color:c.flag == "D" ? Palette.red : Palette.green,detail:c.flag)
        case let .commit(_, c): return rowView(c.title, icon:"clock", color:Palette.blue,detail:String(c.id.prefix(7)))
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
