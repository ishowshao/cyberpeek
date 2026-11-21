import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var workbench: Workbench!
    private var pending = [URL]()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        installMenu()
        workbench = Workbench()
        workbench.window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps:true)
        let environment = ProcessInfo.processInfo.environment
        if let fixture = environment["CYBERPEEK_TEST_WORKSPACE"] {
            workbench.openFolder(URL(fileURLWithPath: fixture), remember: false)
            return
        }
        // A test runner without the scheme's fixture starts with an empty window.
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil { return }
        let urls = pending.isEmpty ? Self.fileArguments(CommandLine.arguments.dropFirst()) : pending
        if !urls.isEmpty { open(urls) }
        else if let last = UserDefaults.standard.string(forKey:"lastFolder"), last != "/" {
            workbench.openFolder(URL(fileURLWithPath:last), remember: false)
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
        if workbench == nil { pending.append(contentsOf:urls) } else { open(urls) }
    }
    private func open(_ urls: [URL]) {
        guard let first = urls.first?.resolvingSymlinksInPath().standardizedFileURL, first.isFileURL,
              let type = try? first.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { return }
        if type.isDirectory == true {
            workbench.openFolder(first)
            if let file = urls.dropFirst().first?.resolvingSymlinksInPath().standardizedFileURL,
               workbench.root?.path == first.path, file.pathComponents.starts(with: first.pathComponents),
               (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                workbench.open(.file(file),pin:true)
            }
        } else if type.isRegularFile == true {
            let parent = first.deletingLastPathComponent()
            if workbench.root.map({ first.pathComponents.starts(with: $0.pathComponents) }) != true { workbench.openFolder(parent) }
            if let root = workbench.root, first.pathComponents.starts(with: root.pathComponents) { workbench.open(.file(first),pin:true) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidBecomeActive(_ notification: Notification) {
        // An external Git command may update an index outside the monitored workspace folder.
        if workbench?.side.git?.repositories.isEmpty == false { workbench.refreshGit() }
    }
    func applicationWillTerminate(_ notification: Notification) { workbench?.cancelWorkspaceJobs() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let w = workbench, w.window.isVisible, !w.documents.allSatisfy({ w.confirmClosing($0) }) { return .terminateCancel }
        return .terminateNow
    }
    @objc func folder() { workbench.chooseFolder() }
    @objc func file() {
        let panel = NSOpenPanel()
        panel.beginSheetModal(for:workbench.window) { result in if result == .OK, let url = panel.url { self.open([url]) } }
    }
    @objc func save() { workbench.save() }
    @objc func copyFile() { workbench.saveCopy() }
    @objc func closeTab() { if let doc = workbench.activeDocument { workbench.close(doc) } else { workbench.window.performClose(nil) } }
    @objc func quickOpen() { workbench.quickOpen() }
    @objc func files() { workbench.selectSection(.files) }
    @objc func search() { workbench.selectSection(.search) }
    @objc func git() { workbench.selectSection(.git) }
    @objc func toggleSidebar() { workbench.toggleSidebar() }
    @objc func back() { workbench.navigate(backwards:true) }
    @objc func forward() { workbench.navigate(backwards:false) }
    @objc func find(_ sender: NSMenuItem) {
        guard let editor = workbench.current else { return }
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
        item(fileMenu,"打开文件…",#selector(file),"o",.command,self); item(fileMenu,"打开文件夹…",#selector(folder),"o",[.command,.shift],self)
        item(fileMenu,"快速打开…",#selector(quickOpen),"p",.command,self)
        fileMenu.addItem(.separator()); item(fileMenu,"保存",#selector(save),"s",.command,self); item(fileMenu,"保存副本…",#selector(copyFile),"s",[.command,.shift],self); item(fileMenu,"关闭标签页",#selector(closeTab),"w",.command,self)
        let edit = menu("编辑")
        item(edit,"撤销",Selector(("undo:")),"z"); item(edit,"重做",Selector(("redo:")),"z",[.command,.shift])
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
