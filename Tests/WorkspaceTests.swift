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
        defer { bench.quick.dismiss(); bench.cancelWorkspaceJobs() }
        XCTAssertNil(bench.indexJob)
        bench.quickOpen()
        bench.search("needle")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !bench.quick.paths.isEmpty && bench.side.git != nil && !bench.side.hits.isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
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
