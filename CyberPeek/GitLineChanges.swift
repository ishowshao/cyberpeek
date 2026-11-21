import Foundation

struct GitLineChanges: Equatable {
    enum Kind { case added, modified }
    struct Hunk: Equatable {
        // A pure deletion is an empty range at the boundary before the following line.
        let lines: Range<Int>
        let kind: Kind?
    }

    private(set) var hunks: [Hunk] = []
    // Keys count surviving lines before the deletion. Zero means before line one.
    private(set) var deletedAfter: [Int: Int] = [:]

    static func added(lines: Int) -> Self {
        var changes = Self()
        if lines > 0 { changes.hunks.append(Hunk(lines: 1..<(lines + 1), kind: .added)) }
        return changes
    }

    func kind(at line: Int) -> Kind? {
        var low = 0, high = hunks.count
        while low < high {
            let mid = (low + high) / 2
            if hunks[mid].lines.upperBound <= line { low = mid + 1 } else { high = mid }
        }
        guard low < hunks.count, hunks[low].lines.contains(line) else { return nil }
        return hunks[low].kind
    }

    private mutating func appendHunk(_ header: String) {
        // With zero context each hunk is one contiguous replacement, insertion or deletion.
        let fields = header.split(separator: " ", maxSplits: 3)
        guard fields.count == 4, fields[0] == "@@", fields[1].first == "-", fields[2].first == "+" else { return }
        func range(_ field: Substring) -> (start: Int, count: Int)? {
            let parts = field.dropFirst().split(separator: ",")
            guard let first = parts.first, let start = Int(first) else { return nil }
            if parts.count == 1 { return (start, 1) }
            guard let count = Int(parts[1]) else { return nil }
            return (start, count)
        }
        guard let old = range(fields[1]), let new = range(fields[2]) else { return }
        let start = new.count == 0 ? new.start + 1 : new.start
        let kind: Kind? = new.count == 0 ? nil : (old.count == 0 ? .added : .modified)
        hunks.append(Hunk(lines: start..<(start + new.count), kind: kind))
        if old.count > new.count {
            let anchor = new.count == 0 ? new.start : new.start + new.count - 1
            deletedAfter[anchor, default: 0] += old.count - new.count
        }
    }

    fileprivate static func readDiff(in dir: URL, job: ShellJob) throws -> Self {
        var changes = Self(), prefix = Data()
        let args = ["diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv", "--ignore-cr-at-eol",
                    "--unified=0", "--inter-hunk-context=0", "--", "base", "editor"]
        // Keep only hunk headers, even for patches with very long lines.
        try job.run(Tools.git, args, in: dir, success: [0, 1]) { chunk in
            var start = chunk.startIndex
            while start < chunk.endIndex {
                let end = chunk[start...].firstIndex(of: 10) ?? chunk.endIndex
                prefix.append(contentsOf: chunk[start..<end].prefix(96 - prefix.count))
                guard end < chunk.endIndex else { break }
                if prefix.starts(with: [64, 64, 32]) {
                    changes.appendHunk(String(decoding: prefix, as: UTF8.self))
                }
                prefix.removeAll(keepingCapacity: true)
                start = end + 1
            }
            return true
        }
        return changes
    }
}

// One baseline is retained for the active document. All file I/O is confined to the diff queue.
final class GitLineBaseline {
    let repo: URL
    let revision: String
    let path: String
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var prepared = false

    init(repo: URL, revision: String, path: String) {
        self.repo = repo
        self.revision = revision
        self.path = path
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func compare(_ text: String, job: ShellJob) throws -> GitLineChanges {
        if job.isCancelled { throw CancellationError() }
        if !prepared {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let base = directory.appendingPathComponent("base")
            try Data().write(to: base)
            let file = try FileHandle(forUpdating: base)
            defer { try? file.close() }
            try job.run(Tools.git, ["cat-file", "blob", "\(revision):\(path)"], in: repo, standardOutput: file)
            try file.seek(toOffset: 0)
            let prefix = try file.read(upToCount: 3) ?? Data()
            // Plain UTF-8 goes from Git straight to disk. Decode BOM-tagged blobs as the editor does.
            if prefix.starts(with: [0xff, 0xfe]) || prefix.starts(with: [0xfe, 0xff]) || prefix.starts(with: [0xef, 0xbb, 0xbf]) {
                let original = try DiskText(Data(contentsOf: base, options: .mappedIfSafe)).text
                try original.write(to: base, atomically: true, encoding: .utf8)
            }
            prepared = true
        }
        if job.isCancelled { throw CancellationError() }
        let buffer = directory.appendingPathComponent("editor")
        defer { try? FileManager.default.removeItem(at: buffer) }
        try text.write(to: buffer, atomically: false, encoding: .utf8)
        return try GitLineChanges.readDiff(in: directory, job: job)
    }
}
