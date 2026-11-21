import AppKit

struct DiskText {
    let data: Data
    let text: String
    let encoding: String.Encoding
    let bom: Data
    let crlf: Bool

    init(_ data: Data) throws {
        let marks: [(Data, String.Encoding)] = [(Data([0xef,0xbb,0xbf]), .utf8), (Data([0xff,0xfe]), .utf16LittleEndian), (Data([0xfe,0xff]), .utf16BigEndian)]
        let detected = marks.first { data.starts(with: $0.0) }
        bom = detected?.0 ?? Data()
        encoding = detected?.1 ?? .utf8
        guard let string = String(data: data.dropFirst(bom.count), encoding: encoding), !string.utf8.contains(0) else {
            throw CyberPeekError("这个文件是二进制文件，或使用了暂不支持的文本编码。")
        }
        let normalized = string.replacingOccurrences(of: "\r\n", with: "\n")
        crlf = string.contains("\r\n") && !string.replacingOccurrences(of: "\r\n", with: "").contains("\n")
        text = crlf ? normalized : string
        self.data = data
    }
    static func read(_ url: URL) throws -> DiskText {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 32 * 1024 * 1024 else { throw CyberPeekError("当前支持打开最大 32 MiB 的普通文本文件。") }
        return try DiskText(Data(contentsOf: url))
    }
    func encoded(_ edited: String) throws -> Data {
        let content = crlf ? edited.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") : edited
        guard let data = content.data(using: encoding) else { throw CyberPeekError("文本编码失败。") }
        return bom + data
    }
}

final class SyntaxWorker {
    let queue = DispatchQueue(label: "CyberPeek.syntax", qos: .userInitiated)
    private let parser: OpaquePointer?
    var isMarkdown: Bool { vs_is_markdown(parser) }
    init(ext: String) { parser = vs_create(ext) }
    deinit { vs_destroy(parser) }
    func parse(_ source: String, completion: @escaping ([VSToken]) -> Void) {
        guard parser != nil, source.utf16.count <= 1_500_000 else { completion([]); return }
        queue.async { [self] in
            var count: UInt32 = 0
            var units = Array(source.utf16)
            units.append(0)
            let ptr = units.withUnsafeBufferPointer { vs_highlight(parser, $0.baseAddress, UInt32($0.count-1), &count) }
            let tokens = ptr.map { Array(UnsafeBufferPointer(start: $0, count: Int(count))) } ?? []
            DispatchQueue.main.async { completion(tokens) }
        }
    }
}

final class SourceTextView: NSTextView {
    private let localUndo = UndoManager()
    override var undoManager: UndoManager? { localUndo }
    var lineActivated: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if !isEditable && event.clickCount == 1 { lineActivated?() }
    }
    override func insertTab(_ sender: Any?) {
        if isEditable { insertText("    ", replacementRange: selectedRange()) }
        else { super.insertTab(sender) }
    }
}

private final class Gutter: NSView {
    weak var owner: Editor?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let owner, let manager = owner.text.textLayoutManager, let content = manager.textContentManager,
              let visible = manager.textViewportLayoutController.viewportRange else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        let attrs: [NSAttributedString.Key:Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                   .foregroundColor: Palette.muted, .paragraphStyle: style]
        let origin = owner.text.textContainerOrigin.y - owner.scroll.contentView.bounds.origin.y
        manager.enumerateTextLayoutFragments(from: visible.location, options: []) { fragment in
            let y = origin + fragment.layoutFragmentFrame.minY
            if y > self.bounds.maxY { return false }
            let index = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let line = owner.lineNumber(at: index)
            ("\(line)" as NSString).draw(in: NSRect(x: 0, y: y+1, width: self.bounds.width-9, height: 19), withAttributes: attrs)
            return true
        }
    }
}

final class Editor: NSObject, NSTextViewDelegate {
    let view = NSView()
    let text = SourceTextView(usingTextLayoutManager: true)
    let scroll = NSScrollView()
    private let gutter = Gutter()
    let url: URL
    let change: Change?
    let identity: String
    let title: String
    var base: DiskText?
    var pinned = false
    private(set) var dirty = false
    var conflict = false
    var onChange: (() -> Void)?
    var onCursor: (() -> Void)?
    var onDiffLine: ((Int) -> Void)?
    private var lineStarts = [0]
    private let worker: SyntaxWorker
    private var tokens: [VSToken] = []
    private var paintedRange: NSRange?
    private var paintQueued = false
    private var revision = 0
    private var pendingHighlight: DispatchWorkItem?
    private var replacing = false
    let isPatch: Bool

