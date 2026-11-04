import SwiftUI

private func diffColors(_ line: String) -> (Color?, Color) {
    if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff --git") || line.hasPrefix("index ")
        || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("similarity") || line.hasPrefix("rename ") {
        return (nil, .secondary)
    }
    if line.hasPrefix("@@") { return (Color.blue.opacity(0.12), .blue) }
    if line.hasPrefix("+") { return (Color.green.opacity(0.16), .primary) }
    if line.hasPrefix("-") { return (Color.red.opacity(0.16), .primary) }
    return (nil, .primary)
}

struct DiffLineView: View {
    let line: String
    var lang: SyntaxLang? = nil
    var theme: SyntaxTheme = .system

    private var content: Text {
        guard let lang, let first = line.first, first == "+" || first == "-" || first == " ",
              !line.hasPrefix("+++"), !line.hasPrefix("---") else { return Text(line.isEmpty ? " " : line) }
        var a = AttributedString(String(first))
        a += SyntaxHighlighter.highlight(String(line.dropFirst()), lang: lang, theme: theme)
        return Text(a)
    }

    var body: some View {
        let (bg, fg) = diffColors(line)
        content
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(fg == .primary ? (theme.foreground ?? .primary) : fg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .background(bg ?? .clear)
    }
}

/// Простой просмотр произвольного diff/текста.
struct DiffTextView: View {
    let text: String
    @AppStorage("syntaxTheme") private var themeID = SyntaxTheme.system.id

    /// Язык каждой строки патча — по последнему заголовку `diff --git a/… b/путь`.
    static func languages(for lines: [String]) -> [SyntaxLang?] {
        var cur: SyntaxLang?
        return lines.map { l in
            if l.hasPrefix("diff --git "), let r = l.range(of: " b/", options: .backwards) {
                cur = SyntaxLang.forExtension(String(l[r.upperBound...]))
            }
            return cur
        }
    }

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        let langs = Self.languages(for: lines)
        let theme = SyntaxTheme.byID(themeID)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, l in DiffLineView(line: l, lang: langs[i], theme: theme) }
            }
            .padding(.vertical, 6)
            .textSelection(.enabled)
        }
        .background(theme.background ?? Color(nsColor: .textBackgroundColor))
        .environment(\.colorScheme, theme.colorScheme ?? systemScheme)
        .overlay { if text.trimmed.isEmpty { Text("Нет изменений").foregroundStyle(.secondary) } }
    }
}

/// Diff с кнопками по блокам (hunk).
struct HunkDiffView: View {
    let diff: ParsedDiff
    let staged: Bool
    let untracked: Bool
    var path: String = ""
    @ObservedObject var model: RepoModel
    @AppStorage("syntaxTheme") private var themeID = SyntaxTheme.system.id

    var body: some View {
        let lang = SyntaxLang.forExtension(path)
        let theme = SyntaxTheme.byID(themeID)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if diff.isBinary {
                    Text("Бинарный файл").padding()
                }
                if diff.hunks.isEmpty && !diff.isBinary {
                    ForEach(Array(diff.header.enumerated()), id: \.offset) { _, l in DiffLineView(line: l) }
                }
                ForEach(diff.hunks) { h in
                    HStack {
                        Text(h.header).font(.system(size: 12, design: .monospaced)).foregroundStyle(.blue).lineLimit(1)
                        Spacer()
                        if !untracked {
                            if staged {
                                Button("Убрать блок из индекса") { Task { await model.applyHunk(h, mode: .unstage) } }
                            } else {
                                Button("Добавить блок") { Task { await model.applyHunk(h, mode: .stage) } }
                                Button("Отменить блок", role: .destructive) {
                                    model.confirm = ConfirmRequest(title: L("Отменить этот блок?"), message: L("Изменения в блоке будут потеряны."),
                                                                   confirmLabel: L("Отменить блок")) {
                                        Task { await model.applyHunk(h, mode: .discard) }
                                    }
                                }
                            }
                        }
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.blue.opacity(0.10))
                    ForEach(Array(h.lines.enumerated()), id: \.offset) { _, l in DiffLineView(line: l, lang: lang, theme: theme) }
                }
            }
            .textSelection(.enabled)
        }
        .background(theme.background ?? Color(nsColor: .textBackgroundColor))
        .environment(\.colorScheme, theme.colorScheme ?? systemScheme)
    }
}

/// Текущая системная тема оформления (для схем «Системная»).
private var systemScheme: ColorScheme {
    NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
}
