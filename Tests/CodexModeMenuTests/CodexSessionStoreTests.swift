import XCTest
@testable import CodexModeMenuCore

final class CodexSessionStoreTests: XCTestCase {
    func testListSessionsReturnsData() {
        let sessions = CodexSessionStore.listSessions(options: .init(limit: 10))
        XCTAssertFalse(sessions.isEmpty, "应能读到本地会话索引")
        print("SMOKE_TEST 会话数: \(sessions.count)")
        for s in sessions.prefix(10) {
            let time = s.updatedAt.map { "\($0)" } ?? "?"
            print("SMOKE_TEST \(s.modeLabel) | \(s.title.prefix(30)) | \(time) | \(s.provider ?? "-") | \(s.cwd ?? "-")")
        }
    }

    func testListGroupedSessionsGroupsByProject() {
        let groups = CodexSessionStore.listGroupedSessions(
            options: .init(limit: 60, perProjectLimit: 6)
        )
        XCTAssertFalse(groups.isEmpty, "应至少有一个项目分组")

        print("SMOKE_TEST 分组数: \(groups.count)")
        for g in groups {
            print("SMOKE_TEST 项目: \(g.name) (\(g.sessions.count) 条)")
            for s in g.sessions {
                let time = s.updatedAt.map { "\($0)" } ?? "?"
                print("  - \(s.modeLabel) | \(s.title.prefix(30)) | \(time)")
            }
        }

        // 常见项目应存在（用户日常项目）
        let names = groups.map { $0.name }
        XCTAssertTrue(names.contains("WubiHelper"), "应包含 WubiHelper 项目")

        // 未关联分组存在（历史会话并非都有项目归属）
        let hasUnassigned = names.contains("未关联")
        print("SMOKE_TEST 未关联分组存在: \(hasUnassigned)")

        // 每个分组内按时间倒序
        for g in groups {
            let times = g.sessions.map { $0.updatedAt ?? .distantPast }
            let sorted = times.sorted(by: >)
            XCTAssertEqual(times, sorted, "项目 \(g.name) 内应按时间倒序")
        }

        // 每项目条数不超过 perProjectLimit
        for g in groups {
            XCTAssertLessThanOrEqual(g.sessions.count, 6, "项目 \(g.name) 会话数超限")
        }
    }
}
