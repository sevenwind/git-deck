import Foundation
import SwiftUI
import AppKit

enum HunkMode { case stage, unstage, discard }
enum PullMode { case merge, rebase, ffOnly }

@MainActor
final class RepoModel: ObservableObject {
    let path: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    @Published var tab: RepoTab = .changes

    // Статус
    @Published var branch = ""
    @Published var upstream: String?
    @Published var ahead = 0
    @Published var behind = 0
    @Published var hasCommits = true
    @Published var files: [FileEntry] = []
    @Published var state: RepoState = .none
    @Published var selection: FileSelection?
    @Published var diff: ParsedDiff?

    // Коммит
    @Published var commitMessage = ""
    @Published var amend = false
    @Published var skipHooks = false

    // История
    @Published var commits: [Commit] = []
    @Published var historyQuery = ""
    @Published var historyAll = true
    @Published var canLoadMore = false
    @Published var selectedCommitID: String?
    @Published var commitBody = ""
    @Published var commitPatch = ""
    private var historyLimit = 200

    // Прочее
    @Published var branches: [Branch] = []
    @Published var stashes: [StashItem] = []
    @Published var selectedStash: String?
    @Published var stashPatch = ""
    @Published var tags: [TagItem] = []
    @Published var remotes: [RemoteItem] = []
    @Published var hooks = HooksInfo()

    // Служебное
    @Published var busyCount = 0
    @Published var busyTitle = ""
    @Published var banner: Banner?
    @Published var prompt: PromptRequest?
    @Published var confirm: ConfirmRequest?
    @Published var consoleLog: [ConsoleEntry] = []

    private var gitDir: String?
    var busy: Bool { busyCount > 0 }

    init(path: String) {
        self.path = path
        Task { await refreshAll() }
    }

    var staged: [FileEntry] { files.filter(\.isStaged) }
    var unstaged: [FileEntry] { files.filter(\.isUnstaged) }
    var conflicted: [FileEntry] { files.filter(\.conflicted) }
    var localBranches: [Branch] { branches.filter { !$0.isRemote } }
    var detached: Bool { branch.hasPrefix("(") }
    var branchTitle: String { branch.isEmpty ? "—" : branch }
    var defaultRemote: String { remotes.first(where: { $0.name == "origin" })?.name ?? remotes.first?.name ?? "origin" }

    // MARK: git

    private var huskyEnv: [String: String] {
        UserDefaults.standard.bool(forKey: "disableHusky") ? ["HUSKY": "0"] : [:]
    }

    private func display(_ args: [String]) -> String {
        "git " + args.map { a in
            let one = a.replacingOccurrences(of: "\n", with: "⏎")
            return one.contains(" ") ? "'\(one)'" : one
        }.joined(separator: " ")
    }

    func addLog(_ command: String, _ r: CmdResult) {
        consoleLog.append(ConsoleEntry(command: command, output: r.combined, code: r.code))
        if consoleLog.count > 300 { consoleLog.removeFirst(consoleLog.count - 300) }
    }

    @discardableResult
    func git(_ args: [String], stdin: String? = nil, log: Bool = true, env: [String: String] = [:]) async -> CmdResult {
        var e = huskyEnv
        for (k, v) in env { e[k] = v }
        let r = await Shell.git(args, cwd: path, env: e, stdin: stdin)
        if log { addLog(display(args), r) }
        return r
    }

    /// Выполняет git-операцию с индикатором занятости, показом ошибки и обновлением состояния.
    @discardableResult
    func run(_ title: String, _ args: [String], stdin: String? = nil, showOutput: Bool = false) async -> Bool {
        busyCount += 1
        busyTitle = title
        let r = await git(args, stdin: stdin)
        busyCount -= 1
        if r.ok {
            if showOutput, !r.combined.isEmpty { show(title, r.combined, error: false) }
        } else {
            show("\(title): ошибка", r.combined.isEmpty ? "Код выхода \(r.code)" : r.combined, error: true)
        }
        await refreshAll()
        return r.ok
    }

    func runShell(_ title: String, _ command: String) async {
        busyCount += 1
        busyTitle = title
        let r = await Shell.run("/bin/sh", ["-c", command], cwd: path, env: huskyEnv)
        addLog(command, r)
        busyCount -= 1
        show(r.ok ? title : "\(title): ошибка", r.combined.isEmpty ? "Готово" : r.combined, error: !r.ok)
        await refreshAll()
    }

