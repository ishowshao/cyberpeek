import XCTest
@testable import CyberPeek

final class MarkdownTests: XCTestCase {
    @MainActor func testOpenEditAndSaveMarkdownWithVisibleStyles() throws {
        let folder = try makeTestWorkspace()
        let file = folder.appendingPathComponent("笔记.MARKDOWN")
        let source = """
        # 标题🍓

        > **粗体与 *斜体*** 和 `code` [链接](https://example.org)。

        - [x] ~~完成~~

        | 列 |
        | --- |
        | **表格** |

        ```swift
        func say() {}
        ```
        """
        try source.write(to: file, atomically: true, encoding: .utf8)
        let bench = Workbench()
        bench.open(.file(file))
        func waitUntil(_ condition: @escaping () -> Bool) {
            let wait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 4), .completed)
        }
        waitUntil { bench.current != nil }
        let editor = try XCTUnwrap(bench.current)
        let storage = try XCTUnwrap(editor.text.textStorage)
        func attribute<T>(_ key: NSAttributedString.Key, at word: String) -> T? {
            let range = (storage.string as NSString).range(of: word)
            guard range.location != NSNotFound else { return nil }
            return storage.attribute(key, at: range.location, effectiveRange: nil) as? T
        }
        func color(_ word: String) -> NSColor? { attribute(.foregroundColor, at: word) }
        func traits(_ word: String) -> NSFontTraitMask {
            guard let font: NSFont = attribute(.font, at: word) else { return [] }
            return NSFontManager.shared.traits(of: font)
        }

        waitUntil { color("func") == Palette.syntax[4] }
        XCTAssertEqual(color("标题🍓"), Palette.blue)
        XCTAssertTrue(traits("粗体").contains(.boldFontMask))
        XCTAssertTrue(traits("斜体").contains([.boldFontMask, .italicFontMask]))
        XCTAssertTrue(traits("表格").contains(.boldFontMask))
        XCTAssertEqual(color("code"), Palette.syntax[2])
        XCTAssertEqual(color("https"), Palette.syntax[5])
        XCTAssertEqual(color("[x]"), Palette.syntax[3])
        let strike: NSNumber? = attribute(.strikethroughStyle, at: "完成")
        XCTAssertEqual(strike?.intValue, NSUnderlineStyle.single.rawValue)

        let replacement = "🍓普通文本\n\n最后一行标题\n==="
        editor.text.insertText(replacement, replacementRange: NSRange(location: 0, length: storage.length))
        waitUntil { color("普通文本") == Palette.text && color("最后一行标题") == Palette.blue }
        XCTAssertFalse(traits("普通文本").contains(.boldFontMask))
        let cleared: NSNumber? = attribute(.strikethroughStyle, at: "普通文本")
        XCTAssertEqual(cleared?.intValue ?? 0, 0)
        try editor.save()
        XCTAssertEqual(try Data(contentsOf: file), Data(replacement.utf8))
    }

    func testMarkdownFenceLanguagesAndSortedUTF16Runs() throws {
        let worker = SyntaxWorker(ext: "md")
        let source = """
        🍓 ota_0 or ota_1

        > ~~~Python
        > def hello():
        >     return 42
        > ~~~

        ```made-up
        *literal*
        ```
        """
        let done = expectation(description: "Markdown parsed")
        worker.parse(source) { tokens in
            let text = source as NSString
            var end = 0
            for token in tokens {
                XCTAssertGreaterThanOrEqual(Int(token.start), end)
                XCTAssertGreaterThan(token.length, 0)
                end = Int(token.start + token.length)
                XCTAssertLessThanOrEqual(end, text.length)
            }
            func color(_ word: String) -> Int {
                let location = text.range(of: word).location
                return tokens.first { Int($0.start) <= location && location < Int($0.start + $0.length) }
                    .map { Int($0.color) } ?? 0
            }
            XCTAssertEqual(color("_0 or ota_"), 0)
            XCTAssertEqual(color("def"), 4)
            XCTAssertEqual(color("return"), 4)
            XCTAssertEqual(color("42"), 3)
            XCTAssertEqual(color("*literal*"), 2)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
}
