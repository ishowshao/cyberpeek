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
