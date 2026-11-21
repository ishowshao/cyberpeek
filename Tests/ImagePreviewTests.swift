import XCTest
@testable import CyberPeek

final class ImagePreviewTests: XCTestCase {
    @MainActor private func until(_ condition: () -> Bool, line: UInt = #line) {
        let end = Date(timeIntervalSinceNow: 5)
        while !condition(), Date() < end { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        XCTAssertTrue(condition(), line: line)
    }

    @MainActor func testSVGPreviewUsesEditedBufferAndKeepsSelectionUndoAndTab() throws {
        let root = try makeTestWorkspace(), svg = root.appendingPathComponent("mark.SVG")
        let original = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 40"><rect width="60" height="40" fill="red"/></svg>"#
        try original.write(to: svg, atomically: true, encoding: .utf8)
        let bench = Workbench()
        bench.window.makeKeyAndOrderFront(nil)
        defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        bench.openFolder(root, remember: false)
        bench.open(.file(svg))
        until { bench.current?.url == svg }
        let editor = try XCTUnwrap(bench.current)
        XCTAssertTrue(editor.view.superview === bench.editorHost)
        XCTAssertFalse(bench.previewButton.isHidden)
        XCTAssertEqual(bench.previewButton.toolTip, "预览 SVG")
        let range = (original as NSString).range(of: "red")
        editor.text.insertText("blue", replacementRange: range)
        let selection = NSRange(location: range.location, length: 4)
        editor.text.setSelectedRange(selection)
        bench.previewButton.performClick(nil)
        until { bench.imagePreview.displayedImage != nil }
        let preview = try XCTUnwrap(bench.imagePreview.displayedImage)
        XCTAssertTrue(bench.imagePreview.clipsToBounds)
        XCTAssertEqual(preview.size, NSSize(width: 60, height: 40))
        let pixels = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(preview.tiffRepresentation)))
        let color = try XCTUnwrap(pixels.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.blueComponent, 0.9)
        XCTAssertLessThan(color.redComponent, 0.1)
        XCTAssertEqual(try String(contentsOf: svg, encoding: .utf8), original)
        XCTAssertEqual(bench.documents.count, 1)
        XCTAssertTrue(bench.imagePreview === bench.window.firstResponder)
        XCTAssertTrue(editor.dirty)
        XCTAssertEqual(bench.previewButton.toolTip, "查看 SVG 源代码")
        bench.previewButton.performClick(nil)
        XCTAssertTrue(bench.current === editor && editor.text === bench.window.firstResponder)
        XCTAssertEqual(editor.text.selectedRange(), selection)
        editor.text.undoManager?.undo()
        XCTAssertEqual(editor.text.string, original)
        until { !editor.dirty }

