import AppKit
import ImageIO

struct ImageFileVersion: Equatable {
    let modified: Date?
    let size: Int?
    let inode: UInt64?

    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CyberPeekError("请选择普通图片文件。") }
        modified = attributes[.modificationDate] as? Date
        size = (attributes[.size] as? NSNumber)?.intValue
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}

final class ImageDocument: DocumentTab {
    var image: RasterImage?
    var diskVersion: ImageFileVersion?

    init(url: URL, identity: String, title: String, image: RasterImage?, diskVersion: ImageFileVersion?) {
        self.image = image
        self.diskVersion = diskVersion
        super.init(url: url, identity: identity, title: title)
    }
}

final class RasterImage {
    static let extensions: Set<String> = ["png", "apng", "jpg", "jpeg", "jfif", "gif", "webp", "avif", "ico", "bmp"]
    private static let options = [kCGImageSourceShouldCache: false] as CFDictionary
    private let source: CGImageSource
    let size: NSSize
    let firstIndex: Int
    let frameCount: Int
    private let animationKey: CFString?
    let plays: Int

    convenience init(url: URL) throws {
        try self.init(CGImageSourceCreateWithURL(url as CFURL, Self.options))
    }

    convenience init(data: Data) throws {
        try self.init(CGImageSourceCreateWithData(data as CFData, Self.options))
    }

    private init(_ source: CGImageSource?) throws {
        guard let source, CGImageSourceGetCount(source) > 0 else { throw CyberPeekError("无法读取这张图片。") }
        self.source = source
        let type = CGImageSourceGetType(source) as String?
        let count = CGImageSourceGetCount(source)
        func dimensions(_ index: Int) -> NSSize {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            if (5...8).contains(properties?[kCGImagePropertyOrientation] as? Int ?? 1) {
                return NSSize(width: height, height: width)
            }
            return NSSize(width: width, height: height)
        }
        var index = CGImageSourceGetPrimaryImageIndex(source)
        var best = dimensions(index)
        if type == "com.microsoft.ico" {
            for i in 0..<count {
                let candidate = dimensions(i)
                if candidate.width * candidate.height > best.width * best.height { index = i; best = candidate }
            }
        }
        guard best.width > 0, best.height > 0 else { throw CyberPeekError("无法读取图片尺寸。") }
        size = best
        firstIndex = index
        switch type {
        case "com.compuserve.gif": animationKey = kCGImagePropertyGIFDictionary
        case "public.png": animationKey = kCGImagePropertyPNGDictionary
        case "org.webmproject.webp": animationKey = kCGImagePropertyWebPDictionary
        default: animationKey = nil
        }
        frameCount = animationKey == nil ? 1 : count
        let loop = animationKey.flatMap { key -> Int? in
            guard count > 1, let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
                  let animation = props[key] as? [String: Any] else { return nil }
            return animation["LoopCount"] as? Int
        }
        // GIF counts repeats after its first play. APNG and WebP count total plays.
        if let loop { plays = loop > 0 && type == "com.compuserve.gif" ? loop + 1 : loop }
        else { plays = 1 }
    }

    func frame(at index: Int, maxPixels: Int) -> (CGImage, Double)? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        var delay = 0.1
        if frameCount > 1, let animationKey {
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let animation = props?[animationKey] as? [String: Any]
            let seconds = animation?["UnclampedDelayTime"] as? Double ?? animation?["DelayTime"] as? Double ?? delay
            if seconds >= 0.011 { delay = seconds }
        }
        return (image, delay)
    }
}