    func show(_ title: String, _ text: String, error: Bool) {
        let b = Banner(title: title, text: text, isError: error)
        banner = b
        if !error {
            Task {
                try? await Task.sleep(for: .seconds(7))
                if banner?.id == b.id { banner = nil }
            }
        }
    }

    // MARK: refresh

    func refreshAll() async {
        async let a: () = refreshStatus()
        async let b: () = refreshBranches()
        async let c: () = refreshHistory()
        async let d: () = refreshStashes()
        async let e: () = refreshTagsRemotes()
        async let f: () = refreshHooks()
        _ = await (a, b, c, d, e, f)
    }

    func refreshStatus() async {
        let r = await git(["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"],
                          log: false, env: ["GIT_OPTIONAL_LOCKS": "0"])
        guard r.ok else { return }
        let s = parseStatus(r.out)
        let changed = s.files != files
        if branch != s.branch { branch = s.branch }
        if upstream != s.upstream { upstream = s.upstream }
        if ahead != s.ahead { ahead = s.ahead }
        if behind != s.behind { behind = s.behind }
        if hasCommits != s.hasCommits { hasCommits = s.hasCommits }
        if changed { files = s.files }
        await detectState()
        if let sel = selection {
            let valid = files.contains { $0.path == sel.path && (sel.staged ? $0.isStaged : ($0.isUnstaged || $0.conflicted)) }
            if !valid { selection = nil; diff = nil }
            else if changed { await loadDiff() }
        }
    }

    private func detectState() async {
        if gitDir == nil {
            let r = await git(["rev-parse", "--absolute-git-dir"], log: false)
            if r.ok { gitDir = r.out.trimmed }
        }
        guard let g = gitDir else { return }
        let fm = FileManager.default
        func has(_ n: String) -> Bool { fm.fileExists(atPath: g + "/" + n) }
        let s: RepoState = has("rebase-merge") || has("rebase-apply") ? .rebasing
            : has("MERGE_HEAD") ? .merging
            : has("CHERRY_PICK_HEAD") ? .cherryPicking
            : has("REVERT_HEAD") ? .reverting : .none
        if s != state { state = s }
    }

    func refreshHistory(reset: Bool = true) async {
        if reset { historyLimit = 200 }
        var args = ["log", "--no-color", "-n", String(historyLimit + 1), commitFormat, "--date-order"]
        if historyAll { args.append("--all") }
        let q = historyQuery.trimmed
        if !q.isEmpty { args += ["-i", "--grep=" + q] }
        let r = await git(args, log: false, env: ["GIT_OPTIONAL_LOCKS": "0"])
        guard r.ok else { commits = []; canLoadMore = false; return }
        var list = parseCommits(r.out)
        canLoadMore = list.count > historyLimit
        if canLoadMore { list.removeLast() }
        commits = list
    }

    func loadMoreHistory() async {
        historyLimit += 300
        await refreshHistory(reset: false)
    }

    func refreshBranches() async {
        let fmt = "%(refname)%1f%(refname:short)%1f%(HEAD)%1f%(upstream:short)%1f%(upstream:track)%1f%(objectname:short)%1f%(contents:subject)%1f%(committerdate:relative)"
        let r = await git(["for-each-ref", "--format=" + fmt, "--sort=-committerdate", "refs/heads", "refs/remotes"],
                          log: false, env: ["GIT_OPTIONAL_LOCKS": "0"])
        guard r.ok else { return }
        var list: [Branch] = []
        for line in r.out.split(separator: "\n") {
            let f = line.components(separatedBy: "\u{1f}")
            guard f.count >= 8 else { continue }
            let remote = f[0].hasPrefix("refs/remotes/")
            if remote && f[1].hasSuffix("/HEAD") { continue }
            list.append(Branch(name: f[1], isRemote: remote, isCurrent: f[2] == "*", upstream: f[3],
                               track: f[4], hash: f[5], subject: f[6], date: f[7]))
        }
        branches = list
    }

    func refreshStashes() async {
        let r = await git(["stash", "list", "--format=%gd%x1f%gs%x1f%cr"], log: false, env: ["GIT_OPTIONAL_LOCKS": "0"])
        guard r.ok else { return }
        stashes = r.out.split(separator: "\n").compactMap { l in
            let f = l.components(separatedBy: "\u{1f}")
            return f.count >= 3 ? StashItem(ref: f[0], message: f[1], date: f[2]) : nil
        }
        if let s = selectedStash, !stashes.contains(where: { $0.ref == s }) { selectedStash = nil; stashPatch = "" }
    }

