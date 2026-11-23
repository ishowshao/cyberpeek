import AppKit

class DocumentTab: NSObject {
    let url: URL
    let identity: String
    let title: String
    var pinned = false
    var dirty = false

    init(url: URL, identity: String, title: String) {
        self.url = url
        self.identity = identity
        self.title = title
    }
}

enum OpenedContent {
    case text(String, DiskText?)
    case image(RasterImage?, ImageFileVersion?)
}

struct DocumentRequest {
    let target: Workbench.Target
    let id: String, url: URL, change: Change?, title: String

    init(_ target: Workbench.Target) {
        self.target = target
        switch target {
        case let .file(file):
            url = file.resolvingSymlinksInPath().standardizedFileURL; id = "file|" + url.path; change = nil; title = url.lastPathComponent
        case let .patch(repo,c):
            url = repo.appendingPathComponent(c.path); id = "diff|\(repo.path)|\(c.area)|\(c.revision ?? "")|\(c.path)"; change = c
            title = "\(url.lastPathComponent) (\(c.area.rawValue))"
        case let .blob(repo,rev,path):
            url = repo.appendingPathComponent(path); id = "blob|\(repo.path)|\(rev)|\(path)"; change = nil
            title = "\(url.lastPathComponent) (\(rev.isEmpty ? "暂存区" : String(rev.prefix(7))))"
        }
    }

    func read() throws -> OpenedContent {
        let isImage = RasterImage.extensions.contains(url.pathExtension.lowercased())
        switch target {
        case .file:
            if isImage {
                let version = try ImageFileVersion(url)
                return .image(try? RasterImage(url: url), version)
            }
            let disk = try DiskText.read(url); return .text(disk.text,disk)
        case let .patch(repo,c):
            return .text(try GitState(repo:repo).diff(c), nil)
        case let .blob(repo, rev, path):
            let data = try ShellJob().run(Tools.git, ["show","\(rev):\(path)"], in:repo)
            return isImage ? .image(try? RasterImage(data: data), nil) : .text(try DiskText(data).text,nil)
        }
    }
}

extension Workbench {
    enum ExplorerReveal { case preserve, reveal, center }

