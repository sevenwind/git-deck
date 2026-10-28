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
    var body: some View {
        let (bg, fg) = diffColors(line)
        Text(line.isEmpty ? " " : line)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .background(bg ?? .clear)
    }
}

/// Простой просмотр произвольного diff/текста.
struct DiffTextView: View {
    let text: String
    var body: some View {
        let lines = text.components(separatedBy: "\n")
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in DiffLineView(line: l) }
            }
            .padding(.vertical, 6)
            .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay { if text.trimmed.isEmpty { Text("Нет изменений").foregroundStyle(.secondary) } }
    }
}

/// Diff с кнопками по блокам (hunk).
struct HunkDiffView: View {
    let diff: ParsedDiff
    let staged: Bool
    let untracked: Bool
    @ObservedObject var model: RepoModel

    var body: some View {
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
                                    model.confirm = ConfirmRequest(title: "Отменить этот блок?", message: "Изменения в блоке будут потеряны.",
                                                                   confirmLabel: "Отменить блок") {
                                        Task { await model.applyHunk(h, mode: .discard) }
                                    }
                                }
                            }
                        }
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.blue.opacity(0.10))
                    ForEach(Array(h.lines.enumerated()), id: \.offset) { _, l in DiffLineView(line: l) }
                }
            }
            .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