    func refreshTagsRemotes() async {
        let t = await git(["tag", "-l", "--sort=-creatordate",
                           "--format=%(refname:short)%1f%(objectname:short)%1f%(contents:subject)%1f%(creatordate:relative)"],
                          log: false, env: ["GIT_OPTIONAL_LOCKS": "0"])
        if t.ok {
            tags = t.out.split(separator: "\n").compactMap { l in
                let f = l.components(separatedBy: "\u{1f}")
                return f.count >= 4 ? TagItem(name: f[0], hash: f[1], subject: f[2], date: f[3]) : nil
            }
        }
        let r = await git(["remote", "-v"], log: false, env: ["GIT_OPTIONAL_LOCKS": "0"])
        if r.ok {
            var list: [RemoteItem] = []
            for l in r.out.split(separator: "\n") where l.hasSuffix("(fetch)") {
                let f = l.split(whereSeparator: { $0 == "\t" || $0 == " " })
                if f.count >= 2 { list.append(RemoteItem(name: String(f[0]), url: String(f[1]))) }
            }
            remotes = list
        }
    }

    // MARK: diff

    func select(_ sel: FileSelection?) async {
        selection = sel
        await loadDiff()
    }

    func loadDiff() async {
        guard let sel = selection, let f = files.first(where: { $0.path == sel.path }) else { diff = nil; return }
        let args: [String]
        if f.untracked { args = ["diff", "--no-index", "--no-color", "--", "/dev/null", f.path] }
        else if sel.staged { args = ["diff", "--cached", "--no-color", "--", f.path] + (f.origPath.map { [$0] } ?? []) }
        else { args = ["diff", "--no-color", "--", f.path] }
        let r = await git(args, log: false, env: ["GIT_OPTIONAL_LOCKS": "0"])
        guard selection == sel else { return }
        diff = ParsedDiff(truncateLines(r.out, max: 8000))
    }

    func applyHunk(_ h: DiffHunk, mode: HunkMode) async {
        guard let d = diff else { return }
        var args = ["apply", "--whitespace=nowarn"]
        switch mode {
        case .stage: args.append("--cached")
        case .unstage: args += ["--cached", "--reverse"]
        case .discard: args.append("--reverse")
        }
        args.append("-")
        await run("Блок", args, stdin: d.patch(for: h))
    }

    // MARK: staging

    func stage(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        await run("Добавить в индекс", ["add", "--"] + paths)
    }

    func unstage(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        if hasCommits { await run("Убрать из индекса", ["restore", "--staged", "--"] + paths) }
        else { await run("Убрать из индекса", ["rm", "--cached", "-r", "--"] + paths) }
    }

    func stageAll() async { await run("Добавить всё", ["add", "-A"]) }
    func unstageAll() async { await unstage(staged.map(\.path)) }

    func askDiscard(_ f: FileEntry) {
        confirm = ConfirmRequest(title: "Отменить изменения в «\(f.fileName)»?",
                                 message: "Изменения будут безвозвратно потеряны.",
                                 confirmLabel: "Отменить изменения") { [weak self] in
            Task { await self?.discard(f) }
        }
    }

    func discard(_ f: FileEntry) async {
        if f.untracked { await run("Удалить файл", ["clean", "-f", "-d", "--", f.path]) }
        else { await run("Отмена изменений", ["restore", "--", f.path]) }
    }

    /// Полный сброс файла (и индекс, и рабочая папка) до состояния HEAD.
    func askDiscardCompletely(_ f: FileEntry) {
        let added = f.x == "A" || f.x == "R" || f.x == "C"
        confirm = ConfirmRequest(title: "Сбросить «\(f.fileName)»?",
                                 message: added ? "Файл добавлен в индекс и будет удалён из индекса и с диска." : "Изменения в индексе и в рабочей папке будут безвозвратно потеряны.",
                                 confirmLabel: "Сбросить") { [weak self] in
            Task { await self?.discardCompletely(f) }
        }
    }

    func discardCompletely(_ f: FileEntry) async {
        guard hasCommits else { await run("Сброс файла", ["rm", "-f", "--", f.path]); return }
        switch f.x {
        case "A":
            await run("Сброс файла", ["rm", "-f", "--", f.path])
        case "R", "C":
            if await run("Сброс файла", ["rm", "-f", "--", f.path]), f.x == "R", let o = f.origPath {
                await run("Сброс файла", ["restore", "--source=HEAD", "--staged", "--worktree", "--", o])
            }
        default:
            await run("Сброс файла", ["restore", "--source=HEAD", "--staged", "--worktree", "--", f.path])
        }
    }

