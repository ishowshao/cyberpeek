import XCTest
@testable import CyberPeek

final class DocumentTests: XCTestCase {
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
