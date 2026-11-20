import AppKit
import CoreServices

func workspaceRelativePath(of url: URL, from root: URL) -> String {
    let base = root.standardizedFileURL.pathComponents
    let target = url.standardizedFileURL.pathComponents
    let shared = zip(base, target).prefix(while: { $0 == $1 }).count
    let components = Array(repeating: "..", count: base.count - shared) + target.dropFirst(shared)
    return components.isEmpty ? "." : components.joined(separator: "/")
}

struct CyberPeekError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class ShellJob {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    @discardableResult
    func run(_ binary: URL, _ arguments: [String], in root: URL,
             success: Set<Int32> = [0], output: ((Data) -> Bool)? = nil) throws -> Data {
        let task = Process(), pipe = Pipe()
        task.executableURL = binary
        task.arguments = arguments
        task.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        task.environment = env
        task.standardOutput = pipe
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close(); try? FileManager.default.removeItem(at: errorURL) }
        task.standardError = errors
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try task.run() } catch { lock.unlock(); throw error }
        process = task
        lock.unlock()
        var data = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if let output {
                if !output(chunk) { cancel(); break }
            } else {
                data.append(chunk)
            }
        }
        try? pipe.fileHandleForReading.close()
        task.waitUntilExit()
        lock.lock()
        process = nil
        let stopped = cancelled
        lock.unlock()
        if stopped { throw CancellationError() }
        if !success.contains(task.terminationStatus) {
            let message = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            throw CyberPeekError(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
}

enum Tools {
    static let git = URL(fileURLWithPath: "/usr/bin/git")
    static var rg: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rg") }
    static let searchFlags = ["--no-config", "--hidden", "-g", "!.git", "-g", "!.vendor", "-g", "!.build", "-g", "!DerivedData"]
}

struct SearchHit {
    let path: String
    let line: Int
    let excerpt: String
    let column: Int
    let length: Int
}

enum WorkspaceSearch {
    static func paths(in root: URL, job: ShellJob) throws -> [String] {
        let data = try job.run(Tools.rg, Tools.searchFlags + ["--files", "--null"], in: root, success: [0,1])
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.sorted()
    }

    static func find(_ query: String, in root: URL, job: ShellJob, deliver: @escaping ([SearchHit]) -> Void) throws {
        var pending = Data(), hits = [SearchHit](), total = 0
        var lastDelivery = Date.distantPast
        defer { if !hits.isEmpty { deliver(hits) } }
        try job.run(Tools.rg, Tools.searchFlags + ["--json", "--smart-case", "--fixed-strings", "-e", query, "."],
                    in: root, success: [0,1]) { chunk in
            pending.append(chunk)
            while let end = pending.firstIndex(of: 10) {
                let row = pending.prefix(upTo: end)
                defer { pending.removeSubrange(...end) }
                guard let obj = try? JSONSerialization.jsonObject(with: row) as? [String: Any],
                      obj["type"] as? String == "match", let fields = obj["data"] as? [String: Any],
                      let name = (fields["path"] as? [String: Any])?["text"] as? String,
                      let line = fields["line_number"] as? Int,
                      let source = (fields["lines"] as? [String: Any])?["text"] as? String,
                      let matches = fields["submatches"] as? [[String: Any]] else { continue }
                let bytes = Array(source.utf8), lineText = source as NSString
                var previousByte = 0, previousColumn = 0
                for match in matches {
                    guard let start = match["start"] as? Int, let stop = match["end"] as? Int,
                          start >= 0, stop >= start, stop <= bytes.count else { continue }
                    guard start >= previousByte else { continue }
                    let column = previousColumn + String(decoding:bytes[previousByte..<start],as:UTF8.self).utf16.count
                    let length = String(decoding:bytes[start..<stop],as:UTF8.self).utf16.count
                    previousByte = stop; previousColumn = column + length
                    let left = max(0,column-70)
                    let context = lineText.rangeOfComposedCharacterSequences(for:NSRange(location:left,length:min(200,lineText.length-left)))
                    let excerpt = lineText.substring(with:context).trimmingCharacters(in:.whitespacesAndNewlines)
                    hits.append(SearchHit(path:name.hasPrefix("./") ? String(name.dropFirst(2)) : name,
                                          line:line,excerpt:(left > 0 ? "…" : "") + excerpt,column:column,length:length))
                    total += 1
                    if total == 1200 { return false }
                }
            }
            if !hits.isEmpty && Date().timeIntervalSince(lastDelivery) > 0.06 {
                deliver(hits); hits.removeAll(keepingCapacity: true); lastDelivery = Date()
            }
            return true
        }
    }

    static func ranked(_ paths: [String], query: String) -> [String] {
        if query.isEmpty { return Array(paths.prefix(80)) }
        let needle = query.lowercased()
        var scores = [(String, Int)]()
        for path in paths {
            let folded = path.lowercased()
            var position = folded.startIndex, previous: String.Index?, score = 0
            var matched = true
            for character in needle {
                guard let index = folded[position...].firstIndex(of: character) else { matched = false; break }
                if let previous, folded.index(after: previous) == index { score += 8 }
                if index == folded.startIndex || folded[folded.index(before: index)] == "/" { score += 15 }
                previous = index
                position = folded.index(after: index)
            }
            if matched {
                let name = folded.split(separator: "/").last ?? ""
                if name.hasPrefix(needle) { score += 100 }
                if name == needle { score += 500 }
                scores.append((path, score - min(80, folded.count / 3)))
            }
        }
        return scores.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(80).map(\.0)
    }
}

struct Change: Hashable {
    enum Area: String { case staged = "已暂存", working = "未暂存", untracked = "未跟踪", commit = "提交" }
    let path: String
    let oldPath: String?
    let flag: String
    let area: Area
    var revision: String? = nil
}
struct Commit { let id: String; let title: String }
struct GitState {
    var changes: [Change] = []
    var commits: [Commit] = []
    var branch = ""
    var gitDirectory: URL?
    var repo: URL
    static func read(_ folder: URL) throws -> GitState {
        let job = ShellJob()
        func git(_ args: [String], at url: URL) throws -> Data { try job.run(Tools.git, args, in: url) }
        let top = try git(["rev-parse", "--show-toplevel"], at: folder)
        let root = URL(fileURLWithPath: String(decoding: top.dropLast(), as: UTF8.self))
        let output = try git(["status", "--porcelain=v1", "-z", "-b", "--untracked-files=all"], at: root)
        let rows = output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var state = GitState(repo: root), i = 0
        if let data = try? git(["rev-parse","--absolute-git-dir"], at: root) {
            state.gitDirectory = URL(fileURLWithPath: String(decoding:data.dropLast(),as:UTF8.self))
        }
        while i < rows.count {
            let row = rows[i]; i += 1
            if row.hasPrefix("## ") {
                state.branch = String(row.dropFirst(3).components(separatedBy: "...")[0])
                continue
            }
            guard row.count >= 4 else { continue }
            let status = Array(row.prefix(2)), path = String(row.dropFirst(3))
            var oldPath: String?
            if status.contains("R") || status.contains("C"), i < rows.count { oldPath = rows[i]; i += 1 }
            if status == ["?", "?"] {
                state.changes.append(Change(path: path, oldPath: nil, flag: "U", area: .untracked))
            } else {
                if status[0] != " " { state.changes.append(Change(path: path, oldPath: oldPath, flag: String(status[0]), area: .staged)) }
                if status[1] != " " { state.changes.append(Change(path: path, oldPath: oldPath, flag: String(status[1]), area: .working)) }
            }
        }
        if let data = try? git(["log", "-12", "--format=%H%x00%s", "-z"], at: root) {
            let parts = data.split(separator: 0, omittingEmptySubsequences: false)
            for index in stride(from: 0, to: max(0, parts.count-1), by: 2) {
                state.commits.append(Commit(id: String(decoding: parts[index], as: UTF8.self), title: String(decoding: parts[index+1], as: UTF8.self)))
            }
        }
        return state
    }

    func commitFiles(_ commit: String) throws -> [Change] {
        let data = try ShellJob().run(Tools.git, ["diff-tree", "--root", "-m", "--first-parent", "--no-commit-id", "--name-status", "--no-renames", "-r", "-z", commit], in: repo)
        let parts = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return stride(from: 0, to: max(0, parts.count-1), by: 2).map {
            Change(path: parts[$0+1], oldPath: nil, flag: parts[$0], area: .commit, revision: commit)
        }
    }
    func diff(_ change: Change) throws -> String {
        let options = ["--no-color", "--no-ext-diff", "--no-textconv"]
        var args = ["--literal-pathspecs"]
        if change.area == .untracked {
            args += ["diff", "--no-index"] + options + ["--", "/dev/null", change.path]
        } else {
            if let rev = change.revision { args += ["show", "--format=", "--diff-merges=first-parent"] + options + [rev] }
            else { args += ["diff"] + options + (change.area == .staged ? ["--cached"] : []) }
            args += ["--", change.path]
            if let old = change.oldPath { args.append(old) }
        }
        let data = try ShellJob().run(Tools.git, args, in: repo, success: change.area == .untracked ? [0,1] : [0])
        return String(decoding: data, as: UTF8.self)
    }
}

final class WorkspaceMonitor {
    private var stream: FSEventStreamRef?
    private let action: () -> Void
    init(url: URL, action: @escaping () -> Void) {
        self.action = action
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<WorkspaceMonitor>.fromOpaque(info).takeUnretainedValue().action()
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.28,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
}
