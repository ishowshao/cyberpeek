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

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    @discardableResult
    func run(_ binary: URL, _ arguments: [String], in root: URL,
             success: Set<Int32> = [0], standardOutput: FileHandle? = nil, output: ((Data) -> Bool)? = nil) throws -> Data {
        let task = Process(), pipe = Pipe()
        task.executableURL = binary
        task.arguments = arguments
        task.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        task.environment = env
        if let standardOutput { task.standardOutput = standardOutput } else { task.standardOutput = pipe }
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
        while standardOutput == nil {
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
        var paths = [String](), pending = Data()
        try job.run(Tools.rg, Tools.searchFlags + ["--files", "--null"], in: root, success: [0,1]) { chunk in
            pending.append(chunk)
            let consumed = pending.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int in
                var start = 0
                for end in bytes.indices where bytes[end] == 0 {
                    paths.append(String(decoding: bytes[start..<end], as: UTF8.self))
                    start = end + 1
                }
                return start
            }
            pending.removeFirst(consumed)
            return true
        }
        paths.sort()
        return paths
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

struct Change: Hashable, Codable {
    enum Area: String, Codable { case staged = "已暂存", working = "未暂存", untracked = "未跟踪", commit = "提交" }
    let path: String
    let oldPath: String?
    let flag: String
    let area: Area
    var revision: String? = nil
    var isUntrackedDirectory: Bool { area == .untracked && path.hasSuffix("/") }
}
struct Commit { let id: String; let title: String }

struct GitFileTree {
    private(set) var changes: [String: [Change]] = [:]
    private(set) var changedDirectories: Set<String> = []
    private(set) var deletedChildren: [String: Set<String>] = [:]
    var untrackedChildren: [String: [Change]] = [:]
    private(set) var untrackedRoots = Set<String>()

    func coversUntrackedDirectory(_ path: String) -> Bool {
        guard !untrackedRoots.isEmpty else { return false }
        var current = path[...]
        while let slash = current.lastIndex(of: "/") {
            if untrackedRoots.contains(String(current)) { return true }
            current = current[..<slash]
        }
        return false
    }

    mutating func record(_ change: Change, repo: URL, folder: URL) {
        var child = repo.appendingPathComponent(change.path, isDirectory: change.isUntrackedDirectory)
        if change.isUntrackedDirectory {
            changedDirectories.insert(child.path)
        } else {
            changes[child.path, default: []].append(change)
        }
        while child.path != folder.path {
            let parent = child.deletingLastPathComponent()
            guard parent.path != child.path else { break }
            let newDirectory = changedDirectories.insert(parent.path).inserted
            if change.flag == "D" {
                if !deletedChildren[parent.path, default: []].insert(child.lastPathComponent).inserted { break }
            } else if !newDirectory {
                break
            }
            child = parent
        }
    }

    mutating func recordSummary(_ change: Change, repo: URL, folder: URL) {
        if change.isUntrackedDirectory { untrackedRoots.insert(repo.appendingPathComponent(change.path, isDirectory: true).path) }
        record(change, repo: repo, folder: folder)
    }
}

struct GitState {
    var changes: [Change] = []
    var commits: [Commit] = []
    var branch = ""
    var head: String?
    var commonDirectory = ""
    var repo: URL
    var pathspec: [String] = []

    func contains(_ path: String) -> Bool {
        let root = repo.path
        return path == root || path.hasPrefix(root == "/" ? root : root + "/")
    }

    static func read(repo root: URL, folder workspace: URL, job: ShellJob) throws -> GitState {
        func git(_ args: [String]) throws -> Data { try job.run(Tools.git, ["--literal-pathspecs"] + args, in: root) }
        let commonArgs = ["--path-format=absolute", "--git-common-dir"]
        let info = try git(["rev-parse", "--revs-only", "HEAD"] + commonArgs)
        let fields = info.dropLast().split(separator: 10, maxSplits: 1)
        // On an unborn branch rev-parse stops at HEAD before printing the common directory.
        let head = fields.count == 2 ? String(decoding: fields[0], as: UTF8.self) : nil
        let common = try fields.count == 2 ? String(decoding: fields[1], as: UTF8.self)
            : String(decoding: git(["rev-parse"] + commonArgs).dropLast(), as: UTF8.self)
        let relative = workspaceRelativePath(of: workspace, from: root)
        let pathspec = relative == "." ? [] : ["--", relative]
        // A literal child pathspec makes Git list this level even if the opened folder is itself untracked.
        let statusScope = relative == "." ? [] : pathspec + [relative + "/.git"]
        let output = try git(["status", "--porcelain=v1", "-z", "-b", "--untracked-files=normal"] + statusScope)
        let rows = output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var state = GitState(head: head, commonDirectory: common, repo: root, pathspec: pathspec), i = 0
        while i < rows.count {
            let row = rows[i]; i += 1
            if row.hasPrefix("## ") {
                let name = String(row.dropFirst(3).components(separatedBy: "...")[0])
                if name.hasPrefix("No commits yet on ") { state.branch = String(name.dropFirst("No commits yet on ".count)) }
                else if name == "HEAD (no branch)", let head { state.branch = "HEAD · " + head.prefix(7) }
                else { state.branch = name }
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
        if let data = try? git(["log", "-12", "--format=%H%x00%s", "-z"] + pathspec) {
            let parts = data.split(separator: 0, omittingEmptySubsequences: false)
            for index in stride(from: 0, to: max(0, parts.count-1), by: 2) {
                state.commits.append(Commit(id: String(decoding: parts[index], as: UTF8.self), title: String(decoding: parts[index+1], as: UTF8.self)))
            }
        }
        return state
    }

    func untrackedChildren(in directory: String, job: ShellJob) throws -> [Change] {
        let path = workspaceRelativePath(of: URL(fileURLWithPath: directory, isDirectory: true), from: repo)
        // Select the directory and a literal child so Git opens just this level and folds its descendants.
        let data = try job.run(Tools.git, ["--literal-pathspecs", "ls-files", "--others", "--exclude-standard",
                                           "--directory", "--no-empty-directory", "-z", "--", path, path + "/.git"], in: repo)
        return data.split(separator: 0).compactMap {
            let name = String(decoding: $0, as: UTF8.self)
            guard name != path + "/" else { return nil } // An embedded worktree can be opaque to the parent.
            return Change(path: name, oldPath: nil, flag: "U", area: .untracked)
        }
    }

    func commitFiles(_ commit: String) throws -> [Change] {
        let data = try ShellJob().run(Tools.git, ["--literal-pathspecs", "diff-tree", "--root", "-m", "--first-parent", "--no-commit-id", "--name-status", "--no-renames", "-r", "-z", commit] + pathspec, in: repo)
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

struct WorkspaceGit {
    private(set) var repositories: [GitState] = []
    private(set) var fileTree = GitFileTree()
    private(set) var errors: [String] = []

    func repository(containing path: String) -> GitState? {
        repositories.first { $0.contains(path) }
    }

    private static func discover(in folder: URL, job: ShellJob) throws -> [URL] {
        do {
            let data = try job.run(Tools.git, ["rev-parse", "--show-toplevel"], in: folder)
            return [URL(fileURLWithPath: String(decoding: data.dropLast(), as: UTF8.self), isDirectory: true)]
        } catch let error as CyberPeekError where error.message.contains("not a git repository") {
            // An unmanaged workspace can contain several independent worktrees.
        }
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let excluded: Set<String> = [".git", ".build", ".vendor", "DerivedData", "node_modules"]
        guard let entries = fm.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants],
                                          errorHandler: { _, _ in true }) else { return [] }
        var roots = [URL]()
        for case let url as URL in entries {
            if job.isCancelled { throw CancellationError() }
            if excluded.contains(url.lastPathComponent) { entries.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) {
                roots.append(url)
                entries.skipDescendants()
            }
        }
        return roots.sorted { $0.path < $1.path }
    }

    // Linked worktrees share Git metadata. A checkout in one can report its event in another.
    private func affectedGitDirectories(for paths: Set<String>) -> Set<String>? {
        guard errors.isEmpty else { return nil }
        var touched = [String: GitState]()
        for path in paths {
            guard let owner = repository(containing: path) else { return nil }
            touched[owner.repo.path] = owner
        }
        for owner in touched.values where !FileManager.default.fileExists(atPath: owner.repo.appendingPathComponent(".git").path) {
            return nil
        }
        return Set(touched.values.map(\.commonDirectory))
    }

    static func read(in folder: URL, previous: Self?, changedPaths: Set<String>?, directories: Set<String> = [], job: ShellJob) throws -> Self {
        let affected = changedPaths.flatMap { previous?.affectedGitDirectories(for: $0) }
        let known = previous?.repositories ?? []
        let cached = Dictionary(uniqueKeysWithValues: known.map { ($0.repo, $0) })
        let roots = try affected == nil ? discover(in: folder, job: job) : known.map(\.repo)
        var result = Self()
        for root in roots {
            if job.isCancelled { throw CancellationError() }
            let state: GitState
            if let affected, let saved = cached[root], !affected.contains(saved.commonDirectory) {
                state = saved
            } else {
                // An opened subdirectory of an existing repo keeps its original pathspec.
                let scope = folder.pathComponents.starts(with: root.pathComponents) ? folder : root
                do { state = try GitState.read(repo: root, folder: scope, job: job) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    let name = scope.path == folder.path ? folder.lastPathComponent : workspaceRelativePath(of: root, from: folder)
                    result.errors.append("\(name) · \(error.localizedDescription)")
                    continue
                }
            }
            result.repositories.append(state)
            for change in state.changes { result.fileTree.recordSummary(change, repo: root, folder: folder) }
            for directory in directories where state.contains(directory) && result.fileTree.coversUntrackedDirectory(directory) {
                let children: [Change]
                if let affected, !affected.contains(state.commonDirectory), let saved = previous?.fileTree.untrackedChildren[directory] {
                    children = saved
                } else {
                    do { children = try state.untrackedChildren(in: directory, job: job) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        result.errors.append(error.localizedDescription)
                        result.fileTree.untrackedChildren[directory] = []
                        continue
                    }
                }
                result.fileTree.untrackedChildren[directory] = children
                for change in children { result.fileTree.record(change, repo: root, folder: folder) }
            }
        }
        return result
    }
}

final class WorkspaceMonitor {
    private var stream: FSEventStreamRef?
    private let action: ([String]) -> Void
    init(url: URL, action: @escaping ([String]) -> Void) {
        self.action = action
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<WorkspaceMonitor>.fromOpaque(info).takeUnretainedValue()
            let all = (0..<count).contains { flags[$0] & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 }
            let urls = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            monitor.action(all ? [] : urls)
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.28,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
}
