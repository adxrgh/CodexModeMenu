import Foundation
import SQLite3

/// 打开历史会话前，把该会话的模型来源同步为当前模式（DeepSeek）。
///
/// 背景：Codex 桌面端打开本地会话时，composer 显示的模型来自多个数据源：
/// - `~/.codex/sessions/**/rollout-*.jsonl` 中的
///   `thread_settings_applied` / `turn_context.collaboration_mode` / `session_meta`
/// - `~/.codex/state_5.sqlite` 的 `threads` 表（模型选择器/列表来源）
/// - `~/.codex/sqlite/codex-dev.db` 的 `local_thread_catalog`（App 线程目录）
///
/// 本类型只做一件事：把某个会话的所有模型字段统一改为 DeepSeek 值，
/// 让「在 DeepSeek 模式下打开历史 GPT 会话」时模型自动跟随当前模式。
/// 修改前会备份原 jsonl；SQLite 修改尽力而为（App 运行时可能有写锁）。
public enum CodexThreadModelSync {
    public static let deepseekProvider = "deepseek_go"
    public static let deepseekModel = "deepseek-v4-flash"
    public static let deepseekEffort = "high"

    public static let stateDBURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/state_5.sqlite")
    public static let devCatalogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sqlite/codex-dev.db")

    public struct Result {
        public let synchronized: Bool
        public let success: Bool
        public let message: String
    }

    /// 若当前模式是 DeepSeek 且会话仍是 GPT 来源，则同步为 DeepSeek 后返回。
    /// GPT 模式下不修改任何数据（保持原样打开）。
    public static func syncToDeepSeekIfNeeded(
        threadID: String,
        rolloutURL: URL? = nil,
        targetMode: CodexModeKind
    ) -> Result {
        guard targetMode == .deepseek else {
            return Result(synchronized: false, success: true, message: "GPT 模式，不修改会话")
        }
        guard !threadID.isEmpty else {
            return Result(synchronized: false, success: false, message: "会话 id 为空")
        }

        // 1. 定位 rollout 文件：优先传入 URL，否则从 state db 查 rollout_path。
        var rollout = rolloutURL
        if rollout == nil, let path = rolloutPathFromStateDB(threadID: threadID) {
            rollout = URL(fileURLWithPath: path)
        }
        guard let rollout, FileManager.default.fileExists(atPath: rollout.path) else {
            return Result(
                synchronized: false,
                success: false,
                message: "找不到会话文件（\(threadID)），已跳过"
            )
        }

        // 2. 判断当前来源是否已经是 DeepSeek（首行 session_meta）。
        guard let provider = sessionProvider(fileAt: rollout) else {
            return Result(
                synchronized: false,
                success: true,
                message: "无法读取会话来源，已跳过"
            )
        }
        if provider == deepseekProvider {
            return Result(synchronized: false, success: true, message: "已是 DeepSeek 会话")
        }

        // 3. 备份 + 改写 jsonl。
        do {
            try backup(fileAt: rollout)
            let rewritten = try rewriteRollout(fileAt: rollout)
            try rewritten.write(to: rollout, atomically: true, encoding: .utf8)
        } catch {
            return Result(
                synchronized: false,
                success: false,
                message: "改写会话失败：\(error.localizedDescription)"
            )
        }

        // 4. 同步 state db / codex-dev catalog（尽力而为，失败不阻断打开）。
        var dbErrors: [String] = []
        if !updateThreadsInStateDB(threadID: threadID) {
            dbErrors.append("state_5.sqlite")
        }
        if !updateCatalogInDevDB(threadID: threadID) {
            dbErrors.append("codex-dev.db")
        }

        let message = dbErrors.isEmpty
            ? "会话已切换为 DeepSeek"
            : "会话已切换为 DeepSeek（SQLite 写入失败：\(dbErrors.joined(separator: ", "))）"
        return Result(synchronized: true, success: true, message: message)
    }

    // MARK: - jsonl