    init(url: URL, identity: String, title: String, source: String, disk: DiskText? = nil,
         change: Change? = nil, patch: Bool = false) {
        self.url = url; self.identity = identity; self.title = title; base = disk; self.change = change; isPatch = patch
        worker = SyntaxWorker(ext: patch ? "" : url.pathExtension.lowercased())
        super.init()
        view.fill(Palette.canvas); gutter.owner = self
        text.isRichText = false; text.allowsUndo = disk != nil; text.isEditable = disk != nil
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false; text.isGrammarCheckingEnabled = false
        text.isAutomaticLinkDetectionEnabled = false; text.smartInsertDeleteEnabled = false
        text.usesFindBar = true; text.isIncrementalSearchingEnabled = true
        text.drawsBackground = true; text.backgroundColor = Palette.canvas; text.textColor = Palette.text
        text.font = Palette.code; text.insertionPointColor = Palette.text
        text.textContainerInset = NSSize(width: 4, height: 12)
        text.isHorizontallyResizable = true; text.isVerticallyResizable = true
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.backgroundColor = Palette.canvas
        gutter.translatesAutoresizingMaskIntoConstraints = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gutter); view.addSubview(scroll)
        NSLayoutConstraint.activate([gutter.leadingAnchor.constraint(equalTo: view.leadingAnchor), gutter.widthAnchor.constraint(equalToConstant: 54),
            gutter.topAnchor.constraint(equalTo: view.topAnchor), gutter.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: gutter.trailingAnchor), scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        text.delegate = self
        text.lineActivated = { [weak self] in
            if let self, let n = self.patchTargetLine() { self.onDiffLine?(n) }
        }
        replace(source)
    }