    /// Сброс всех изменений: reset --hard, опционально clean -fd для новых файлов.
    func askDiscardAll(includeUntracked: Bool) {
        confirm = ConfirmRequest(title: "Отменить все изменения?",
                                 message: "Будут безвозвратно потеряны все изменения в отслеживаемых файлах (включая индекс)"
                                    + (includeUntracked ? " и удалены все новые неотслеживаемые файлы и папки." : ". Новые файлы останутся."),
                                 confirmLabel: "Отменить все") { [weak self] in
            Task { await self?.discardAll(includeUntracked: includeUntracked) }
        }
    }

    func discardAll(includeUntracked: Bool) async {
        busyCount += 1
        busyTitle = "Отмена всех изменений"
        defer { busyCount -= 1 }
        var results: [CmdResult] = []
        if hasCommits { results.append(await git(["reset", "--hard"])) }
        else { results.append(await git(["rm", "-r", "-f", "--cached", "--ignore-unmatch", "--", "."])) }
        if includeUntracked, results.allSatisfy(\.ok) { results.append(await git(["clean", "-f", "-d"])) }
        if let bad = results.first(where: { !$0.ok }) {
            show("Отмена всех изменений: ошибка", bad.combined, error: true)
        } else {
            show("Изменения отменены", includeUntracked ? "Рабочая папка приведена к HEAD" : "Новые файлы сохранены", error: false)
        }
        await refreshAll()
    }

    // MARK: stash files / gitignore

    func promptStashFiles(_ files: [FileEntry]) {
        let title = files.count == 1 ? "Stash: \(files[0].fileName)" : "Stash: файлов \(files.count)"
        prompt = PromptRequest(title: title, fields: [PromptField(label: "Сообщение (необязательно)")],
                               confirmLabel: "Stash") { [weak self] v, _ in
            var args = ["stash", "push"]
            if files.contains(where: \.untracked) { args.append("--include-untracked") }
            if let m = v.first?.trimmed, !m.isEmpty { args += ["-m", m] }
            args.append("--")
            args += files.map(\.path)
            Task { await self?.run("Stash", args) }
        }
    }

    private static func gitignoreEscaped(_ s: String) -> String {
        var out = ""
        for (i, ch) in s.enumerated() {
            if "\\*?[]".contains(ch) || (i == 0 && (ch == "#" || ch == "!")) { out.append("\\") }
            out.append(ch)
        }
        if out.hasSuffix(" ") { out.removeLast(); out += "\\ " }
        return out
    }

    /// Добавляет файл в .gitignore; для уже отслеживаемого файла предлагает ещё и убрать его из индекса.
    func askIgnore(_ f: FileEntry) {
        let pattern = "/" + Self.gitignoreEscaped(f.path)
        if f.untracked {
            Task { await addToGitignore(pattern) }
        } else {
            confirm = ConfirmRequest(title: "Добавить «\(f.fileName)» в .gitignore?",
                                     message: "Файл уже отслеживается git. Чтобы игнорирование сработало, он будет убран из индекса (git rm --cached), на диске останется.",
                                     confirmLabel: "Игнорировать", destructive: false) { [weak self] in
                Task {
                    guard let self else { return }
                    if await self.run("Убрать из индекса", ["rm", "--cached", "-r", "--", f.path]) {
                        await self.addToGitignore(pattern)
                    }
                }
            }
        }
    }

    func askIgnoreExtension(_ f: FileEntry) {
        let ext = (f.path as NSString).pathExtension
        guard !ext.isEmpty else { return }
        Task { await addToGitignore("*." + Self.gitignoreEscaped(ext)) }
    }

    func addToGitignore(_ pattern: String) async {
        let file = path + "/.gitignore"
        let existing = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        if existing.components(separatedBy: "\n").contains(where: { $0.trimmed == pattern }) {
            show(".gitignore", "«\(pattern)» уже есть в .gitignore", error: false)
            return
        }
        let sep = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        do {
            try (existing + sep + pattern + "\n").write(toFile: file, atomically: true, encoding: .utf8)
            show(".gitignore", "Добавлено: \(pattern)", error: false)
        } catch {
            show(".gitignore: ошибка", error.localizedDescription, error: true)
        }
        await refreshAll()
    }

    func resolve(_ f: FileEntry, side: String?) async {
        if let side { await run("Конфликт", ["checkout", "--\(side)", "--", f.path]) }
        await run("Конфликт", ["add", "--", f.path])
    }

    // MARK: commit

