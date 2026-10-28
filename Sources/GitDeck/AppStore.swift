import Foundation
import SwiftUI
import AppKit

enum RepoScanner {
    private static let skip: Set<String> = ["node_modules", "Library", "Pods", "DerivedData", ".Trash", "vendor"]

    static func scan(root: String, maxDepth: Int) -> [String] {
        var result: [String] = []
        let fm = FileManager.default
        func walk(_ dir: String, _ depth: Int) {
            if fm.fileExists(atPath: dir + "/.git") { result.append(dir); return }
            guard depth < maxDepth,
                  let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir),
                                                          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
            for u in items {
                let n = u.lastPathComponent
                if n.hasPrefix(".") || skip.contains(n) { continue }
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if v?.isDirectory == true, v?.isSymbolicLink != true { walk(u.path, depth + 1) }
            }
        }
        walk(root, 0)
        return result
    }
}

struct RowInfo { var branch: String; var dirty: Int }

@MainActor
final class AppStore: ObservableObject {
    @Published var workspaces: [String] { didSet { UserDefaults.standard.set(workspaces, forKey: "workspaces") } }
    @Published var extraRepos: [String] { didSet { UserDefaults.standard.set(extraRepos, forKey: "extraRepos") } }
    @Published private(set) var found: [String: [Repo]] = [:]
    @Published var query = ""
    @Published var scanning = false
    @Published var rowRefresh = 0
    @Published var selected: String? { didSet { if selected != oldValue { updateCurrent() } } }
    @Published private(set) var current: RepoModel?
    @Published var showClone = false
    @Published var banner: Banner?
    @Published var cloning = false
    @Published var updatingWorkspaces: Set<String> = []
    @Published var prompt: PromptRequest?

    private var models: [String: RepoModel] = [:]

    init() {
        workspaces = UserDefaults.standard.stringArray(forKey: "workspaces") ?? []
        extraRepos = UserDefaults.standard.stringArray(forKey: "extraRepos") ?? []
        ShellEnv.shared.resolve()
        rescan()
    }

    // MARK: workspaces

    func addWorkspace() {
        guard let p = pickFolder("Выберите рабочую область (папку с репозиториями)") else { return }
        if !workspaces.contains(p) { workspaces.append(p) }
        rescan()
    }

    func removeWorkspace(_ w: String) {
        workspaces.removeAll { $0 == w }
        found[w] = nil
    }

