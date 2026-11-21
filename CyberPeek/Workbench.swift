import AppKit

final class Workbench: NSObject, NSWindowDelegate, NSSplitViewDelegate {
    let window = NSWindow(contentRect: NSRect(x:0,y:0,width:1180,height:748), styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered,defer:false)
    let side = Sidebar(), quick = QuickOpen()
    let split = NSSplitView(), rail = NSView(), body = NSView(), editorHost = NSView()
    let tabs = NSStackView(), tabScroll = OverlayScrollView()
    let crumb = label("",11,color:Palette.muted), branch = label("",11), position = label("",11), format = label("",11)
    let statusMessage = label("",11,color:Palette.muted)
    let conflictBar = NSView(), crumbBar = NSView()
    private lazy var previousChange = ActionButton(icon: "arrow.up", tip: "上一个 Git 变更", size: 12) { [weak self] in
        self?.current?.navigateChange(forward: false)
    }
    private lazy var nextChange = ActionButton(icon: "arrow.down", tip: "下一个 Git 变更", size: 12) { [weak self] in
        self?.current?.navigateChange(forward: true)
    }
    let pathPasteboard: NSPasteboard
    var projectButton: ActionButton!
    var activity: [Section:(ActionButton,NSView)] = [:]
    var root: URL?, documents = [Editor](), current: Editor?
    var monitor: WorkspaceMonitor?, eventTask: DispatchWorkItem?
    private var gitJob: ShellJob?
    private var queuedGitPaths = Set<String>()
    private var fullGitRefreshQueued = false
    private var pendingEventPaths = Set<String>()
    private let branchIcon = NSImageView(image: symbol("point.3.connected.trianglepath.dotted", size: 12) ?? NSImage())
    private struct LineComparison: Equatable {
        let document: ObjectIdentifier
        let revision: Int
        let repo: URL
        let head: String
        let path: String
    }
    private var lineComparison: LineComparison?
    private var lineJob: ShellJob?
    private var lineBaseline: GitLineBaseline?
    private let lineDiffQueue = DispatchQueue(label: "CyberPeek.gitLineDiff", qos: .utility)
    var queryJob: ShellJob?, indexJob: ShellJob?, queryVersion = 0, projectVersion = 0, loadVersion = 0
    var gitVersion = 0, diskVersion = 0
    private var toolbarDelegate: ToolbarItems!
    enum Target { case file(URL), patch(URL,Change), blob(URL,String,String) }
    struct Location { let target: Target; let line: Int; let column: Int }
    var targets: [String:Target] = [:], back = [Location](), forward = [Location]()
    var welcome: NSView!
    init(pathPasteboard: NSPasteboard = .general) {
        self.pathPasteboard = pathPasteboard
        super.init()
        window.delegate = self; window.minSize = NSSize(width:740,height:420)
        window.title = "CyberPeek"; window.titleVisibility = .hidden; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named:.darkAqua)
        window.backgroundColor = Palette.canvas; window.toolbarStyle = .unifiedCompact
        setupToolbar(); build()
        side.onFolder = { [weak self] in self?.chooseFolder() }
        side.onCopyRelativePath = { [weak self] url in self?.copyRelativePath(of: url) }
        side.onRefresh = { [weak self] in self?.refresh() }
        side.onQuery = { [weak self] in self?.search($0) }
        side.onOpen = { [weak self] node,pin in self?.openNode(node,pin:pin) }
        side.onCommit = { [weak self] repo, commit in self?.loadCommit(commit, repo: repo) }
        quick.onChoose = { [weak self] path,line in
            guard let self, let root = self.root else { return }
            self.open(.file(root.appendingPathComponent(path)),line:line,pin:true)
        }
        selectSection(.files); show(nil)
        window.center()
    }
    private func setupToolbar() {
        projectButton = ActionButton("  打开文件夹",icon:"magnifyingglass",tip:"快速打开文件  ⌘P",size:12) { [weak self] in self?.quickOpen() }
        projectButton.font = .systemFont(ofSize:12); projectButton.contentTintColor = Palette.text
        projectButton.wantsLayer = true; projectButton.layer?.cornerRadius = 6
        projectButton.layer?.backgroundColor = Palette.line.cgColor; projectButton.width(260); projectButton.height(25)
        let previous = ActionButton(icon:"arrow.left",tip:"后退  ⌃−") { [weak self] in self?.navigate(backwards:true) }
        let next = ActionButton(icon:"arrow.right",tip:"前进  ⌃⇧−") { [weak self] in self?.navigate(backwards:false) }
        toolbarDelegate = ToolbarItems(views:["back":previous,"forward":next,"project":projectButton])
        let toolbar = NSToolbar(identifier:"WorkbenchToolbar"); toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly; toolbar.centeredItemIdentifier = .init("project")
        window.toolbar = toolbar
    }
    private func build() {
        let canvas = NSView(); window.contentView = canvas
        let footer = NSView(); footer.fill(Palette.chrome)
        branchIcon.contentTintColor = Palette.blue
        let info = stack([branchIcon,branch,statusMessage,NSView(),position,format],spacing:12)
        info.edgeInsets = .init(top:0,left:12,bottom:0,right:13); footer.place(info)
        let main = NSView()
        let vertical = stack([main,footer],vertical:true); canvas.place(vertical)
        for v in [main,footer] { v.widthAnchor.constraint(equalTo:vertical.widthAnchor).isActive = true }
        footer.height(24)
        rail.fill(Palette.rail)
        let railColumn = stack([],vertical:true)
        for (section,icon,tip) in [(Section.files,"doc.on.doc","资源管理器  ⇧⌘E"),(.search,"magnifyingglass","搜索  ⇧⌘F"),(.git,"arrow.triangle.branch","源代码管理  ⌃⇧G")] {
            let button = ActionButton(icon:icon,tip:tip,size:21) { [weak self] in self?.selectSection(section) }
            let holder = NSView(), indicator = NSView(); holder.place(button)
            holder.width(49); holder.height(49); indicator.fill(Palette.blue)
            indicator.translatesAutoresizingMaskIntoConstraints = false; holder.addSubview(indicator)
            NSLayoutConstraint.activate([indicator.leadingAnchor.constraint(equalTo:holder.leadingAnchor),indicator.topAnchor.constraint(equalTo:holder.topAnchor,constant:8),
                indicator.bottomAnchor.constraint(equalTo:holder.bottomAnchor,constant:-8),indicator.widthAnchor.constraint(equalToConstant:2)])
            railColumn.addArrangedSubview(holder); activity[section] = (button,indicator)
        }
        railColumn.translatesAutoresizingMaskIntoConstraints = false; rail.addSubview(railColumn)
        NSLayoutConstraint.activate([railColumn.leadingAnchor.constraint(equalTo:rail.leadingAnchor),railColumn.topAnchor.constraint(equalTo:rail.topAnchor,constant:5)])
        split.isVertical = true; split.dividerStyle = .thin; split.delegate = self
        split.addArrangedSubview(side.view); split.addArrangedSubview(body)
        side.view.setFrameSize(NSSize(width:260,height:600))
        split.setHoldingPriority(.defaultHigh,forSubviewAt:0)
        let row = stack([rail,split]); main.place(row); rail.width(49)
        for v in [rail,split] { v.heightAnchor.constraint(equalTo:row.heightAnchor).isActive = true }
        body.fill(Palette.canvas); editorHost.fill(Palette.canvas)
        tabs.orientation = .horizontal; tabs.spacing = 1; tabs.alignment = .centerY
        tabScroll.documentView = tabs; tabScroll.drawsBackground = true; tabScroll.backgroundColor = Palette.sidebar
        tabScroll.hasHorizontalScroller = true
        tabScroll.height(35)
        let copyPath = ActionButton(icon: "doc.on.doc", tip: "复制相对路径", size: 12) { [weak self] in
            guard let self, let url = self.breadcrumbURL else { return }
            self.copyRelativePath(of: url)
        }
        copyPath.width(24); copyPath.height(24)
        let breadcrumb = stack([crumb, copyPath], spacing: 3)
        breadcrumb.translatesAutoresizingMaskIntoConstraints = false
        crumbBar.addSubview(breadcrumb)
        let changeButtons = stack([previousChange, nextChange], spacing: 2)
        for button in [previousChange, nextChange] { button.width(24); button.height(24) }
        changeButtons.translatesAutoresizingMaskIntoConstraints = false
        crumbBar.addSubview(changeButtons)
        NSLayoutConstraint.activate([
            breadcrumb.leadingAnchor.constraint(equalTo: crumbBar.leadingAnchor, constant: 6),
            breadcrumb.trailingAnchor.constraint(lessThanOrEqualTo: changeButtons.leadingAnchor, constant: -6),
            changeButtons.trailingAnchor.constraint(equalTo: crumbBar.trailingAnchor, constant: -6),
            changeButtons.centerYAnchor.constraint(equalTo: crumbBar.centerYAnchor),
            breadcrumb.centerYAnchor.constraint(equalTo: crumbBar.centerYAnchor)
        ])
        crumbBar.height(28); crumbBar.fill(Palette.canvas)
        let compare = ActionButton("比较版本",tip:"比较磁盘版本和我的编辑") { [weak self] in self?.compareConflict() }
        compare.contentTintColor = Palette.blue
        let conflictRow = stack([label("磁盘文件已改变，你的编辑已保留。",12),compare,NSView()],spacing:10)
        conflictBar.place(conflictRow,inset:6); conflictBar.fill(Palette.rgb(0x41382b)); conflictBar.height(32)
        let area = stack([tabScroll,crumbBar,conflictBar,editorHost],vertical:true)
        body.place(area)
        for v in [tabScroll,crumbBar,conflictBar,editorHost] { v.widthAnchor.constraint(equalTo:area.widthAnchor).isActive = true }
        welcome = welcomeView()
        window.contentView?.layoutSubtreeIfNeeded()
        split.setPosition(260,ofDividerAt:0)
    }
    private func welcomeView() -> NSView {
        let container = NSView()
        let title = label("CyberPeek",33,color:Palette.text,weight:.medium)
        let open = ActionButton("  打开文件夹…",icon:"folder",tip:"打开文件夹  ⇧⌘O") { [weak self] in self?.chooseFolder() }
        open.contentTintColor = Palette.blue
        let jump = ActionButton("  快速打开文件",icon:"magnifyingglass",tip:"快速打开  ⌘P") { [weak self] in self?.quickOpen() }
        let search = ActionButton("  在项目中搜索",icon:"text.magnifyingglass",tip:"搜索  ⇧⌘F") { [weak self] in self?.selectSection(.search) }
        let lines = stack([title,stack([open,label("⇧⌘O",11,color:Palette.muted)],spacing:18),
                           stack([jump,label("⌘P",11,color:Palette.muted)],spacing:18),
                           stack([search,label("⇧⌘F",11,color:Palette.muted)],spacing:18)],vertical:true,spacing:16)
        container.addSubview(lines); lines.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([lines.centerXAnchor.constraint(equalTo:container.centerXAnchor),lines.centerYAnchor.constraint(equalTo:container.centerYAnchor,constant:-18)])
        return container
    }
    func selectSection(_ section: Section) {
        if side.view.isHidden { toggleSidebar() }
        for (key,pair) in activity {
            pair.0.contentTintColor = key == section ? Palette.text : Palette.muted; pair.1.isHidden = key != section
        }
        side.switchTo(section)
        if let current { side.reveal(current.url) }
        if section == .search { window.makeFirstResponder(side.query) }
        if section == .git { refreshGit() }
    }
    func toggleSidebar() { side.view.isHidden.toggle(); split.adjustSubviews(); if !side.view.isHidden { split.setPosition(260,ofDividerAt:0) } }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 170 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitView.bounds.width-300 }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "打开"
        panel.beginSheetModal(for:window) { [weak self] result in
            if result == .OK, let url = panel.url { self?.openFolder(url) }
        }
    }
    func quickOpen() { if root == nil { chooseFolder() } else { quick.show(in:window) } }
    func cancelWorkspaceJobs() {
        queryJob?.cancel(); indexJob?.cancel(); gitJob?.cancel(); eventTask?.cancel(); lineJob?.cancel()
        gitJob = nil
        queuedGitPaths.removeAll()
        fullGitRefreshQueued = false
        pendingEventPaths.removeAll()
        lineJob = nil
        lineComparison = nil
        lineBaseline = nil
    }
    func openFolder(_ url: URL, remember: Bool = true) {
        let folder = url.resolvingSymlinksInPath().standardizedFileURL
        guard folder.isFileURL, (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
        guard documents.allSatisfy({ confirmClosing($0) }) else { return }
        cancelWorkspaceJobs()
        projectVersion += 1; loadVersion += 1; queryVersion += 1
        root = folder; quick.folder = folder; documents = []; targets = [:]; back = []; forward = []; quick.paths = []
        side.reset(folder); selectSection(.files); show(nil)
        window.title = "\(url.lastPathComponent) — CyberPeek"; projectButton.title = "  \(url.lastPathComponent)"
        if remember { UserDefaults.standard.set(folder.path,forKey:"lastFolder") }
        monitor = WorkspaceMonitor(url:folder) { [weak self] paths in self?.scheduleRefresh(paths) }
        refresh()
    }
    private func scheduleRefresh(_ paths: [String]) {
        guard let root else { return }
        pendingEventPaths.formUnion(paths.isEmpty ? [root.path] : paths)
        eventTask?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let changed = self.pendingEventPaths
            self.pendingEventPaths.removeAll()
            self.refresh(changedPaths: changed)
        }
        eventTask = item
        DispatchQueue.main.asyncAfter(deadline:.now()+0.22,execute:item)
    }
    func refresh(changedPaths: Set<String>? = nil) {
        guard let root else { return }
        let version = projectVersion
        indexJob?.cancel()
        let job = ShellJob(); indexJob = job
        DispatchQueue.global(qos:.utility).async {
            let paths = try? WorkspaceSearch.paths(in:root,job:job)
            DispatchQueue.main.async {
                guard self.projectVersion == version, self.indexJob === job, let paths else { return }
                self.quick.paths = paths
            }
        }
        refreshGit(changedPaths: changedPaths)
        if !side.query.stringValue.isEmpty { search(side.query.stringValue) }
        checkDisk()
    }
    func refreshGit(changedPaths: Set<String>? = nil) {
        guard let root else { return }
        // Let discovery finish even when several repositories keep generating events.
        if gitJob != nil {
            if let changedPaths { queuedGitPaths.formUnion(changedPaths) }
            else { fullGitRefreshQueued = true }
            return
        }
        let previous = side.git
        let job = ShellJob(); gitJob = job
        let version = projectVersion
        gitVersion += 1; let pass = gitVersion
        DispatchQueue.global(qos:.utility).async {
            let result = Result { try WorkspaceGit.read(in: root, previous: previous, changedPaths: changedPaths, job: job) }
            DispatchQueue.main.async {
                guard self.projectVersion == version, self.gitVersion == pass, self.gitJob === job else { return }
                self.gitJob = nil
                switch result {
                case let .success(state):
                    self.side.git = state
                case let .failure(error):
                    self.side.git = nil
                    self.side.gitMessage = error.localizedDescription
                }
                self.updateBranch()
                if self.side.section != .search { self.side.reload() }
                self.refreshLineChanges()
                if self.fullGitRefreshQueued || !self.queuedGitPaths.isEmpty {
                    let next = self.fullGitRefreshQueued ? nil : self.queuedGitPaths
                    self.fullGitRefreshQueued = false
                    self.queuedGitPaths.removeAll()
                    self.refreshGit(changedPaths: next)
                }
            }
        }
        if let doc = current, case let .patch(repo, change)? = targets[doc.identity], change.revision == nil {
            DispatchQueue.global(qos:.utility).async {
                let patch = try? GitState(repo:repo).diff(change)
                DispatchQueue.main.async {
                    if self.gitVersion == pass, self.current === doc, let patch, doc.text.string != patch { doc.replace(patch) }
                }
            }
        }
    }
    func updateBranch() {
        let repository: GitState?
        switch current.flatMap({ targets[$0.identity] }) {
        case let .patch(repo, _), let .blob(repo, _, _):
            repository = side.git?.repositories.first { $0.repo.path == repo.path }
        default:
            // With no tab, only show a branch if the workspace itself belongs to a repo.
            repository = (current?.url ?? root).flatMap { side.git?.repository(containing: $0.path) }
        }
        branch.stringValue = repository?.branch ?? ""
        branch.toolTip = repository?.repo.path
        branch.isHidden = repository == nil
        branchIcon.isHidden = repository == nil
    }
    func refreshLineChanges() {
        defer { updateChangeButtons() }
        var immediate = GitLineChanges()
        if let doc = current, doc.base != nil, let workspace = side.git, let git = workspace.repository(containing: doc.url.path), let root,
           doc.url.pathComponents.starts(with: root.pathComponents) {
            let changes = workspace.fileTree.changes[doc.url.path] ?? []
            let staged = changes.first { $0.area == .staged }
            let working = changes.first { $0.area == .working }
            let addedInIndex = staged?.flag == "A" && working?.flag != "A" && working?.flag != "U"
            let addedInWorktree = staged == nil && (working?.flag == "A" || changes.first?.area == .untracked)
            if addedInIndex || addedInWorktree || staged?.flag == "C" {
                immediate = .added(lines: doc.contentLineCount)
            } else if let head = git.head, doc.dirty || !changes.isEmpty {
                let oldPath = changes.first { $0.flag == "R" }?.oldPath
                let path = oldPath ?? workspaceRelativePath(of: doc.url, from: git.repo)
                compareLines(in: doc, repo: git.repo, head: head, path: path)
                return
            }
        }
        lineJob?.cancel()
        lineJob = nil
        lineComparison = nil
        lineBaseline = nil
        current?.setLineChanges(immediate)
    }
    private func updateChangeButtons() {
        let enabled = current?.lineChanges.hunks.isEmpty == false
        previousChange.isEnabled = enabled
        nextChange.isEnabled = enabled
    }
    private func compareLines(in doc: Editor, repo: URL, head: String, path: String) {
        let request = LineComparison(document: ObjectIdentifier(doc), revision: doc.revision, repo: repo, head: head, path: path)
        guard request != lineComparison else { return }
        lineJob?.cancel()
        lineComparison = request
        let baseline: GitLineBaseline
        if let cached = lineBaseline, cached.repo == repo, cached.revision == head, cached.path == path { baseline = cached }
        else { baseline = GitLineBaseline(repo: repo, revision: head, path: path); lineBaseline = baseline }
        let job = ShellJob()
        lineJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak doc] in
            guard let self, let doc, self.lineJob === job else { return }
            let snapshot = doc.text.string
            self.lineDiffQueue.async {
                let result = try? baseline.compare(snapshot, job: job)
                DispatchQueue.main.async {
                    guard self.lineJob === job, self.current === doc else { return }
                    self.lineJob = nil
                    if result == nil { self.lineComparison = nil }
                    doc.setLineChanges(result ?? GitLineChanges())
                    self.updateChangeButtons()
                }
            }
        }
    }
    func search(_ query: String) {
        queryJob?.cancel(); queryVersion += 1
        let version = queryVersion
        side.hits = []; side.searchInfo = query.isEmpty ? "" : "搜索中…"
        if side.section == .search { side.reload() }
        guard !query.isEmpty, let root else { return }
        let job = ShellJob(); queryJob = job
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+0.14) {
            var errorText: String?
            do {
                try WorkspaceSearch.find(query,in:root,job:job) { hits in
                    DispatchQueue.main.async {
                        guard self.queryVersion == version else { return }
                        self.side.hits += hits
                        if self.side.section == .search { self.side.reload() }
                    }
                }
            } catch is CancellationError {} catch { errorText = error.localizedDescription }
            let problem = errorText
            DispatchQueue.main.async {
                guard self.queryVersion == version else { return }
                let n = self.side.hits.count
                self.side.searchInfo = problem ?? (n == 1200 ? "已显示前 1200 个匹配" : "\(n) 个匹配")
                if self.side.section == .search { self.side.reload() }
            }
        }
    }
    private func loadCommit(_ commit: Commit, repo: URL) {
        guard let git = side.git?.repositories.first(where: { $0.repo == repo }) else { return }
        let v = projectVersion
        DispatchQueue.global().async {
            let changes = Result { try git.commitFiles(commit.id) }
            DispatchQueue.main.async {
                guard self.projectVersion == v else { return }
                switch changes {
                case let .success(items): self.side.loadedCommit(commit.id, repo: repo, changes: items)
                case let .failure(err): self.statusMessage.stringValue = err.localizedDescription
                }
            }
        }
    }
    private func openNode(_ node: SideNode, pin: Bool) {
        switch node.role {
        case let .file(url, deletion):
            if let deletion, let git = side.git?.repository(containing: url.path) { open(.patch(git.repo,deletion),pin:pin) }
            else { open(.file(url),pin:pin) }
        case let .hit(hit):
            if let root { open(.file(root.appendingPathComponent(hit.path)),line:hit.line,column:hit.column,length:hit.length,pin:pin) }
        case let .change(repo, c):
            open(.patch(repo, c), pin: pin)
        default: break
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { documents.allSatisfy { confirmClosing($0) } }
}

private final class ToolbarItems: NSObject, NSToolbarDelegate {
    let views: [String:NSView]
    init(views:[String:NSView]) { self.views = views }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("back"),.init("forward"),.flexibleSpace,.init("project"),.flexibleSpace]
    }
    func toolbar(_ toolbar: NSToolbar,itemForItemIdentifier id: NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let view = views[id.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier:id); item.view = view; item.label = (view as? NSButton)?.toolTip ?? id.rawValue
        return item
    }
}
