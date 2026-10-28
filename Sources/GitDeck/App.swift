import SwiftUI

@main
struct GitDeckApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var updater = Updater()

    var body: some Scene {
        WindowGroup("GitDeck") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") { Task { await updater.checkInteractive() } }
                    .disabled(updater.phase != .idle)
            }
            CommandGroup(after: .newItem) {
                Button("Добавить рабочую область…") { store.addWorkspace() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Открыть репозиторий…") { store.openRepository() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Клонировать…") { store.showClone = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Репозиторий") {
                Button("Обновить") { store.refreshCurrent() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Пересканировать рабочие области") { store.rescan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Открыть в Terminal") { if let p = store.selected { store.openTerminal(at: p) } }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(store.selected == nil)
            }
        }
        Settings { SettingsView().environmentObject(store).environmentObject(updater) }
    }
}

struct SettingsView: View {
    @AppStorage("terminalApp") private var terminalApp = "Terminal"
    @AppStorage("disableHusky") private var disableHusky = false
    @AppStorage("scanDepth") private var scanDepth = 5
    @AppStorage("updateRepo") private var updateRepo = Updater.defaultRepo
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var updater: Updater

    var body: some View {
        Form {
            TextField("Терминал (имя приложения)", text: $terminalApp, prompt: Text("Terminal, iTerm, Warp…"))
            Stepper("Глубина поиска репозиториев: \(scanDepth)", value: $scanDepth, in: 1...10)
            Toggle("Отключить Husky (HUSKY=0) для операций из приложения", isOn: $disableHusky)
            Button("Пересканировать рабочие области") { store.rescan() }
            Section("Обновления") {
                TextField("Репозиторий GitHub", text: $updateRepo, prompt: Text(Updater.defaultRepo))
                HStack {
                    Button("Проверить обновления") { Task { await updater.checkInteractive() } }
                        .disabled(updater.phase != .idle)
                    Text("Версия \(updater.currentVersion)").foregroundStyle(.secondary)
                    if updater.phase != .idle { ProgressView().controlSize(.small) }
                }
                if !updater.status.isEmpty { Text(updater.status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
