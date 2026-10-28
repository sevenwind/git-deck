import Foundation
import SwiftUI

struct Repo: Identifiable, Hashable {
    let path: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct FileSelection: Hashable {
    var path: String
    var staged: Bool
}

struct FileEntry: Identifiable, Hashable {
    var path: String
    var origPath: String?
    var x: Character          // статус в индексе
    var y: Character          // статус в рабочей папке
    var untracked = false
    var conflicted = false
    var id: String { path }
    var isStaged: Bool { !untracked && !conflicted && x != "." && x != " " }
    var isUnstaged: Bool { !conflicted && (untracked || (y != "." && y != " ")) }
    var fileName: String { (path as NSString).lastPathComponent }
    var dirName: String {
        let d = (path as NSString).deletingLastPathComponent
        return d
    }
}

struct StatusSnapshot: Equatable {
    var branch = ""
    var upstream: String?
    var ahead = 0
    var behind = 0
    var hasCommits = true
    var files: [FileEntry] = []
}

/// Разбор `git status --porcelain=v2 --branch -z`
func parseStatus(_ s: String) -> StatusSnapshot {
    var snap = StatusSnapshot()
    let parts = s.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    var i = 0
    while i < parts.count {
        let rec = parts[i]
        i += 1
        if rec.hasPrefix("# ") {
            let f = rec.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
            guard f.count == 2 else { continue }
            switch f[0] {
            case "branch.oid": snap.hasCommits = f[1] != "(initial)"
            case "branch.head": snap.branch = f[1]
            case "branch.upstream": snap.upstream = f[1]
            case "branch.ab":
                let n = f[1].split(separator: " ")
                if n.count == 2 {
                    snap.ahead = Int(n[0].dropFirst()) ?? 0
                    snap.behind = Int(n[1].dropFirst()) ?? 0
                }
            default: break
            }
        } else if rec.hasPrefix("1 ") {
            let f = rec.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 9 else { continue }
            let xy = Array(f[1])
            snap.files.append(FileEntry(path: f[8], x: xy[0], y: xy[1]))
        } else if rec.hasPrefix("2 ") {
            let f = rec.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            let orig = i < parts.count ? parts[i] : nil
            i += 1
            guard f.count == 10 else { continue }
            let xy = Array(f[1])
            snap.files.append(FileEntry(path: f[9], origPath: orig, x: xy[0], y: xy[1]))
        } else if rec.hasPrefix("u ") {
            let f = rec.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 11 else { continue }
            let xy = Array(f[1])
            snap.files.append(FileEntry(path: f[10], x: xy[0], y: xy[1], conflicted: true))
        } else if rec.hasPrefix("? ") {
            snap.files.append(FileEntry(path: String(rec.dropFirst(2)), x: "?", y: "?", untracked: true))
        }
    }
    snap.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    return snap
}

struct Commit: Identifiable, Hashable {
    var hash: String
    var short: String
    var author: String
    var email: String
    var date: Date
    var refs: [String]
    var subject: String
    var parents: [String]
    var id: String { hash }
}

func parseCommits(_ s: String) -> [Commit] {
    s.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { rec in
        let f = rec.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
        guard f.count >= 8 else { return nil }
        return Commit(hash: f[0], short: f[1], author: f[2], email: f[3],
                      date: Date(timeIntervalSince1970: TimeInterval(Int(f[4]) ?? 0)),
                      refs: f[5].isEmpty ? [] : f[5].components(separatedBy: ", "),
                      subject: f[6],
                      parents: f[7].split(separator: " ").map(String.init))
    }
}

let commitFormat = "--pretty=format:%H%x1f%h%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1f%P%x1e"

struct Branch: Identifiable, Hashable {
    var name: String
    var isRemote: Bool
    var isCurrent: Bool
    var upstream: String
    var track: String
    var hash: String
    var subject: String
    var date: String
    var id: String { (isRemote ? "r:" : "l:") + name }
}

struct StashItem: Identifiable, Hashable {
    var ref: String
    var message: String
    var date: String
    var id: String { ref }
}

struct TagItem: Identifiable, Hashable {
    var name: String
    var hash: String
    var subject: String
    var date: String
    var id: String { name }
}

struct RemoteItem: Identifiable, Hashable {
    var name: String
    var url: String
    var id: String { name }
}

enum RepoState: Equatable {
    case none, merging, rebasing, cherryPicking, reverting
    var title: String {
        switch self {
        case .none: ""
        case .merging: "Идёт слияние (merge)"
        case .rebasing: "Идёт перебазирование (rebase)"
        case .cherryPicking: "Идёт cherry-pick"
        case .reverting: "Идёт revert"
        }
    }
}

// MARK: - Diff

struct DiffHunk: Identifiable {
    let id: Int
    var header: String
    var lines: [String]
}

struct ParsedDiff {
    var header: [String] = []
    var hunks: [DiffHunk] = []
    var raw = ""
    var isBinary: Bool { header.contains { $0.hasPrefix("Binary files") } }

