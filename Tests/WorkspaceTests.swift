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
        func descendants<T: NSView>(_ type: T.Type, of view: NSView) -> [T] {
            if let match = view as? T { return [match] }
            return view.subviews.flatMap { descendants(type, of: $0) }
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

    @MainActor func testHostUsesProjectFixtureAndInvalidPathsCannotChangeWorkspace() throws {
        let expected = URL(fileURLWithPath: #filePath).deletingLastPathComponent().standardizedFileURL
        let host = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        XCTAssertEqual(host.workbench.root?.path, expected.path)
        let folder = try makeTestWorkspace()
        let missing = folder.appendingPathComponent("missing")
        let file = folder.appendingPathComponent("YES")
        try Data().write(to: file)

        let flags = ["-NSTreatUnknownArgumentsAsOpen", "NO", "-ApplePersistenceIgnoreState", "YES"]
        XCTAssertEqual(AppDelegate.fileArguments(flags[...]), [])
        XCTAssertEqual(AppDelegate.fileArguments((flags + ["--", file.path])[...]).map(\.path), [file.path])
        host.application(NSApp, open: [missing])
        XCTAssertEqual(host.workbench.root?.path, expected.path)
        host.workbench.openFolder(file)
        XCTAssertEqual(host.workbench.root?.path, expected.path)
    }

    @MainActor func testOpeningSubfolderScopesIndexSearchAndGit() throws {
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
        bench.openFolder(folder, remember: false)
        defer { bench.cancelWorkspaceJobs() }
        bench.search("needle")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !bench.quick.paths.isEmpty && bench.side.git != nil && !bench.side.hits.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertTrue(bench.quick.paths.contains("file.md"))
        XCTAssertTrue(Set(bench.quick.paths).isSubset(of: ["file.md", "link"]))
        XCTAssertEqual(bench.side.hits.map(\.path), ["file.md"])
        let state = try XCTUnwrap(bench.side.git)
        XCTAssertEqual(Set(state.changes.map(\.path)), ["\(name)/file.md", "\(name)/link"])
        XCTAssertEqual(state.commits.map(\.title), ["both folders"])
        let commit = try XCTUnwrap(state.commits.first)
        XCTAssertEqual(try state.commitFiles(commit.id).map(\.path), ["\(name)/file.md"])
        let change = try XCTUnwrap(state.changes.first { $0.area == .working })
        XCTAssertTrue(try state.diff(change).contains("+needle changed"))
    }
}