    private static func sessionProvider(fileAt url: URL) -> String? {
        guard let firstLine = readFirstLine(fileAt: url),
              let data = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any]
        else {
            return nil
        }
        return payload["model_provider"] as? String
    }

    private static func backup(fileAt url: URL) throws {
        let backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-deepseek-sync-\(url.lastPathComponent)")
        try? FileManager.default.removeItem(at: backupURL)
        try FileManager.default.copyItem(at: url, to: backupURL)
    }

    /// 逐行重写 rollout：把 session_meta / turn_context / thread_settings_applied 中的
    /// model、model_provider、reasoning_effort 统一改为 DeepSeek 值。
    private static func rewriteRollout(fileAt url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let data = line.data(using: .utf8),
                  var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                lines.append(line)
                continue
            }

            var payload = obj["payload"] as? [String: Any] ?? [:]
            let eventType = payload["type"] as? String ?? obj["type"] as? String

            if eventType == "session_meta" {
                payload["model_provider"] = deepseekProvider
            } else if eventType == "turn_context" {
                payload["model"] = deepseekModel
                if payload["effort"] != nil {
                    payload["effort"] = deepseekEffort
                }
                payload["collaboration_mode"] = fixCollaborationMode(payload["collaboration_mode"])
            } else if eventType == "thread_settings_applied" {
                var ts = payload["thread_settings"] as? [String: Any] ?? [:]
                ts["model"] = deepseekModel
                ts["model_provider_id"] = deepseekProvider
                if ts["reasoning_effort"] != nil {
                    ts["reasoning_effort"] = deepseekEffort
                }
                ts["collaboration_mode"] = fixCollaborationMode(ts["collaboration_mode"])
                payload["thread_settings"] = ts
            }

            obj["payload"] = payload
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
               let newLine = String(data: data, encoding: .utf8) {
                lines.append(newLine)
            } else {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func fixCollaborationMode(_ raw: Any?) -> Any? {
        guard var cm = raw as? [String: Any],
              var settings = cm["settings"] as? [String: Any]
        else {
            return raw
        }
        if settings["model"] != nil {
            settings["model"] = deepseekModel
        }
        if settings["reasoning_effort"] != nil {
            settings["reasoning_effort"] = deepseekEffort
        }
        cm["settings"] = settings
        return cm
    }

    // MARK: - SQLite

    private static func rolloutPathFromStateDB(threadID: String) -> String? {
        guard FileManager.default.fileExists(atPath: stateDBURL.path) else { return nil }
        guard let conn = openSQLite(url: stateDBURL) else { return nil }
        defer { sqlite3_close(conn) }

        let sql = "SELECT rollout_path FROM threads WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, threadID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cString)
    }

    private static func updateThreadsInStateDB(threadID: String) -> Bool {
        guard FileManager.default.fileExists(atPath: stateDBURL.path) else { return true }
        guard let conn = openSQLite(url: stateDBURL) else { return false }
        defer { sqlite3_close(conn) }

        let sql = """
        UPDATE threads
        SET model_provider = ?, model = ?, reasoning_effort = ?
        WHERE id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, deepseekProvider, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, deepseekModel, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, deepseekEffort, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 4, threadID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private static func updateCatalogInDevDB(threadID: String) -> Bool {
        guard FileManager.default.fileExists(atPath: devCatalogURL.path) else { return true }
        guard let conn = openSQLite(url: devCatalogURL) else { return false }
        defer { sqlite3_close(conn) }

        let sql = """
        UPDATE local_thread_catalog
        SET model_provider = ?
        WHERE thread_id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, deepseekProvider, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, threadID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private static func openSQLite(url: URL) -> OpaquePointer? {
        var conn: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &conn, flags, nil) == SQLITE_OK else {
            return nil
        }
        // App 运行时 state db 可能被 Codex 主进程占用写锁；等待而不是立刻失败。
        sqlite3_busy_timeout(conn, 3000)
        return conn
    }

    private static func readFirstLine(fileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 64 * 1024)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init)
    }
}