    init(_ text: String) {
        raw = text
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var cur: DiffHunk?
        var n = 0
        for l in lines {
            if l.hasPrefix("@@") {
                if let c = cur { hunks.append(c) }
                cur = DiffHunk(id: n, header: l, lines: [])
                n += 1
            } else if cur != nil {
                cur!.lines.append(l)
            } else {
                header.append(l)
            }
        }
        if let c = cur { hunks.append(c) }
    }

    func patch(for hunk: DiffHunk) -> String {
        (header + [hunk.header] + hunk.lines).joined(separator: "\n") + "\n"
    }
}

func truncateLines(_ s: String, max: Int = 6000) -> String {
    var count = 0
    var idx = s.startIndex
    while idx < s.endIndex {
        guard let nl = s[idx...].firstIndex(of: "\n") else { return s }
        count += 1
        idx = s.index(after: nl)
        if count >= max {
            return String(s[..<idx]) + "\n… вывод обрезан (показаны первые \(max) строк)\n"
        }
    }
    return s
}

// MARK: - Hooks

struct HookFile: Identifiable, Hashable {
    var name: String
    var path: String
    var executable: Bool
    var id: String { path }
}

struct HookGroup: Identifiable {
    var title: String
    var dir: String
    var isHusky: Bool
    var files: [HookFile]
    var id: String { dir }
}

struct HooksInfo {
    var hooksPathConfig: String?
    var hasPackageJson = false
    var huskyInstalled = false
    var huskyVersion: String?
    var huskyDirExists = false
    var huskyActive: Bool { (hooksPathConfig ?? "").hasPrefix(".husky") }
    var groups: [HookGroup] = []
    var huskyMajor: Int { Int((huskyVersion ?? "").split(separator: ".").first ?? "") ?? 9 }
}

let standardHookNames = ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "pre-push",
                         "pre-rebase", "post-checkout", "post-merge", "post-rewrite", "pre-merge-commit",
                         "applypatch-msg", "pre-applypatch", "post-applypatch", "pre-auto-gc"]

// MARK: - UI requests

struct Banner: Identifiable {
    let id = UUID()
    var title: String
    var text: String
    var isError: Bool
}

struct PromptField: Identifiable {
    let id = UUID()
    var label: String
    var value: String = ""
}

struct PromptRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String = ""
    var fields: [PromptField]
    var toggleTitle: String? = nil
    var toggleValue = false
    var confirmLabel = "OK"
    var action: @MainActor ([String], Bool) -> Void
}

struct ConfirmRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmLabel: String
    var destructive = true
    var action: @MainActor () -> Void
}

struct ConsoleEntry: Identifiable {
    let id = UUID()
    var command: String
    var output: String
    var code: Int32
}

enum RepoTab: String, CaseIterable, Identifiable {
    case changes = "Изменения"
    case history = "История"
    case branches = "Ветки"
    case stash = "Stash"
    case tags = "Теги и remotes"
    case hooks = "Хуки"
    case console = "Консоль"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .changes: "square.and.pencil"
        case .history: "clock.arrow.circlepath"
        case .branches: "arrow.triangle.branch"
        case .stash: "tray.full"
        case .tags: "tag"
        case .hooks: "link"
        case .console: "terminal"
        }
    }
}