    func rescan() {
        scanning = true
        let roots = workspaces
        let depth = (UserDefaults.standard.object(forKey: "scanDepth") as? Int) ?? 5
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [String: [Repo]] in
                var d: [String: [Repo]] = [:]
                for r in roots { d[r] = RepoScanner.scan(root: r, maxDepth: depth).map { Repo(path: $0) } }
                return d
            }.value
            found = result
            scanning = false
            rowRefresh += 1
        }
    }

    private var allFoundPaths: Set<String> { Set(found.values.flatMap { $0.map(\.path) }) }

    func repos(in ws: String) -> [Repo] {
        filtered(found[ws] ?? [])
    }

    var standalone: [Repo] {
        let f = allFoundPaths
        return filtered(extraRepos.filter { !f.contains($0) }.map { Repo(path: $0) })
    }

    private func filtered(_ list: [Repo]) -> [Repo] {
        let q = query.trimmed
        return list
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var totalMatches: Int {
        workspaces.reduce(0) { $0 + repos(in: $1).count } + standalone.count
    }

    // MARK: selection

    private func updateCurrent() {
        guard let p = selected else { current = nil; return }
        if let m = models[p] { current = m; return }
        let m = RepoModel(path: p)
        models[p] = m
        current = m
    }

    func refreshCurrent() { Task { await current?.refreshAll() } }

    // MARK: open / init / clone

    func openRepository() {
        guard let p = pickFolder("Выберите папку с репозиторием") else { return }
        guard FileManager.default.fileExists(atPath: p + "/.git") else {
            banner = Banner(title: "Это не git-репозиторий", text: p, isError: true)
            return
        }
        addExtra(p)
    }

    func initRepository() {
        guard let p = pickFolder("Выберите папку для git init") else { return }
        Task {
            let r = await Shell.git(["init"], cwd: p)
            if r.ok { addExtra(p) } else { banner = Banner(title: "git init: ошибка", text: r.combined, isError: true) }
        }
    }

    private func addExtra(_ p: String) {
        if !allFoundPaths.contains(p), !extraRepos.contains(p) { extraRepos.append(p) }
        selected = p
    }

    func removeExtra(_ p: String) {
        extraRepos.removeAll { $0 == p }
        if selected == p { selected = nil }
    }

    func clone(url: String, parent: String, name: String) async {
        let target = parent + "/" + name
        cloning = true
        let r = await Shell.run("/usr/bin/env", ["git", "clone", "--progress", url, target], cwd: parent)
        cloning = false
        if r.ok {
            let inWorkspace = workspaces.contains { target.hasPrefix($0 + "/") }
            if !inWorkspace { extraRepos.append(target) }
            rescan()
            selected = target
            showClone = false
            banner = Banner(title: "Клонировано", text: target, isError: false)
        } else {
            banner = Banner(title: "git clone: ошибка", text: r.combined, isError: true)
        }
    }

    // MARK: update all / fetch branch

    /// fetch --all --prune и pull --ff-only для каждого репозитория рабочей области.
    func updateAll(in ws: String) {
        guard !updatingWorkspaces.contains(ws) else { return }
        let paths = (found[ws] ?? []).map(\.path)
        guard !paths.isEmpty else {
            banner = Banner(title: "Обновить все", text: "В рабочей области нет репозиториев", isError: true)
            return
        }
        updatingWorkspaces.insert(ws)
        Task {
            var lines: [String] = []
            var failed = 0
            var index = 0
            await withTaskGroup(of: (String, Bool, String).self) { group in
                func next() {
                    guard index < paths.count else { return }
                    let p = paths[index]; index += 1
                    group.addTask { await AppStore.updateRepo(p) }
                }
                for _ in 0..<min(4, paths.count) { next() }
                while let (p, ok, msg) = await group.next() {
                    if !ok { failed += 1 }
                    lines.append("\(ok ? "✓" : "✗") \((p as NSString).lastPathComponent): \(msg)")
                    next()
                }
            }
            lines.sort()
            updatingWorkspaces.remove(ws)
            await refreshModels()
            banner = Banner(title: failed == 0 ? "Обновлено репозиториев: \(paths.count)" : "Обновление: ошибок \(failed) из \(paths.count)",
                            text: lines.joined(separator: "\n"), isError: failed > 0)
        }
    }

    private nonisolated static func updateRepo(_ p: String) async -> (String, Bool, String) {
        let f = await Shell.git(["fetch", "--all", "--prune"], cwd: p)
        guard f.ok else { return (p, false, "fetch: " + f.combined) }
        let up = await Shell.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], cwd: p)
        guard up.ok else { return (p, true, "fetch выполнен (у текущей ветки нет upstream или HEAD отсоединён)") }
        let r = await Shell.git(["pull", "--ff-only"], cwd: p)
        return (p, r.ok, r.combined.isEmpty ? "готово" : r.combined.split(separator: "\n").last.map(String.init) ?? "готово")
    }

    private func refreshModels() async {
        rowRefresh += 1
        for m in models.values { await m.refreshAll() }
    }

    func promptFetchBranch(for repo: Repo) {
        prompt = PromptRequest(title: "Выкачать ветку", message: repo.name,
                               fields: [PromptField(label: "Имя ветки")],
                               confirmLabel: "Выкачать") { [weak self] v, _ in
            guard let name = v.first?.trimmed, !name.isEmpty else { return }
            Task { await self?.fetchBranch(name, in: repo.path) }
        }
    }

    /// Подтягивает ветку по имени с удалённого репозитория и переключается на неё.
    func fetchBranch(_ name: String, in path: String) async {
        let title = "Выкачать ветку \(name)"
        let f = await Shell.git(["fetch", "--all", "--prune"], cwd: path)
        guard f.ok else { banner = Banner(title: "\(title): ошибка", text: f.combined, isError: true); return }

        let local = await Shell.git(["rev-parse", "--verify", "--quiet", "refs/heads/" + name], cwd: path)
        let r: CmdResult
        if local.ok {
            let sw = await Shell.git(["switch", name], cwd: path)
            if sw.ok, (await Shell.git(["rev-parse", "--abbrev-ref", "@{u}"], cwd: path)).ok {
                let pull = await Shell.git(["pull", "--ff-only"], cwd: path)
                r = pull.ok ? sw : pull
            } else { r = sw }
        } else {
            guard let remote = await Shell.remoteTrackingRef(name, cwd: path) else {
                banner = Banner(title: "\(title): ошибка", text: "Ветка «\(name)» не найдена ни локально, ни на удалённых репозиториях", isError: true)
                return
            }
            r = await Shell.switchTracking(remote, name: name) { await Shell.git($0, cwd: path) }
        }
        if r.ok {
            banner = Banner(title: title, text: r.combined.isEmpty ? "Готово" : r.combined, isError: false)
            if let m = models[path] { await m.refreshAll() }
            rowRefresh += 1
        } else {
            banner = Banner(title: "\(title): ошибка", text: r.combined, isError: true)
        }
    }

    func pickFolder(_ message: String) -> String? {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.message = message
        p.prompt = "Выбрать"
        return p.runModal() == .OK ? p.url?.path : nil
    }

    func openTerminal(at path: String) {
        let app = UserDefaults.standard.string(forKey: "terminalApp") ?? "Terminal"
        Task { _ = await Shell.run("/usr/bin/open", ["-a", app.isEmpty ? "Terminal" : app, path]) }
    }

    func loadRowInfo(_ repo: Repo) async -> RowInfo? {
        let r = await Shell.git(["status", "--porcelain=v1", "--branch"], cwd: repo.path, env: ["GIT_OPTIONAL_LOCKS": "0"])
        guard r.ok else { return nil }
        var lines = r.out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return nil }
        var head = lines.removeFirst()
        if head.hasPrefix("## ") { head.removeFirst(3) }
        if head.hasPrefix("No commits yet on ") { head = String(head.dropFirst("No commits yet on ".count)) }
        if let r = head.range(of: "...") { head = String(head[..<r.lowerBound]) }
        else if let r = head.range(of: " [") { head = String(head[..<r.lowerBound]) }
        return RowInfo(branch: head, dirty: lines.count)
    }
}
