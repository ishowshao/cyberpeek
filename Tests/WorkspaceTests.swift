import XCTest
@testable import CyberPeek

extension XCTestCase {
    func makeTestWorkspace() throws -> URL {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let folder = project.appendingPathComponent(".build/TestWorkspaces", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }
}

final class WorkspaceTests: XCTestCase {
    @MainActor func testWorkspaceRefreshKeepsSearchRowsUntilMatchesChange() throws {
        let root = try makeTestWorkspace()
        let first = root.appendingPathComponent("a.txt"), second = root.appendingPathComponent("b.txt")
        try "needle".write(to: first, atomically: true, encoding: .utf8)
        try "other".write(to: second, atomically: true, encoding: .utf8)
        let bench = Workbench()
        defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        bench.openFolder(root, remember: false)
        bench.monitor = nil // Deliver file events at known points in the search.
        bench.selectSection(.search)
        bench.side.query.stringValue = "needle"
        bench.search("needle")
        func waitFor(_ predicate: @escaping () -> Bool, line: UInt = #line) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, line: line)
        }
        waitFor { bench.side.searchInfo == "1 个匹配" }
        let outline = try XCTUnwrap(descendants(NSOutlineView.self, of: bench.side.view).first)
        let group = try XCTUnwrap(outline.item(atRow: 0) as? SideNode)
        outline.collapseItem(group)
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let originalVersion = bench.queryVersion

        bench.refresh(changedPaths: [root.appendingPathComponent("project/.build/output").path])
        XCTAssertEqual(bench.queryVersion, originalVersion)
        XCTAssertEqual(bench.side.hits.count, 1)
        bench.refresh(changedPaths: [second.path])
        let inFlight = bench.queryJob
        bench.refresh(changedPaths: [second.path])
        XCTAssertTrue(bench.queryJob === inFlight)
        XCTAssertEqual(bench.side.searchInfo, "1 个匹配")
        XCTAssertTrue(outline.item(atRow: 0) as? SideNode === group)
        waitFor { bench.queryJob == nil }
        XCTAssertEqual(bench.queryVersion, originalVersion + 2)
        XCTAssertTrue(outline.item(atRow: outline.selectedRow) as? SideNode === group)
        XCTAssertFalse(outline.isItemExpanded(group))

        try "needle".write(to: second, atomically: true, encoding: .utf8)
        bench.refresh(changedPaths: [second.path])
        XCTAssertEqual(bench.side.hits.map(\.path), ["a.txt"])
        waitFor { bench.side.searchInfo == "2 个匹配" }
        XCTAssertEqual(Set(bench.side.hits.map(\.path)), ["a.txt", "b.txt"])
        XCTAssertTrue(outline.item(atRow: outline.selectedRow) as? SideNode === group)
        XCTAssertFalse(outline.isItemExpanded(group))
        let secondGroup = try XCTUnwrap(outline.item(atRow: 1) as? SideNode)
        XCTAssertTrue(outline.isItemExpanded(secondGroup))
        let retainedHit = try XCTUnwrap(outline.item(atRow: 2) as? SideNode)
        try "needle\nneedle".write(to: second, atomically: true, encoding: .utf8)
        bench.refresh(changedPaths: [second.path])
        waitFor { bench.side.searchInfo == "3 个匹配" }
        XCTAssertTrue(outline.item(atRow: 2) as? SideNode === retainedHit)
        try FileManager.default.removeItem(at: first)
        bench.refresh(changedPaths: [first.path])
        waitFor { bench.side.hits.map(\.path) == ["b.txt", "b.txt"] }

        bench.refresh(changedPaths: [second.path])
        bench.side.query.stringValue = "absent"
        bench.search("absent")
        waitFor { bench.side.searchInfo == "0 个匹配" }
        XCTAssertTrue(bench.side.hits.isEmpty)
    }

    @MainActor private func descendants<T: NSView>(_ type: T.Type, of view: NSView) -> [T] {
        if let match = view as? T { return [match] }
        return view.subviews.flatMap { descendants(type, of: $0) }
    }

    func testQuickOpenIndexPreservesPathsAcrossOutputChunks() throws {
        let root = try makeTestWorkspace()
        try ShellJob().run(Tools.git, ["init", "-q"], in: root)
        let suffix = String(repeating: "文", count: 46) + "\n.js"
        let names = (0..<1000).map { "\($0) \(suffix)" }
        for name in names { try Data().write(to: root.appendingPathComponent(name)) }
        XCTAssertEqual(try WorkspaceSearch.paths(in: root, job: ShellJob()), names.sorted())
    }

