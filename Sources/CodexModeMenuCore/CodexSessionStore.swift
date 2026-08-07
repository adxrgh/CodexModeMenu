import Foundation

/// 一条历史会话（跨 GPT / DeepSeek 模式）。
public struct CodexSession: Equatable {
    public let id: String
    public let title: String
    public let updatedAt: Date?
    public let provider: String?
    public let cwd: String?
    /// 所属项目名（来自 thread-project-assignments，可能为 nil）。
    public let projectName: String?

    /// 会话对应的模式标记，用于菜单显示。
    public var modeLabel: String {
        let p = provider?.lowercased() ?? ""
        if p.contains("deepseek") {
            return "DS"
        }
        if p == "openai" {
            return "GPT"
        }
        return "?"
    }
}

/// 按项目分组的历史会话。
public struct CodexProjectGroup: Equatable {
    public let name: String
    public let sessions: [CodexSession]
}

/// 读取本地 Codex 会话索引与 rollout 元数据，构建跨模式历史会话列表。
///
/// 数据来源（纯本地，不依赖服务端）：
/// - `~/.codex/session_index.jsonl`：会话 id / 标题 / updated_at
/// - `~/.codex/sessions/**/rollout-*-<id>.jsonl` 首行 `session_meta`：model_provider / cwd
/// - `~/.codex/.codex-global-state.json`：local-projects / thread-project-assignments
public enum CodexSessionStore {
    public static let defaultIndexURL = URL(
        fileURLWithPath: "/Users/bob/.codex/session_index.jsonl"
    )
    public static let defaultSessionsDir = URL(
        fileURLWithPath: "/Users/bob/.codex/sessions"
    )
    public static let defaultGlobalStateURL = URL(
        fileURLWithPath: "/Users/bob/.codex/.codex-global-state.json"
    )

    public struct ListOptions {
        public var limit: Int
        /// 每个项目最多保留的会话数（控制菜单体积）。
        public var perProjectLimit: Int

        public init(limit: Int = 60, perProjectLimit: Int = 5) {
            self.limit = limit
            self.perProjectLimit = perProjectLimit
        }
    }

    /// 返回按 updated_at 倒序的最近会话。
    public static func listSessions(
        indexAt indexURL: URL = defaultIndexURL,
        sessionsDir: URL = defaultSessionsDir,
        globalStateAt stateURL: URL = defaultGlobalStateURL,
        options: ListOptions = ListOptions()
    ) -> [CodexSession] {
        let rolloutFiles = indexRolloutFiles(sessionsDir: sessionsDir)
        let indexRows = readIndex(fileAt: indexURL)
        let projects = readProjects(fileAt: stateURL)
        var sessions: [CodexSession] = []

        for row in indexRows {
            guard let id = row["id"], !id.isEmpty else { continue }
            let title = row["thread_name"] ?? "（无标题）"
            let updatedAt = parseDate(row["updated_at"])
            let meta = rolloutFiles[id].flatMap { readSessionMeta(fileAt: $0) }
            sessions.append(
                CodexSession(
                    id: id,
                    title: title,
                    updatedAt: updatedAt,
                    provider: meta?.provider,
                    cwd: meta?.cwd,
                    projectName: projects.projectName(forThread: id)
                )
            )
        }

        sessions.sort { lhs, rhs in
            let l = lhs.updatedAt ?? .distantPast
            let r = rhs.updatedAt ?? .distantPast
            return l > r
        }
        if options.limit > 0, sessions.count > options.limit {
            return Array(sessions.prefix(options.limit))
        }
        return sessions
    }

    /// 返回按项目分组的会话列表（项目内按时间倒序，每个项目最多 perProjectLimit 条）。
    public static func listGroupedSessions(
        indexAt indexURL: URL = defaultIndexURL,
        sessionsDir: URL = defaultSessionsDir,
        globalStateAt stateURL: URL = defaultGlobalStateURL,
        options: ListOptions = ListOptions()
    ) -> [CodexProjectGroup] {
        let sessions = listSessions(
            indexAt: indexURL,
            sessionsDir: sessionsDir,
            globalStateAt: stateURL,
            options: options
        )

        // 保持分组顺序：按组内最新会话时间倒序。
        var byProject: [String: [CodexSession]] = [:]
        var order: [String] = []
        for session in sessions {
            let key = session.projectName ?? "未关联"
            if byProject[key] == nil {
                byProject[key] = []
                order.append(key)
            }
            if byProject[key]!.count < options.perProjectLimit {
                byProject[key]!.append(session)
            }
        }

        let sortedKeys = order.sorted { a, b in
            let aLatest = byProject[a]?.first?.updatedAt ?? .distantPast
            let bLatest = byProject[b]?.first?.updatedAt ?? .distantPast
            return aLatest > bLatest
        }

        return sortedKeys.map { key in
            CodexProjectGroup(name: key, sessions: byProject[key] ?? [])
        }
    }

    // MARK: - 项目读取

    private struct ProjectIndex {
        let names: [String: String]
        let threadToProject: [String: String]

        func projectName(forThread id: String) -> String? {
            guard let pid = threadToProject[id] else { return nil }
            return names[pid]
        }
    }

    private static func readProjects(fileAt url: URL) -> ProjectIndex {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ProjectIndex(names: [:], threadToProject: [:])
        }

        var names: [String: String] = [:]
        if let projects = obj["local-projects"] as? [String: [String: Any]] {
            for (pid, p) in projects {
                if let name = p["name"] as? String {
                    names[pid] = name
                }
            }
        }

        var threadToProject: [String: String] = [:]
        if let assignments = obj["thread-project-assignments"] as? [String: [String: Any]] {
            for (tid, a) in assignments {
                if let pid = a["projectId"] as? String {
                    threadToProject[tid] = pid
                }
            }
        }

        return ProjectIndex(names: names, threadToProject: threadToProject)
    }

    // MARK: - 内部实现

    /// 遍历 sessions 目录一次，返回 [会话id: rollout 文件 URL]。
    /// 文件名格式：rollout-<timestamp>-<完整uuid>.jsonl。
    private static func indexRolloutFiles(sessionsDir: URL) -> [String: URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var map: [String: URL] = [:]
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let name = fileURL.lastPathComponent
            guard name.hasPrefix("rollout-") else { continue }
            let withoutExt = name.dropLast(".jsonl".count)
            let segments = withoutExt.split(separator: "-", omittingEmptySubsequences: false)
            // segments: [rollout, YYYY, MM, DDTHH, MM, SS, id...]
            guard segments.count >= 7 else { continue }
            let id = segments[6...].joined(separator: "-")
            guard id.count == 36 else { continue }
            map[id] = fileURL
        }
        return map
    }

    private static func readIndex(fileAt url: URL) -> [[String: String]] {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var rows: [[String: String]] = []
        for line in data.split(separator: "\n") {
            guard let jsonData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else {
                continue
            }
            var row: [String: String] = [:]
            for (key, value) in obj {
                if let stringValue = value as? String {
                    row[key] = stringValue
                }
            }
            rows.append(row)
        }
        return rows
    }

    private static func readSessionMeta(
        fileAt url: URL
    ) -> (provider: String?, cwd: String?)? {
        guard let firstLine = readFirstLine(fileAt: url),
              let jsonData = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let payload = obj["payload"] as? [String: Any]
        else {
            return nil
        }
        return (
            provider: payload["model_provider"] as? String,
            cwd: payload["cwd"] as? String
        )
    }

    private static func readFirstLine(fileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 64 * 1024)
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init)
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
