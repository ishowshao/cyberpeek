import AppKit

extension Workbench {
    private func rememberLocation() {
        guard let doc = current, let target = targets[doc.identity] else { return }
        back.append(Location(target:target,line:doc.cursor.line,column:doc.cursor.column-1))
        if back.count > 150 { back.removeFirst() }; forward.removeAll()
    }
    func navigate(backwards: Bool) {
        let next = backwards ? back.popLast() : forward.popLast()
        guard let next else { return }
        if let current, let target = targets[current.identity] {
            let place = Location(target:target,line:current.cursor.line,column:current.cursor.column-1)
            if backwards { forward.append(place) } else { back.append(place) }
        }
        open(next.target,line:next.line,column:next.column,record:false)
    }
    func open(_ target: Target, line: Int? = nil, column: Int = 0, length: Int = 0, pin: Bool = false, record: Bool = true) {
        let id: String, url: URL, change: Change?, title: String
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
        loadVersion += 1; let version = loadVersion
        func activate(_ doc: Editor) {
            if record, current !== doc || line != nil { rememberLocation() }
            if pin { doc.pinned = true }
            targets[id] = target; show(doc)
            if let line { doc.go(line,column:column,length:length) }
            window.makeFirstResponder(doc.text)
        }
        if let old = documents.first(where:{ $0.identity == id }) {
            activate(old); refreshSelectedDocument(); return
        }
        statusMessage.stringValue = "正在打开…"
        DispatchQueue.global(qos:.userInitiated).async {
            let result = Result { () throws -> (String,DiskText?) in
                switch target {
                case .file:
                    let disk = try DiskText.read(url); return (disk.text,disk)
                case let .patch(repo,c):
                    let patch = try GitState(repo:repo).diff(c); return (patch.isEmpty ? "没有文本差异" : patch,nil)
                case let .blob(repo, rev, path):
                    let data = try ShellJob().run(Tools.git, ["show","\(rev):\(path)"], in:repo)
                    return (try DiskText(data).text,nil)
                }
            }
            DispatchQueue.main.async {
                guard self.loadVersion == version else { return }
                self.statusMessage.stringValue = ""
                do {
                    let (source,disk) = try result.get()
                    let doc = Editor(url:url,identity:id,title:title,source:source,disk:disk,change:change,patch:change != nil)
                    self.wire(doc)
                    var replacedID: String?
                    if let preview = self.documents.firstIndex(where:{ !$0.pinned && !$0.dirty }) {
                        replacedID = self.documents[preview].identity
                        self.documents[preview] = doc
                    } else { self.documents.append(doc) }
                    activate(doc)
                    if let replacedID { self.targets.removeValue(forKey:replacedID) }
                } catch { self.alert(error.localizedDescription) }
            }
        }
    }
    private func wire(_ doc: Editor) {
        doc.onChange = { [weak self] in self?.statusMessage.stringValue = ""; self?.updateTabs(); self?.updateStatus() }
        doc.onCursor = { [weak self,weak doc] in if self?.current === doc { self?.updateStatus() } }
        doc.onDiffLine = { [weak self,weak doc] line in
            guard let self, let doc, let change = doc.change, let target = self.targets[doc.identity],
                  case let .patch(repo,_) = target else { return }
            if change.area == .commit || change.area == .staged {
                self.open(.blob(repo,change.revision ?? "",change.path),line:line,pin:true)
            } else { self.open(.file(doc.url),line:line,pin:true) }
        }
    }
    func show(_ doc: Editor?) {
        current = doc
        crumbBar.isHidden = doc == nil
        if let url = breadcrumbURL, let root {
            let path = workspaceRelativePath(of: url, from: root)
            crumb.stringValue = path.components(separatedBy: "/").joined(separator: "    ›    ") + (doc?.isPatch == true ? "    ›    Diff" : "")
        }
        editorHost.subviews.forEach { $0.removeFromSuperview() }
        editorHost.place(doc?.view ?? welcome)
        updateTabs(); updateStatus()
        if let doc { window.makeFirstResponder(doc.text); side.reveal(doc.url); doc.becameVisible() }
    }
    var breadcrumbURL: URL? {
        guard let current else { return nil }
        if case let .file(openedURL)? = targets[current.identity] { return openedURL }
        return current.url
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
            let selected = current === doc
            let button = ActionButton("  " + doc.title,icon:doc.isPatch ? "plus.forwardslash.minus" : kindIcon(doc.url.path).0,
                                      tip:doc.url.path,size:13) { [weak self,weak doc] in
                guard let self, let doc else { return }
                self.loadVersion += 1
                if self.current !== doc { self.rememberLocation() }
                if NSApp.currentEvent?.clickCount == 2 { doc.pinned = true }
                self.show(doc); self.refreshSelectedDocument()
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
        guard let doc = current else {
            conflictBar.isHidden = true; position.stringValue = ""; format.stringValue = ""; return
        }
        conflictBar.isHidden = !doc.conflict
        position.stringValue = "行 \(doc.cursor.line)，列 \(doc.cursor.column)"
        let encoding = doc.base?.encoding
        let codec = encoding == .utf16LittleEndian ? "UTF-16 LE" : encoding == .utf16BigEndian ? "UTF-16 BE" : "UTF-8"
        format.stringValue = (doc.base == nil ? "只读" : "\(codec)     \(doc.base?.crlf == true ? "CRLF" : "LF")") + "     " + (doc.isPatch ? "Diff" : doc.url.pathExtension.uppercased())
    }
    func close(_ doc: Editor) {
        guard confirmClosing(doc), let index = documents.firstIndex(where:{ $0 === doc }) else { return }
        loadVersion += 1
        documents.remove(at:index); targets.removeValue(forKey:doc.identity)
        if current === doc { show(documents.isEmpty ? nil : documents[min(index,documents.count-1)]) }
        else { updateTabs() }
    }
    func confirmClosing(_ doc: Editor) -> Bool {
        guard doc.dirty else { return true }
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
        guard let doc = current, let change = doc.change, change.revision == nil, let repo = side.git?.repo else { checkDisk(); return }
        let token = loadVersion
        DispatchQueue.global(qos:.utility).async {
            let result = try? GitState(repo:repo).diff(change)
            DispatchQueue.main.async {
                if self.current === doc, self.loadVersion == token, let result, doc.text.string != result { doc.replace(result) }
            }
        }
    }
    func checkDisk() {
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