final class ImagePreview: NSView {
    private let message = label("", 13, color: Palette.muted)
    private let queue = DispatchQueue(label: "CyberPeek.imagePreview", qos: .userInitiated)
    private var raster: RasterImage?
    private(set) var displayedImage: NSImage?
    private var generation = 0
    private var pending: DispatchWorkItem?
    private var pixelLimit = 0
    private var vector = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        NSLayoutConstraint.activate([message.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     message.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("ImagePreview is created programmatically") }

    func clear() {
        generation += 1
        pending?.cancel()
        pending = nil
        raster = nil
        displayedImage = nil
        vector = false
        pixelLimit = 0
        message.stringValue = ""
        needsDisplay = true
    }

    func show(_ image: RasterImage?, name: String) {
        if let image, raster === image { return }
        clear()
        setAccessibilityLabel(name)
        raster = image
        message.stringValue = image == nil ? "无法读取这张图片。" : ""
        updateResolution()
    }

    func showSVG(_ source: String, name: String) {
        clear()
        vector = true
        setAccessibilityLabel(name)
        let token = generation
        let job = DispatchWorkItem { [weak self] in
            // The buffer is already Unicode, including documents opened from UTF-16 Git blobs.
            // Drop the disk encoding declaration before passing UTF-8 to the native SVG renderer.
            var xml = source[...]
            if xml.hasPrefix("<?xml"), xml.dropFirst(5).first?.isWhitespace == true, let end = xml.range(of: "?>") {
                xml = xml[end.upperBound...]
            }
            let image = NSImage(data: Data(xml.utf8))
            image?.cacheMode = .never
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                if let image, image.size.width > 0, image.size.height > 0 {
                    self.displayedImage = image
                } else {
                    self.message.stringValue = "无法预览 SVG，请检查源代码。"
                }
                self.needsDisplay = true
            }
        }
        pending = job
        queue.async(execute: job)
    }

    private func fittedRect(for size: NSSize) -> NSRect {
        let area = bounds.insetBy(dx: 12, dy: 12)
        guard area.width > 0, area.height > 0 else { return .zero }
        var scale = min(area.width / size.width, area.height / size.height)
        if !vector { scale = min(1, scale) }
        let width = size.width * scale, height = size.height * scale
        return NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    override func layout() { super.layout(); updateResolution() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateResolution() }

    private func updateResolution() {
        guard let raster else { return }
        let rect = fittedRect(for: raster.size)
        guard !rect.isEmpty else { return }
        let pixels = max(rect.width, rect.height) * (window?.backingScaleFactor ?? 1)
        let limit = min(Int(max(raster.size.width, raster.size.height)), Int(ceil(pixels / 128)) * 128)
        guard limit != pixelLimit else { return }
        pixelLimit = limit
        generation += 1
        pending?.cancel()
        render(raster, index: raster.firstIndex, play: 1)
    }

    private func render(_ image: RasterImage, index: Int, play: Int) {
        let token = generation, limit = pixelLimit
        let job = DispatchWorkItem { [weak self] in
            let result = image.frame(at: index, maxPixels: limit)
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                guard let (frame, delay) = result else {
                    self.message.stringValue = "无法解码这张图片。"
                    self.displayedImage = nil
                    self.needsDisplay = true
                    return
                }
                self.message.stringValue = ""
                let bitmap = NSBitmapImageRep(cgImage: frame)
                bitmap.size = image.size
                let rendered = NSImage(size: image.size)
                rendered.cacheMode = .never
                rendered.addRepresentation(bitmap)
                self.displayedImage = rendered
                self.needsDisplay = true
                guard image.frameCount > 1 else { return }
                let next = (index + 1) % image.frameCount
                let nextPlay = next == 0 ? play + 1 : play
                guard image.plays == 0 || nextPlay <= image.plays else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.generation == token, let image = self.raster else { return }
                    self.render(image, index: next, play: nextPlay)
                }
            }
        }
        pending = job
        queue.async(execute: job)
    }

    private static let transparency = NSColor(patternImage: NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        Palette.rgb(0x55585c).setFill(); rect.fill()
        Palette.rgb(0x63666a).setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        NSRect(x: 8, y: 8, width: 8, height: 8).fill()
        return true
    })

    override func draw(_ dirtyRect: NSRect) {
        Palette.canvas.setFill(); dirtyRect.intersection(bounds).fill()
        guard let displayedImage else { return }
        let rect = fittedRect(for: displayedImage.size)
        Self.transparency.setFill(); rect.fill()
        displayedImage.draw(in: rect)
    }
}