    func commit(thenPush: Bool) async {
        var args = ["commit"]
        let msg = commitMessage.trimmed
        if amend {
            args.append("--amend")
            if msg.isEmpty { args.append("--no-edit") }
        }
        if !msg.isEmpty { args += ["-m", msg] }
        if skipHooks { args.append("--no-verify") }
        let ok = await run(amend ? "Amend" : "Commit", args, showOutput: true)
        if ok {
            commitMessage = ""
            amend = false
            if thenPush { await push() }
        }
    }

    func setAmend(_ on: Bool) async {
        amend = on
        if on, commitMessage.trimmed.isEmpty {
            let r = await git(["log", "-1", "--format=%B"], log: false)
            if r.ok { commitMessage = r.out.trimmed }
        }
    }

    // MARK: remote ops

    func fetch() async { await run("Fetch", ["fetch", "--all", "--prune"], showOutput: true) }

    func promptFetchBranch() {
        prompt = PromptRequest(title: "Выкачать ветку", message: "Fetch и переключение на ветку по имени",
                               fields: [PromptField(label: "Имя ветки")],
                               confirmLabel: "Выкачать") { [weak self] v, _ in
            guard let name = v.first?.trimmed, !name.isEmpty else { return }
            Task { await self?.fetchBranch(name) }
        }
    }

    /// Fetch всех remote, затем переключение на локальную ветку (с ff-pull) или создание отслеживающей из remote.
    func fetchBranch(_ name: String) async {
        let title = "Выкачать ветку \(name)"
        busyCount += 1
        busyTitle = title
        defer { busyCount -= 1 }
        let f = await git(["fetch", "--all", "--prune"])
        guard f.ok else { show("\(title): ошибка", f.combined, error: true); return }

        let r: CmdResult
        if (await git(["rev-parse", "--verify", "--quiet", "refs/heads/" + name])).ok {
            let sw = await git(["switch", name])
            if sw.ok, (await git(["rev-parse", "--abbrev-ref", "@{u}"])).ok {
                let pull = await git(["pull", "--ff-only"])
                r = pull.ok ? sw : pull
            } else { r = sw }
        } else {
            guard let remote = await Shell.remoteTrackingRef(name, cwd: path) else {
                show("\(title): ошибка", "Ветка «\(name)» не найдена ни локально, ни на удалённых репозиториях", error: true)
                await refreshAll()
                return
            }
            r = await Shell.switchTracking(remote, name: name) { [self] in await git($0) }
        }
        show(r.ok ? title : "\(title): ошибка", r.combined.isEmpty ? "Готово" : r.combined, error: !r.ok)
        await refreshAll()
    }

    func pull(_ mode: PullMode) async {
        let flag = switch mode { case .merge: "--no-rebase"; case .rebase: "--rebase"; case .ffOnly: "--ff-only" }
        await run("Pull", ["pull", flag], showOutput: true)
    }

    func push(force: Bool = false) async {
        var args = ["push"]
        if upstream == nil && !detached { args += ["-u", defaultRemote, "HEAD"] }
        if force { args.append("--force-with-lease") }
        await run("Push", args, showOutput: true)
    }

    func askForcePush() {
        confirm = ConfirmRequest(title: "Force push?",
                                 message: "Будет выполнен push --force-with-lease: удалённая история ветки может быть перезаписана.",
                                 confirmLabel: "Force push") { [weak self] in
            Task { await self?.push(force: true) }
        }
    }

    // MARK: operation in progress

    func continueOperation() async {
        switch state {
        case .merging: await run("Завершить merge", ["commit", "--no-edit"])
        case .rebasing: await run("Rebase", ["rebase", "--continue"])
        case .cherryPicking: await run("Cherry-pick", ["cherry-pick", "--continue"])
        case .reverting: await run("Revert", ["revert", "--continue"])
        case .none: break
        }
    }

    func abortOperation() async {
        switch state {
        case .merging: await run("Отмена merge", ["merge", "--abort"])
        case .rebasing: await run("Отмена rebase", ["rebase", "--abort"])
        case .cherryPicking: await run("Отмена cherry-pick", ["cherry-pick", "--abort"])
        case .reverting: await run("Отмена revert", ["revert", "--abort"])
        case .none: break
        }
    }

    // MARK: branches

    func checkout(_ b: Branch) async {
        if b.isRemote { await run("Checkout", ["switch", "--track", b.name]) }
        else { await run("Checkout", ["switch", b.name]) }
    }

    func checkoutRef(_ ref: String) async { await run("Checkout", ["switch", "--detach", ref]) }

