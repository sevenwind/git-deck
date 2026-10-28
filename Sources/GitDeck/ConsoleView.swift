import SwiftUI

struct ConsoleView: View {
    @ObservedObject var model: RepoModel
    @Local private var input = ""
    @Local private var histIndex: Int?
    @FocusState private var focused: Bool

    private var history: [String] { model.consoleLog.map(\.command) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.consoleLog.isEmpty {
                            Text("Здесь видны все git-команды, которые выполняет приложение, и ваши собственные.\nВведите команду git (префикс «git» необязателен). Для произвольной shell-команды начните со «!».")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.consoleLog) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("$ " + e.command).fontWeight(.semibold).foregroundStyle(e.code == 0 ? Color.green : Color.red)
                                if !e.output.isEmpty { Text(e.output).foregroundStyle(e.code == 0 ? .primary : Color.red) }
                                if e.code != 0 { Text("exit \(e.code)").foregroundStyle(.secondary) }
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .onChange(of: model.consoleLog.count) { proxy.scrollTo("end") }
                .onAppear { proxy.scrollTo("end") }
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack(spacing: 8) {
                Text("$ git").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                TextField("status, log --oneline -5, !ls …", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($focused)
                    .onSubmit { send() }
                    .onKeyPress(.upArrow) { step(-1); return .handled }
                    .onKeyPress(.downArrow) { step(1); return .handled }
                if model.busy { ProgressView().controlSize(.small) }
                Button("Выполнить") { send() }.disabled(input.trimmed.isEmpty || model.busy)
                Button { model.consoleLog.removeAll() } label: { Image(systemName: "trash") }.help("Очистить")
                Button { model.openTerminal() } label: { Label("Открыть в Terminal", systemImage: "terminal") }
            }
            .padding(10)
        }
        .onAppear { focused = true }
    }

    private func send() {
        let line = input
        input = ""
        histIndex = nil
        Task { await model.runConsole(line) }
    }

    private func step(_ d: Int) {
        let h = history
        guard !h.isEmpty else { return }
        var i = (histIndex ?? h.count) + d
        i = max(0, min(h.count, i))
        histIndex = i
        input = i == h.count ? "" : h[i].replacingOccurrences(of: "git ", with: "", options: .anchored)
    }
}
