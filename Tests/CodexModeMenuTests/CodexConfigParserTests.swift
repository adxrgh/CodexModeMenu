import XCTest
@testable import CodexModeMenuCore

final class CodexConfigParserTests: XCTestCase {
    func testTopLevelGPT() {
        let text = """
        # 顶层配置
        model = "gpt-5.2-codex"
        model_provider = "openai"

        [model]
        model = "deepseek-r1"
        model_provider = "deepseek_go"
        """
        let mode = CodexConfigParser.parse(text: text)
        XCTAssertEqual(mode.kind, .gpt)
        XCTAssertEqual(mode.model, "gpt-5.2-codex")
        XCTAssertEqual(mode.provider, "openai")
        XCTAssertEqual(mode.title, "Codex · GPT")
    }

    func testTopLevelDeepSeek() {
        let text = """
        model = "deepseek-v4-flash"
        model_provider = "deepseek_go"

        [other]
        model = "gpt-5"
        model_provider = "openai"
        """
        let mode = CodexConfigParser.parse(text: text)
        XCTAssertEqual(mode.kind, .deepseek)
        XCTAssertEqual(mode.model, "deepseek-v4-flash")
        XCTAssertEqual(mode.provider, "deepseek_go")
        XCTAssertEqual(mode.title, "Codex · DS")
    }

    func testUnknown() {
        let text = """
        model = "claude-sonnet"
        model_provider = "anthropic"
        """
        let mode = CodexConfigParser.parse(text: text)
        XCTAssertEqual(mode.kind, .unknown)
        XCTAssertEqual(mode.title, "Codex · ?")
    }

    func testSectionKeysIgnored() {
        // section 内同名键不属于顶层，应完全忽略。
        let text = """
        [model]
        model = "gpt-5"
        model_provider = "openai"
        """
        let mode = CodexConfigParser.parse(text: text)
        XCTAssertEqual(mode.kind, .unknown)
        XCTAssertNil(mode.model)
        XCTAssertNil(mode.provider)
        XCTAssertEqual(mode.title, "Codex · ?")
    }
}
