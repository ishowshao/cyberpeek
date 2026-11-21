import XCTest
@testable import CyberPeek

final class EditorFontTests: XCTestCase {
    @MainActor func testSizeMenuShortcutsLimitsAndPersistence() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = EditorFontSettings(defaults: defaults)
        let menu = NSMenu()
        settings.addMenuItems(to: menu)
        let sizes = try XCTUnwrap(menu.item(withTitle: "编辑器字号")?.submenu)

        func choose(_ size: Int) throws {
            let index = sizes.indexOfItem(withTag: size)
            XCTAssertNotEqual(index, -1)
            sizes.performActionForItem(at: index)
            sizes.update()
            XCTAssertEqual(sizes.item(withTag: size)?.state, .on)
        }
        func press(_ key: String, code: UInt16, shift: Bool = false) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: shift ? [.command, .shift] : [.command], timestamp: 0, windowNumber: 0,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            XCTAssertTrue(menu.performKeyEquivalent(with: event), "⌘\(key)")
        }

        XCTAssertEqual(settings.fonts.size, 16)
        try choose(19)
        let reopened = EditorFontSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reopened.fonts.size, 19)
        try press("=", code: 24)
        XCTAssertEqual(settings.fonts.size, 20)
        try press("+", code: 24, shift: true)
        XCTAssertEqual(settings.fonts.size, 21)
        try press("-", code: 27)
        XCTAssertEqual(settings.fonts.size, 20)
        try choose(32)
        menu.update()
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "放大字号")).isEnabled)
        try choose(9)
        menu.update()
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "缩小字号")).isEnabled)
        try press("0", code: 29)
        XCTAssertEqual(settings.fonts.size, 16)
    }

    @MainActor func testOpenEditorsKeepMarkupSelectionAndUndoWhenResized() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = EditorFontSettings(defaults: defaults)
        let folder = try makeTestWorkspace()
        func editor(_ filename: String, _ source: String, patch: Bool = false) throws -> Editor {
            let file = folder.appendingPathComponent(filename)
            return try Editor(url: file, identity: file.path, title: filename, source: source,
                              disk: patch ? nil : DiskText(Data(source.utf8)), patch: patch, fontSettings: settings)
        }
        let markdown = try editor("note.md", "# 标题🍓\n\n***加粗斜体***")
        let patch = try editor("diff.swift", "+ added\n", patch: true)
        let plain = try editor("a.txt", "草稿")
        plain.text.insertText("!", replacementRange: NSRange(location: 2, length: 0))
        let windows = [markdown, patch].map { editor in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = editor.view
            editor.view.layoutSubtreeIfNeeded()
            return window
        }
        defer { windows.forEach { $0.orderOut(nil) } }
        let range = (markdown.text.string as NSString).range(of: "加粗斜体")
        markdown.text.setSelectedRange(range)
        func checkMarkdown(_ points: CGFloat) {
            let styled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let font = markdown.text.textStorage?.attribute(.font, at: range.location,
                    effectiveRange: nil) as? NSFont else { return false }
                return font.pointSize == points && NSFontManager.shared.traits(of: font).contains([.boldFontMask, .italicFontMask])
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [styled], timeout: 3), .completed)
        }
        checkMarkdown(16)
        settings.setSize(24)
        checkMarkdown(24)
        XCTAssertEqual(markdown.text.selectedRange(), range)
        XCTAssertFalse(markdown.dirty)
        let patchFont = patch.text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(patchFont?.pointSize, 24)
        XCTAssertEqual(patch.text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, Palette.green)
        XCTAssertEqual(settings.fonts.lineNumber.pointSize, 22)
        XCTAssertTrue(plain.dirty)
        XCTAssertEqual(plain.text.string, "草稿!")
        plain.text.undoManager?.undo()
        XCTAssertEqual(plain.text.string, "草稿")
        let empty = try editor("new.txt", "")
        empty.text.insertText("新", replacementRange: NSRange(location: 0, length: 0))
        let typed = empty.text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(typed?.pointSize, 24)
    }
}
