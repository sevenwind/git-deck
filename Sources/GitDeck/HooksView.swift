import SwiftUI

struct HooksView: View {
    @ObservedObject var model: RepoModel
    @AppStorage("disableHusky") private var disableHusky = false
    @Local private var selectedPath: String?

    private var selectedFile: HookFile? {
        model.hooks.groups.flatMap(\.files).first { $0.path == selectedPath }
    }

    var body: some View {
        VStack(spacing: 0) {
            huskyCard
            Divider()
            HSplitView {
                hooksList.frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                if let f = selectedFile {
                    HookEditor(model: model, file: f).id(f.path)
                } else {
                    Text("Выберите хук, чтобы посмотреть и изменить его").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await model.refreshHooks() }
    }

    private var huskyCard: some View {
        let h = model.hooks
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "dog.fill").foregroundStyle(h.huskyActive ? .green : .secondary)
                Text("Husky").font(.headline)
                if h.huskyInstalled {
                    Text("v\(h.huskyVersion ?? "?")").font(.caption).padding(.horizontal, 6).background(Capsule().fill(.secondary.opacity(0.2)))
                }
                Text(statusText).foregroundStyle(.secondary)
                Spacer()
                if !h.huskyInstalled && !h.huskyDirExists {
                    Button("Инициализировать Husky…") { model.askInitHusky() }
                } else {
                    Button(h.huskyInstalled ? "Активировать хуки" : "npm install") { Task { await model.activateHusky() } }
                        .help(h.huskyInstalled ? "npx husky — выставляет core.hooksPath" : "Установит зависимости; husky подключится через prepare-скрипт")
                }
                Button { Task { await model.refreshHooks() } } label: { Image(systemName: "arrow.clockwise") }
            }
            HStack(spacing: 14) {
                Text("core.hooksPath: \(h.hooksPathConfig ?? "не задан (.git/hooks)")").font(.caption).foregroundStyle(.secondary)
                Button("Изменить…") { model.promptHooksPath() }.buttonStyle(.link).font(.caption)
                if h.hooksPathConfig != nil { Button("Сбросить") { Task { await model.resetHooksPath() } }.buttonStyle(.link).font(.caption) }
                Spacer()
                Toggle("Отключить Husky (HUSKY=0) для операций из приложения", isOn: $disableHusky)
                    .toggleStyle(.checkbox).font(.caption)
                    .help("Переменная HUSKY=0 передаётся во все git-команды приложения: husky-хуки будут пропущены")
            }
        }
        .padding(12)
    }

    private var statusText: String {
        let h = model.hooks
        if h.huskyActive { return "активен · \(h.hooksPathConfig ?? "")" }
        if h.huskyDirExists { return "папка .husky есть, но не активирована" }
        if h.huskyInstalled { return "установлен, папки .husky нет" }
        return h.hasPackageJson ? "не установлен" : "нет package.json"
    }

    private var hooksList: some View {
        List(selection: $selectedPath) {
            ForEach(model.hooks.groups) { g in
                Section {
                    ForEach(g.files) { f in
                        HStack {
                            Image(systemName: f.executable || g.isHusky ? "play.circle.fill" : "pause.circle")
                                .foregroundStyle(f.executable || g.isHusky ? .green : .secondary)
                            Text(f.name)
                        }
                        .tag(f.path)
                    }
                    if g.files.isEmpty { Text("Хуков нет").font(.caption).foregroundStyle(.secondary) }
                } header: {
                    HStack {
                        Text(g.title)
                        Spacer()
                        Menu {
                            ForEach(standardHookNames, id: \.self) { n in
                                if !g.files.contains(where: { $0.name == n }) {
                                    Button(n) { Task { await model.createHook(n, in: g); selectedPath = g.dir + "/" + n } }
                                }
                            }
                        } label: { Image(systemName: "plus") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay { if model.hooks.groups.isEmpty { Text("Папка хуков не найдена").foregroundStyle(.secondary) } }
    }
}

struct HookEditor: View {
    @ObservedObject var model: RepoModel
    let file: HookFile
    @Local private var text = ""
    @Local private var original = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(file.name).font(.headline)
                Text((file.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Toggle("Исполняемый", isOn: Binding(get: { file.executable }, set: { v in Task { await model.setExecutable(file, v) } }))
                    .toggleStyle(.checkbox)
                Button { Task { await model.runHook(file) } } label: { Label("Запустить", systemImage: "play.fill") }
                    .help("Выполнить хук вручную в папке репозитория")
                Button { model.askDeleteHook(file) } label: { Image(systemName: "trash") }
                Button("Сохранить") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(text == original)
            }
            .padding(10)
            Divider()
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
        }
        .task { load() }
    }

    private func load() {
        let s = (try? String(contentsOfFile: file.path, encoding: .utf8)) ?? ""
        text = s
        original = s
    }

    private func save() {
        do {
            try text.write(toFile: file.path, atomically: true, encoding: .utf8)
            original = text
            if file.executable { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        } catch { model.show("Не удалось сохранить", error.localizedDescription, error: true) }
    }
}
