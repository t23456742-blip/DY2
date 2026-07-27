import Foundation
import Darwin

/// 自定义 SH 路径执行（对齐工具箱 RootHelper：posix_spawn + /bin/sh）
/// FUCK 工具箱「清理」本身不是外置 .sh，而是 CleanService 原生删路径；
/// RootHelper 通过 posix_spawn 调内嵌 rm/cp/mv 或 /bin/sh。本功能让你填任意脚本路径执行。
enum ShellScriptRunner {
    struct Result {
        let ok: Bool
        let exitCode: Int32
        let output: String
        let message: String
    }

    private static let shCandidates = [
        "/bin/sh",
        "/var/jb/bin/sh",
        "/usr/bin/sh",
        "/bin/bash",
        "/var/jb/bin/bash"
    ]

    static func execute(path: String, extraArgs: [String] = []) -> Result {
        let script = (path as NSString)
            .expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else {
            return .init(ok: false, exitCode: -1, output: "", message: "请填写 SH 脚本路径")
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: script) else {
            return .init(ok: false, exitCode: -1, output: "", message: "找不到脚本：\n\(script)")
        }

        let sh = shCandidates.first { fm.fileExists(atPath: $0) } ?? "/bin/sh"
        let logURL = fm.temporaryDirectory
            .appendingPathComponent("dysh_\(UUID().uuidString).log")
        fm.createFile(atPath: logURL.path, contents: Data())

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        logURL.path.withCString { cPath in
            _ = posix_spawn_file_actions_addopen(
                &fileActions, STDOUT_FILENO, cPath,
                O_WRONLY | O_CREAT | O_TRUNC, 0o644
            )
            _ = posix_spawn_file_actions_addopen(
                &fileActions, STDERR_FILENO, cPath,
                O_WRONLY | O_CREAT | O_APPEND, 0o644
            )
        }

        let argvStrings = [sh, script] + extraArgs
        var cArgv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
        cArgv.append(nil)
        defer {
            for p in cArgv where p != nil {
                free(p)
            }
        }

        var pid: pid_t = 0
        let spawnRC: Int32 = sh.withCString { cSh in
            cArgv.withUnsafeMutableBufferPointer { buf in
                posix_spawn(&pid, cSh, &fileActions, nil, buf.baseAddress, environ)
            }
        }

        guard spawnRC == 0 else {
            try? fm.removeItem(at: logURL)
            return .init(
                ok: false,
                exitCode: spawnRC,
                output: "",
                message: "posix_spawn 失败（\(spawnRC)）\n解释器：\(sh)\n脚本：\(script)"
            )
        }

        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        let code: Int32 = ((status & 0o177) == 0) ? ((status >> 8) & 0xff) : status
        let raw = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        try? fm.removeItem(at: logURL)

        let clipped = String(raw.prefix(4000))
        let ok = code == 0
        var tip = ok ? "SH 执行成功" : "SH 执行失败"
        tip += "（exit \(code)）\n解释器：\(sh)\n脚本：\(script)"
        if !clipped.isEmpty {
            tip += "\n—— 输出 ——\n\(clipped)"
        }
        return .init(ok: ok, exitCode: code, output: raw, message: tip)
    }

    /// 写临时脚本再执行（迁移 / 清目录用，对齐工具箱 RootHelper 调 /bin/cp /bin/rm）
    static func executeInline(_ scriptBody: String) -> Result {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("dymig_\(UUID().uuidString).sh")
        let body = "#!/bin/sh\nset -e\n" + scriptBody + "\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            return .init(ok: false, exitCode: -1, output: "", message: "无法写临时脚本：\(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: url) }
        return execute(path: url.path)
    }
}
