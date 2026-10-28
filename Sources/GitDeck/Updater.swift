import SwiftUI
import AppKit

/// Обновление по кнопке: проверяет последний GitHub Release, скачивает .dmg,
/// подменяет GitDeck.app и перезапускает приложение.
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading
        case installing
    }

    @Published var phase: Phase = .idle
    @Published var status = ""

    /// Репозиторий вида «owner/repo», задаётся в настройках.
    static let defaultRepo = "sevenwind/git-deck"
    private var repo: String {
        let r = UserDefaults.standard.string(forKey: "updateRepo") ?? ""
        return r.isEmpty ? Self.defaultRepo : r
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let assets: [Asset]
    }

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m } else { return nil } }
    }

    /// Пункт меню / кнопка: проверить и, если есть новая версия, предложить установить.
    func checkInteractive() async {
        guard phase == .idle else { return }
        phase = .checking
        status = "Проверка обновлений…"
        do {
            let (release, asset) = try await fetchLatest()
            let latest = release.tag_name
            guard Self.isNewer(latest, than: currentVersion) else {
                phase = .idle
                status = "Установлена последняя версия (\(currentVersion))"
                alert("Обновлений нет", "У вас последняя версия GitDeck (\(currentVersion)).")
                return
            }
            phase = .idle
            status = "Доступна версия \(latest)"
            let notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = "Доступна версия \(latest), у вас \(currentVersion)." + (notes.isEmpty ? "" : "\n\n\(notes.prefix(800))")
            if confirm("Доступно обновление", text, ok: "Установить и перезапустить") {
                await install(asset: asset)
            }
        } catch {
            phase = .idle
            status = "Ошибка: \(error.localizedDescription)"
            alert("Не удалось проверить обновления", error.localizedDescription)
        }
    }

    private func fetchLatest() async throws -> (Release, Release.Asset) {
        guard repo.split(separator: "/").count == 2 else {
            throw UpdateError.message("Укажите репозиторий GitHub (owner/repo) в настройках.")
        }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.message(http.statusCode == 404
                ? "Релизы не найдены (404). Для приватного репозитория обновление недоступно."
                : "GitHub вернул статус \(http.statusCode).")
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            throw UpdateError.message("В релизе \(release.tag_name) нет .dmg-файла.")
        }
        return (release, asset)
    }

    private func install(asset: Release.Asset) async {
        do {
            let target = Bundle.main.bundleURL
            guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                throw UpdateError.message("Нет прав на запись в \(target.deletingLastPathComponent().path).")
            }
            phase = .downloading
            status = "Скачивание \(asset.name)…"
            let (tmp, resp) = try await URLSession.shared.download(from: asset.browser_download_url)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.message("Скачивание не удалось (статус \(http.statusCode)).")
            }

            phase = .installing
            status = "Установка…"
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("gitdeck-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let dmg = work.appendingPathComponent("update.dmg")
            try FileManager.default.moveItem(at: tmp, to: dmg)
            let mount = work.appendingPathComponent("mnt")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)

            try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
            let staged = work.appendingPathComponent("GitDeck.app")
            do {
                guard FileManager.default.fileExists(atPath: mount.appendingPathComponent("GitDeck.app").path) else {
                    throw UpdateError.message("В образе нет GitDeck.app.")
                }
                try await run("/usr/bin/ditto", [mount.appendingPathComponent("GitDeck.app").path, staged.path])
            } catch {
                _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
                throw error
            }
            _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try await run("/usr/bin/codesign", ["--verify", staged.path])

            // Отдельный процесс ждёт выхода приложения, подменяет .app и запускает новую версию.
            let script = """
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
            rm -rf "$TARGET" && ditto "$STAGED" "$TARGET" && xattr -dr com.apple.quarantine "$TARGET"
            open "$TARGET"
            rm -rf "$WORK"
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            p.environment = ["TARGET": target.path, "STAGED": staged.path, "WORK": work.path, "PATH": "/usr/bin:/bin"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            NSApp.terminate(nil)
        } catch {
            phase = .idle
            status = "Ошибка: \(error.localizedDescription)"
            alert("Не удалось установить обновление", error.localizedDescription)
        }
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do {
                    try p.run()
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    p.waitUntilExit()
                    if p.terminationStatus == 0 { cont.resume(returning: out) }
                    else { cont.resume(throwing: UpdateError.message("\((exe as NSString).lastPathComponent): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")) }
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Сравнение версий вида «v1.2.3» по числовым компонентам.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private func confirm(_ title: String, _ text: String, ok: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Позже")
        return a.runModal() == .alertFirstButtonReturn
    }
}
