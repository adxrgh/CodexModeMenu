import XCTest
@testable import CodexModeMenuCore

/// 端到端：对真实 openai 会话的临时副本执行同步，验证完整链路。
/// 不修改真实文件；仅验证 jsonl 重写逻辑在真实数据上可工作。
final class CodexThreadModelSyncE2ETests: XCTestCase {
    func testRealRolloutRewrite() throws {
        // 每次运行从真实 openai 会话重新复制原始 jsonl，保证测试自包含且可重复。
        guard let home = ProcessInfo.processInfo.environment["HOME"] else {
            throw XCTSkip("缺少 HOME")
        }
        let real = URL(fileURLWithPath: home)
            .appendingPathComponent(".codex/sessions/2026/08/07/rollout-2026-08-07T10-13-45-019fd9ff-74b9-7c11-9d0e-bf3260883245.jsonl")
        guard FileManager.default.fileExists(atPath: real.path) else {
            throw XCTSkip("真实会话文件不存在")
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-e2e-real-\(UUID().uuidString).jsonl")
        try FileManager.default.copyItem(at: real, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let before = try String(contentsOf: tmp, encoding: .utf8)
        let result = CodexThreadModelSync.syncToDeepSeekIfNeeded(
            threadID: "019fd9ff-74b9-7c11-9d0e-bf3260883245",
            rolloutURL: tmp,
            targetMode: .deepseek
        )
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.synchronized)
        let after = try String(contentsOf: tmp, encoding: .utf8)
        // 状态字段必须已切换（base_instructions 里的模型列表说明文本允许保留）
        XCTAssertFalse(after.contains("\"model\":\"gpt-5.6-sol\""))
        XCTAssertFalse(after.contains("\"model_provider_id\":\"openai\""))
        XCTAssertFalse(after.contains("\"model_provider\":\"openai\""))
        XCTAssertFalse(after.contains("\"model\":\"gpt-5.5\""))
        // thinking 枚举里的 "ultra" 是合法值（tool schema），非状态字段；只排除状态字段里的 ultra。
        XCTAssertFalse(after.contains("\"reasoning_effort\":\"ultra\""))
        XCTAssertFalse(after.contains("\"effort\":\"ultra\""))
        XCTAssertTrue(after.contains("deepseek_go"))
        XCTAssertTrue(after.contains("deepseek-v4-flash"))
        // 必须能被逐行解析且行数不减少
        let nBefore = before.split(separator: "\n").count
        let nAfter = after.split(separator: "\n").count
        XCTAssertEqual(nAfter, nBefore, "重写不应丢失行")
        print("E2E: \(result.message)")
    }
}
