import Foundation

/// Список организаций и репозиториев GitHub. Авторизация — токен из git credential helper (тот же, что у git clone/fetch),
/// сторонних CLI не нужно.
enum GitHubAPI {
    struct RepoInfo: Sendable { var name: String; var cloneURL: String; var archived: Bool }
    struct Failure: Error { var text: String }

    static func token(control: RunControl? = nil) async throws -> String {
        let r = await Shell.run("/usr/bin/env", ["git", "credential", "fill"],
                                stdin: "protocol=https\nhost=github.com\n\n", control: control)
        guard r.ok, let line = r.out.split(separator: "\n").first(where: { $0.hasPrefix("password=") }) else {
            throw Failure(text: L("Не удалось получить токен GitHub из git credential helper. Выполните git clone любого репозитория GitHub по https и войдите.\n") + r.combined)
        }
        return String(line.dropFirst("password=".count))
    }

    private static func pages(_ path: String, token: String, control: RunControl?) async throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        var page = 1
        while true {
            if control?.isCancelled == true { throw CancellationError() }
            let sep = path.contains("?") ? "&" : "?"
            var req = URLRequest(url: URL(string: "https://api.github.com/\(path)\(sep)per_page=100&page=\(page)")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
                throw Failure(text: "GitHub API \(code): \(msg)")
            }
            all += arr
            if arr.count < 100 { return all }
            page += 1
        }
    }

    static func organizations(control: RunControl? = nil) async throws -> [String] {
        let t = try await token(control: control)
        return try await pages("user/orgs", token: t, control: control).compactMap { $0["login"] as? String }
    }

    static func repos(org: String, control: RunControl? = nil) async throws -> [RepoInfo] {
        let t = try await token(control: control)
        return try await pages("orgs/\(org)/repos?type=all", token: t, control: control).compactMap {
            guard let n = $0["name"] as? String, let u = $0["clone_url"] as? String else { return nil }
            return RepoInfo(name: n, cloneURL: u, archived: ($0["archived"] as? Bool) ?? false)
        }
    }
}