    func promptNewBranch(from ref: String?) {
        prompt = PromptRequest(title: "Новая ветка",
                               message: ref.map { "От: \($0)" } ?? "От текущего коммита",
                               fields: [PromptField(label: "Название ветки")],
                               toggleTitle: "Переключиться на неё", toggleValue: true, confirmLabel: "Создать") { [weak self] v, sw in
            guard let name = v.first?.trimmed, !name.isEmpty else { return }
            Task { await self?.createBranch(name, from: ref, checkout: sw) }
        }
    }

    func createBranch(_ name: String, from ref: String?, checkout: Bool) async {
        var args = checkout ? ["switch", "-c", name] : ["branch", name]
        if let ref { args.append(ref) }
        await run("Новая ветка", args)
    }

    func askDelete(_ b: Branch) {
        confirm = ConfirmRequest(title: "Удалить ветку «\(b.name)»?",
                                 message: b.isRemote ? "Ветка будет удалена на сервере (push --delete)." : "Если ветка не слита, git откажет — тогда можно повторить с принудительным удалением.",
                                 confirmLabel: "Удалить") { [weak self] in
            Task { await self?.delete(b) }
        }
    }

    func delete(_ b: Branch) async {
        if b.isRemote {
            let parts = b.name.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 { await run("Удаление ветки", ["push", parts[0], "--delete", parts[1]], showOutput: true) }
        } else {
            let ok = await run("Удаление ветки", ["branch", "-d", b.name])
            if !ok {
                confirm = ConfirmRequest(title: "Удалить принудительно?",
                                         message: "Ветка «\(b.name)» не слита. Принудительное удаление (-D) потеряет её коммиты.",
                                         confirmLabel: "Удалить -D") { [weak self] in
                    Task { await self?.run("Удаление ветки", ["branch", "-D", b.name]) }
                }
            }
        }
    }

    func promptRename(_ b: Branch) {
        prompt = PromptRequest(title: "Переименовать ветку", fields: [PromptField(label: "Новое имя", value: b.name)],
                               confirmLabel: "Переименовать") { [weak self] v, _ in
            guard let n = v.first?.trimmed, !n.isEmpty else { return }
            Task { await self?.run("Переименование", ["branch", "-m", b.name, n]) }
        }
    }

    func merge(_ b: Branch) async { await run("Merge", ["merge", "--no-edit", b.name], showOutput: true) }
    func rebase(onto b: Branch) async { await run("Rebase", ["rebase", b.name], showOutput: true) }

    // MARK: history actions

    func selectCommit(_ id: String?) async {
        selectedCommitID = id
        guard let id else { commitBody = ""; commitPatch = ""; return }
        async let m = git(["show", "-s", "--format=%B", id], log: false)
        async let p = git(["show", "--format=", "--no-color", "-M", "-m", "--first-parent", "--stat", "--patch", id], log: false)
        let (mr, pr) = await (m, p)
        guard selectedCommitID == id else { return }
        commitBody = mr.out.trimmed
        commitPatch = truncateLines(pr.out)
    }

    func cherryPick(_ c: Commit) async { await run("Cherry-pick", ["cherry-pick", c.hash], showOutput: true) }
    func revert(_ c: Commit) async { await run("Revert", ["revert", "--no-edit", c.hash], showOutput: true) }

    func askReset(_ c: Commit, mode: String) {
        let hard = mode == "hard"
        confirm = ConfirmRequest(title: "Reset --\(mode) на \(c.short)?",
                                 message: hard ? "Все незафиксированные изменения и коммиты после этой точки будут потеряны." : "Указатель ветки переместится на выбранный коммит.",
                                 confirmLabel: "Reset --\(mode)", destructive: hard) { [weak self] in
            Task { await self?.run("Reset", ["reset", "--\(mode)", c.hash]) }
        }
    }

    func promptTag(at ref: String?) {
        prompt = PromptRequest(title: "Новый тег", message: ref.map { "На: \($0)" } ?? "На текущем коммите",
                               fields: [PromptField(label: "Имя тега"), PromptField(label: "Сообщение (необязательно, создаст annotated-тег)")],
                               confirmLabel: "Создать") { [weak self] v, _ in
            guard let n = v.first?.trimmed, !n.isEmpty else { return }
            let msg = v.count > 1 ? v[1].trimmed : ""
            var args = ["tag"]
            if !msg.isEmpty { args += ["-a", n, "-m", msg] } else { args.append(n) }
            if let ref { args.append(ref) }
            Task { await self?.run("Новый тег", args) }
        }
    }

    // MARK: stash

