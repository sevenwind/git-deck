import Foundation

struct CmdResult: Sendable {
    var out = ""
    var err = ""
    var code: Int32 = 0
    var ok: Bool { code == 0 }
    var combined: String {
        let o = out.trimmingCharacters(in: .newlines)
        let e = err.trimmingCharacters(in: .newlines)
        return [o, e].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// PATH из login-шелла пользователя: приложение, запущенное из Finder, иначе не видит node/npm (нужны husky-хукам).
final class ShellEnv: @unchecked Sendable {
    static let shared = ShellEnv()
    private let lock = NSLock()
    private var _path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    var path: String { lock.lock(); defer { lock.unlock() }; return _path }

    func resolve() {
        DispatchQueue.global(qos: .utility).async {
            let r = Shell.runSync("/bin/zsh", ["-ilc", "printf '@@%s@@' \"$PATH\""], cwd: nil)
            guard let a = r.out.range(of: "@@"),
                  let b = r.out.range(of: "@@", options: .backwards),
                  a.upperBound <= b.lowerBound else { return }
            let p = String(r.out[a.upperBound..<b.lowerBound])
            if !p.isEmpty {
                self.lock.lock(); self._path = p; self.lock.unlock()
            }
        }
    }
}

enum Shell {
    static func baseEnv() -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = ShellEnv.shared.path
        e["GIT_TERMINAL_PROMPT"] = "0"
        e["GIT_EDITOR"] = "true"
        e["GIT_PAGER"] = "cat"
        e["PAGER"] = "cat"
        if e["LANG"] == nil { e["LANG"] = "en_US.UTF-8" }
        return e
    }

    static func runSync(_ exe: String, _ args: [String], cwd: String?,
                        env: [String: String] = [:], stdin: String? = nil) -> CmdResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var e = baseEnv()
        for (k, v) in env { e[k] = v }
        p.environment = e

        let o = Pipe(), er = Pipe(), i = Pipe()
        p.standardOutput = o
        p.standardError = er
        p.standardInput = stdin == nil ? FileHandle.nullDevice : i

        let outBox = DataBox(), errBox = DataBox()
        let outDone = DispatchSemaphore(value: 0), errDone = DispatchSemaphore(value: 0)
        func attach(_ pipe: Pipe, _ box: DataBox, _ done: DispatchSemaphore) {
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; done.signal() } else { box.append(d) }
            }
        }
        attach(o, outBox, outDone)
        attach(er, errBox, errDone)

        do { try p.run() } catch {
            o.fileHandleForReading.readabilityHandler = nil
            er.fileHandleForReading.readabilityHandler = nil
            return CmdResult(out: "", err: error.localizedDescription, code: 127)
        }
        if let stdin {
            i.fileHandleForWriting.write(Data(stdin.utf8))
            try? i.fileHandleForWriting.close()
        }
        p.waitUntilExit()
        outDone.wait()
        errDone.wait()
        return CmdResult(out: String(decoding: outBox.value, as: UTF8.self),
                         err: String(decoding: errBox.value, as: UTF8.self),
                         code: p.terminationStatus)
    }

    static func run(_ exe: String, _ args: [String], cwd: String? = nil,
                    env: [String: String] = [:], stdin: String? = nil) async -> CmdResult {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(returning: runSync(exe, args, cwd: cwd, env: env, stdin: stdin))
            }
        }
    }

    /// git с настройками по умолчанию (вывод путей в UTF-8, без интерактивных запросов).
    static func git(_ args: [String], cwd: String, env: [String: String] = [:], stdin: String? = nil) async -> CmdResult {
        await run("/usr/bin/env", ["git", "-c", "core.quotepath=false"] + args, cwd: cwd, env: env, stdin: stdin)
    }

    /// Находит ветку `name` среди remote-ссылок; если её нет (узкий refspec у single-branch клона) —
    /// спрашивает сами remote и скачивает ветку явным refspec. Возвращает "remote/name" или nil.
    static func remoteTrackingRef(_ name: String, cwd: String) async -> String? {
        let refs = await git(["for-each-ref", "--format=%(refname:short)", "refs/remotes"], cwd: cwd)
        let known = refs.out.split(separator: "\n").map(String.init).first { ref in
            guard let slash = ref.firstIndex(of: "/") else { return false }
            return String(ref[ref.index(after: slash)...]) == name
        }
        if let known { return known }
        let remotes = await git(["remote"], cwd: cwd).out.split(separator: "\n").map(String.init)
        for remote in remotes {
            let ls = await git(["ls-remote", "--exit-code", "--heads", remote, "refs/heads/" + name], cwd: cwd)
            guard ls.ok else { continue }
            let f = await git(["fetch", remote, "+refs/heads/\(name):refs/remotes/\(remote)/\(name)"], cwd: cwd)
            if f.ok { return "\(remote)/\(name)" }
        }
        return nil
    }

    /// Создаёт локальную ветку `name` из "remote/name" и прописывает upstream в конфиге напрямую:
    /// `switch --track` не работает, если ссылка не попадает под fetch-refspec remote.
    static func switchTracking(_ remoteRef: String, name: String,
                               git run: ([String]) async -> CmdResult) async -> CmdResult {
        let sw = await run(["switch", "-c", name, "--no-track", remoteRef])
        guard sw.ok, let slash = remoteRef.firstIndex(of: "/") else { return sw }
        let remote = String(remoteRef[..<slash])
        _ = await run(["config", "branch.\(name).remote", remote])
        _ = await run(["config", "branch.\(name).merge", "refs/heads/" + name])
        return sw
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
