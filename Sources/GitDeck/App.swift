import SwiftUI
import AppKit

extension NSWindow {
    /// Главное окно GitDeck (не окно настроек и не служебные окна).
    var isGitDeckMain: Bool { canBecomeMain && title == "GitDeck" }
}

extension NSApplication {
    /// Надёжно выводит приложение и главное окно вперёд, в том числе сразу после смены activation policy.
    func bringToFront() {
        activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            for w in self.windows where w.isGitDeckMain {
                if w.isMiniaturized { w.deminiaturize(nil) }
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
            }
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }
    }
}

/// Клик по иконке в Dock: вернуть свёрнутое или закрытое окно.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Открывает главное окно заново, когда оно было закрыто (задаётся из GitDeckApp).
    var openMainWindow: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard sender.windows.contains(where: { $0.isGitDeckMain }) else {
            openMainWindow?()
            sender.bringToFront()
            return false
        }
        sender.bringToFront()
        return false
    }
}

@main
struct GitDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    @StateObject private var updater = Updater()
    @AppStorage("menuBarMode") private var menuBarMode = false
    @Environment(\.openWindow) private var openWindow

    /// В режиме строки меню приложение скрывается из Dock и Cmd+Tab (.accessory).
    private func applyActivationPolicy() {
        // Смена policy не должна прятать окна: запоминаем видимые и возвращаем их после переключения.
        let visible = NSApp.windows.filter { $0.isVisible }
        let key = NSApp.keyWindow
        NSApp.setActivationPolicy(menuBarMode ? .accessory : .regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            visible.forEach { $0.orderFrontRegardless() }
            key?.makeKeyAndOrderFront(nil)
        }
    }

    private func showMainWindow() {
        if let w = NSApp.windows.first(where: { $0.isGitDeckMain }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        Window("GitDeck", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(updater)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear {
                    updater.startAutoCheck()
                    appDelegate.openMainWindow = { openWindow(id: "main") }
                    applyActivationPolicy()
                }
                .onChange(of: menuBarMode) { applyActivationPolicy() }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(updater.availableVersion.map { "Доступна версия \($0) — установить…" } ?? "Проверить обновления…") {
                    Task { await updater.promptInstall() }
                }
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
        MenuBarExtra(isInserted: $menuBarMode) {
            Button("Показать GitDeck") { showMainWindow() }
            Divider()
            Button(updater.availableVersion.map { "Доступна версия \($0) — установить…" } ?? "Проверить обновления…") {
                Task { await updater.promptInstall() }
            }
            .disabled(updater.phase != .idle)
            SettingsLink { Text("Настройки…") }
            Divider()
            Button("Выйти из GitDeck") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: updater.availableVersion == nil ? "arrow.triangle.branch" : "arrow.down.circle.fill")
        }
        Settings { SettingsView().environmentObject(store).environmentObject(updater) }
    }
}

struct SettingsView: View {
    @AppStorage("terminalApp") private var terminalApp = "Terminal"
    @AppStorage("disableHusky") private var disableHusky = false
    @AppStorage("scanDepth") private var scanDepth = 5
    @AppStorage("menuBarMode") private var menuBarMode = false
    @AppStorage("updateRepo") private var updateRepo = Updater.defaultRepo
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var updater: Updater

    var body: some View {
        Form {
            TextField("Терминал (имя приложения)", text: $terminalApp, prompt: Text("Terminal, iTerm, Warp…"))
            Stepper("Глубина поиска репозиториев: \(scanDepth)", value: $scanDepth, in: 1...10)
            Toggle("Отключить Husky (HUSKY=0) для операций из приложения", isOn: $disableHusky)
            Toggle("Показывать в строке меню вместо Dock", isOn: $menuBarMode)
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