    func promptStash() {
        prompt = PromptRequest(title: "Спрятать изменения (stash)", fields: [PromptField(label: "Сообщение (необязательно)")],
                               toggleTitle: "Включая неотслеживаемые файлы", toggleValue: true, confirmLabel: "Stash") { [weak self] v, sw in
            var args = ["stash", "push"]
            if sw { args.append("--include-untracked") }
            if let m = v.first?.trimmed, !m.isEmpty { args += ["-m", m] }
            Task { await self?.run("Stash", args) }
        }
    }

    func selectStash(_ ref: String?) async {
        selectedStash = ref
        guard let ref else { stashPatch = ""; return }
        let r = await git(["stash", "show", "-p", "--no-color", "--stat", ref], log: false)
        guard selectedStash == ref else { return }
        stashPatch = truncateLines(r.out)
    }

    // MARK: tags / remotes

    func askDeleteTag(_ t: TagItem) {
        confirm = ConfirmRequest(title: "Удалить тег «\(t.name)»?", message: "Локальный тег будет удалён.", confirmLabel: "Удалить") { [weak self] in
            Task { await self?.run("Удаление тега", ["tag", "-d", t.name]) }
        }
    }

    func promptAddRemote() {
        prompt = PromptRequest(title: "Добавить remote", fields: [PromptField(label: "Имя", value: "origin"), PromptField(label: "URL")],
                               confirmLabel: "Добавить") { [weak self] v, _ in
            guard v.count == 2, !v[0].trimmed.isEmpty, !v[1].trimmed.isEmpty else { return }
            Task { await self?.run("Добавить remote", ["remote", "add", v[0].trimmed, v[1].trimmed]) }
        }
    }

    func promptSetURL(_ r: RemoteItem) {
        prompt = PromptRequest(title: "URL remote «\(r.name)»", fields: [PromptField(label: "URL", value: r.url)],
                               confirmLabel: "Сохранить") { [weak self] v, _ in
            guard let u = v.first?.trimmed, !u.isEmpty else { return }
            Task { await self?.run("Изменить URL", ["remote", "set-url", r.name, u]) }
        }
    }

    func askRemoveRemote(_ r: RemoteItem) {
        confirm = ConfirmRequest(title: "Удалить remote «\(r.name)»?", message: r.url, confirmLabel: "Удалить") { [weak self] in
            Task { await self?.run("Удалить remote", ["remote", "remove", r.name]) }
        }
    }

    // MARK: hooks

    func refreshHooks() async {
        var info = HooksInfo()
        let cfg = await git(["config", "--get", "core.hooksPath"], log: false)
        if cfg.ok, !cfg.out.trimmed.isEmpty { info.hooksPathConfig = cfg.out.trimmed }
        if gitDir == nil {
            let r = await git(["rev-parse", "--absolute-git-dir"], log: false)
            if r.ok { gitDir = r.out.trimmed }
        }
        let fm = FileManager.default
        info.hasPackageJson = fm.fileExists(atPath: path + "/package.json")
        let hp = path + "/node_modules/husky/package.json"
        if let d = fm.contents(atPath: hp), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            info.huskyInstalled = true
            info.huskyVersion = j["version"] as? String
        }
        var isDir: ObjCBool = false
        info.huskyDirExists = fm.fileExists(atPath: path + "/.husky", isDirectory: &isDir) && isDir.boolValue

