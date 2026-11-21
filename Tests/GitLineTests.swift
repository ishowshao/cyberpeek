import XCTest
@testable import CyberPeek

final class GitLineTests: XCTestCase {
    @MainActor func testBreadcrumbNavigatesWholeHunksAndDeletionBoundaries() throws {
        let repo = try makeTestWorkspace()
        let file = repo.appendingPathComponent("review.txt")
        let clean = repo.appendingPathComponent("clean.txt")
        let original = (1...4_000).map { "original line \($0)" }
        try original.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try Data().write(to: clean)
        let job = ShellJob()
        try job.run(Tools.git, ["init", "-q"], in: repo)
        try job.run(Tools.git, ["add", "."], in: repo)
        try job.run(Tools.git, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false",
                               "-c", "core.hooksPath=/dev/null", "commit", "-qm", "base"], in: repo)
        var updated = original
        for i in [0] + Array(99...101) + Array(349...800) + [3899, 3999] { updated[i] += " changed" }
        updated.removeSubrange(189..<191)
        try updated.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let bench = Workbench()
        bench.window.orderFront(nil)
        defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        bench.openFolder(repo, remember: false)
        bench.open(.file(file))
        func waitFor(_ predicate: @escaping () -> Bool) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        }
        waitFor { bench.current?.lineChanges.hunks.count == 6 }
        let editor = try XCTUnwrap(bench.current)
        let buttons = bench.crumbBar.subviews.compactMap { $0 as? NSStackView }.flatMap(\.arrangedSubviews).compactMap { $0 as? NSButton }
        let down = try XCTUnwrap(buttons.first { $0.toolTip == "下一个 Git 变更" })
        let up = try XCTUnwrap(buttons.first { $0.toolTip == "上一个 Git 变更" })
        XCTAssertTrue(down.isEnabled && up.isEnabled)
        let downFrame = down.convert(down.bounds, to: bench.crumbBar)
        XCTAssertEqual(bench.crumbBar.bounds.maxX - downFrame.maxX, 6, accuracy: 1)
        XCTAssertLessThan(up.convert(up.bounds, to: bench.crumbBar).maxX, downFrame.minX)
        let layout = try XCTUnwrap(editor.text.textLayoutManager)
        let content = try XCTUnwrap(layout.textContentManager)
        func row(_ number: Int) throws -> ClosedRange<CGFloat> {
            let offset = (editor.text.string as NSString).range(of: updated[number - 1]).location
            let location = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: offset))
            let fragment = try XCTUnwrap(layout.textLayoutFragment(for: location))
            XCTAssertEqual(fragment.state, .layoutAvailable)
            let top = fragment.layoutFragmentFrame.minY + editor.text.textContainerOrigin.y
            return top...(top + (try XCTUnwrap(fragment.textLineFragments.first)).typographicBounds.height)
        }
        let clip = editor.scroll.contentView
        let originalInsets = clip.contentInsets
        func press(_ button: NSButton) {
            button.performClick(nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.04))
            XCTAssertTrue(NSEdgeInsetsEqual(clip.contentInsets, originalInsets))
        }
        func checkLastLine(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(clip.bounds.maxY, clip.documentRect.maxY, accuracy: 1, file: file, line: line)
            let lastRow = try row(updated.count)
            XCTAssertGreaterThan(lastRow.lowerBound, clip.bounds.midY, file: file, line: line)
            XCTAssertLessThanOrEqual(lastRow.upperBound, clip.bounds.maxY + 1, file: file, line: line)
        }
        press(down)
        XCTAssertEqual(clip.bounds.minY, clip.documentRect.minY, accuracy: 1)
        press(down)
        XCTAssertEqual(clip.bounds.midY, try (row(100).lowerBound + row(102).upperBound) / 2, accuracy: 1)
        press(down)
        XCTAssertEqual(clip.bounds.midY, try row(189).upperBound, accuracy: 1)
        press(down)
        XCTAssertEqual(clip.bounds.minY, try row(348).lowerBound, accuracy: 1)
        press(down)
        XCTAssertEqual(clip.bounds.midY, try (row(3898).lowerBound + row(3898).upperBound) / 2, accuracy: 1)
        press(down)
        try checkLastLine()
        press(down)
        XCTAssertEqual(clip.bounds.minY, clip.documentRect.minY, accuracy: 1)
        press(up)
        try checkLastLine()
        XCTAssertEqual(editor.text.selectedRange(), NSRange(location: 0, length: 0))
        bench.open(.file(clean))
        waitFor { bench.current?.url == clean }
        XCTAssertFalse(down.isEnabled || up.isEnabled)
    }

    @MainActor func testStripeStartsAtGutterEdgeAndTintReachesPastShortText() throws {
        let file = try makeTestWorkspace().appendingPathComponent("sample.txt")
        let editor = Editor(url: file, identity: file.path, title: "sample", source: "a\nb\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        editor.view.layoutSubtreeIfNeeded()
        let layout = try XCTUnwrap(editor.text.textLayoutManager)
        layout.textViewportLayoutController.layoutViewport()
        let content = try XCTUnwrap(layout.textContentManager)
        func pixel(x: CGFloat, offset: Int) throws -> NSColor {
            let location = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: offset))
            let fragment = try XCTUnwrap(layout.textLayoutFragment(for: location))
            let top = fragment.layoutFragmentFrame.minY + editor.text.textContainerOrigin.y
            let y = editor.view.convert(NSPoint(x: 0, y: top + 4), from: editor.text).y
            let rect = NSRect(x: x, y: y, width: 1, height: 1)
            let bitmap = try XCTUnwrap(editor.view.bitmapImageRepForCachingDisplay(in: rect))
            editor.view.cacheDisplay(in: rect, to: bitmap)
            return try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        }
        editor.setLineChanges(.added(lines: 1))
        window.displayIfNeeded()
        let stripe = try pixel(x: 1, offset: 0)
        let tinted = try pixel(x: 485, offset: 0)
        let plain = try pixel(x: 485, offset: 2)
        XCTAssertGreaterThan(stripe.greenComponent, tinted.greenComponent + 0.2)
        XCTAssertGreaterThan(tinted.greenComponent, plain.greenComponent + 0.03)
        XCTAssertEqual(try pixel(x: 20, offset: 0), tinted)
    }

    @MainActor func testWorkingEditorComparedToCommitAcrossEditsSavesAndCommits() throws {
        let repo = try makeTestWorkspace()
        let folder = repo.appendingPathComponent("Sources [1]", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("文档 #1.txt")
        func git(_ args: String...) throws {
            try ShellJob().run(Tools.git, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                          "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null"] + args, in: repo)
        }
        // The editor displays decoded text. Neither the BOM nor CRLF should appear as an edit.
        func write(_ text: String) throws {
            let crlf = text.replacingOccurrences(of: "\n", with: "\r\n")
            try (Data([0xff, 0xfe]) + XCTUnwrap(crlf.data(using: .utf16LittleEndian))).write(to: file)
        }
        try git("init", "-q")
        try write("head\none\nold A\nold B\ntwo\nthree\ndeleted\nfour\nfive\ntail\n")
        try git("add", ".")
        try git("commit", "-qm", "baseline")
        try write("one\nnew A\nnew B\nextra\ntwo\ninserted\nthree\nfour\nfive\n")
        try git("add", ".")

        let bench = Workbench()
        bench.window.orderFront(nil)
        defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        bench.openFolder(folder, remember: false)
        bench.open(.file(file))
        func waitFor(_ f: @escaping () -> Bool, line: UInt = #line) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in f() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, line: line)
        }
        waitFor { bench.current?.lineChanges.deletedAfter == [0: 1, 7: 1, 9: 1] }
        let editor = try XCTUnwrap(bench.current)
        XCTAssertEqual((1...9).map(editor.lineChanges.kind), [nil, .modified, .modified, .modified, nil, .added, nil, nil, nil])
        editor.text.insertText("last\n", replacementRange: NSRange(location: (editor.text.string as NSString).length, length: 0))
        waitFor { editor.dirty && editor.lineChanges.kind(at: 10) == .modified && editor.lineChanges.deletedAfter[9] == nil }
        editor.text.insertText("", replacementRange: NSRange(location: 0, length: (editor.text.string as NSString).length))
        waitFor { editor.lineChanges.hunks.map(\.lines) == [1..<1] && editor.lineChanges.deletedAfter == [0: 10] }
        let emptyBounds = editor.scroll.contentView.bounds
        editor.navigateChange(forward: true)
        XCTAssertEqual(editor.scroll.contentView.bounds, emptyBounds)
        try editor.save()
        try git("add", ".")
        try git("commit", "-qm", "save empty document")
        bench.refreshGit()
        waitFor { editor.lineChanges == GitLineChanges() }

        let fresh = folder.appendingPathComponent("new.txt")
        try "a\n\nb\n".write(to: fresh, atomically: true, encoding: .utf8)
        bench.refreshGit()
        bench.open(.file(fresh))
        waitFor { bench.current?.url == fresh && bench.current?.lineChanges == .added(lines: 3) }
    }
}
