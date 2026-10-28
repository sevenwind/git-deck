import SwiftUI

struct RepoView: View {
    @ObservedObject var model: RepoModel
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model)
            if model.state != .none { StateBar(model: model) }
            Divider()
            Picker("", selection: $model.tab) {
                ForEach(RepoTab.allCases) { t in
                    Label(t.rawValue, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            Group {
                switch model.tab {
                case .changes: ChangesView(model: model)
                case .history: HistoryView(model: model)
                case .branches: BranchesView(model: model)
                case .stash: StashView(model: model)
                case .tags: TagsRemotesView(model: model)
                case .hooks: HooksView(model: model)
                case .console: ConsoleView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(model.name)
        .navigationSubtitle(model.path)
        .overlay(alignment: .bottom) {
            if let b = model.banner {
                BannerView(banner: b) { model.banner = nil }
                    .padding(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.banner?.id)
        .sheet(item: $model.prompt) { p in PromptSheet(request: p) }
        .alert(model.confirm?.title ?? "", isPresented: Binding(get: { model.confirm != nil }, set: { if !$0 { model.confirm = nil } }),
               presenting: model.confirm) { c in
            Button(c.confirmLabel, role: c.destructive ? .destructive : nil) { c.action() }
            Button("Отмена", role: .cancel) {}
        } message: { c in Text(c.message) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshAll() }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if NSApp.isActive { await model.refreshStatus() }
            }
        }
    }
}

struct HeaderBar: View {
    @ObservedObject var model: RepoModel
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(model.localBranches) { b in
                    Button {
                        Task { await model.checkout(b) }
                    } label: {
                        if b.isCurrent { Label(b.name, systemImage: "checkmark") } else { Text(b.name) }
                    }
                }
                Divider()
                Button("Новая ветка…", systemImage: "plus") { model.promptNewBranch(from: nil) }
            } label: {
                Label(model.branchTitle, systemImage: "arrow.triangle.branch").font(.headline)
            }
            .fixedSize()

            if let u = model.upstream {
                Text(u).font(.caption).foregroundStyle(.secondary)
            }
            if model.ahead > 0 { Label("\(model.ahead)", systemImage: "arrow.up").font(.caption.bold()).foregroundStyle(.green).help("Коммитов к отправке: \(model.ahead)") }
            if model.behind > 0 { Label("\(model.behind)", systemImage: "arrow.down").font(.caption.bold()).foregroundStyle(.orange).help("Коммитов к получению: \(model.behind)") }

            Spacer()
            if model.busy {
                ProgressView().controlSize(.small)
                Text(model.busyTitle).font(.caption).foregroundStyle(.secondary)
            }

            Menu {
                Button("Fetch --all --prune") { Task { await model.fetch() } }
                Button("Выкачать ветку по имени…") { model.promptFetchBranch() }
            } label: { Label("Fetch", systemImage: "arrow.triangle.2.circlepath") } primaryAction: { Task { await model.fetch() } }
                .fixedSize()
                .help("git fetch --all --prune (стрелка — выкачать ветку по имени)")
            Menu {
                Button("Pull (merge)") { Task { await model.pull(.merge) } }
                Button("Pull --rebase") { Task { await model.pull(.rebase) } }
                Button("Pull --ff-only") { Task { await model.pull(.ffOnly) } }
            } label: { Label("Pull", systemImage: "arrow.down.circle") } primaryAction: { Task { await model.pull(.merge) } }
                .fixedSize()
            Menu {
                Button("Push") { Task { await model.push() } }
                Button("Force push (--force-with-lease)…") { model.askForcePush() }
            } label: { Label("Push", systemImage: "arrow.up.circle") } primaryAction: { Task { await model.push() } }
                .fixedSize()

            Divider().frame(height: 18)
            Button { model.openTerminal() } label: { Label("Terminal", systemImage: "terminal") }
                .help("Открыть репозиторий в терминале (⇧⌘T)")
            Button { model.revealInFinder() } label: { Image(systemName: "folder") }.help("Показать в Finder")
            Button { Task { await model.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }.help("Обновить (⌘R)")
        }
        .disabled(model.busy && false)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct StateBar: View {
    @ObservedObject var model: RepoModel
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(model.state.title).bold()
            if !model.conflicted.isEmpty { Text("— конфликтов: \(model.conflicted.count)").foregroundStyle(.secondary) }
            Spacer()
            Button("Продолжить") { Task { await model.continueOperation() } }
                .disabled(!model.conflicted.isEmpty)
            Button("Отменить операцию", role: .destructive) { Task { await model.abortOperation() } }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.orange.opacity(0.15))
    }
}

struct PromptSheet: View {
    let request: PromptRequest
    @Environment(\.dismiss) private var dismiss
    @Local private var values: [String] = []
    @Local private var flag = false
    @FocusState private var focus: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.title3.bold())
            if !request.message.isEmpty { Text(request.message).foregroundStyle(.secondary) }
            ForEach(Array(request.fields.enumerated()), id: \.element.id) { i, f in
                VStack(alignment: .leading, spacing: 3) {
                    Text(f.label).font(.caption).foregroundStyle(.secondary)
                    TextField("", text: Binding(get: { i < values.count ? values[i] : "" },
                                                set: { if i < values.count { values[i] = $0 } }))
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: i)
                        .onSubmit { submit() }
                }
            }
            if let t = request.toggleTitle { Toggle(t, isOn: $flag) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.confirmLabel) { submit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            values = request.fields.map(\.value)
            flag = request.toggleValue
            focus = 0
        }
    }

    private func submit() {
        request.action(values, flag)
        dismiss()
    }
}