        func list(_ dir: String, skipSamples: Bool) -> [HookFile] {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
            return names.sorted().compactMap { n in
                if n.hasPrefix("_") || n.hasPrefix(".") || n.hasSuffix(".sample") && skipSamples { return nil }
                var d: ObjCBool = false
                let p = dir + "/" + n
                guard fm.fileExists(atPath: p, isDirectory: &d), !d.boolValue else { return nil }
                return HookFile(name: n, path: p, executable: fm.isExecutableFile(atPath: p))
            }
        }
        var groups: [HookGroup] = []
        let huskyDir = path + "/.husky"
        if info.huskyDirExists {
            groups.append(HookGroup(title: "Husky (.husky/)", dir: huskyDir, isHusky: true, files: list(huskyDir, skipSamples: true).filter { $0.name != "husky.sh" }))
        }
        if let c = info.hooksPathConfig {
            let abs = c.hasPrefix("/") ? c : path + "/" + c
            let norm = URL(fileURLWithPath: abs).resolvingSymlinksInPath().path
            let huskyReal = URL(fileURLWithPath: huskyDir).resolvingSymlinksInPath().path
            if !c.hasPrefix(".husky"), !norm.hasPrefix(huskyReal) {
                groups.append(HookGroup(title: "core.hooksPath (\(c))", dir: norm, isHusky: false, files: list(norm, skipSamples: true)))
            }
        }
        if let g = gitDir {
            groups.append(HookGroup(title: "Git (.git/hooks)", dir: g + "/hooks", isHusky: false, files: list(g + "/hooks", skipSamples: true)))
        }
        info.groups = groups
        hooks = info
    }

    func createHook(_ name: String, in group: HookGroup) async {
        let p = group.dir + "/" + name
        let fm = FileManager.default
        try? fm.createDirectory(atPath: group.dir, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: p) else { show("Хук уже существует", name, error: true); return }
        let body = group.isHusky ? "# Команды запускаются при хуке \(name)\n" : "#!/bin/sh\n\n"
        do {
            try body.write(toFile: p, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p)
        } catch { show("Не удалось создать хук", error.localizedDescription, error: true) }
        await refreshHooks()
    }

    func setExecutable(_ f: HookFile, _ on: Bool) async {
        try? FileManager.default.setAttributes([.posixPermissions: on ? 0o755 : 0o644], ofItemAtPath: f.path)
        await refreshHooks()
    }

    func deleteHook(_ f: HookFile) async {
        try? FileManager.default.removeItem(atPath: f.path)
        await refreshHooks()
    }

    func askDeleteHook(_ f: HookFile) {
        confirm = ConfirmRequest(title: "Удалить хук «\(f.name)»?", message: f.path, confirmLabel: "Удалить") { [weak self] in
            Task { await self?.deleteHook(f) }
        }
    }

    func runHook(_ f: HookFile) async {
        busyCount += 1
        busyTitle = "Хук \(f.name)"
        var args = ["-e", f.path]
        if f.name == "commit-msg", let g = gitDir { args.append(g + "/COMMIT_EDITMSG") }
        let r = await Shell.run("/bin/sh", args, cwd: path, env: ["HUSKY": "1"])
        addLog("sh -e \(f.path)", r)
        busyCount -= 1
        show(r.ok ? "Хук \(f.name): успешно" : "Хук \(f.name): код \(r.code)",
             r.combined.isEmpty ? "(нет вывода)" : r.combined, error: !r.ok)
    }

    func askInitHusky() {
        confirm = ConfirmRequest(title: "Инициализировать Husky?",
                                 message: "Будет выполнено: \(hooks.hasPackageJson ? "" : "npm init -y && ")npm install --save-dev husky && npx husky init",
                                 confirmLabel: "Выполнить", destructive: false) { [weak self] in
            guard let self else { return }
            let pre = self.hooks.hasPackageJson ? "" : "npm init -y && "
            Task { await self.runShell("Husky init", pre + "npm install --save-dev husky && npx husky init") }
        }
    }

    func activateHusky() async {
        if !hooks.huskyInstalled { await runShell("npm install", "npm install"); return }
        let cmd = hooks.huskyMajor >= 9 ? "npx --no-install husky" : "npx --no-install husky install"
        await runShell("Активация Husky", cmd)
    }

    func promptHooksPath() {
        prompt = PromptRequest(title: "core.hooksPath", message: "Путь к папке с хуками (относительно репозитория или абсолютный)",
                               fields: [PromptField(label: "Путь", value: hooks.hooksPathConfig ?? "")],
                               confirmLabel: "Сохранить") { [weak self] v, _ in
            guard let p = v.first?.trimmed, !p.isEmpty else { return }
            Task { await self?.run("core.hooksPath", ["config", "core.hooksPath", p]) }
        }
    }

    func resetHooksPath() async { await run("core.hooksPath", ["config", "--unset", "core.hooksPath"]) }

    // MARK: console

    func runConsole(_ line: String) async {
        let t = line.trimmed
        guard !t.isEmpty else { return }
        let cmd: String
        if t.hasPrefix("!") { cmd = String(t.dropFirst()) }
        else if t == "git" || t.hasPrefix("git ") { cmd = t }
        else { cmd = "git " + t }
        busyCount += 1
        busyTitle = "Консоль"
        let r = await Shell.run("/bin/zsh", ["-c", cmd], cwd: path, env: huskyEnv)
        addLog(t, r)
        busyCount -= 1
        await refreshAll()
    }

    // MARK: system

    func revealInFinder(_ rel: String? = nil) {
        let p = rel.map { path + "/" + $0 } ?? path
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    func openTerminal() {
        let app = UserDefaults.standard.string(forKey: "terminalApp") ?? "Terminal"
        Task { _ = await Shell.run("/usr/bin/open", ["-a", app.isEmpty ? "Terminal" : app, path]) }
    }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
