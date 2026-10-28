import SwiftUI

struct ChangesView: View {
    @ObservedObject var model: RepoModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if !model.files.isEmpty { bulkBar; Divider() }
                fileList
                Divider()
                CommitBox(model: model)
            }
            .frame(minWidth: 290, idealWidth: 340, maxWidth: 520)
            diffPane.frame(minWidth: 320)
        }
        .onChange(of: model.selection) { Task { await model.loadDiff() } }
    }

    private var bulkBar: some View {
        HStack(spacing: 8) {
            Button { model.promptStash() } label: { Label("Stash", systemImage: "tray.and.arrow.down") }
                .help("Спрятать все изменения в stash")
            Button { Task { await model.run("Stash pop", ["stash", "pop"]) } } label: { Label("Pop", systemImage: "tray.and.arrow.up") }
                .disabled(model.stashes.isEmpty)
                .help("Вернуть последний stash (git stash pop)")
            Spacer()
            Menu {
                Button("Отменить все изменения (кроме новых файлов)…", role: .destructive) { model.askDiscardAll(includeUntracked: false) }
                Button("Отменить все, включая новые файлы…", role: .destructive) { model.askDiscardAll(includeUntracked: true) }
            } label: { Label("Отменить все", systemImage: "arrow.uturn.backward.circle") }
                .fixedSize()
                .help("Сбросить рабочую папку до HEAD")
        }
        .controlSize(.small)
        .disabled(model.busy)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var fileList: some View {
        List(selection: $model.selection) {
            if !model.conflicted.isEmpty {
                Section("Конфликты (\(model.conflicted.count))") {
                    ForEach(model.conflicted) { f in
                        FileRow(model: model, file: f, staged: false)
                            .tag(FileSelection(path: f.path, staged: false))
                    }
                }
            }
            Section {
                ForEach(model.staged) { f in
                    FileRow(model: model, file: f, staged: true).tag(FileSelection(path: f.path, staged: true))
                }
            } header: {
                HStack {
                    Text("В индексе (\(model.staged.count))")
                    Spacer()
                    if !model.staged.isEmpty { Button("Снять все") { Task { await model.unstageAll() } }.buttonStyle(.borderless) }
                }
            }
            Section {
                ForEach(model.unstaged) { f in
                    FileRow(model: model, file: f, staged: false).tag(FileSelection(path: f.path, staged: false))
                }
            } header: {
                HStack {
                    Text("Изменения (\(model.unstaged.count))")
                    Spacer()
                    if !model.unstaged.isEmpty { Button("Добавить все") { Task { await model.stageAll() } }.buttonStyle(.borderless) }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.files.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 36)).foregroundStyle(.green)
                    Text("Нет изменений").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var diffPane: some View {
        if let sel = model.selection, let d = model.diff, let f = model.files.first(where: { $0.path == sel.path }) {
            VStack(spacing: 0) {
                HStack {
                    Text(f.path).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(sel.staged ? "в индексе" : (f.untracked ? "новый файл" : "рабочая папка"))
                        .font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(.secondary.opacity(0.2)))
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
                HunkDiffView(diff: d, staged: sel.staged, untracked: f.untracked, model: model)
            }
        } else {
            Text("Выберите файл, чтобы увидеть изменения").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct StatusBadge: View {
    let letter: Character
    var color: Color {
        switch letter {
        case "M": .orange
        case "A": .green
        case "D": .red
        case "R", "C": .blue
        case "U": .red
        default: .gray
        }
    }
    var body: some View {
        Text(String(letter == "?" ? "U" : letter))
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.25)))
            .foregroundStyle(color)
    }
}

struct FileRow: View {
    @ObservedObject var model: RepoModel
    let file: FileEntry
    let staged: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusBadge(letter: file.conflicted ? "U" : (file.untracked ? "?" : (staged ? file.x : file.y)))
            VStack(alignment: .leading, spacing: 0) {
                Text(file.fileName).lineLimit(1)
                if !file.dirName.isEmpty {
                    Text(file.dirName).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            if file.conflicted {
                Button { Task { await model.resolve(file, side: nil) } } label: { Image(systemName: "checkmark.circle") }
                    .buttonStyle(.borderless).help("Отметить как решённый")
            } else if staged {
                Button { Task { await model.unstage([file.path]) } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Убрать из индекса")
            } else {
                Button { Task { await model.stage([file.path]) } } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless).help("Добавить в индекс")
            }
        }
        .contextMenu {
            if file.conflicted {
                Button("Взять нашу версию (ours)") { Task { await model.resolve(file, side: "ours") } }
                Button("Взять их версию (theirs)") { Task { await model.resolve(file, side: "theirs") } }
                Button("Отметить как решённый") { Task { await model.resolve(file, side: nil) } }
            } else if staged {
                Button("Убрать из индекса") { Task { await model.unstage([file.path]) } }
                Button("Сбросить файл полностью…", role: .destructive) { model.askDiscardCompletely(file) }
            } else {
                Button("Добавить в индекс") { Task { await model.stage([file.path]) } }
                Button(file.untracked ? "Удалить файл…" : "Отменить изменения…", role: .destructive) { model.askDiscard(file) }
            }
            if !file.conflicted {
                Divider()
                Button("Stash этого файла…") { model.promptStashFiles([file]) }
                Button("Добавить в .gitignore") { model.askIgnore(file) }
                if !(file.path as NSString).pathExtension.isEmpty {
                    Button("Добавить в .gitignore: *.\((file.path as NSString).pathExtension)") { model.askIgnoreExtension(file) }
                }
            }
            Divider()
            Button("Показать в Finder") { model.revealInFinder(file.path) }
            Button("Копировать путь") { copyToPasteboard(file.path) }
        }
    }
}

struct CommitBox: View {
    @ObservedObject var model: RepoModel

    private var canCommit: Bool {
        if model.amend { return true }
        return !model.staged.isEmpty && !model.commitMessage.trimmed.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.commitMessage)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                if model.commitMessage.isEmpty {
                    Text("Сообщение коммита").foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 6).allowsHitTesting(false)
                }
            }
            .frame(height: 84)

            HStack {
                Toggle("Amend", isOn: Binding(get: { model.amend }, set: { v in Task { await model.setAmend(v) } }))
                Toggle("Без хуков", isOn: $model.skipHooks).help("git commit --no-verify: не запускать pre-commit / commit-msg (в т.ч. Husky)")
            }
            .toggleStyle(.checkbox)

            HStack {
                Button {
                    Task { await model.commit(thenPush: false) }
                } label: { Text(model.amend ? "Amend" : "Commit (\(model.staged.count))").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canCommit || model.busy)
                Button {
                    Task { await model.commit(thenPush: true) }
                } label: { Text("Commit и Push") }
                    .disabled(!canCommit || model.busy)
            }
        }
        .padding(10)
    }
}
