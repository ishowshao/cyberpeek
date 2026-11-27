import XCTest
@testable import CyberPeek

final class DocumentTests: XCTestCase {
    @MainActor func testDeleteUndoRedoUsingEditorKeyboardShortcuts() async throws {
        let folder = try makeTestWorkspace()
        let file = folder.appendingPathComponent("note.txt")
        let original = "保留这一段"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let bench = Workbench()
        defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        if !NSApp.isActive {
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: .init())
        }
        bench.window.makeKeyAndOrderFront(nil)
        bench.openFolder(folder, remember: false)
        bench.open(.file(file))
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            bench.current?.url == file && bench.window.isKeyWindow
        }, object: nil)
        await fulfillment(of: [opened], timeout: 5)
        let editor = try XCTUnwrap(bench.current)
        XCTAssertTrue(bench.window.firstResponder === editor.text)

        func press(_ code: CGKeyCode, modifiers: CGEventFlags = []) throws {
            for down in [true, false] {
                let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
                event.flags = modifiers
                NSApp.sendEvent(try XCTUnwrap(NSEvent(cgEvent: event)))
            }
        }
        editor.text.setSelectedRange((original as NSString).range(of: "这一段"))
        try press(51) // Delete
        XCTAssertEqual(editor.text.string, "保留")
        XCTAssertTrue(editor.dirty)
        let editMenu = try XCTUnwrap(NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "编辑" })
        editMenu.update()
        let undo = try XCTUnwrap(editMenu.items.first { $0.action == #selector(SourceTextView.undo(_:)) })
        let redo = try XCTUnwrap(editMenu.items.first { $0.action == #selector(SourceTextView.redo(_:)) })
        XCTAssertTrue(undo.isEnabled)
        XCTAssertFalse(redo.isEnabled)
        try press(6, modifiers: .maskCommand) // ⌘Z
        XCTAssertEqual(editor.text.string, original)
        XCTAssertFalse(editor.dirty)
        editMenu.update()
        XCTAssertTrue(redo.isEnabled)
        try press(6, modifiers: [.maskCommand, .maskShift]) // ⇧⌘Z
        XCTAssertEqual(editor.text.string, "保留")
        XCTAssertTrue(editor.dirty)
    }

    @MainActor private func showText(_ source: String, filename: String = "sample.txt") throws -> (Editor, NSWindow) {
        let file = try makeTestWorkspace().appendingPathComponent(filename)
        let disk = try DiskText(Data(source.utf8))
        let editor = Editor(url: file, identity: file.path, title: file.lastPathComponent, source: source, disk: disk)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor.text)
        editor.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return (editor, window)
    }

    @MainActor func testJSONColorsObjectKeysAndValues() throws {
        let source = #"{"name":"name","items":[{"转义\"🔑":"x:y"},"array",42,true,null]}"#
        let (editor, window) = try showText(source, filename: "sample.json")
        defer { window.orderOut(nil) }
        let storage = try XCTUnwrap(editor.text.textStorage)
        let value = Palette.syntax[2], literal = Palette.syntax[3]
        let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let offset = (source as NSString).range(of: "array").location
            return storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor == value
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 3), .completed)

        var strings: [String] = [], colors: [NSColor] = []
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { color, range, _ in
            guard let color = color as? NSColor, color != Palette.text else { return }
            strings.append((source as NSString).substring(with: range))
            colors.append(color)
        }
        XCTAssertEqual(strings, [#""name""#, #""name""#, #""items""#, #""转义\"🔑""#,
                                 #""x:y""#, #""array""#, "42", "true", "null"])
        XCTAssertEqual(colors, [Palette.blue, value, Palette.blue, Palette.blue, value, value, literal, literal, literal])
    }

    @MainActor func testScrollingKeepsOverlayStyleWhenAppKitRequestsLegacyScrollers() throws {
        let (editor, window) = try showText(String(repeating: String(repeating: "x", count: 200) + "\n", count: 60))
        defer { window.orderOut(nil) }
        let list = resultScroll(NSTableView())
        for scroll in [editor.scroll as NSScrollView, list] {
            XCTAssertEqual(scroll.scrollerStyle, .overlay)
            scroll.scrollerStyle = .legacy
            XCTAssertEqual(scroll.scrollerStyle, .overlay)
            XCTAssertEqual(scroll.verticalScroller?.scrollerStyle, .overlay)
        }
        XCTAssertEqual(editor.scroll.horizontalScroller?.scrollerStyle, .overlay)
    }

    @MainActor func testFirstScreenLeavesDistantTextUnlaid() throws {
        let source = String(repeating: "A line of text\n", count: 8_000)
        let (editor, window) = try showText(source)
        defer { window.orderOut(nil) }
        let layout = try XCTUnwrap(editor.text.textLayoutManager)
        let content = try XCTUnwrap(layout.textContentManager)
        layout.textViewportLayoutController.layoutViewport()
        XCTAssertEqual(layout.textLayoutFragment(for: content.documentRange.location)?.state, .layoutAvailable)
        let middle = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: source.utf16.count / 2))
        XCTAssertNotEqual(layout.textLayoutFragment(for: middle)?.state, .layoutAvailable)
    }

    @MainActor func testOffscreenLinesDoNotChangeFirstLineNumber() throws {
        func firstLineNumber(lineCount: Int) throws -> Data {
            let folder = try makeTestWorkspace()
            let file = folder.appendingPathComponent("Sample.swift")
            // Long lines make the horizontal scroller appear while first-screen layout is settling.
            let lines = (0..<lineCount).map { line in
                let value = String(repeating: "x", count: line.isMultiple(of: 10) ? 160 : 20)
                return "let v = \"\(value)\""
            }
            try ("import AppKit\n" + lines.joined(separator: "\n")).write(to: file, atomically: true, encoding: .utf8)
            let bench = Workbench()
            defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
            bench.window.makeKeyAndOrderFront(nil)
            bench.openFolder(folder, remember: false)
            bench.open(.file(file))
            let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                bench.current?.text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Palette.syntax[4]
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 3), .completed)
            let editor = try XCTUnwrap(bench.current)
            let top = editor.scroll.frame.maxY - editor.text.textContainerInset.height
            let rect = NSRect(x: 0, y: top - 20, width: editor.scroll.frame.minX, height: 20)
            let bitmap = try XCTUnwrap(editor.view.bitmapImageRepForCachingDisplay(in: rect))
            editor.view.cacheDisplay(in: rect, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let short = try firstLineNumber(lineCount: 3)
        XCTAssertEqual(try firstLineNumber(lineCount: 253), short)
    }

    @MainActor func testSearchResultShowsAsMuchOfLineStartAsFits() throws {
        let folder = try makeTestWorkspace(), name = "sample.txt"
        let file = folder.appendingPathComponent(name)
        let line = String(repeating: "a", count: 16) + "near" + "\t🍓中文" + String(repeating: "a", count: 200) + "far"
            + String(repeating: "z", count: 180)
        let prefix = String(repeating: "short\n", count: 180)
        try (prefix + line).write(to: file, atomically: true, encoding: .utf8)
        let bench = Workbench()
        defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        bench.window.makeKeyAndOrderFront(nil)
        bench.openFolder(folder, remember: false)
        bench.selectSection(.search)
        func openHit(_ range: NSRange) {
            let hit = SearchHit(path: name, line: 181, excerpt: line, column: range.location, length: range.length)
            bench.side.onOpen?(.searchHit(hit), false)
        }
        let near = (line as NSString).range(of: "near"), far = (line as NSString).range(of: "far")
        openHit(far) // First activation loads the document asynchronously.
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in bench.current?.url == file }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 5), .completed)
        let editor = try XCTUnwrap(bench.current), clip = editor.scroll.contentView
        func selectionRect(_ local: NSRange, at sourceLine: UInt = #line) -> NSRect {
            bench.window.displayIfNeeded()
            let range = NSRange(location: prefix.utf16.count + local.location, length: local.length)
            XCTAssertEqual(editor.text.selectedRange(), range, line: sourceLine)
            let screen = editor.text.firstRect(forCharacterRange: range, actualRange: nil)
            let rect = editor.text.convert(bench.window.convertFromScreen(screen), from: nil)
            XCTAssertGreaterThan(rect.height, 0, line: sourceLine)
            XCTAssertTrue(clip.bounds.minY <= rect.midY && rect.midY <= clip.bounds.maxY, line: sourceLine)
            return rect
        }

        let farRect = selectionRect(far)
        XCTAssertEqual(clip.bounds.maxX, farRect.maxX, accuracy: 1)
        XCTAssertLessThanOrEqual(clip.bounds.minX, farRect.minX)
        clip.scroll(to: NSPoint(x: 100, y: clip.bounds.minY))
        openHit(near) // Already visible at x=100, but also visible at the line start.
        let nearRect = selectionRect(near)
        XCTAssertEqual(clip.bounds.minX, 0, accuracy: 0.5)
        XCTAssertLessThan(nearRect.maxX, clip.bounds.maxX)

        // Straddle the right edge: some of the match already fits at the origin.
        let edge = editor.text.characterIndexForInsertion(at: NSPoint(x: clip.bounds.maxX, y: nearRect.midY))
        let partial = NSRange(location: edge - prefix.utf16.count - 2, length: 12)
        openHit(partial)
        let partialRect = selectionRect(partial)
        XCTAssertGreaterThan(clip.bounds.minX, 0)
        XCTAssertEqual(clip.bounds.maxX, partialRect.maxX, accuracy: 1)

        let caret = NSRange(location: far.location, length: 0)
        openHit(caret)
        let caretRect = selectionRect(caret)
        XCTAssertEqual(clip.bounds.maxX, caretRect.minX, accuracy: 1)
        let oversized = (line as NSString).range(of: String(repeating: "z", count: 180))
        openHit(oversized)
        let wideRect = selectionRect(oversized)
        XCTAssertEqual(clip.bounds.minX, wideRect.minX, accuracy: 1)
    }

    @MainActor func testScrolledSelectionAndMarkedTextUseVisibleCoordinates() throws {
        let precedingLines = String(repeating: "短行\n", count: 2_000)
        let prefix = String(repeating: "a", count: 150) + "🍓"
        let source = precedingLines + prefix + "目标\n"
        let (editor, window) = try showText(source)
        defer { window.orderOut(nil) }
        let text = editor.text
        let target = (source as NSString).range(of: "目标")
        editor.go(2_001, column: prefix.utf16.count, matchLength: target.length)
        XCTAssertEqual(text.selectedRange(), target)
        XCTAssertEqual(editor.cursor.line, 2_001)

        // The input method requests a screen rect; mouse hit-testing uses view coordinates.
        func checkGeometry(_ range: NSRange) {
            let rect = text.firstRect(forCharacterRange: range, actualRange: nil)
            let point = text.convert(window.convertPoint(fromScreen: NSPoint(x: rect.minX + 1, y: rect.midY)), from: nil)
            XCTAssertGreaterThan(rect.height, 0)
            XCTAssertTrue(text.visibleRect.contains(point))
            XCTAssertEqual(text.characterIndexForInsertion(at: point), range.location)
        }
        checkGeometry(target)
        XCTAssertGreaterThan(editor.scroll.contentView.bounds.minX, 0)
        XCTAssertGreaterThan(editor.scroll.contentView.bounds.minY, 0)

        text.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0), replacementRange: target)
        XCTAssertEqual(text.markedRange(), target)
        checkGeometry(text.markedRange())
        text.insertText("中文", replacementRange: text.markedRange())
        XCTAssertFalse(text.hasMarkedText())
        XCTAssertTrue(text.string.hasSuffix("中文\n"))

        editor.go(1)
        checkGeometry(NSRange(location: 0, length: 1))
    }

    @MainActor func testCopyRelativePathFromBreadcrumbAndOtherTreeRow() throws {
        let root = try makeTestWorkspace()
        let folder = root.appendingPathComponent("源码 目录")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let active = folder.appendingPathComponent("main.swift")
        let other = folder.appendingPathComponent("说明 #1.md")
        try Data().write(to: active)
        try Data().write(to: other)

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let workbench = Workbench(pathPasteboard: board)
        workbench.root = root
        workbench.side.reset(root)
        workbench.open(.file(active))
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            workbench.current != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 3), .completed)
        workbench.window.contentView?.layoutSubtreeIfNeeded()

        func descendant<T: NSView>(_ type: T.Type, in parent: NSView) -> T? {
            if let found = parent as? T { return found }
            return parent.subviews.lazy.compactMap { descendant(type, in: $0) }.first
        }
        let button = try XCTUnwrap(descendant(NSButton.self, in: workbench.crumbBar))
        button.performClick(nil)
        XCTAssertEqual(board.string(forType: .string), "源码 目录/main.swift")
        let outline = try XCTUnwrap(descendant(NSOutlineView.self, in: workbench.side.view))
        let row = try XCTUnwrap((0..<outline.numberOfRows).first {
            (outline.item(atRow: $0) as? SideNode)?.name == other.lastPathComponent
        })
        XCTAssertNotEqual(outline.selectedRow, row)
        let rect = outline.rect(ofRow: row)
        let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: workbench.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(outline.menu(for: event))
        let item = try XCTUnwrap(menu.item(withTitle: "复制相对路径"))
        menu.performActionForItem(at: menu.index(of: item))
        XCTAssertEqual(board.string(forType: .string), "源码 目录/说明 #1.md")
        XCTAssertEqual(workbench.current?.url.lastPathComponent, active.lastPathComponent)
    }

    func testUTF16AndCRLFRoundTrip() throws {
        let string = "第一行\r\n🍓 second\r\n"
        let data = Data([0xff,0xfe]) + (try XCTUnwrap(string.data(using:.utf16LittleEndian)))
        let disk = try DiskText(data)
        XCTAssertTrue(disk.crlf)
        XCTAssertEqual(disk.text,"第一行\n🍓 second\n")
        XCTAssertEqual(try disk.encoded(disk.text),data)
    }

    @MainActor func testExternalSaveConflictPreservesBothVersions() throws {
        let folder = try makeTestWorkspace()
        let file = folder.appendingPathComponent("sample.txt")
        try Data("base\n".utf8).write(to:file)
        let base = try DiskText.read(file)
        let editor = Editor(url:file,identity:file.path,title:"sample",source:base.text,disk:base)
        editor.text.insertText("local",replacementRange:NSRange(location:0,length:4))
        XCTAssertTrue(editor.dirty)
        try Data("agent\n".utf8).write(to:file,options:.atomic)
        XCTAssertThrowsError(try editor.save())
        XCTAssertTrue(editor.conflict)
        XCTAssertEqual(editor.text.string,"local\n")
        XCTAssertEqual(try DiskText.read(file).text,"agent\n")
    }

    @MainActor func testSwiftKeywordHasVisibleColor() throws {
        let file = try makeTestWorkspace().appendingPathComponent("example.swift")
        let disk = try DiskText(Data("func hello() {}\n".utf8))
        let editor = Editor(url:file,identity:file.path,title:"example",source:disk.text,disk:disk)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:240),styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView = editor.view
        window.contentView?.layoutSubtreeIfNeeded()
        let painted = NSPredicate { _, _ in
            editor.text.textStorage?.attribute(.foregroundColor,at:0,effectiveRange:nil) as? NSColor == Palette.syntax[4]
        }
        let expectation = XCTNSPredicateExpectation(predicate:painted,object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[expectation],timeout:3),.completed)
    }

    func testSearchReturnsUTF16SelectionAfterEmoji() throws {
        let folder = try makeTestWorkspace()
        try "🍓中文 search here\n".write(to:folder.appendingPathComponent("test.txt"),atomically:true,encoding:.utf8)
        var hits = [SearchHit]()
        try WorkspaceSearch.find("search",in:folder,job:ShellJob()) { hits += $0 }
        XCTAssertEqual(hits.count,1)
        XCTAssertEqual(hits.first?.column,5)
        XCTAssertEqual(hits.first?.length,6)
    }
}
