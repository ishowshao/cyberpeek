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

    // Handle the Edit menu here so it uses this tab's history while the editor has focus.
    @objc func undo(_ sender: Any?) { localUndo.undo() }
    @objc func redo(_ sender: Any?) { localUndo.redo() }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return localUndo.canUndo
        case #selector(redo(_:)): return localUndo.canRedo
        default: return super.validateMenuItem(menuItem)
        }
    }

    // Source text starts at the top-left inset. Asking AppKit for the used text
    // bounds here would lay out offscreen paragraphs just to position the first one.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: textContainerInset.height)
    }

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

private final class EditorLineBackground: NSView, NSViewToolTipOwner {
    private struct Deletion: Equatable {
        let y: CGFloat
        let count: Int
    }
    private var visibleDeletions = [Deletion]()
    private var toolTipCounts = [NSView.ToolTipTag: Int]()
    weak var owner: Editor?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        let origin = owner.text.textContainerOrigin.y - owner.scroll.contentView.bounds.origin.y
        var deletions = [Deletion]()
        defer { drawDeletions(deletions) }
        if let count = owner.lineChanges.deletedAfter[0], origin >= -4 {
            deletions.append(Deletion(y: origin, count: count))
        }
        guard let manager = owner.text.textLayoutManager, let content = manager.textContentManager,
              let visible = manager.textViewportLayoutController.viewportRange else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        let font = owner.fontSettings.fonts.lineNumber
        let attrs: [NSAttributedString.Key:Any] = [.font: font,
                                                   .foregroundColor: Palette.muted, .paragraphStyle: style]
        let height = ceil(("0" as NSString).size(withAttributes: attrs).height)
        let gutterWidth = owner.scroll.frame.minX
        let scale = window?.backingScaleFactor ?? 1
        manager.enumerateTextLayoutFragments(from: visible.location, options: []) { fragment in
            let location = fragment.rangeInElement.location
            // Unlaid fragments can have a zero frame, even when they are far below the viewport.
            guard location.compare(visible.endLocation) != .orderedDescending else { return false }
            guard fragment.state == .layoutAvailable else { return true }
            let y = origin + fragment.layoutFragmentFrame.minY
            if y > self.bounds.maxY { return false }
            let index = content.offset(from: content.documentRange.location, to: location)
            let line = owner.lineNumber(at: index)
            let number = "\(line)" as NSString
            let lineHeight = fragment.textLineFragments.first?.typographicBounds.height ?? height
            if let kind = owner.lineChanges.kind(at: line) {
                let color = kind == .added ? Palette.green : Palette.blue
                let top = (y * scale).rounded() / scale
                let bottom = ((y + lineHeight) * scale).rounded() / scale
                color.withAlphaComponent(0.13).setFill()
                NSRect(x: 0, y: top, width: self.bounds.width, height: bottom - top).fill()
                color.setFill()
                NSRect(x: 0, y: top, width: 3, height: bottom - top).fill()
            }
            number.draw(in: NSRect(x: 0, y: y + (lineHeight - height)/2, width: gutterWidth-9, height: height), withAttributes: attrs)
            if let count = owner.lineChanges.deletedAfter[line] {
                deletions.append(Deletion(y: y + lineHeight, count: count))
            }
            return true
        }
    }

    private func drawDeletions(_ deletions: [Deletion]) {
        for deletion in deletions {
            let wedge = NSBezierPath()
            wedge.move(to: NSPoint(x: 0, y: deletion.y - 4))
            wedge.line(to: NSPoint(x: 9, y: deletion.y))
            wedge.line(to: NSPoint(x: 0, y: deletion.y + 4))
            wedge.close()
            Palette.red.setFill()
            wedge.fill()
        }
        guard visibleDeletions != deletions else { return }
        visibleDeletions = deletions
        removeAllToolTips()
        toolTipCounts.removeAll(keepingCapacity: true)
        for deletion in deletions {
            let hit = NSRect(x: 0, y: deletion.y - 6, width: 14, height: 12)
            toolTipCounts[addToolTip(hit, owner: self, userData: nil)] = deletion.count
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        toolTipCounts[tag].map { "此处删除了 \($0) 行" } ?? ""
    }
}