    func replace(_ source: String) {
        let old = text.selectedRange(), position = scroll.contentView.bounds.origin
        replacing = true
        text.string = source
        let length = (source as NSString).length
        text.setSelectedRange(NSRange(location: min(old.location,length), length: 0))
        text.undoManager?.removeAllActions()
        dirty = false; conflict = false
        replacing = false
        indexLines()
        scroll.contentView.scroll(to: position); scroll.reflectScrolledClipView(scroll.contentView)
        highlight(); redraw()
    }
    @objc private func redraw() {
        gutter.needsDisplay = true
        guard !paintQueued else { return }
        paintQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.paintQueued = false
            self.paintVisibleText()
        }
    }
    private func indexLines() {
        lineStarts = [0]
        var index = 0
        for unit in text.string.utf16 { index += 1; if unit == 10 { lineStarts.append(index) } }
    }
    func lineNumber(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count
        while low < high {
            let mid = (low + high)/2
            if lineStarts[mid] <= offset { low = mid+1 } else { high = mid }
        }
        return max(1,low)
    }
    var cursor: (line: Int, column: Int) {
        let offset = text.selectedRange().location, line = lineNumber(at: offset)
        return (line, offset-lineStarts[line-1]+1)
    }
    func go(_ line: Int, column: Int = 0, length: Int = 0) {
        let i = max(0, min(lineStarts.count-1, line-1))
        let end = i+1 < lineStarts.count ? lineStarts[i+1]-1 : (text.string as NSString).length
        let offset = min(end, lineStarts[i] + column)
        let range = NSRange(location: offset, length: min(length,end-offset))
        text.setSelectedRange(range); text.scrollRangeToVisible(range); redraw()
    }
    func textDidChange(_ notification: Notification) {
        guard !replacing else { return }
        dirty = text.string != base?.text; pinned = true
        indexLines(); highlight(); redraw(); onChange?()
    }
    func textViewDidChangeSelection(_ notification: Notification) { if !replacing { onCursor?() } }

    private func highlight() {
        revision += 1
        let generation = revision
        paintedRange = nil
        pendingHighlight?.cancel()
        if isPatch { redraw(); return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, generation == self.revision else { return }
            self.worker.parse(self.text.string) { [weak self] tokens in
                guard let self, generation == self.revision else { return }
                self.tokens = tokens
                self.paintedRange = nil
                self.redraw()
            }
        }
        pendingHighlight = item
        DispatchQueue.main.asyncAfter(deadline:.now()+0.09,execute:item)
    }
    func becameVisible() { redraw() }
    private func paintVisibleText() {
        guard let storage = text.textStorage, storage.length > 0, text.window != nil else { return }
        var target = NSRange(location:0,length:storage.length)
        if storage.length > 32_768, let manager = text.textLayoutManager,
           let viewport = manager.textViewportLayoutController.viewportRange, let content = manager.textContentManager {
            let start = content.offset(from:content.documentRange.location,to:viewport.location)
            let end = content.offset(from:content.documentRange.location,to:viewport.endLocation)
            let first = lineNumber(at:max(0,start))-1, last = lineNumber(at:min(storage.length,end))-1
            let low = lineStarts[max(0,first-18)], high = last+19 < lineStarts.count ? lineStarts[last+19] : storage.length
            let visible = NSRange(location:start,length:max(0,end-start))
            if let paintedRange, NSIntersectionRange(visible,paintedRange) == visible { return }
            target = NSRange(location:low,length:max(0,high-low))
        }
        if target == paintedRange { return }
        paintedRange = target
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.addAttribute(.foregroundColor,value:Palette.text,range:target)
        if worker.isMarkdown {
            storage.addAttribute(.font, value: Palette.code, range: target)
            storage.removeAttribute(.strikethroughStyle, range: target)
        }
        if isPatch {
            storage.removeAttribute(.backgroundColor,range:target)
            let ns = storage.string as NSString
            var start = target.location
            while start < NSMaxRange(target) {
                let range = ns.lineRange(for:NSRange(location:start,length:0))
                let first = ns.character(at:start)
                let ink = first == 43 ? Palette.green : first == 45 ? Palette.red : first == 64 ? Palette.blue : Palette.text
                storage.addAttribute(.foregroundColor,value:ink,range:range)
                if first == 43 || first == 45 { storage.addAttribute(.backgroundColor,value:ink.withAlphaComponent(0.1),range:range) }
                start = NSMaxRange(range)
            }
            return
        }
        var low = 0, high = tokens.count
        while low < high {
            let mid = (low + high)/2, token = tokens[mid]
            if Int(token.start + token.length) <= target.location { low = mid+1 } else { high = mid }
        }
        for token in tokens[low...] {
            if Int(token.start) >= NSMaxRange(target) { break }
            let range = NSIntersectionRange(target,NSRange(location:Int(token.start),length:Int(token.length)))
            guard range.length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: Palette.syntax[Int(token.color)], range: range)
            let fontIndex = Int(token.traits) & (VSBold | VSItalic)
            if fontIndex != 0 {
                storage.addAttribute(.font, value: Palette.markdownFonts[fontIndex], range: range)
            }
            if Int(token.traits) & VSStrike != 0 {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
    }
    private func patchTargetLine() -> Int? {
        guard isPatch else { return nil }
        let ns = text.string as NSString
        var target: Int?
        for i in 0..<cursor.line where lineStarts[i] < ns.length {
            let line = ns.substring(with: ns.lineRange(for: NSRange(location: lineStarts[i],length: 0)))
            if line.hasPrefix("@@ "), let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                target = Int(plus.dropFirst().prefix(while: \.isNumber))
                continue
            }
            guard let n = target else { continue }
            if i == cursor.line-1 { return line.hasPrefix("+") || line.hasPrefix(" ") ? n : nil }
            if line.hasPrefix("+") || line.hasPrefix(" ") { target = n+1 }
        }
        return nil
    }
    func save() throws {
        guard dirty, let base else { return }
        let output = try base.encoded(text.string)
        var coordinationError: NSError?, writeError: Error?
        let destination = url.resolvingSymlinksInPath()
        NSFileCoordinator().coordinate(writingItemAt: destination, options: [], error: &coordinationError) { target in
            do {
                guard let current = try? Data(contentsOf: target), current == base.data else {
                    self.conflict = true
                    throw CyberPeekError("磁盘文件已经改变。请先比较两个版本。")
                }
                try output.write(to: target, options: .atomic)
            } catch { writeError = error }
        }
        if let error = writeError ?? coordinationError { throw error }
        self.base = try DiskText(output); dirty = false; conflict = false
        onChange?()
    }
}
