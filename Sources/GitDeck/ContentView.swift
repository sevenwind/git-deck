import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
        } detail: {
            if let m = store.current {
                RepoView(model: m).id(m.path)
            } else {
                EmptyDetail()
            }
        }
        .sheet(isPresented: $store.showClone) { CloneSheet().environmentObject(store) }
        .sheet(item: $store.prompt) { p in PromptSheet(request: p) }
        .safeAreaInset(edge: .bottom) {
            if let b = store.banner {
                BannerView(banner: b) { store.banner = nil }
                    .padding(10)
            }
        }
    }
}

struct EmptyDetail: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 54)).foregroundStyle(.secondary)
            if store.workspaces.isEmpty && store.extraRepos.isEmpty {
                Text("Добавьте рабочую область").font(.title2.bold())
                Text("Рабочая область — папка, внутри которой приложение найдёт все git-репозитории.\nПотом их можно искать по части названия.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Добавить рабочую область…") { store.addWorkspace() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Text("Выберите репозиторий").font(.title2.bold())
                Text("\(store.totalMatches) репозиториев найдено").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        List(selection: $store.selected) {
            ForEach(store.workspaces, id: \.self) { ws in
                let repos = store.repos(in: ws)
                if !repos.isEmpty || store.query.trimmed.isEmpty {
                    Section {
                        ForEach(repos) { r in RepoRow(repo: r).tag(r.path) }
                        if repos.isEmpty {
                            Text("Репозитории не найдены").font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        HStack {
                            Label((ws as NSString).lastPathComponent, systemImage: "folder.badge.gearshape")
                            Spacer()
                            if store.updatingWorkspaces.contains(ws) { ProgressView().controlSize(.mini) }
                            Text("\(repos.count)").foregroundStyle(.secondary)
                        }
                        .help(ws)
                        .contextMenu {
                            Button("Обновить все репозитории") { store.updateAll(in: ws) }
                                .disabled(store.updatingWorkspaces.contains(ws))
                            Divider()
                            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ws)]) }
                            Button("Убрать рабочую область", role: .destructive) { store.removeWorkspace(ws) }
                        }
                    }
                }
            }
            let extra = store.standalone
            if !extra.isEmpty {
                Section("Отдельные репозитории") {
                    ForEach(extra) { r in
                        RepoRow(repo: r).tag(r.path)
                            .contextMenu { Button("Убрать из списка") { store.removeExtra(r.path) } }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $store.query, placement: .sidebar, prompt: "Поиск репозитория по названию")
        .overlay {
            if store.workspaces.isEmpty && store.extraRepos.isEmpty {
                Text("Нет рабочих областей").foregroundStyle(.secondary)
            } else if !store.query.trimmed.isEmpty && store.totalMatches == 0 {
                Text("Ничего не найдено").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Добавить рабочую область…", systemImage: "folder.badge.plus") { store.addWorkspace() }
                    Button("Открыть репозиторий…", systemImage: "folder") { store.openRepository() }
                    Button("Клонировать…", systemImage: "square.and.arrow.down") { store.showClone = true }
                    Button("Создать репозиторий (git init)…", systemImage: "plus.square") { store.initRepository() }
                } label: { Label("Добавить", systemImage: "plus") }
                Button { store.rescan() } label: {
                    if store.scanning { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .help("Пересканировать рабочие области")
            }
        }
    }
}

struct RepoRow: View {
    let repo: Repo
    @EnvironmentObject var store: AppStore
    @Local private var info: RowInfo?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(repo.name).lineLimit(1)
                if let i = info {
                    Text(i.branch).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let i = info, i.dirty > 0 {
                Text("\(i.dirty)").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.orange.opacity(0.25))).foregroundStyle(.orange)
                    .help("Изменённых файлов: \(i.dirty)")
            }
        }
        .help(repo.path)
        .task(id: store.rowRefresh) { info = await store.loadRowInfo(repo) }
        .contextMenu {
            Button("Выкачать ветку…") { store.promptFetchBranch(for: repo) }
            Divider()
            Button("Открыть в Terminal") { store.openTerminal(at: repo.path) }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)]) }
            Button("Копировать путь") { copyToPasteboard(repo.path) }
        }
    }
}

struct CloneSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Local private var url = ""
    @Local private var parent = ""
    @Local private var name = ""
    @Local private var nameEdited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Клонировать репозиторий").font(.title3.bold())
            TextField("URL (https://… или git@…)", text: $url)
                .textFieldStyle(.roundedBorder)
                .onChange(of: url) { if !nameEdited { name = guessName(url) } }
            HStack {
                Picker("В папку", selection: $parent) {
                    ForEach(store.workspaces, id: \.self) { Text(($0 as NSString).abbreviatingWithTildeInPath).tag($0) }
                    if !parent.isEmpty && !store.workspaces.contains(parent) { Text(parent).tag(parent) }
                }
                Button("Другая…") { if let p = store.pickFolder("Куда клонировать") { parent = p } }
            }
            TextField("Имя папки", text: $name, onEditingChanged: { _ in nameEdited = true })
                .textFieldStyle(.roundedBorder)
            HStack {
                if store.cloning { ProgressView().controlSize(.small); Text("Клонирование…").foregroundStyle(.secondary) }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Клонировать") {
                    Task { await store.clone(url: url.trimmed, parent: parent, name: name.trimmed) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.trimmed.isEmpty || parent.isEmpty || name.trimmed.isEmpty || store.cloning)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { if parent.isEmpty { parent = store.workspaces.first ?? "" } }
    }

    private func guessName(_ u: String) -> String {
        var s = u.trimmed
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
    }
}

struct BannerView: View {
    let banner: Banner
    let close: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: banner.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? .red : .green)
            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title).font(.headline)
                ScrollView {
                    Text(banner.text).font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            Spacer(minLength: 0)
            Button { copyToPasteboard(banner.text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Копировать")
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(banner.isError ? Color.red.opacity(0.5) : Color.secondary.opacity(0.3)))
        .shadow(radius: 6, y: 2)
    }
}
