import SwiftUI

struct RefChip: View {
    let ref: String
    var body: some View {
        let isTag = ref.hasPrefix("tag: ")
        let isHead = ref.hasPrefix("HEAD")
        let color: Color = isHead ? .green : (isTag ? .orange : (ref.contains("/") ? .purple : .blue))
        Text(ref.replacingOccurrences(of: "tag: ", with: "").replacingOccurrences(of: "HEAD -> ", with: ""))
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.22)))
            .foregroundStyle(color)
    }
}

struct HistoryView: View {
    @ObservedObject var model: RepoModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Поиск по сообщению коммита", text: $model.historyQuery)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await model.refreshHistory() } }
                    Toggle("Все ветки", isOn: $model.historyAll).toggleStyle(.checkbox)
                        .onChange(of: model.historyAll) { Task { await model.refreshHistory() } }
                }
                .padding(8)
                Divider()
                List(selection: Binding(get: { model.selectedCommitID }, set: { id in Task { await model.selectCommit(id) } })) {
                    ForEach(model.commits) { c in
                        CommitRow(commit: c).tag(c.id)
                            .contextMenu { CommitMenu(model: model, commit: c) }
                    }
                    if model.canLoadMore {
                        Button("Загрузить ещё") { Task { await model.loadMoreHistory() } }.buttonStyle(.borderless)
                    }
                }
                .listStyle(.inset)
                .overlay { if model.commits.isEmpty { Text("Коммитов нет").foregroundStyle(.secondary) } }
            }
            .frame(minWidth: 340, idealWidth: 420, maxWidth: 600)

            if let id = model.selectedCommitID, let c = model.commits.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.subject).font(.title3.bold()).textSelection(.enabled)
                        let body = model.commitBody.components(separatedBy: "\n").dropFirst().joined(separator: "\n").trimmed
                        if !body.isEmpty { Text(body).textSelection(.enabled).foregroundStyle(.secondary) }
                        HStack(spacing: 8) {
                            Text("\(c.author) <\(c.email)>")
                            Text(c.date.formatted(date: .abbreviated, time: .shortened))
                            Button(c.short) { copyToPasteboard(c.hash) }.buttonStyle(.link).help("Копировать полный хеш")
                            if !c.parents.isEmpty { Text("родитель: " + c.parents.map { String($0.prefix(7)) }.joined(separator: ", ")).foregroundStyle(.secondary) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    Divider()
                    DiffTextView(text: model.commitPatch)
                }
            } else {
                Text("Выберите коммит").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct CommitRow: View {
    let commit: Commit
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(commit.subject).lineLimit(1)
                ForEach(commit.refs, id: \.self) { RefChip(ref: $0) }
            }
            HStack(spacing: 8) {
                Text(commit.short).font(.system(size: 11, design: .monospaced))
                Text(commit.author)
                Spacer()
                Text(commit.date, style: .relative)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct CommitMenu: View {
    @ObservedObject var model: RepoModel
    let commit: Commit
    var body: some View {
        Button("Копировать хеш") { copyToPasteboard(commit.hash) }
        Divider()
        Button("Переключиться на коммит (detached)") { Task { await model.checkoutRef(commit.hash) } }
        Button("Создать ветку отсюда…") { model.promptNewBranch(from: commit.hash) }
        Button("Создать тег…") { model.promptTag(at: commit.hash) }
        Divider()
        Button("Cherry-pick") { Task { await model.cherryPick(commit) } }
        Button("Revert") { Task { await model.revert(commit) } }
        Menu("Reset текущей ветки сюда") {
            Button("--soft") { model.askReset(commit, mode: "soft") }
            Button("--mixed") { model.askReset(commit, mode: "mixed") }
            Button("--hard…") { model.askReset(commit, mode: "hard") }
        }
    }
}