    func testCappedSearchReturnsTheSameMatchesAfterUnrelatedChanges() throws {
        let root = try makeTestWorkspace()
        let matches = String(repeating: "needle\n", count: 50)
        for index in (0..<30).reversed() {
            try matches.write(to: root.appendingPathComponent(String(format: "%02d.txt", index)),
                              atomically: true, encoding: .utf8)
        }
        func search() throws -> [SearchHit] {
            var hits: [SearchHit] = []
            do { try WorkspaceSearch.find("needle", in: root, job: ShellJob()) { hits += $0 } }
            catch is CancellationError {} // ripgrep stops after the result limit.
            return hits
        }
        let before = try search()
        XCTAssertEqual(before.count, 1200)
        try "other".write(to: root.appendingPathComponent("unrelated.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try search(), before)
    }

    @MainActor func testSearchResultEditsKeepVisibleHitAtSameHeight() throws {
        let bench = Workbench()
        defer { bench.window.orderOut(nil) }
        bench.window.orderFront(nil)
        bench.selectSection(.search)
        func hit(_ file: String, _ line: Int) -> SearchHit {
            SearchHit(path: file, line: line, excerpt: "found", column: 0, length: 5)
        }
        let matches = (1...100).map { hit("b.txt", $0) }
        bench.side.hits = [hit("a.txt", 1)] + matches
        bench.side.reload()
        bench.window.contentView?.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(descendants(NSOutlineView.self, of: bench.side.view).first)
        let anchor = try XCTUnwrap(outline.item(atRow: 60) as? SideNode)
        outline.selectRowIndexes(IndexSet(integer: 60), byExtendingSelection: false)
        outline.scrollRowToVisible(65)
        let offset = outline.rect(ofRow: 60).minY - outline.visibleRect.minY

        // Insert and remove both file groups and matches above the viewport.
        bench.side.hits = [hit("0.txt", 1)] + matches.dropFirst(8) + [hit("c.txt", 1)]
        bench.side.reload()
        XCTAssertTrue(outline.item(atRow: outline.selectedRow) as? SideNode === anchor)
        XCTAssertEqual(outline.rect(ofRow: outline.row(forItem: anchor)).minY - outline.visibleRect.minY, offset, accuracy: 1)
        XCTAssertEqual(outline.numberOfRows, 97)
    }

    func testWideChangeListKeepsExpandedGroupWhenFilesArrive() throws {
        let repo = try makeTestWorkspace()
        let changes = (0..<401).map { Change(path: "files/\($0).js", oldPath: nil, flag: "U", area: .untracked) }
        let before = SideNode.changeNodes(Array(changes.dropLast()), repo: repo)
        let after = SideNode.changeNodes(changes, repo: repo)
        XCTAssertEqual(before.map(\.key), after.prefix(before.count).map(\.key))
        XCTAssertEqual(after.count, 3)
        XCTAssertTrue(after.allSatisfy { $0.children == nil })
        XCTAssertEqual(after.flatMap { $0.items(in: nil) }.map(\.name), changes.map(\.path))
    }

    @MainActor func testCollapseFoldersClearsNestedExpansionAndSurvivesRefresh() throws {
        let root = try makeTestWorkspace()
        for path in ["App/Models", "Tests/Unit", "Tests/Unopened/Deep"] {
            let directory = root.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: directory.appendingPathComponent("sample.swift"))
        }
        let side = Sidebar()
        side.reset(root)
        let outline = try XCTUnwrap(descendants(NSOutlineView.self, of: side.view).first)
        let button = try XCTUnwrap(descendants(NSButton.self, of: side.view).first { $0.toolTip == "折叠所有文件夹" })
        func visible() -> [SideNode] {
            (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SideNode }
        }
        func node(_ name: String) throws -> SideNode { try XCTUnwrap(visible().first { $0.name == name }) }
        side.reveal(root.appendingPathComponent("App/Models/sample.swift"))
        outline.collapseItem(try node("App"))
        side.reveal(root.appendingPathComponent("Tests/Unit/sample.swift"))
        let unopened = try node("Unopened")
        XCTAssertNil(unopened.children)

        button.performClick(nil)
        XCTAssertEqual(visible().map(\.name), [root.lastPathComponent, "App", "Tests"])
        XCTAssertNil(unopened.children)
        for name in ["App", "Tests"] { outline.expandItem(try node(name)) }
        XCTAssertFalse(outline.isItemExpanded(try node("Models")))
        XCTAssertFalse(outline.isItemExpanded(try node("Unit")))

        button.performClick(nil)
        side.reload()
        XCTAssertEqual(visible().map(\.name), [root.lastPathComponent, "App", "Tests"])
        for section in [Section.search, .git] { side.switchTo(section); XCTAssertTrue(button.isHidden) }
        side.switchTo(.files)
        XCTAssertFalse(button.isHidden)
        outline.collapseItem(try node(root.lastPathComponent))
        button.performClick(nil)
        XCTAssertEqual(visible().map(\.name), [root.lastPathComponent])
    }

    @MainActor func testTabClickCentersExplorerRowWithinScrollLimits() throws {
        let root = try makeTestWorkspace()
        let directory = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (0..<100).map { directory.appendingPathComponent("File\($0).txt") }
        for file in files { try Data().write(to: file) }

        let bench = Workbench()
        defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        bench.root = root
        bench.side.reset(root)
        bench.window.makeKeyAndOrderFront(nil)
        for index in [0, 50, 52, 99] {
            let opened = expectation(description: "Open " + files[index].lastPathComponent)
            bench.open(.file(files[index]), pin: true) { opened.fulfill() }
            wait(for: [opened], timeout: 3)
        }
        bench.window.contentView?.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(descendants(NSOutlineView.self, of: bench.side.view).first)
        func clickTab(_ index: Int) throws {
            let button = try XCTUnwrap(descendants(NSButton.self, of: bench.tabs).first { $0.toolTip == files[index].path })
            button.performClick(nil)
            XCTAssertEqual((outline.item(atRow: outline.selectedRow) as? SideNode)?.key, files[index].path)
        }

        let folder = try XCTUnwrap(outline.parent(forItem: outline.item(atRow: outline.selectedRow)))
        outline.collapseItem(folder)
        try clickTab(50)
        XCTAssertEqual(outline.rect(ofRow: outline.selectedRow).midY, outline.visibleRect.midY, accuracy: 1)

        let beforeClick = outline.visibleRect.minY
        let nearby = try XCTUnwrap((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SideNode)?.key == files[52].path })
        outline.selectRowIndexes(IndexSet(integer: nearby), byExtendingSelection: false)
        outline.sendAction(outline.action, to: outline.target)
        XCTAssertEqual(bench.activeDocument?.url, files[52])
        XCTAssertEqual(outline.visibleRect.minY, beforeClick, accuracy: 1)
        try clickTab(52)
        XCTAssertEqual(outline.rect(ofRow: nearby).midY, outline.visibleRect.midY, accuracy: 1)

        try clickTab(0)
        XCTAssertEqual(outline.visibleRect.minY, outline.bounds.minY, accuracy: 1)
        try clickTab(99)
        XCTAssertEqual(outline.visibleRect.maxY, outline.bounds.maxY, accuracy: 1)
    }

