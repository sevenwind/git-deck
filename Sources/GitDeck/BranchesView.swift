import SwiftUI

struct BranchesView: View {
    @ObservedObject var model: RepoModel
    @Local private var filter = ""

    private func match(_ b: Branch) -> Bool { filter.trimmed.isEmpty || b.name.localizedCaseInsensitiveContains(filter.trimmed) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Фильтр веток", text: $filter).textFieldStyle(.plain)
                Spacer()
                Button { model.promptNewBranch(from: nil) } label: { Label("Новая ветка", systemImage: "plus") }
            }
            .padding(8)
            Divider()
            List {
                Section("Локальные") {
                    ForEach(model.branches.filter { !$0.isRemote && match($0) }) { b in BranchRow(model: model, branch: b) }
                }
                Section("Удалённые") {
                    ForEach(model.branches.filter { $0.isRemote && match($0) }) { b in BranchRow(model: model, branch: b) }
                }
            }
            .listStyle(.inset)
        }
    }
}

struct BranchRow: View {
    @ObservedObject var model: RepoModel
    let branch: Branch

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : (branch.isRemote ? "cloud" : "arrow.triangle.branch"))
                .foregroundStyle(branch.isCurrent ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(branch.name).fontWeight(branch.isCurrent ? .bold : .regular)
                    if !branch.upstream.isEmpty {
                        Text(branch.upstream + (branch.track.isEmpty ? "" : " " + branch.track)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("\(branch.hash) · \(branch.subject)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(branch.date).font(.caption).foregroundStyle(.secondary)
            if !branch.isCurrent {
                Button("Checkout") { Task { await model.checkout(branch) } }.controlSize(.small)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if !branch.isCurrent {
                Button("Checkout") { Task { await model.checkout(branch) } }
                Button("Влить «\(branch.name)» в текущую (merge)") { Task { await model.merge(branch) } }
                Button("Rebase текущей на «\(branch.name)»") { Task { await model.rebase(onto: branch) } }
                Divider()
            }
            Button("Создать ветку отсюда…") { model.promptNewBranch(from: branch.name) }
            if !branch.isRemote { Button("Переименовать…") { model.promptRename(branch) } }
            Button("Копировать имя") { copyToPasteboard(branch.name) }
            if !branch.isCurrent {
                Divider()
                Button("Удалить…", role: .destructive) { model.askDelete(branch) }
            }
        }
    }
}

struct StashView: View {
    @ObservedObject var model: RepoModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Button { model.promptStash() } label: { Label("Спрятать изменения", systemImage: "tray.and.arrow.down") }
                    Spacer()
                }
                .padding(8)
                Divider()
                List(selection: Binding(get: { model.selectedStash }, set: { r in Task { await model.selectStash(r) } })) {
                    ForEach(model.stashes) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.message).lineLimit(2)
                            Text("\(s.ref) · \(s.date)").font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(s.ref)
                        .contextMenu {
                            Button("Apply") { Task { await model.run("Stash apply", ["stash", "apply", s.ref]) } }
                            Button("Pop") { Task { await model.run("Stash pop", ["stash", "pop", s.ref]) } }
                            Button("Создать ветку…") {
                                model.prompt = PromptRequest(title: "Ветка из stash", fields: [PromptField(label: "Название")], confirmLabel: "Создать") { v, _ in
                                    guard let n = v.first?.trimmed, !n.isEmpty else { return }
                                    Task { await model.run("Stash branch", ["stash", "branch", n, s.ref]) }
                                }
                            }
                            Divider()
                            Button("Drop…", role: .destructive) {
                                model.confirm = ConfirmRequest(title: "Удалить \(s.ref)?", message: s.message, confirmLabel: "Drop") {
                                    Task { await model.run("Stash drop", ["stash", "drop", s.ref]) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .overlay { if model.stashes.isEmpty { Text("Stash пуст").foregroundStyle(.secondary) } }
                if let r = model.selectedStash {
                    Divider()
                    HStack {
                        Button("Apply") { Task { await model.run("Stash apply", ["stash", "apply", r]) } }
                        Button("Pop") { Task { await model.run("Stash pop", ["stash", "pop", r]) } }
                        Button("Drop", role: .destructive) {
                            model.confirm = ConfirmRequest(title: "Удалить \(r)?", message: "Stash будет удалён.", confirmLabel: "Drop") {
                                Task { await model.run("Stash drop", ["stash", "drop", r]) }
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .frame(minWidth: 300, idealWidth: 380, maxWidth: 520)
            if model.selectedStash != nil { DiffTextView(text: model.stashPatch) }
            else { Text("Выберите stash").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
}

struct TagsRemotesView: View {
    @ObservedObject var model: RepoModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Теги").font(.headline)
                    Spacer()
                    Button { model.promptTag(at: nil) } label: { Label("Новый тег", systemImage: "plus") }
                }
                .padding(8)
                Divider()
                List {
                    ForEach(model.tags) { t in
                        HStack {
                            Image(systemName: "tag").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.name)
                                Text("\(t.hash) · \(t.subject)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(t.date).font(.caption).foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Push тега") { Task { await model.run("Push тега", ["push", model.defaultRemote, t.name], showOutput: true) } }
                            Button("Checkout") { Task { await model.checkoutRef(t.name) } }
                            Button("Копировать имя") { copyToPasteboard(t.name) }
                            Divider()
                            Button("Удалить…", role: .destructive) { model.askDeleteTag(t) }
                        }
                    }
                }
                .listStyle(.inset)
                .overlay { if model.tags.isEmpty { Text("Тегов нет").foregroundStyle(.secondary) } }
            }
            .frame(minWidth: 300)
            VStack(spacing: 0) {
                HStack {
                    Text("Remotes").font(.headline)
                    Spacer()
                    Button { model.promptAddRemote() } label: { Label("Добавить", systemImage: "plus") }
                }
                .padding(8)
                Divider()
                List {
                    ForEach(model.remotes) { r in
                        HStack {
                            Image(systemName: "cloud").foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name).bold()
                                Text(r.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        .contextMenu {
                            Button("Fetch") { Task { await model.run("Fetch \(r.name)", ["fetch", r.name, "--prune"], showOutput: true) } }
                            Button("Изменить URL…") { model.promptSetURL(r) }
                            Button("Копировать URL") { copyToPasteboard(r.url) }
                            Divider()
                            Button("Удалить…", role: .destructive) { model.askRemoveRemote(r) }
                        }
                    }
                }
                .listStyle(.inset)
                .overlay { if model.remotes.isEmpty { Text("Remote не настроен").foregroundStyle(.secondary) } }
            }
            .frame(minWidth: 300)
        }
    }
}
