import Foundation

/// 当前 Codex 主控模式。
public enum CodexModeKind: Equatable {
    case gpt
    case deepseek
    case unknown
}

/// 从 config.toml 顶层解析出的 model / model_provider。
public struct CodexMode: Equatable {
    public let model: String?
    public let provider: String?

    public init(model: String?, provider: String?) {
        self.model = model
        self.provider = provider
    }

    /// 依据顶层 model 与 model_provider 判定模式。
    public var kind: CodexModeKind {
        let model = self.model?.lowercased() ?? ""
        let provider = self.provider?.lowercased() ?? ""
        if provider == "openai" && model.hasPrefix("gpt") {
            return .gpt
        }
        if provider == "deepseek_go" && model.contains("deepseek") {
            return .deepseek
        }
        return .unknown
    }

    /// 状态栏标题：Codex · GPT / Codex · DS / Codex · ?
    public var title: String {
        switch kind {
        case .gpt:
            return "Codex · GPT"
        case .deepseek:
            return "Codex · DS"
        case .unknown:
            return "Codex · ?"
        }
    }

    /// 菜单里“当前模式说明”的详细文案。
    public var detailDescription: String {
        let model = self.model ?? "（无）"
        let provider = self.provider ?? "（无）"
        switch kind {
        case .gpt:
            return "当前模式：GPT 主控（\(model) / \(provider)）"
        case .deepseek:
            return "当前模式：DeepSeek 全量（\(model) / \(provider)）"
        case .unknown:
            return "当前模式：未知（\(model) / \(provider)）"
        }
    }
}
