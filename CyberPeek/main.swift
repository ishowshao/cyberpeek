import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var workbenches: [Workbench] = []
    var activeWorkbench: Workbench? {
        var window = NSApp.keyWindow
        while let candidate = window {
            if let owner = workbenches.first(where: { $0.window === candidate }) { return owner }
            window = candidate.sheetParent ?? candidate.parent
        }
        if let main = workbenches.first(where: { $0.window === NSApp.mainWindow }) { return main }
        // An open event can arrive before the app has a key or main window.
        for window in NSApp.orderedWindows {
            if let owner = workbenches.first(where: { $0.window === window }) { return owner }
        }
        return workbenches.last
    }
    private var pending = [URL]()
    private var launched = false
    private var rememberFolders = true
    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        installMenu()
        launched = true
        let initial = makeWorkbench()
        initial.window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps:true)
        let environment = ProcessInfo.processInfo.environment
        if let fixture = environment["CYBERPEEK_TEST_WORKSPACE"] {
            rememberFolders = false
            initial.openFolder(URL(fileURLWithPath: fixture), remember: false)
            return
        }
        // A test runner without the scheme's fixture starts with an empty window.
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil { return }
        let urls = pending.isEmpty ? Self.fileArguments(CommandLine.arguments.dropFirst()) : pending
        pending.removeAll()
        if !urls.isEmpty { open(urls) }
        else if let last = UserDefaults.standard.string(forKey:"lastFolder"), last != "/" {
            initial.openFolder(URL(fileURLWithPath:last), remember: false)
        }
    }
    static func fileArguments(_ arguments: ArraySlice<String>) -> [URL] {
        var urls: [URL] = [], options = true, skipValue = false
        for argument in arguments {
            if options && argument == "--" { options = false; skipValue = false; continue }
            if options && argument.hasPrefix("-") {
                // AppKit and XCTest supply defaults as key/value pairs, e.g. -ApplePersistenceIgnoreState YES.
                skipValue = !argument.hasPrefix("-psn_") && !argument.contains("=")
                continue
            }
            if skipValue { skipValue = false; continue }
            if !argument.isEmpty { urls.append(URL(fileURLWithPath: argument)) }
        }
        return urls
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if launched { open(urls) } else { pending.append(contentsOf: urls) }
    }
    private func makeWorkbench() -> Workbench {
        let bench = Workbench()
        if let frame = activeWorkbench?.window.frame {
            bench.window.cascadeTopLeft(from: NSPoint(x: frame.minX + 22, y: frame.maxY - 22))
        }
        bench.onOpenFolder = { [weak self, weak bench] url in self?.open([url], from: bench) }
        bench.onClose = { [weak self] owner in self?.workbenches.removeAll { $0 === owner } }
        workbenches.append(bench)
        return bench
    }
    private func focus(_ bench: Workbench) {
        if bench.window.isMiniaturized { bench.window.deminiaturize(nil) }
        bench.window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { NSApp.activate() }
    }
    private func workspace(for folder: URL, from source: Workbench?) -> Workbench {
        if let existing = workbenches.first(where: { $0.root?.path == folder.path }) { return existing }
        let bench: Workbench
        if let source, source.root == nil { bench = source }
        else { bench = workbenches.last(where: { $0.root == nil }) ?? makeWorkbench() }
        bench.openFolder(folder, remember: rememberFolders)
        return bench
    }
    private func open(_ urls: [URL], from source: Workbench? = nil) {
        let source = source ?? activeWorkbench
        var files = [URL]()
        // Establish explicitly requested workspaces before assigning files from the same Finder event.
        for url in urls where url.isFileURL {
            let url = url.resolvingSymlinksInPath().standardizedFileURL
            guard let type = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { continue }
            if type.isDirectory == true { focus(workspace(for: url, from: source)) }
            else if type.isRegularFile == true { files.append(url) }
        }
        for file in files {
            let path = file.pathComponents
            let owners = workbenches.filter { $0.root.map { path.starts(with: $0.pathComponents) } == true }
            let bench = owners.max { ($0.root?.pathComponents.count ?? 0) < ($1.root?.pathComponents.count ?? 0) }
                ?? workspace(for: file.deletingLastPathComponent(), from: source)
            focus(bench)
            bench.enqueueFile(file)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidBecomeActive(_ notification: Notification) {
        // An external Git command may update an index outside the monitored workspace folder.
        if let bench = activeWorkbench, bench.side.git?.repositories.isEmpty == false { bench.refreshGit() }
    }
    func applicationWillTerminate(_ notification: Notification) { workbenches.forEach { $0.cancelWorkspaceJobs() } }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for bench in workbenches where bench.documents.contains(where: \.dirty) {
            focus(bench)
            if !bench.documents.allSatisfy({ bench.confirmClosing($0) }) { return .terminateCancel }
        }
        return .terminateNow
    }
    @objc func newWindow() { focus(makeWorkbench()) }
    @objc func closeWindow() { activeWorkbench?.window.performClose(nil) }
    @objc func folder() { activeWorkbench?.chooseFolder() }
    @objc func file() {
        guard let bench = activeWorkbench else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for:bench.window) { result in if result == .OK { self.open(panel.urls, from: bench) } }
    }
    @objc func save() { activeWorkbench?.save() }
    @objc func copyFile() { activeWorkbench?.saveCopy() }
    @objc func closeTab() {
        guard let bench = activeWorkbench else { return }
        if let doc = bench.activeDocument { bench.close(doc) } else { bench.window.performClose(nil) }
    }
    @objc func quickOpen() { activeWorkbench?.quickOpen() }
    @objc func files() { activeWorkbench?.selectSection(.files) }
    @objc func search() { activeWorkbench?.selectSection(.search) }
    @objc func git() { activeWorkbench?.selectSection(.git) }
    @objc func toggleSidebar() { activeWorkbench?.toggleSidebar() }
    @objc func back() { activeWorkbench?.navigate(backwards:true) }
    @objc func forward() { activeWorkbench?.navigate(backwards:false) }
    @objc func find(_ sender: NSMenuItem) {
        guard let workbench = activeWorkbench, let editor = workbench.current else { return }
        if editor.showsSVGPreview { editor.showsSVGPreview = false; workbench.show(editor) }
        let view = editor.text
        workbench.window.makeFirstResponder(view)
        view.performTextFinderAction(sender)
    }
    private func installMenu() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let header = NSMenuItem(); main.addItem(header); let menu = NSMenu(title:title); header.submenu = menu; return menu
        }
        @discardableResult func item(_ m: NSMenu,_ title: String,_ action: Selector,_ key: String = "",
                                    _ mods: NSEvent.ModifierFlags = [.command],_ target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title:title,action:action,keyEquivalent:key); i.keyEquivalentModifierMask = mods; i.target = target; m.addItem(i); return i
        }
        let app = menu("CyberPeek")
        item(app,"关于 CyberPeek",#selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        item(app,"隐藏 CyberPeek",#selector(NSApplication.hide(_:)),"h")
        item(app,"退出 CyberPeek",#selector(NSApplication.terminate(_:)),"q")
        let fileMenu = menu("文件")
        item(fileMenu,"新建窗口",#selector(newWindow),"n",.command,self)
        item(fileMenu,"打开文件…",#selector(file),"o",.command,self); item(fileMenu,"打开文件夹…",#selector(folder),"o",[.command,.shift],self)
        item(fileMenu,"快速打开…",#selector(quickOpen),"p",.command,self)
        fileMenu.addItem(.separator()); item(fileMenu,"保存",#selector(save),"s",.command,self); item(fileMenu,"保存副本…",#selector(copyFile),"s",[.command,.shift],self); item(fileMenu,"关闭标签页",#selector(closeTab),"w",.command,self)
        item(fileMenu,"关闭窗口",#selector(closeWindow),"w",[.command,.shift],self)
        let edit = menu("编辑")
        item(edit,"撤销",#selector(SourceTextView.undo(_:)),"z"); item(edit,"重做",#selector(SourceTextView.redo(_:)),"z",[.command,.shift])
        edit.addItem(.separator()); item(edit,"剪切",#selector(NSText.cut(_:)),"x"); item(edit,"复制",#selector(NSText.copy(_:)),"c")
        item(edit,"粘贴",#selector(NSText.paste(_:)),"v"); item(edit,"全选",#selector(NSText.selectAll(_:)),"a")
        edit.addItem(.separator())
        item(edit,"查找",#selector(find(_:)),"f",.command,self).tag = NSTextFinder.Action.showFindInterface.rawValue
        item(edit,"查找下一个",#selector(find(_:)),"g",.command,self).tag = NSTextFinder.Action.nextMatch.rawValue
        let view = menu("查看")
        item(view,"资源管理器",#selector(files),"e",[.command,.shift],self)
        item(view,"在文件中搜索",#selector(search),"f",[.command,.shift],self)
        item(view,"源代码管理",#selector(git),"g",[.control,.shift],self)
        item(view,"切换侧边栏",#selector(toggleSidebar),"b",.command,self)
        EditorFontSettings.shared.addMenuItems(to: view)
        let go = menu("前往"); item(go,"后退",#selector(back),"-",.control,self); item(go,"前进",#selector(forward),"-",[.control,.shift],self)
        let window = menu("窗口"); item(window,"最小化",#selector(NSWindow.performMiniaturize(_:)),"m"); item(window,"缩放",#selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = window; NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
