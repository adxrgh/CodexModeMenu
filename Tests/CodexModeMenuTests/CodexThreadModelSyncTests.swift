import XCTest
@testable import CodexModeMenuCore

final class CodexThreadModelSyncTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexThreadModelSyncTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func writeRollout(
        sessionProvider: String = "openai",
        threadSettingsModel: String = "gpt-5.6-sol",
        turnModel: String = "gpt-5.6-sol"
    ) -> URL {
        let url = tempDir.appendingPathComponent("rollout-2026-07-18T14-09-42-019f73d8-4a9c-7633-93d3-3ddad2299e8a.jsonl")
        let lines = [
            "{\"timestamp\":\"2026-07-18T06:09:45.337Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"019f73d8-4a9c-7633-93d3-3ddad2299e8a\",\"cwd\":\"/Users/bob/poet\",\"model_provider\":\"\(sessionProvider)\"}}",
            "{\"timestamp\":\"2026-07-18T06:09:46.706Z\",\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"019f73d8-5483-7ec0-a8b3-e05d073c8432\",\"model\":\"\(turnModel)\",\"effort\":\"ultra\",\"collaboration_mode\":{\"mode\":\"default\",\"settings\":{\"model\":\"\(turnModel)\",\"reasoning_effort\":\"ultra\"}}}}",
            "{\"timestamp\":\"2026-07-18T06:09:47.000Z\",\"type\":\"thread_settings_applied\",\"payload\":{\"type\":\"thread_settings_applied\",\"thread_settings\":{\"model\":\"\(threadSettingsModel)\",\"model_provider_id\":\"openai\",\"reasoning_effort\":\"ultra\",\"collaboration_mode\":{\"mode\":\"default\",\"settings\":{\"model\":\"\(threadSettingsModel)\",\"reasoning_effort\":\"ultra\"}}}}}",
            "{\"timestamp\":\"2026-07-18T06:09:48.000Z\",\"type\":\"task_started\",\"payload\":{\"type\":\"task_started\"}}"
        ]
        try! lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testGPTModeDoesNotModify() throws {
        let url = writeRollout()
        let original = try String(contentsOf: url, encoding: .utf8)
        _ = CodexThreadModelSync.syncToDeepSeekIfNeeded(
            threadID: "019f73d8-4a9c-7633-93d3-3ddad2299e8a",
            rolloutURL: url,
            targetMode: .gpt
        )
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testDeepSeekModeRewritesModelFields() throws {
        let url = writeRollout()
        let result = CodexThreadModelSync.syncToDeepSeekIfNeeded(
            threadID: "019f73d8-4a9c-7633-93d3-3ddad2299e8a",
            rolloutURL: url,
            targetMode: .deepseek
        )
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.synchronized)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"model_provider\":\"deepseek_go\""))
        XCTAssertFalse(text.contains("gpt-5.6-sol"))
        XCTAssertFalse(text.contains("\"model_provider_id\":\"openai\""))
        XCTAssertFalse(text.contains("\"ultra\""))
        // 非模型事件保持原样
        XCTAssertTrue(text.contains("task_started"))
    }

    func testAlreadyDeepSeekIsIdempotent() throws {
        let url = writeRollout(sessionProvider: "deepseek_go")
        let original = try String(contentsOf: url, encoding: .utf8)
        let result = CodexThreadModelSync.syncToDeepSeekIfNeeded(
            threadID: "019f73d8-4a9c-7633-93d3-3ddad2299e8a",
            rolloutURL: url,
            targetMode: .deepseek
        )
        XCTAssertTrue(result.success)
        XCTAssertFalse(result.synchronized)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }
}
