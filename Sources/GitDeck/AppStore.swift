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
    @Published var favorites: Set<String> { didSet { UserDefaults.standard.set(Array(favorites), forKey: "favorites") } }
    @Published var lang: AppLang = Loc.lang { didSet { Loc.set(lang) } }
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
    @Published var showOrgSync = false
    @Published var syncingOrg = false
    @Published var syncProgress = ""
    private var syncControl: RunControl?

    private var models: [String: RepoModel] = [:]

    init() {
        workspaces = UserDefaults.standard.stringArray(forKey: "workspaces") ?? []
        extraRepos = UserDefaults.standard.stringArray(forKey: "extraRepos") ?? []
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
        Loc.prepare()
        ShellEnv.shared.resolve()
        rescan()
    }

    // MARK: workspaces

    func addWorkspace() {
        guard let p = pickFolder(L("Выберите рабочую область (папку с репозиториями)")) else { return }
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
            .sorted {
                let f0 = favorites.contains($0.path), f1 = favorites.contains($1.path)
                if f0 != f1 { return f0 }   // избранные всегда сверху
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func toggleFavorite(_ path: String) {
        if favorites.contains(path) { favorites.remove(path) } else { favorites.insert(path) }
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
        guard let p = pickFolder(L("Выберите папку с репозиторием")) else { return }
        guard FileManager.default.fileExists(atPath: p + "/.git") else {
            banner = Banner(title: L("Это не git-репозиторий"), text: p, isError: true)
            return
        }
        addExtra(p)
    }

    func initRepository() {
        guard let p = pickFolder(L("Выберите папку для git init")) else { return }
        Task {
            let r = await Shell.git(["init"], cwd: p)
            if r.ok { addExtra(p) } else { banner = Banner(title: L("git init: ошибка"), text: r.combined, isError: true) }
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
            banner = Banner(title: L("Клонировано"), text: target, isError: false)
        } else {
            banner = Banner(title: L("git clone: ошибка"), text: r.combined, isError: true)
        }
    }

    // MARK: sync GitHub organization

    /// Организации текущего пользователя GitHub.
    func loadOrganizations() async -> (orgs: [String], error: String?) {
        do {
            let o = try await GitHubAPI.organizations()
            return (o.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, nil)
        } catch let e as GitHubAPI.Failure { return ([], e.text) }
        catch { return ([], error.localizedDescription) }
    }

    func cancelSync() { syncControl?.cancel(); syncProgress = L("Прерываю…") }

    /// Клонирует в `ws` все репозитории организации, которых там ещё нет. Существующие не трогает и ничего не удаляет.
    func syncOrganization(_ org: String, into ws: String, includeArchived: Bool) async {
        guard !syncingOrg else { return }
        syncingOrg = true
        syncProgress = L("Получаю список репозиториев…")
        let control = RunControl()
        syncControl = control
        defer { syncingOrg = false; syncProgress = ""; syncControl = nil }

        let list: [GitHubAPI.RepoInfo]
        do {
            list = try await GitHubAPI.repos(org: org, control: control).filter { includeArchived || !$0.archived }
        } catch {
            if control.isCancelled {
                banner = Banner(title: L("Синхронизация %@ прервана", org), text: L("Список репозиториев не получен"), isError: true)
            } else {
                banner = Banner(title: L("Синхронизация %@: ошибка", org), text: (error as? GitHubAPI.Failure)?.text ?? error.localizedDescription, isError: true)
            }
            return
        }
        let urls = Dictionary(list.map { ($0.name, $0.cloneURL) }, uniquingKeysWith: { a, _ in a })
        let names = list.map(\.name)
        let fm = FileManager.default
        var existing: [String: String] = [:]   // имя -> путь
        for r in found[ws] ?? [] { existing[r.name] = r.path }
        var missing: [String] = []
        for n in names {
            let dir = ws + "/" + n
            if existing[n] != nil { continue }
            if fm.fileExists(atPath: dir + "/.git") { existing[n] = dir }
            else if !fm.fileExists(atPath: dir) { missing.append(n) }
        }
        let toUpdate = names.compactMap { existing[$0] }

        var failures: [String] = []
        var done = 0
        let total = missing.count + toUpdate.count
        var index = 0
        await withTaskGroup(of: (String, Bool, String, Bool).self) { group in
            func next() {
                if control.isCancelled { return }
                if index < missing.count {
                    let n = missing[index]; index += 1
                    group.addTask {
                        let r = await Shell.run("/usr/bin/env", ["git", "clone", urls[n] ?? "", ws + "/" + n], cwd: ws, control: control)
                        if control.isCancelled { try? FileManager.default.removeItem(atPath: ws + "/" + n) }  // недокачанный клон
                        return (n, r.ok, r.combined.split(separator: "\n").last.map(String.init) ?? L("ошибка"), true)
                    }
                } else if index - missing.count < toUpdate.count {
                    let p = toUpdate[index - missing.count]; index += 1
                    group.addTask {
                        let (_, ok, msg) = await AppStore.updateRepo(p, control: control)
                        return ((p as NSString).lastPathComponent, ok, msg, false)
                    }
                }
            }
            for _ in 0..<min(8, total) { next() }
            while let (n, ok, msg, _) = await group.next() {
                done += 1
                syncProgress = L("Обработано %lld из %lld", done, total)
                if !ok && !control.isCancelled { failures.append("✗ \(n): \(msg)") }
                next()
            }
        }
        rescan()
        await refreshModels()
        if control.isCancelled {
            banner = Banner(title: L("Синхронизация %@ прервана", org),
                            text: L("Обработано %lld из %lld. Недокачанные клоны удалены, уже готовые репозитории сохранены.", done, total) +
                                  (failures.isEmpty ? "" : L("\nОшибки до прерывания:\n") + failures.sorted().joined(separator: "\n")),
                            isError: true)
            return
        }
        let clonedNew = missing.count - failures.filter { f in missing.contains { f.hasPrefix("✗ \($0):") } }.count
        var text = L("Склонировано новых: %lld, обновлено существующих: %lld", clonedNew, toUpdate.count)
        if !failures.isEmpty { text += L(", ошибок: %lld\n", failures.count) + failures.sorted().joined(separator: "\n") }
        banner = Banner(title: failures.isEmpty ? L("Синхронизация %@ завершена", org) : L("Синхронизация %@: есть ошибки", org),
                        text: text, isError: !failures.isEmpty)
        if failures.isEmpty { showOrgSync = false }
    }

    // MARK: update all / fetch branch

    /// fetch --all --prune и pull --ff-only для каждого репозитория рабочей области.
    func updateAll(in ws: String) {
        guard !updatingWorkspaces.contains(ws) else { return }
        let paths = (found[ws] ?? []).map(\.path)
        guard !paths.isEmpty else {
            banner = Banner(title: L("Обновить все"), text: L("В рабочей области нет репозиториев"), isError: true)
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
            banner = Banner(title: failed == 0 ? L("Обновлено репозиториев: %lld", paths.count) : L("Обновление: ошибок %lld из %lld", failed, paths.count),
                            text: lines.joined(separator: "\n"), isError: failed > 0)
        }
    }

    private nonisolated static func updateRepo(_ p: String, control: RunControl? = nil) async -> (String, Bool, String) {
        let f = await Shell.git(["fetch", "--all", "--prune"], cwd: p, control: control)
        guard f.ok else { return (p, false, "fetch: " + f.combined) }
        let up = await Shell.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], cwd: p, control: control)
        guard up.ok else { return (p, true, L("fetch выполнен (у текущей ветки нет upstream или HEAD отсоединён)")) }
        let r = await Shell.git(["pull", "--ff-only"], cwd: p, control: control)
        return (p, r.ok, r.combined.isEmpty ? L("готово") : r.combined.split(separator: "\n").last.map(String.init) ?? L("готово"))
    }

    private func refreshModels() async {
        rowRefresh += 1
        for m in models.values { await m.refreshAll() }
    }

    func promptFetchBranch(for repo: Repo) {
        prompt = PromptRequest(title: L("Выкачать ветку"), message: repo.name,
                               fields: [PromptField(label: L("Имя ветки"))],
                               confirmLabel: L("Выкачать")) { [weak self] v, _ in
            guard let name = v.first?.trimmed, !name.isEmpty else { return }
            Task { await self?.fetchBranch(name, in: repo.path) }
        }
    }

    /// Подтягивает ветку по имени с удалённого репозитория и переключается на неё.
    func fetchBranch(_ name: String, in path: String) async {
        let title = L("Выкачать ветку %@", name)
        let f = await Shell.git(["fetch", "--all", "--prune"], cwd: path)
        guard f.ok else { banner = Banner(title: L("%@: ошибка", title), text: f.combined, isError: true); return }

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
                banner = Banner(title: L("%@: ошибка", title), text: L("Ветка «%@» не найдена ни локально, ни на удалённых репозиториях", name), isError: true)
                return
            }
            r = await Shell.switchTracking(remote, name: name) { await Shell.git($0, cwd: path) }
        }
        if r.ok {
            banner = Banner(title: title, text: r.combined.isEmpty ? L("Готово") : r.combined, isError: false)
            if let m = models[path] { await m.refreshAll() }
            rowRefresh += 1
        } else {
            banner = Banner(title: L("%@: ошибка", title), text: r.combined, isError: true)
        }
    }

    func pickFolder(_ message: String) -> String? {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.message = message
        p.prompt = L("Выбрать")
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