        bench.previewButton.performClick(nil)
        XCTAssertTrue(editor.showsSVGPreview)
        let resized = original.replacingOccurrences(of: "0 0 60 40", with: "0 0 80 70")
        try resized.write(to: svg, atomically: true, encoding: .utf8)
        bench.checkDisk()
        until { bench.imagePreview.displayedImage?.size == NSSize(width: 80, height: 70) }
        XCTAssertEqual(editor.text.string, resized)
        bench.open(.file(svg), line: 1)
        XCTAssertFalse(editor.showsSVGPreview)
    }

    @MainActor func testRasterTabFitsRefreshesAndNavigatesWithoutTextEditor() throws {
        let root = try makeTestWorkspace(), file = root.appendingPathComponent("asset.PNG")
        func writeImage(_ width: Int, _ height: Int) throws {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file, options: .atomic)
        }
        try writeImage(3000, 1000)
        let text = root.appendingPathComponent("code.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        let bench = Workbench()
        bench.window.makeKeyAndOrderFront(nil)
        defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        bench.openFolder(root, remember: false)
        bench.open(.file(file), pin: true)
        until { bench.imagePreview.displayedImage != nil }
        let doc = try XCTUnwrap(bench.activeDocument as? ImageDocument)
        XCTAssertTrue(bench.previewButton.isHidden)
        XCTAssertNil(bench.current)
        XCTAssertEqual(bench.position.stringValue, "3000 × 1000 px")
        XCTAssertEqual(bench.crumb.stringValue, "asset.PNG")
        let displayed = try XCTUnwrap(bench.imagePreview.displayedImage?.representations.first)
        XCTAssertLessThan(displayed.pixelsWide, 3000)
        XCTAssertEqual(Double(displayed.pixelsWide) / Double(displayed.pixelsHigh), 3, accuracy: 0.03)

        bench.open(.file(text), pin: true)
        until { bench.current?.url == text }
        XCTAssertTrue(bench.previewButton.isHidden)
        XCTAssertNil(bench.imagePreview.displayedImage)
        bench.navigate(backwards: true)
        until { bench.activeDocument === doc && bench.imagePreview.displayedImage != nil }
        try writeImage(36, 24)
        bench.checkDisk()
        until { bench.imagePreview.displayedImage?.size == NSSize(width: 36, height: 24) }
        XCTAssertEqual(bench.position.stringValue, "36 × 24 px")
        try FileManager.default.removeItem(at: file)
        bench.checkDisk()
        until { doc.image == nil && bench.imagePreview.displayedImage == nil }
        try writeImage(64, 32)
        bench.checkDisk()
        until { bench.imagePreview.displayedImage?.size == NSSize(width: 64, height: 32) }
        bench.close(doc)
        XCTAssertEqual(bench.current?.url, text)
        XCTAssertEqual(bench.documents.count, 1)
    }

    @MainActor func testAnimatedWebPAdvancesAndStopsWhenLeavingPreview() throws {
        // Two 18 × 12 lossless frames (red and blue), each lasting 160 ms.
        let bytes = try XCTUnwrap(Data(base64Encoded: "UklGRoQAAABXRUJQVlA4WAoAAAACAAAAEQAACwAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAAAAAAAABEAAAsAAKAAAAJWUDhMDwAAAC8RwAIABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAABEAAAsAAKAAAABWUDhMDwAAAC8RwAIABxDR//4HIqL/AQA="))
        let image = try RasterImage(data: bytes)
        XCTAssertEqual(image.frameCount, 2)
        let view = ImagePreview(frame: NSRect(x: 0, y: 0, width: 180, height: 120))
        view.show(image, name: "animation.webp")
        var colors = Set<String>()
        until {
            if let rep = view.displayedImage?.representations.first as? NSBitmapImageRep,
               let c = rep.colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB) {
                if c.redComponent > 0.9 { colors.insert("red") }
                if c.blueComponent > 0.9 { colors.insert("blue") }
            }
            return colors.count == 2
        }
        view.clear()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertNil(view.displayedImage)
    }

    @MainActor func testInvalidSVGCanReturnToSourceAndPreviewCorrectedUTF16() throws {
        let root = try makeTestWorkspace(), url = root.appendingPathComponent("draft.svg")
        try "<svg".write(to: url, atomically: true, encoding: .utf16)
        let bench = Workbench()
        bench.window.makeKeyAndOrderFront(nil)
        defer { bench.cancelWorkspaceJobs(); bench.window.orderOut(nil) }
        bench.openFolder(root, remember: false)
        bench.open(.file(url))
        until { bench.current?.url == url }
        let editor = try XCTUnwrap(bench.current)
        bench.previewButton.performClick(nil)
        until { bench.imagePreview.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("无法预览") } }
        XCTAssertNil(bench.window.attachedSheet)
        bench.previewButton.performClick(nil)
        let fixed = #"<?xml version="1.0" encoding="UTF-16"?><svg xmlns="http://www.w3.org/2000/svg" width="18" height="12"/>"#
        editor.text.insertText(fixed, replacementRange: NSRange(location: 0, length: 4))
        bench.previewButton.performClick(nil)
        until { bench.imagePreview.displayedImage?.size == NSSize(width: 18, height: 12) }
        XCTAssertEqual(editor.text.string, fixed)
        XCTAssertTrue(editor.dirty)
    }
}
