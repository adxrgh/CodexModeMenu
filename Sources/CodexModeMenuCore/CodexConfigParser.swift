import Foundation

/// 解析 ~/.codex/config.toml 的顶层 model / model_provider。
///
/// 规则：只读取第一个 TOML section（以 `[` 开头的行）之前的顶层键值；
/// section 内出现的同名键一律忽略。
public enum CodexConfigParser {
    public static let defaultConfigURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/config.toml")

    /// 从文本解析出顶层模式信息。
    public static func parse(text: String) -> CodexMode {
        var model: String?
        var provider: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            // 进入 TOML section：之后的所有同名键都不属于顶层。
            if trimmed.hasPrefix("[") {
                break
            }
            if let value = extractValue(line: trimmed, key: "model") {
                model = value
            } else if let value = extractValue(line: trimmed, key: "model_provider") {
                provider = value
            }
        }
        return CodexMode(model: model, provider: provider)
    }

    /// 读取配置文件；读取失败时返回 unknown（不抛错）。
    public static func parse(fileAt url: URL = CodexConfigParser.defaultConfigURL) -> CodexMode {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return CodexMode(model: nil, provider: nil)
        }
        return parse(text: text)
    }

    /// 提取 `key = "value"` 或 `key = value`，返回去掉引号的值。
    private static func extractValue(line: String, key: String) -> String? {
        guard let equalIndex = line.firstIndex(of: "=") else {
            return nil
        }
        let lhs = line[..<equalIndex].trimmingCharacters(in: .whitespaces)
        guard lhs == key else {
            return nil
        }
        var rhs = String(line[line.index(after: equalIndex)...])
            .trimmingCharacters(in: .whitespaces)

        // 带引号的值。
        if rhs.hasPrefix("\"") {
            let start = rhs.index(after: rhs.startIndex)
            if let end = rhs[start...].firstIndex(of: "\"") {
                return String(rhs[start..<end])
            }
            return nil
        }
        // 未加引号的值：去掉行内注释。
        if let hash = rhs.firstIndex(of: "#") {
            rhs = String(rhs[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        return rhs.isEmpty ? nil : rhs
    }
}