    private var currentLocation: Location? {
        guard let doc = activeDocument, let target = targets[doc.identity] else { return nil }
        let cursor = current?.cursor ?? (line: 1, column: 1)
        return Location(target: target, line: cursor.line, column: cursor.column - 1)
    }
    private func rememberLocation() {
        guard let currentLocation else { return }
        back.append(currentLocation)
        if back.count > 150 { back.removeFirst() }; forward.removeAll()
    }
    func navigate(backwards: Bool) {
        let next = backwards ? back.popLast() : forward.popLast()
        guard let next else { return }
        if let place = currentLocation {
            if backwards { forward.append(place) } else { back.append(place) }
        }
        open(next.target,line:next.line,column:next.column,record:false)
    }
    func enqueueFile(_ url: URL) {
        queuedFiles.append((url, replacePreview: restoringSession == nil))
        if queuedFiles.count == 1 { openNextFile() }
    }
    private func openNextFile() {
        guard let file = queuedFiles.first else { return }
        let workspace = projectVersion
        open(.file(file.url), pin: true, replacePreview: file.replacePreview) { [weak self] in
            guard let self, self.projectVersion == workspace else { return }
            self.queuedFiles.removeFirst()
            if self.queuedFiles.isEmpty { self.queuedFiles = []; return }
            DispatchQueue.main.async {
                if self.projectVersion == workspace { self.openNextFile() }
            }
        }
    }
    func open(_ target: Target, line: Int? = nil, column: Int = 0, length: Int = 0, pin: Bool = false, record: Bool = true,
              explorerReveal: ExplorerReveal = .reveal, replacePreview: Bool = true, completion: (() -> Void)? = nil) {
        let request = DocumentRequest(target)
        loadVersion += 1; let version = loadVersion
        func activate(_ doc: DocumentTab) {
            if record, activeDocument !== doc || line != nil { rememberLocation() }
            if pin { doc.pinned = true }
            let editor = doc as? Editor
            if line != nil { editor?.showsSVGPreview = false }
            targets[request.id] = target; show(doc, explorerReveal: explorerReveal)
            if let line { editor?.go(line,column:column,length:length) }
        }
        if let old = documents.first(where:{ $0.identity == request.id }) {
            activate(old); refreshSelectedDocument(); completion?(); return
        }
        pendingOpen = target
        statusMessage.stringValue = "正在打开…"
        DispatchQueue.global(qos:.userInitiated).async {
            let result = Result { try request.read() }
            DispatchQueue.main.async {
                defer { completion?() }
                guard self.loadVersion == version else { return }
                self.pendingOpen = nil
                self.statusMessage.stringValue = ""
                do {
                    if let restored = self.documents.first(where: { $0.identity == request.id }) {
                        activate(restored)
                        return
                    }
                    let doc = self.makeDocument(request, content: try result.get())
                    var replacedID: String?
                    if replacePreview, let preview = self.documents.firstIndex(where:{ !$0.pinned && !$0.dirty }) {
                        replacedID = self.documents[preview].identity
                        self.documents[preview] = doc
                    } else { self.documents.append(doc) }
                    activate(doc)
                    if let replacedID { self.forgetTarget(replacedID) }
                } catch { self.alert(error.localizedDescription) }
            }
        }
    }
    func makeDocument(_ request: DocumentRequest, content: OpenedContent) -> DocumentTab {
        switch content {
        case let .text(source, disk):
            let text = request.change != nil && source.isEmpty ? "没有文本差异" : source
            let editor = Editor(url: request.url, identity: request.id, title: request.title, source: text,
                                disk: disk, change: request.change, patch: request.change != nil)
            wire(editor)
            return editor
        case let .image(image, version):
            return ImageDocument(url: request.url, identity: request.id, title: request.title, image: image, diskVersion: version)
        }
    }
    private func wire(_ doc: Editor) {
        doc.onChange = { [weak self, weak doc] contentChanged in
            guard let self else { return }
            self.statusMessage.stringValue = ""; self.updateTabs(); self.updateStatus()
            if contentChanged, let doc, self.current === doc {
                if doc.showsSVGPreview { self.imagePreview.showSVG(doc.text.string, name: doc.title) }
                self.refreshLineChanges()
            }
        }
        doc.onCursor = { [weak self,weak doc] in if self?.current === doc { self?.updateStatus() } }
        doc.onDiffLine = { [weak self,weak doc] line in
            guard let self, let doc, let change = doc.change, let target = self.targets[doc.identity],
                  case let .patch(repo,_) = target else { return }
            if change.area == .commit || change.area == .staged {
                self.open(.blob(repo,change.revision ?? "",change.path),line:line,pin:true)
            } else { self.open(.file(doc.url),line:line,pin:true) }
        }
    }
    func show(_ doc: DocumentTab?, explorerReveal: ExplorerReveal = .reveal) {
        activeDocument = doc
        updateBranch()
        crumbBar.isHidden = doc == nil
        let editor = current
        let previewingSVG = editor?.showsSVGPreview == true
        previewButton.isHidden = editor?.supportsSVGPreview != true
        previewButton.image = symbol(previewingSVG ? "chevron.left.forwardslash.chevron.right" : "eye", size: 13)
        let action = previewingSVG ? "查看 SVG 源代码" : "预览 SVG"
        previewButton.toolTip = action
        previewButton.setAccessibilityLabel(action)
        if let url = breadcrumbURL, let root {
            let path = workspaceRelativePath(of: url, from: root)
            crumb.stringValue = path.components(separatedBy: "/").joined(separator: "    ›    ") + (editor?.isPatch == true ? "    ›    Diff" : "")
        }
        editorHost.subviews.forEach { $0.removeFromSuperview() }
        if let imageDoc = doc as? ImageDocument {
            editorHost.place(imagePreview)
            imagePreview.show(imageDoc.image, name: imageDoc.title)
            window.makeFirstResponder(imagePreview)
        } else if let editor, previewingSVG {
            editorHost.place(imagePreview)
            imagePreview.showSVG(editor.text.string, name: editor.title)
            window.makeFirstResponder(imagePreview)
        } else {
            imagePreview.clear()
            editorHost.place(editor?.view ?? welcome)
            if let editor { window.makeFirstResponder(editor.text); editor.becameVisible() }
        }
        updateTabs(); updateStatus()
        refreshLineChanges()
        if let doc, explorerReveal != .preserve { side.reveal(doc.url, centerSelectedRow: explorerReveal == .center) }
    }
    var breadcrumbURL: URL? {
        guard let activeDocument else { return nil }
        if case let .file(openedURL)? = targets[activeDocument.identity] { return openedURL }
        return activeDocument.url
    }
    func copyRelativePath(of url: URL) {
        guard let root else { return }
        let path = workspaceRelativePath(of: url, from: root)
        pathPasteboard.clearContents()
        if pathPasteboard.setString(path, forType: .string) { statusMessage.stringValue = "已复制相对路径" }
    }
    func updateTabs() {
        tabs.arrangedSubviews.forEach { tabs.removeArrangedSubview($0); $0.removeFromSuperview() }
        var width: CGFloat = 0, selectedFrame = NSRect.zero
        for doc in documents {
            let selected = activeDocument === doc
            let button = ActionButton("  " + doc.title,icon:(doc as? Editor)?.isPatch == true ? "plus.forwardslash.minus" : kindIcon(doc.url.path).0,
                                      tip:doc.url.path,size:13) { [weak self,weak doc] in
                guard let self, let doc else { return }
                self.loadVersion += 1
                if self.activeDocument !== doc { self.rememberLocation() }
                if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type), event.clickCount == 2 {
                    doc.pinned = true
                }
                self.show(doc, explorerReveal: .center); self.refreshSelectedDocument()
            }
            let font = NSFont.systemFont(ofSize:12)
            button.font = doc.pinned ? font : NSFontManager.shared.convert(font,toHaveTrait:.italicFontMask)
            button.contentTintColor = selected ? Palette.text : Palette.muted
            let close = ActionButton(icon:doc.dirty ? "circle.fill" : "xmark",tip:"关闭 \(doc.title)",size:doc.dirty ? 7 : 9) { [weak self,weak doc] in
                if let doc { self?.close(doc) }
            }
            let row = stack([button,close],spacing:9)
            row.edgeInsets = .init(top:0,left:11,bottom:0,right:10)
            let holder = NSView(); holder.fill(selected ? Palette.canvas : Palette.chrome); holder.place(row)
            let w = max(90,ceil(row.fittingSize.width))
            holder.width(w); holder.height(35)
            if selected {
                let border = NSView(); border.fill(Palette.blue); border.translatesAutoresizingMaskIntoConstraints = false; holder.addSubview(border)
                NSLayoutConstraint.activate([border.topAnchor.constraint(equalTo:holder.topAnchor),border.leadingAnchor.constraint(equalTo:holder.leadingAnchor),
                    border.trailingAnchor.constraint(equalTo:holder.trailingAnchor),border.heightAnchor.constraint(equalToConstant:2)])
                selectedFrame = NSRect(x:width,y:0,width:w,height:35)
            }
            tabs.addArrangedSubview(holder); width += w+1
        }
        tabs.frame = NSRect(x:0,y:0,width:width,height:35)
        if !selectedFrame.isEmpty { tabs.scrollToVisible(selectedFrame) }
    }
    func updateStatus() {
        if let doc = activeDocument as? ImageDocument {
            conflictBar.isHidden = true
            position.stringValue = doc.image.map { "\(Int($0.size.width)) × \(Int($0.size.height)) px" } ?? ""
            format.stringValue = doc.url.pathExtension.uppercased()
            return
        }
        guard let doc = current else {
            conflictBar.isHidden = true; position.stringValue = ""; format.stringValue = ""; return
        }
        conflictBar.isHidden = !doc.conflict
        position.stringValue = doc.showsSVGPreview ? "" : "行 \(doc.cursor.line)，列 \(doc.cursor.column)"
        let encoding = doc.base?.encoding
        let codec = encoding == .utf16LittleEndian ? "UTF-16 LE" : encoding == .utf16BigEndian ? "UTF-16 BE" : "UTF-8"
        format.stringValue = (doc.base == nil ? "只读" : "\(codec)     \(doc.base?.crlf == true ? "CRLF" : "LF")") + "     " + (doc.isPatch ? "Diff" : doc.url.pathExtension.uppercased())
    }
    func close(_ doc: DocumentTab) {
        guard confirmClosing(doc) else { return }
        loadVersion += 1
        removeTab(doc)
    }
    private func forgetTarget(_ id: String) {
        targets.removeValue(forKey: id)
        restoringSession?.tabs.removeAll { DocumentRequest($0.target).id == id }
    }
    private func removeTab(_ doc: DocumentTab) {
        guard let index = documents.firstIndex(where:{ $0 === doc }) else { return }
        documents.remove(at:index); forgetTarget(doc.identity)
        if activeDocument === doc { show(documents.isEmpty ? nil : documents[min(index,documents.count-1)]) }
        else { updateTabs() }
    }
    func trashFile(_ url: URL) {
        // Resolve the parent only. Trashing a symlink must move the link itself.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard let root, parent.pathComponents.starts(with: root.pathComponents) else { return }
        let file = parent.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        func usesFile(_ target: Target) -> Bool {
            switch target {
            case let .file(opened):
                return opened.path == file.path || opened.resolvingSymlinksInPath().path == file.path
            case let .patch(repo, change) where change.area == .working || change.area == .untracked:
                return repo.appendingPathComponent(change.path).path == file.path
            default: return false
            }
        }
        let tabs = documents.filter { targets[$0.identity].map(usesFile) == true }
        guard tabs.allSatisfy(confirmClosing) else { return }
        do {
            let type = try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeSymbolicLink else { throw CyberPeekError("请选择要移到废纸篓的文件。") }
            let remainingBack = back.filter { !usesFile($0.target) }
            let remainingForward = forward.filter { !usesFile($0.target) }
            let cancelOpen = pendingOpen.map(usesFile) == true
            try moveToTrash(file)
            if cancelOpen { loadVersion += 1 }
            back = remainingBack
            forward = remainingForward
            tabs.forEach(removeTab)
            statusMessage.stringValue = "已将“\(file.lastPathComponent)”移到废纸篓"
            refresh(changedPaths: [file.path])
        } catch {
            alert(error.localizedDescription)
        }
    }
    func confirmClosing(_ tab: DocumentTab) -> Bool {
        guard let doc = tab as? Editor, doc.dirty else { return true }
        let alert = NSAlert(); alert.messageText = "保存对 \(doc.title) 的修改？"
        alert.addButton(withTitle:"保存"); alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"放弃修改")
        switch alert.runModal() {
        case .alertFirstButtonReturn: do { try doc.save(); return true } catch { self.alert(error.localizedDescription); return false }
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
    func save() {
        guard let current, current.dirty else { return }
        do { try current.save(); statusMessage.stringValue = "已保存" }
        catch { updateStatus(); if current.conflict { compareConflict() } else { alert(error.localizedDescription) } }
    }
    func alert(_ message: String) {
        let panel = NSAlert(); panel.messageText = message
        if window.attachedSheet == nil { panel.beginSheetModal(for:window,completionHandler:nil) }
        else { statusMessage.stringValue = message }
    }
    private func refreshSelectedDocument() {
        guard let doc = current, case let .patch(repo, change)? = targets[doc.identity], change.revision == nil else { checkDisk(); return }
        let token = loadVersion
        DispatchQueue.global(qos:.utility).async {
            let result = try? GitState(repo:repo).diff(change)
            DispatchQueue.main.async {
                if self.current === doc, self.loadVersion == token, let result, doc.text.string != result { doc.replace(result) }
            }
        }
    }
    func checkDisk() {
        if let image = activeDocument as? ImageDocument, case .file? = targets[image.identity] {
            diskVersion += 1
            let token = diskVersion, previous = image.diskVersion
            DispatchQueue.global(qos: .utility).async {
                let version = try? ImageFileVersion(image.url)
                guard version != previous else { return }
                let updated = try? RasterImage(url: image.url)
                DispatchQueue.main.async {
                    guard self.diskVersion == token, self.activeDocument === image else { return }
                    image.diskVersion = version
                    image.image = updated
                    self.imagePreview.show(updated, name: image.title)
                    self.updateStatus()
                }
            }
            return
        }
        guard let doc = current, let base = doc.base else { return }
        diskVersion += 1; let token = diskVersion
        DispatchQueue.global(qos:.utility).async {
            let disk = try? DiskText.read(doc.url)
            DispatchQueue.main.async {
                guard self.diskVersion == token, self.current === doc, doc.base?.data == base.data else { return }
                if let disk, disk.data == base.data { doc.conflict = false }
                else if let disk, !doc.dirty { doc.base = disk; doc.replace(disk.text) }
                else { doc.conflict = true }
                self.updateStatus()
            }
        }
    }
    func saveCopy() {
        guard let doc = current, let base = doc.base else { return }
        let panel = NSSavePanel()
        let filename = doc.url.deletingPathExtension().lastPathComponent + " 副本"
        panel.nameFieldStringValue = doc.url.pathExtension.isEmpty ? filename : filename + "." + doc.url.pathExtension
        panel.directoryURL = doc.url.deletingLastPathComponent()
        panel.beginSheetModal(for:window) { result in
            guard result == .OK, let target = panel.url else { return }
            do {
                let data = try base.encoded(doc.text.string)
                try data.write(to:target,options:.atomic)
                self.statusMessage.stringValue = "已保存副本"
            } catch { self.alert(error.localizedDescription) }
        }
    }
    func compareConflict() {
        guard let doc = current, let base = doc.base else { return }
        guard FileManager.default.fileExists(atPath:doc.url.path) else {
            let panel = NSAlert()
            panel.messageText = "磁盘上的文件已移除"
            panel.informativeText = "编辑器仍保留当前内容，可以将它保存为副本。"
            panel.addButton(withTitle:"保存副本…"); panel.addButton(withTitle:"继续查看")
            panel.beginSheetModal(for:window) { if $0 == .alertFirstButtonReturn { self.saveCopy() } }
            return
        }
        do {
            let disk = try DiskText.read(doc.url)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:directory) }
            try disk.text.write(to:directory.appendingPathComponent("disk"),atomically:true,encoding:.utf8)
            try doc.text.string.write(to:directory.appendingPathComponent("editor"),atomically:true,encoding:.utf8)
            let diff = try ShellJob().run(Tools.git,["diff","--no-index","--no-color","--no-ext-diff","--","disk","editor"],in:directory,success:[0,1])
            let panel = NSAlert(); panel.messageText = "比较 \(doc.title)"
            panel.informativeText = "红色为磁盘版本，绿色为编辑器版本。"
            let preview = Editor(url:doc.url,identity:"compare",title:"",source:String(decoding:diff,as:UTF8.self),patch:true)
            preview.view.frame.size = NSSize(width:640,height:350); panel.accessoryView = preview.view
            panel.addButton(withTitle:"继续编辑"); panel.addButton(withTitle:"载入磁盘版本"); panel.addButton(withTitle:"保存我的版本")
            panel.beginSheetModal(for:window) { result in
                _ = preview
                switch result {
                case .alertSecondButtonReturn: doc.base = disk; doc.replace(disk.text)
                case .alertThirdButtonReturn:
                    doc.base = disk
                    do { try doc.save() } catch { doc.base = base; self.alert(error.localizedDescription) }
                default: break
                }
                self.updateStatus(); self.updateTabs()
            }
        } catch { alert(error.localizedDescription) }
    }
}