    @MainActor func testWorkspaceRefreshKeepsManuallyScrolledExplorerPosition() throws {
        let root = try makeTestWorkspace()
        try ShellJob().run(Tools.git, ["init", "-q"], in: root)
        let files = (0..<120).map { root.appendingPathComponent("File\($0).txt") }
        for file in files { try Data().write(to: file) }
        let bench = Workbench()
        defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        bench.window.orderFront(nil)
        bench.openFolder(root, remember: false)
        let opened = expectation(description: "Open selected file")
        bench.open(.file(files[4]), pin: true) { opened.fulfill() }
        wait(for: [opened], timeout: 3)
        bench.window.contentView?.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(descendants(NSOutlineView.self, of: bench.side.view).first)
        func row(_ file: URL) -> Int? {
            (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SideNode)?.key == file.path }
        }
        func offset(_ file: URL) throws -> CGFloat {
            outline.rect(ofRow: try XCTUnwrap(row(file))).minY - outline.visibleRect.minY
        }
        let anchor = files[60]
        let anchorRow = try XCTUnwrap(row(anchor))
        outline.scroll(NSPoint(x: 0, y: outline.rect(ofRow: anchorRow).minY + 7))
        XCTAssertEqual(try offset(anchor), -7, accuracy: 1)

        let inserted = root.appendingPathComponent("Added.txt")
        try Data().write(to: inserted)
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in row(inserted) != nil }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 5), .completed)
        XCTAssertEqual(try offset(anchor), -7, accuracy: 1)
        XCTAssertEqual((outline.item(atRow: outline.selectedRow) as? SideNode)?.key, files[4].path)
        let scroller = try XCTUnwrap(outline.enclosingScrollView?.verticalScroller)
        XCTAssertEqual(scroller.doubleValue, outline.visibleRect.minY / (outline.bounds.height - outline.visibleRect.height), accuracy: 0.001)

        let nextOffset = try offset(files[61])
        try FileManager.default.removeItem(at: anchor)
        bench.side.reload()
        XCTAssertEqual(try offset(files[61]), nextOffset, accuracy: 1)
        bench.side.reload()
        XCTAssertEqual(try offset(files[61]), nextOffset, accuracy: 1)
    }

    @MainActor func testExplorerRefreshPreservesUnchangedRowsAndUpdatesBadges() throws {
        let root = try makeTestWorkspace()
        let module = root.appendingPathComponent("Module", isDirectory: true)
        let folder = module.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("main.swift")
        let keep = root.appendingPathComponent("keep.txt")
        for url in [file, keep] { try Data().write(to: url) }
        try ShellJob().run(Tools.git, ["init", "-q"], in: root)
        let bench = Workbench()
        defer { bench.window.orderOut(nil) }
        bench.side.reset(root)
        bench.window.orderFront(nil)
        bench.side.reveal(file)
        bench.window.contentView?.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(descendants(NSOutlineView.self, of: bench.side.view).first)
        func row(_ url: URL) throws -> Int {
            try XCTUnwrap((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SideNode)?.key == url.path })
        }
        func cell(_ url: URL) throws -> NSView {
            try XCTUnwrap(outline.view(atColumn: 0, row: try row(url), makeIfNecessary: true))
        }
        func refresh() throws {
            bench.side.git = try WorkspaceGit.read(in: root, previous: nil, changedPaths: nil, directories: [folder.path], job: ShellJob())
            bench.side.reload()
        }
        try refresh()
        let untouched = try cell(keep), original = try cell(file)
        let directory = try XCTUnwrap(outline.item(atRow: try row(folder)) as? SideNode)
        XCTAssertEqual(descendants(NSTextField.self, of: original).last?.stringValue, "U")
        try refresh()
        XCTAssertTrue(try cell(file) === original)
        XCTAssertTrue(try cell(keep) === untouched)

        try ShellJob().run(Tools.git, ["add", "Module/Sources/main.swift"], in: root)
        try refresh()
        XCTAssertEqual(descendants(NSTextField.self, of: try cell(file)).last?.stringValue, "A")
        XCTAssertTrue(try cell(keep) === untouched)
        XCTAssertTrue(outline.isItemExpanded(directory))

        let added = folder.appendingPathComponent("another.swift")
        try Data().write(to: added)
        try refresh()
        XCTAssertEqual(try row(added) + 1, try row(file))
        XCTAssertTrue(try cell(keep) === untouched)
        XCTAssertEqual(outline.selectedRow, try row(file))

        let parent = try XCTUnwrap(outline.item(atRow: try row(module)))
        outline.collapseItem(parent)
        try FileManager.default.removeItem(at: added)
        try refresh()
        outline.expandItem(parent)
        outline.expandItem(directory)
        XCTAssertEqual(try row(folder) + 1, try row(file))
        XCTAssertEqual(try row(file) + 1, try row(keep))

        try FileManager.default.removeItem(at: file)
        try refresh()
        let deleted = try XCTUnwrap(outline.item(atRow: try row(file)) as? SideNode)
        guard case let .file(_, deletion) = deleted.role else { return XCTFail("Expected a deleted file") }
        XCTAssertEqual(deletion?.flag, "D")
        try ShellJob().run(Tools.git, ["rm", "--cached", "-f", "--", "Module/Sources/main.swift"], in: root)
        try refresh()
        XCTAssertEqual(try row(folder) + 1, try row(keep))
    }

    @MainActor func testExplorerFileFinishingOpenKeepsSubsequentScroll() throws {
        let root = try makeTestWorkspace()
        let files = (0..<100).map { root.appendingPathComponent("File\($0).txt") }
        for file in files { try Data().write(to: file) }
        let bench = Workbench()
        defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        bench.root = root
        bench.side.reset(root)
        bench.window.orderFront(nil)
        bench.window.contentView?.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(descendants(NSOutlineView.self, of: bench.side.view).first)
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SideNode)?.key == files[4].path })
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.sendAction(outline.action, to: outline.target)
        outline.scroll(NSPoint(x: 0, y: 1000))
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in bench.activeDocument?.url == files[4] }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 3), .completed)
        XCTAssertEqual(outline.visibleRect.minY, 1000, accuracy: 1)
        XCTAssertEqual(outline.selectedRow, row)
    }

    @MainActor func testUntrackedFolderExpandedDuringInitialRefreshGetsFileBadges() throws {
        let root = try makeTestWorkspace()
        try ShellJob().run(Tools.git, ["init", "-q"], in: root)
        let folder = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("main.swift")
        try Data().write(to: file)
        let bench = Workbench()
        defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        bench.window.orderFront(nil)
        bench.openFolder(root, remember: false)
        bench.side.reveal(file)
        let outline = try XCTUnwrap(descendants(NSOutlineView.self, of: bench.side.view).first)
        let decorated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let cell = outline.view(atColumn: 0, row: outline.selectedRow, makeIfNecessary: true) else { return false }
            return self.descendants(NSTextField.self, of: cell).map(\.stringValue) == ["main.swift", "U"]
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [decorated], timeout: 5), .completed)
    }

    @MainActor func testExplorerShowsGitChangesAndOpensDeletedFileDiff() throws {
        let repo = try makeTestWorkspace()
        let root = repo.appendingPathComponent("src [1]", isDirectory: true)
        let removed = root.appendingPathComponent("old/nested/gone.md")
        try FileManager.default.createDirectory(at: removed.deletingLastPathComponent(), withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func git(_ args: String...) throws {
            try ShellJob().run(Tools.git, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                          "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null"] + args, in: root)
        }
        try ShellJob().run(Tools.git, ["init", "-q"], in: repo)
        for name in ["changed.md", "clean.md", "before.md", "old/nested/gone.md"] { try write(name, name + "\n") }
        try git("add", ".")
        try git("commit", "-qm", "Initial files")
        try git("mv", "before.md", "after.md")
        try write("changed.md", "modified\n")
        try write("new.md", "staged\n")
        try git("add", "new.md")
        try write("new.md", "working\n")
        let longName = String(repeating: "很长的文件名", count: 5) + ".md"
        try write(longName, "untracked\n")
        try FileManager.default.removeItem(at: root.appendingPathComponent("old"))

        let bench = Workbench()
        bench.window.orderFront(nil)
        defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        bench.openFolder(root, remember: false)
        func waitFor(_ predicate: @escaping () -> Bool) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 6), .completed)
        }
        let outline = try XCTUnwrap(descendants(NSOutlineView.self, of: bench.side.view).first)
        func row(_ name: String) -> Int? {
            (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SideNode)?.name == name }
        }
        func labels(_ name: String) -> [String] {
            guard let i = row(name), let cell = outline.view(atColumn: 0, row: i, makeIfNecessary: true) else { return [] }
            return descendants(NSTextField.self, of: cell).map(\.stringValue)
        }
        waitFor { labels("changed.md") == ["changed.md", "M"] }
        func checkBadgeFits(_ name: String) throws {
            let cell = try XCTUnwrap(outline.view(atColumn: 0, row: try XCTUnwrap(row(name)), makeIfNecessary: true))
            let badge = try XCTUnwrap(descendants(NSTextField.self, of: cell).last)
            bench.side.view.layoutSubtreeIfNeeded()
            let bounds = badge.convert(badge.bounds, to: outline)
            XCTAssertLessThanOrEqual(bounds.maxX, outline.visibleRect.maxX - 4)
            XCTAssertGreaterThanOrEqual(bounds.width, badge.intrinsicContentSize.width)
        }
        try checkBadgeFits("changed.md")
        XCTAssertEqual(labels("new.md"), ["new.md", "AM"])
        XCTAssertEqual(labels(longName), [longName, "U"])
        XCTAssertEqual(labels("after.md"), ["after.md", "R"])
        XCTAssertEqual(labels("clean.md"), ["clean.md"])
        XCTAssertEqual(labels("old"), ["old", "•"])
        for name in ["old", "nested"] { outline.expandItem(outline.item(atRow: try XCTUnwrap(row(name)))) }
        XCTAssertEqual(labels("gone.md"), ["gone.md", "D"])
        bench.split.setPosition(180, ofDividerAt: 0)
        bench.window.contentView?.layoutSubtreeIfNeeded()
        try checkBadgeFits("gone.md")
        try checkBadgeFits(longName)
        outline.selectRowIndexes(IndexSet(integer: try XCTUnwrap(row("gone.md"))), byExtendingSelection: false)
        outline.sendAction(outline.doubleAction, to: outline.target)
        waitFor { bench.current?.isPatch == true }
        XCTAssertTrue(bench.current?.text.string.contains("-old/nested/gone.md") == true)

        try git("restore", "--", "changed.md", "old")
        try git("add", "new.md")
        waitFor { labels("changed.md") == ["changed.md"] && labels("new.md") == ["new.md", "A"] }
        XCTAssertEqual(labels("gone.md"), ["gone.md"])
        XCTAssertEqual(labels("old"), ["old"])
    }

    @MainActor func testTrashMenuUsesClickedFileAndShowsTrackedDeletion() throws {
        let fixture = try makeTestWorkspace()
        let repo = fixture.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let target = repo.appendingPathComponent("要删除 #1.md"), keep = repo.appendingPathComponent("keep.md")
        let trashed = fixture.appendingPathComponent("trashed.md")
        try "one".write(to: target, atomically: true, encoding: .utf8)
        try Data().write(to: keep)
        try ShellJob().run(Tools.git, ["init", "-q"], in: repo)
        try ShellJob().run(Tools.git, ["add", "--", "."], in: repo)
        let bench = Workbench(moveToTrash: { try FileManager.default.moveItem(at: $0, to: trashed) })
        bench.window.orderFront(nil)
        bench.openFolder(repo, remember: false)
        defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        func waitFor(_ f: @escaping () -> Bool, line: UInt = #line) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in f() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, line: line)
        }
        bench.open(.file(target), pin: true)
        waitFor { bench.activeDocument?.url == target }
        bench.open(.file(keep), pin: true)
        waitFor { bench.activeDocument?.url == keep }
        let outline = try XCTUnwrap(descendants(NSOutlineView.self, of: bench.side.view).first)
        func row(_ name: String) throws -> Int {
            try XCTUnwrap((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SideNode)?.name == name })
        }
        func menu(_ name: String) throws -> NSMenu {
            let rect = outline.rect(ofRow: try row(name))
            let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: bench.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            return try XCTUnwrap(outline.menu(for: event))
        }
        XCTAssertNil(try menu(repo.lastPathComponent).item(withTitle: "移到废纸篓"))
        XCTAssertNotEqual(try row(target.lastPathComponent), outline.selectedRow)
        let context = try menu(target.lastPathComponent)
        let trash = try XCTUnwrap(context.item(withTitle: "移到废纸篓"))
        context.performActionForItem(at: context.index(of: trash))
        XCTAssertEqual(try String(contentsOf: trashed, encoding: .utf8), "one")
        XCTAssertEqual(bench.documents.map(\.url), [keep])
        XCTAssertTrue(bench.back.isEmpty)
        waitFor { bench.side.git?.fileTree.changes[target.path]?.last?.flag == "D" }
        XCTAssertNil(try menu(target.lastPathComponent).item(withTitle: "移到废纸篓"))
    }

    @MainActor func testTrashPreservesDirtyTabOnCancelOrFailure() throws {
        let root = try makeTestWorkspace(), file = root.appendingPathComponent("draft.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        var attempts = 0
        let bench = Workbench(moveToTrash: { _ in attempts += 1; throw CyberPeekError("废纸篓不可用") })
        bench.openFolder(root, remember: false)
        bench.window.orderFront(nil)
        defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        bench.open(.file(file))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in bench.current?.url == file }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        let doc = try XCTUnwrap(bench.current)
        doc.text.insertText(" edited", replacementRange: NSRange(location: 8, length: 0))
        XCTAssertTrue(doc.dirty)
        for response in [NSApplication.ModalResponse.alertSecondButtonReturn, .alertThirdButtonReturn] {
            RunLoop.main.perform(inModes: [.modalPanel]) { NSApp.stopModal(withCode: response) }
            bench.trashFile(file)
            XCTAssertTrue(bench.current === doc && doc.dirty)
            XCTAssertEqual(doc.text.string, "original edited")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
            XCTAssertEqual(attempts, response == .alertSecondButtonReturn ? 0 : 1)
        }
        let sheet = try XCTUnwrap(bench.window.attachedSheet)
        bench.window.endSheet(sheet)
    }

    @MainActor func testTrashMovesSymlinkAndCancelsPendingOpenOfThatLink() throws {
        let root = try makeTestWorkspace(), original = root.appendingPathComponent("original.txt")
        let link = root.appendingPathComponent("link.txt"), moved = root.appendingPathComponent("trashed-link")
        try Data().write(to: original)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let bench = Workbench(moveToTrash: { try FileManager.default.moveItem(at: $0, to: moved) })
        bench.openFolder(root, remember: false)
        defer { bench.cancelWorkspaceJobs() }
        bench.open(.file(link))
        bench.trashFile(link)
        XCTAssertNil(bench.pendingOpen)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: moved.path), original.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
    }

    @MainActor func testMultipleRepositoriesFollowTheActiveDocument() throws {
        let parent = try makeTestWorkspace()
        // Keep this fixture inside the project without inheriting the project's outer repo.
        let previousCeiling = ProcessInfo.processInfo.environment["GIT_CEILING_DIRECTORIES"]
        setenv("GIT_CEILING_DIRECTORIES", parent.path, 1)
        defer {
            if let previousCeiling { setenv("GIT_CEILING_DIRECTORIES", previousCeiling, 1) }
            else { unsetenv("GIT_CEILING_DIRECTORIES") }
        }
        let workspace = parent.appendingPathComponent("Workspace", isDirectory: true)
        let client = workspace.appendingPathComponent("client", isDirectory: true)
        let api = workspace.appendingPathComponent("services/api", isDirectory: true)
        let notes = workspace.appendingPathComponent("notes.txt")
        let fm = FileManager.default
        try fm.createDirectory(at: client, withIntermediateDirectories: true)
        try fm.createDirectory(at: api.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "notes".write(to: notes, atomically: true, encoding: .utf8)
        func git(_ repo: URL, _ args: String...) throws {
            try ShellJob().run(Tools.git, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                         "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null"] + args, in: repo)
        }
        let clientFile = client.appendingPathComponent("shared.txt"), apiFile = api.appendingPathComponent("shared.txt")
        try git(client, "init", "-qb", "ui")
        try "one\ntwo\n".write(to: clientFile, atomically: true, encoding: .utf8)
        try git(client, "add", ".")
        try git(client, "commit", "-qm", "Shared baseline")
        try git(workspace, "clone", "-q", "--no-hardlinks", client.path, api.path)
        try git(api, "switch", "-qc", "service")
        try "client changed\ntwo\n".write(to: clientFile, atomically: true, encoding: .utf8)
        try "one\napi changed\n".write(to: apiFile, atomically: true, encoding: .utf8)
        try git(api, "add", ".")
        try fm.createSymbolicLink(at: workspace.appendingPathComponent("alias"), withDestinationURL: api)

        let bench = Workbench()
        bench.window.orderFront(nil)
        defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        bench.openFolder(workspace, remember: false)
        func waitFor(_ predicate: @escaping () -> Bool, line: UInt = #line) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, line: line)
        }
        waitFor { bench.side.git?.repositories.count == 2 }
        XCTAssertTrue(bench.branch.isHidden)
        let tree = try XCTUnwrap(bench.side.git?.fileTree)
        XCTAssertEqual(tree.changes[clientFile.path]?.first?.area, .working)
        XCTAssertEqual(tree.changes[apiFile.path]?.first?.area, .staged)
        XCTAssertTrue(tree.changedDirectories.contains(workspace.path))
        XCTAssertTrue(tree.changedDirectories.contains(api.deletingLastPathComponent().path))

        bench.open(.file(clientFile), pin: true)
        waitFor { bench.branch.stringValue == "ui" && bench.current?.lineChanges.kind(at: 1) == .modified }
        let clientTab = try XCTUnwrap(bench.current)
        bench.open(.file(apiFile), pin: true)
        waitFor { bench.branch.stringValue == "service" && bench.current?.lineChanges.kind(at: 2) == .modified }
        bench.show(clientTab)
        XCTAssertEqual(bench.branch.stringValue, "ui")
        bench.open(.file(notes))
        waitFor { bench.current?.url == notes && bench.branch.isHidden }
        XCTAssertEqual(bench.current?.lineChanges, GitLineChanges())

        bench.selectSection(.git)
        let outline = try XCTUnwrap(descendants(NSOutlineView.self, of: bench.side.view).first)
        func nodes() -> [SideNode] {
            (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SideNode }
        }
        XCTAssertEqual(nodes().filter { if case .repository = $0.role { return true }; return false }.map(\.name), ["client", "services/api"])
        func review(_ repo: URL, expected: String) throws {
            let node = try XCTUnwrap(nodes().first {
                if case let .change(owner, change) = $0.role { return owner.path == repo.path && change.path == "shared.txt" }
                return false
            })
            bench.side.onOpen?(node, true)
            waitFor { bench.current?.isPatch == true && bench.current?.text.string.contains(expected) == true }
        }
        try review(client, expected: "+client changed")
        XCTAssertEqual(bench.branch.stringValue, "ui")
        try review(api, expected: "+api changed")
        XCTAssertEqual(bench.branch.stringValue, "service")
        bench.current?.onDiffLine?(2)
        waitFor { bench.current?.isPatch == false && bench.current?.text.string == "one\napi changed\n" }
        XCTAssertEqual(bench.branch.stringValue, "service")

        // Both repositories have the same commit hash. Commit children must keep their own origin.
        for repo in [client, api] {
            let found = try XCTUnwrap(nodes().first { $0.key == repo.path + "|history" })
            outline.expandItem(found)
            let commit = try XCTUnwrap(nodes().first {
                if case let .commit(owner, _) = $0.role { return owner.path == repo.path }
                return false
            })
            outline.expandItem(commit)
            waitFor {
                nodes().contains {
                    if case let .change(owner, change) = $0.role { return owner.path == repo.path && change.area == .commit }
                    return false
                }
            }
        }
        try git(api, "branch", "-m", "service-next")
        waitFor { bench.branch.stringValue == "service-next" }
        let extra = workspace.appendingPathComponent("client-worktree", isDirectory: true)
        try git(client, "worktree", "add", "-qb", "preview", extra.path)
        waitFor { bench.side.git?.repositories.count == 3 }
        bench.open(.file(extra.appendingPathComponent("shared.txt")))
        waitFor { bench.branch.stringValue == "preview" }
        try git(extra, "switch", "-qc", "preview-next")
        waitFor { bench.branch.stringValue == "preview-next" }
        try git(client, "worktree", "remove", extra.path)
        waitFor { bench.side.git?.repositories.count == 2 && bench.branch.isHidden }
    }

    @MainActor func testHostUsesProjectFixtureAndInvalidPathsCannotChangeWorkspace() throws {
        let expected = URL(fileURLWithPath: #filePath).deletingLastPathComponent().standardizedFileURL
        let host = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let initial = try XCTUnwrap(host.activeWorkbench)
        XCTAssertEqual(initial.root?.path, expected.path)
        let folder = try makeTestWorkspace()
        let missing = folder.appendingPathComponent("missing")
        let file = folder.appendingPathComponent("YES")
        try Data().write(to: file)

        let flags = ["-NSTreatUnknownArgumentsAsOpen", "NO", "-ApplePersistenceIgnoreState", "YES"]
        XCTAssertEqual(AppDelegate.fileArguments(flags[...]), [])
        XCTAssertEqual(AppDelegate.fileArguments((flags + ["--", file.path])[...]).map(\.path), [file.path])
        host.application(NSApp, open: [missing])
        XCTAssertTrue(host.activeWorkbench === initial)
        initial.openFolder(file)
        XCTAssertEqual(initial.root?.path, expected.path)
    }

    @MainActor func testSessionRestoresAvailableTabsInOrderAndKeepsSelectedPreview() async throws {
        let folder = try makeTestWorkspace()
        let file = folder.appendingPathComponent("notes.txt"), svg = folder.appendingPathComponent("icon.svg")
        let gone = folder.appendingPathComponent("gone.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        try "removed".write(to: gone, atomically: true, encoding: .utf8)
        try "<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'/>".write(to: svg, atomically: true, encoding: .utf8)
        try ShellJob().run(Tools.git, ["init", "-q"], in: folder)
        try ShellJob().run(Tools.git, ["add", "notes.txt"], in: folder)
        let index = Workbench.Target.blob(folder, "", "notes.txt")
        let diff = Workbench.Target.patch(folder, Change(path: "notes.txt", oldPath: nil, flag: "M", area: .working))
        try "modified".write(to: file, atomically: true, encoding: .utf8)

        let first = Workbench(), next = Workbench()
        defer { for bench in [first, next] { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) } }
        first.openFolder(folder, remember: false)
        let targets: [Workbench.Target] = [.file(file), .file(gone), index, diff, .file(svg)]
        for target in targets {
            await withCheckedContinuation { done in
                first.open(target, pin: true) { done.resume() }
            }
        }
        let svgTab = try XCTUnwrap(first.current)
        svgTab.pinned = false
        svgTab.showsSVGPreview = true
        let saved = try XCTUnwrap(first.session)
        XCTAssertEqual(saved.tabs.map(\.target), targets)
        XCTAssertEqual(saved.selected, .file(svg))
        let stored = try JSONEncoder().encode(saved)
        try FileManager.default.removeItem(at: gone)
        // The working diff is now empty, but the file and its indexed version still open.
        try "on disk at relaunch".write(to: file, atomically: true, encoding: .utf8)
        try ShellJob().run(Tools.git, ["add", "notes.txt"], in: folder)
        let restore = try JSONDecoder().decode(WorkspaceSession.self, from: stored)
        next.openFolder(restore.folder, remember: false)
        next.restoreTabs(restore)
        XCTAssertEqual(next.session?.tabs.map(\.target), targets)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in next.restoringSession == nil }, object: nil)
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertEqual(next.session?.tabs.map(\.target), [.file(file), index, .file(svg)])
        XCTAssertEqual(next.documents.map(\.pinned), [true, true, false])
        XCTAssertEqual(next.current?.url, svg)
        XCTAssertEqual(next.current?.showsSVGPreview, true)
        XCTAssertEqual((next.documents.first as? Editor)?.text.string, "on disk at relaunch")
        XCTAssertNil(next.window.attachedSheet)

        next.openFolder(folder, remember: false)
        next.restoreTabs(restore)
        let extras = ["first.txt", "second.txt"].map { folder.appendingPathComponent($0) }
        for url in extras { try Data().write(to: url); next.enqueueFile(url) }
        let requested = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            next.restoringSession == nil && next.queuedFiles.isEmpty
        }, object: nil)
        await fulfillment(of: [requested], timeout: 5)
        XCTAssertEqual(next.session?.tabs.map(\.target), [.file(file), index, .file(svg)] + extras.map(Workbench.Target.file))
        XCTAssertEqual(next.activeDocument?.url, extras.last)
    }

    @MainActor func testWorkspacesOwnSeparateWindowsAndReopeningRestoresExistingEditor() async throws {
        let host = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let original = try XCTUnwrap(host.activeWorkbench)
        let initialCount = host.workbenches.count
        let temp = try makeTestWorkspace()
        let first = temp.appendingPathComponent("Client", isDirectory: true)
        let second = temp.appendingPathComponent("Service", isDirectory: true)
        let alias = temp.appendingPathComponent("Client link")
        for dir in [first, second] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        let a = first.appendingPathComponent("main.txt"), b = second.appendingPathComponent("main.txt")
        try "client".write(to: a, atomically: true, encoding: .utf8)
        try "service".write(to: b, atomically: true, encoding: .utf8)
        func waitFor(_ predicate: @escaping () -> Bool, line: UInt = #line) async {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
            let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
            XCTAssertEqual(result, .completed, line: line)
        }
        defer {
            for bench in host.workbenches where bench !== original { bench.window.close() }
            original.window.makeKeyAndOrderFront(nil)
        }

        host.newWindow()
        let client = try XCTUnwrap(host.activeWorkbench)
        XCTAssertNil(client.root)
        client.onOpenFolder?(first)
        host.application(NSApp, open: [a])
        await waitFor { client.current?.url == a }
        let draft = try XCTUnwrap(client.current)
        draft.text.insertText("!", replacementRange: NSRange(location: 6, length: 0))
        draft.text.setSelectedRange(NSRange(location: 1, length: 2))
        let monitor = try XCTUnwrap(client.monitor)
        client.onOpenFolder?(second)
        let service = try XCTUnwrap(host.activeWorkbench)
        XCTAssertFalse(client === service)
        host.application(NSApp, open: [b])
        await waitFor { service.current?.url == b }
        let other = try XCTUnwrap(service.current)
        other.text.insertText("?", replacementRange: NSRange(location: 7, length: 0))
        host.save()
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "service?")
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "client")
        XCTAssertTrue(draft.dirty)

        // A hosted test can order its windows while its title-bar controls are still inactive.
        if !NSApp.isActive {
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: .init())
        }
        client.window.makeKeyAndOrderFront(nil)
        await waitFor {
            client.window.isKeyWindow && client.window.standardWindowButton(.miniaturizeButton)?.isEnabled == true
        }
        let minimized = expectation(forNotification: NSWindow.didMiniaturizeNotification, object: client.window)
        client.window.miniaturize(nil)
        await fulfillment(of: [minimized], timeout: 5)
        XCTAssertTrue(client.window.isMiniaturized)
        service.onOpenFolder?(alias)
        await waitFor { !client.window.isMiniaturized && client.window.isVisible && host.activeWorkbench === client }
        host.application(NSApp, open: [first, alias])
        XCTAssertEqual(host.workbenches.count, initialCount + 2)
        XCTAssertTrue(host.activeWorkbench === client && client.current === draft && client.monitor === monitor)
        XCTAssertEqual(draft.text.selectedRange(), NSRange(location: 1, length: 2))
        XCTAssertEqual(draft.text.string, "client!")
        XCTAssertTrue(draft.dirty)

        // A clean foreground window must not let Quit bypass a background window's dirty tab.
        host.application(NSApp, open: [second])
        RunLoop.main.perform(inModes: [.modalPanel]) { NSApp.stopModal(withCode: .alertSecondButtonReturn) }
        XCTAssertEqual(host.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertTrue(host.activeWorkbench === client)
        RunLoop.main.perform(inModes: [.modalPanel]) { NSApp.stopModal(withCode: .alertSecondButtonReturn) }
        host.closeWindow()
        XCTAssertTrue(host.workbenches.contains { $0 === client })
        host.application(NSApp, open: [second])
        host.closeWindow()
        XCTAssertNil(service.monitor)
        XCTAssertEqual(host.workbenches.count, initialCount + 1)
        XCTAssertTrue(client.current === draft && draft.dirty)
    }

    @MainActor func testFinderBatchRoutesEveryFileToTheMostSpecificWindow() throws {
        let host = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let original = try XCTUnwrap(host.activeWorkbench)
        let parent = try makeTestWorkspace(), child = parent.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let files = ["a.txt", "b.txt", "nested/c.txt", "nested/d.txt"].map { parent.appendingPathComponent($0) }
        for file in files { try Data().write(to: file) }
        defer {
            for bench in host.workbenches where bench !== original { bench.window.close() }
            original.window.makeKeyAndOrderFront(nil)
        }
        host.application(NSApp, open: [files[0], child, parent, files[1], files[2], files[3]])
        let outer = try XCTUnwrap(host.workbenches.first { $0.root?.path == parent.path })
        let inner = try XCTUnwrap(host.workbenches.first { $0.root?.path == child.path })
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            outer.documents.count == 2 && inner.documents.count == 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertEqual(outer.documents.map(\.url), Array(files.prefix(2)))
        XCTAssertEqual(inner.documents.map(\.url), Array(files.suffix(2)))
        XCTAssertTrue((outer.documents + inner.documents).allSatisfy(\.pinned))
    }

    @MainActor func testOpeningSubfolderScopesIndexSearchAndGit() async throws {
        let repo = try makeTestWorkspace()
        let name = "src [1]"
        let folder = repo.appendingPathComponent(name, isDirectory: true)
        let sibling = repo.appendingPathComponent("src 1", isDirectory: true)
        for directory in [folder, sibling] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "needle\n".write(to: directory.appendingPathComponent("file.md"), atomically: true, encoding: .utf8)
        }
        func git(_ args: String...) throws {
            try ShellJob().run(Tools.git, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                          "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null"] + args, in: repo)
        }
        try git("init", "-q")
        try git("add", ".")
        try git("commit", "-qm", "both folders")
        try "outside needle".write(to: sibling.appendingPathComponent("only.md"), atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("commit", "-qm", "sibling only")
        try "outside again".write(to: sibling.appendingPathComponent("only.md"), atomically: true, encoding: .utf8)
        try "needle changed".write(to: folder.appendingPathComponent("file.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: sibling)

        let bench = Workbench()
        // Quick Open only indexes while its panel is visible in an active workspace.
        if !NSApp.isActive {
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: .init())
        }
        bench.window.makeKeyAndOrderFront(nil)
        bench.openFolder(folder, remember: false)
        defer { bench.quick.dismiss(); bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        XCTAssertNil(bench.indexJob)
        bench.quickOpen()
        bench.search("needle")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !bench.quick.paths.isEmpty && bench.side.git != nil && !bench.side.hits.isEmpty
        }, object: nil)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertTrue(bench.quick.paths.contains("file.md"))
        XCTAssertTrue(Set(bench.quick.paths).isSubset(of: ["file.md", "link"]))
        XCTAssertEqual(bench.side.hits.map(\.path), ["file.md"])
        let state = try XCTUnwrap(bench.side.git?.repository(containing: folder.path))
        XCTAssertEqual(Set(state.changes.map(\.path)), ["\(name)/file.md", "\(name)/link"])
        XCTAssertEqual(state.commits.map(\.title), ["both folders"])
        let commit = try XCTUnwrap(state.commits.first)
        XCTAssertEqual(try state.commitFiles(commit.id).map(\.path), ["\(name)/file.md"])
        let change = try XCTUnwrap(state.changes.first { $0.area == .working })
        XCTAssertTrue(try state.diff(change).contains("+needle changed"))
    }

    @MainActor func testUntrackedDirectoriesExpandOnDemandAndFollowIgnoreRules() throws {
        let root = try makeTestWorkspace()
        let modules = root.appendingPathComponent("node_modules", isDirectory: true)
        let package = modules.appendingPathComponent("包 [1]", isDirectory: true)
        let src = package.appendingPathComponent("index.js")
        let ignored = package.appendingPathComponent("skip.log")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try ShellJob().run(Tools.git, ["init", "-q"], in: root)
        try "*.log\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try ShellJob().run(Tools.git, ["add", ".gitignore"], in: root)
        for file in [src, ignored] { try "first\nsecond\n".write(to: file, atomically: true, encoding: .utf8) }
        let scoped = try GitState.read(repo: root, folder: package, job: ShellJob())
        XCTAssertEqual(scoped.changes.map(\.path), ["node_modules/包 [1]/index.js"])
        let bench = Workbench()
        bench.openFolder(root, remember: false)
        defer { bench.cancelWorkspaceJobs() }
        let outline = try XCTUnwrap(descendants(NSOutlineView.self, of: bench.side.view).first)
        func node(_ name: String) -> SideNode? {
            (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SideNode }.first { $0.name == name }
        }
        func waitFor(_ f: @escaping () -> Bool, line: UInt = #line) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in f() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, line: line)
        }
        bench.selectSection(.git)
        waitFor { node("node_modules/") != nil }
        XCTAssertEqual(bench.side.git?.fileTree.untrackedChildren.count, 0)
        XCTAssertNil(node("index.js"))
        // Open directly with the source-control folder collapsed.
        bench.open(.file(src))
        waitFor { bench.current?.lineChanges == .added(lines: 2) }
        XCTAssertNil(bench.side.git?.fileTree.untrackedChildren[modules.path])
        outline.expandItem(try XCTUnwrap(node("node_modules/")))
        waitFor { node("包 [1]") != nil }
        outline.expandItem(try XCTUnwrap(node("包 [1]")))
        waitFor { node("index.js") != nil }
        XCTAssertNil(node("skip.log"))
        let fileNode = try XCTUnwrap(node("index.js"))
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: fileNode)), byExtendingSelection: false)
        outline.sendAction(outline.doubleAction, to: outline.target)
        waitFor { bench.current?.isPatch == true && bench.current?.text.string.contains("+second") == true }
        bench.selectSection(.files)
        bench.open(.file(ignored))
        waitFor { bench.current?.url == ignored && node("index.js") != nil && bench.side.git?.fileTree.changes[src.path]?.first?.flag == "U" }
        XCTAssertTrue(bench.current?.lineChanges.hunks.isEmpty == true)
        XCTAssertNil(bench.side.git?.fileTree.changes[ignored.path])
        try "node_modules/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        bench.refreshGit()
        waitFor { bench.side.git?.fileTree.untrackedRoots.isEmpty == true }
        XCTAssertNil(bench.side.git?.fileTree.changes[src.path])
    }
}