final class Editor: DocumentTab, NSTextViewDelegate {
    let view = NSView()
    let text = SourceTextView(usingTextLayoutManager: true)
    let scroll = OverlayScrollView()
    private let lineBackground = EditorLineBackground()
    private lazy var gutterWidth = scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 54)
    private(set) var lineChanges = GitLineChanges()
    private var lastChangeJump: (index: Int, scrollY: CGFloat)?
    var contentLineCount: Int {
        lineStarts.count - (lineStarts.last == text.textStorage?.length ? 1 : 0)
    }
    fileprivate let fontSettings: EditorFontSettings
    let change: Change?
    var base: DiskText?
    var supportsSVGPreview: Bool { !isPatch && url.pathExtension.lowercased() == "svg" }
    var showsSVGPreview = false
    var conflict = false
    var onChange: ((_ contentChanged: Bool) -> Void)?
    var onCursor: (() -> Void)?
    var onDiffLine: ((Int) -> Void)?
    private var lineStarts = [0]
    private let worker: SyntaxWorker
    private var tokens: [VSToken] = []
    private var paintedRange: NSRange?
    private var paintQueued = false
    private(set) var revision = 0
    private var pendingHighlight: DispatchWorkItem?
    private var replacing = false
    let isPatch: Bool

    init(url: URL, identity: String, title: String, source: String, disk: DiskText? = nil,
         change: Change? = nil, patch: Bool = false, fontSettings: EditorFontSettings = .shared) {
        self.fontSettings = fontSettings
        base = disk; self.change = change; isPatch = patch
        worker = SyntaxWorker(ext: patch ? "" : url.pathExtension.lowercased())
        super.init(url: url, identity: identity, title: title)
        view.fill(Palette.canvas); lineBackground.owner = self
        text.isRichText = false; text.allowsUndo = disk != nil; text.isEditable = disk != nil
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false; text.isGrammarCheckingEnabled = false
        text.isAutomaticLinkDetectionEnabled = false; text.smartInsertDeleteEnabled = false
        text.usesFindBar = true; text.isIncrementalSearchingEnabled = true
        text.backgroundColor = Palette.canvas; text.drawsBackground = false; text.textColor = Palette.text
        text.font = fontSettings.fonts.regular; text.insertionPointColor = Palette.text
        text.textContainerInset = NSSize(width: 4, height: 12)
        text.isHorizontallyResizable = true; text.isVerticallyResizable = true
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.place(lineBackground); view.addSubview(scroll)
        NSLayoutConstraint.activate([gutterWidth, scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeChanged), name: EditorFontSettings.didChange, object: fontSettings)
        if let undo = text.undoManager, disk != nil {
            for event in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(edited), name: event, object: undo)
            }
        }
        text.delegate = self
        text.lineActivated = { [weak self] in
            if let self, let n = self.patchTargetLine() { self.onDiffLine?(n) }
        }
        replace(source)
    }
    @objc private func fontSizeChanged() {
        text.font = fontSettings.fonts.regular
        text.typingAttributes[.font] = fontSettings.fonts.regular
        updateGutterWidth()
        paintedRange = nil
        redraw()
    }

    private func updateGutterWidth() {
        let digits = max(4, String(lineStarts.count).count)
        let width = ("0" as NSString).size(withAttributes: [.font: fontSettings.fonts.lineNumber]).width
        gutterWidth.constant = max(54, ceil(CGFloat(digits) * width) + 18)
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
        highlight(); redraw(); onChange?(true)
    }
    func setLineChanges(_ changes: GitLineChanges) {
        guard changes != lineChanges else { return }
        lineChanges = changes
        lastChangeJump = nil
        lineBackground.needsDisplay = true
    }
    func navigateChange(forward: Bool) {
        let hunks = lineChanges.hunks
        guard !hunks.isEmpty, let layout = text.textLayoutManager, let content = layout.textContentManager else { return }
        let clip = scroll.contentView
        let index = changeIndex(forward: forward, layout: layout, content: content)
        let lines = hunks[index].lines
        // The deletion marker sits on the bottom edge of the preceding surviving row.
        let firstLine = lines.isEmpty ? max(1, lines.lowerBound - 1) : lines.lowerBound
        let firstOffset = lineStarts[min(firstLine, lineStarts.count) - 1]
        let lastLine = max(firstLine, lines.upperBound - 1)
        let lastOffset = lineStarts[min(lastLine, lineStarts.count) - 1]
        guard let start = content.location(content.documentRange.location, offsetBy: firstOffset) else { return }
        let previousX = clip.bounds.minX
        text.scrollRangeToVisible(NSRange(location: firstOffset, length: 0))

        // Moving the viewport can revise TextKit's estimates for distant paragraphs.
        // Recheck the destination using the geometry of the newly visible rows.
        for _ in 0..<3 {
            layout.textViewportLayoutController.layoutViewport()
            paintVisibleText()
            text.layoutSubtreeIfNeeded()
            let extent = changeExtent(lines: lines, start: start, lastOffset: lastOffset, layout: layout, content: content)
            var bounds = clip.bounds
            let y = extent.upperBound - extent.lowerBound >= bounds.height
                ? extent.lowerBound : (extent.lowerBound + extent.upperBound - bounds.height) / 2
            bounds.origin = NSPoint(x: previousX, y: y)
            let target = clip.constrainBoundsRect(bounds).origin
            if abs(clip.bounds.minY - target.y) < 0.5 && clip.bounds.minX == target.x { break }
            clip.scroll(to: target)
            scroll.reflectScrolledClipView(clip)
        }
        lastChangeJump = (index, clip.bounds.minY)
        redraw()
    }

    private func changeIndex(forward: Bool, layout: NSTextLayoutManager, content: NSTextContentManager) -> Int {
        let hunks = lineChanges.hunks
        let bounds = scroll.contentView.bounds
        if let last = lastChangeJump, abs(last.scrollY - bounds.minY) < 1 {
            return (last.index + (forward ? 1 : -1) + hunks.count) % hunks.count
        }
        let caret = text.selectedRange().location
        let location = content.location(content.documentRange.location, offsetBy: caret)
        let fragment = location.flatMap { layout.textLayoutFragment(for: $0) }
        let reference: Int
        if let fragment, fragment.state == .layoutAvailable,
           bounds.intersects(fragment.layoutFragmentFrame.offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)) {
            reference = lineNumber(at: caret)
        } else {
            reference = lineNumber(at: text.characterIndexForInsertion(at: NSPoint(x: bounds.midX, y: bounds.midY)))
        }
        if forward {
            return hunks.firstIndex { max($0.lines.lowerBound, $0.lines.upperBound - 1) >= reference } ?? 0
        }
        return hunks.lastIndex { $0.lines.lowerBound <= reference } ?? hunks.count - 1
    }

    private func changeExtent(lines: Range<Int>, start: NSTextLocation, lastOffset: Int,
                              layout: NSTextLayoutManager, content: NSTextContentManager) -> ClosedRange<CGFloat> {
        let inset = text.textContainerOrigin.y
        if lines.isEmpty && lines.lowerBound == 1 { return inset...inset }
        let viewportHeight = scroll.contentView.bounds.height
        var top: CGFloat?, bottom = inset
        // Measure at most one screen of fragments, even for a whole-file insertion.
        layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let y = inset + fragment.layoutFragmentFrame.minY
            if top == nil { top = y }
            bottom = y + (fragment.textLineFragments.first?.typographicBounds.height ?? fragment.layoutFragmentFrame.height)
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            return offset < lastOffset && bottom - (top ?? y) < viewportHeight
        }
        return (lines.isEmpty ? bottom : min(top ?? bottom, bottom))...bottom
    }
    @objc private func redraw() {
        lineBackground.needsDisplay = true
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
        updateGutterWidth()
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
        if let manager = text.undoManager, manager.isUndoing || manager.isRedoing { return }
        edited()
    }
    @objc private func edited() {
        guard !replacing else { return }
        dirty = text.string != base?.text; pinned = true
        indexLines(); highlight(); redraw(); onChange?(true)
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        lastChangeJump = nil
        if !replacing { onCursor?() }
    }

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
            storage.addAttribute(.font, value: fontSettings.fonts.regular, range: target)
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
                storage.addAttribute(.font, value: fontSettings.fonts.markdown[fontIndex], range: range)
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
        onChange?(false)
    }
}
