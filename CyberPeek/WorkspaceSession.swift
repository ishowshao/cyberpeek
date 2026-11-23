import AppKit

struct WorkspaceSession: Codable {
    struct Tab: Codable {
        let target: Workbench.Target
        let pinned: Bool
        let svgPreview: Bool
    }

    let folder: URL
    var tabs: [Tab]
    let selected: Workbench.Target?
}

extension Workbench {
    var session: WorkspaceSession? {
        guard let root else { return nil }
        let live = documents.compactMap { doc -> WorkspaceSession.Tab? in
            guard let target = targets[doc.identity] else { return nil }
            return .init(target: target, pinned: doc.pinned, svgPreview: (doc as? Editor)?.showsSVGPreview == true)
        }
        // Quitting again while files are loading must retain the tabs still waiting to open.
        var tabs = live
        if let waiting = restoringSession?.tabs {
            let waitingTargets = Set(waiting.map(\.target))
            let updated = Dictionary(live.map { ($0.target, $0) }, uniquingKeysWith: { _, latest in latest })
            tabs = waiting.map { updated[$0.target] ?? $0 } + live.filter { !waitingTargets.contains($0.target) }
        }
        return WorkspaceSession(folder: root, tabs: tabs,
                                selected: activeDocument.flatMap { targets[$0.identity] } ?? restoringSession?.selected)
    }

    func restoreTabs(_ session: WorkspaceSession) {
        guard !session.tabs.isEmpty else { return }
        restoringSession = session
        let workspace = projectVersion
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = session.tabs.compactMap { tab -> (WorkspaceSession.Tab, DocumentRequest, OpenedContent)? in
                let request = DocumentRequest(tab.target)
                guard let content = try? request.read() else { return nil }
                if case .patch = tab.target, case .text("", _) = content { return nil }
                return (tab, request, content)
            }
            DispatchQueue.main.async {
                guard self.projectVersion == workspace, let pending = self.restoringSession else { return }
                self.restoringSession = nil
                let wanted = Set(pending.tabs.map(\.target))
                let live = self.documents
                let hasLivePreview = live.contains { !$0.pinned }
                var ordered: [DocumentTab] = [], seen = Set<String>()
                var selected: DocumentTab?
                for (tab, request, content) in loaded where wanted.contains(tab.target) && seen.insert(request.id).inserted {
                    let doc: DocumentTab
                    if let existing = live.first(where: { $0.identity == request.id }) {
                        doc = existing
                    } else {
                        if !tab.pinned && hasLivePreview { continue }
                        doc = self.makeDocument(request, content: content)
                        doc.pinned = tab.pinned
                        if let editor = doc as? Editor { editor.showsSVGPreview = tab.svgPreview && editor.supportsSVGPreview }
                        self.targets[request.id] = tab.target
                    }
                    ordered.append(doc)
                    if tab.target == session.selected { selected = doc }
                }
                self.documents = ordered + live.filter { !seen.contains($0.identity) }
                // A Finder open or a tab selected during loading takes precedence.
                if self.activeDocument != nil { self.updateTabs() }
                else { self.show(selected ?? self.documents.first) }
            }
        }
    }
}
