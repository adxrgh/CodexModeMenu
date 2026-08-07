import Foundation

/// 调用 switch-client-mode.py 完成模式切换。
public enum CodexModeSwitcher {
    public static let scriptPath = "/Users/bob/.codex/codex-deepseek-go/bin/switch-client-mode.py"
    public static let pythonPath = "/usr/bin/python3"

    public struct SwitchResult {
        public let exitCode: Int32
        public let output: String
        public let error: String

        public var isSuccess: Bool {
            exitCode == 0
        }
    }

    /// 同步执行 python3 switch-client-mode.py gpt|deepseek。
    /// 注意：仅当调用方显式触发时才执行；本方法本身不改变任何外部状态。
    public static func switchMode(to kind: CodexModeKind) -> SwitchResult {
        let argument: String
        switch kind {
        case .gpt:
            argument = "gpt"
        case .deepseek:
            argument = "deepseek"
        case .unknown:
            argument = "gpt"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath, argument]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return SwitchResult(
                exitCode: 127,
                output: "",
                error: "无法启动切换脚本：\(error.localizedDescription)"
            )
        }
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return SwitchResult(
            exitCode: process.terminationStatus,
            output: String(data: outData, encoding: .utf8) ?? "",
            error: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
