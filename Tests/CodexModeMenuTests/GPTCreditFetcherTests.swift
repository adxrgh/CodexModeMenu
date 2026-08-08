import XCTest
@testable import CodexModeMenuCore

final class GPTCreditFetcherTests: XCTestCase {
    func testParseUsageJSON() throws {
        // 2026-08-08 实测返回结构（已脱敏）
        let json: [String: Any] = [
            "plan_type": "pro",
            "rate_limit": [
                "allowed": false,
                "limit_reached": true,
                "primary_window": [
                    "used_percent": 100,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 203292,
                    "reset_at": 1786352039
                ],
                "secondary_window": NSNull()
            ],
            "credits": [
                "has_credits": false,
                "unlimited": false,
                "overage_limit_reached": false,
                "balance": "0"
            ],
            "rate_limit_reset_credits": [
                "available_count": 0,
                "applicable_available_count": 0
            ]
        ]

        let status = try XCTUnwrap(GPTCreditFetcher.parse(json: json))
        XCTAssertEqual(status.planType, "pro")
        XCTAssertEqual(status.usedPercent, 100)
        XCTAssertEqual(status.remainingPercent, 0)
        XCTAssertTrue(status.limitReached)
        XCTAssertEqual(status.resetAt?.timeIntervalSince1970, 1786352039)
        XCTAssertEqual(status.creditsBalance, "0")
        XCTAssertEqual(status.summaryText, "PRO 额度: 已用尽")
        XCTAssertTrue(status.detailText.contains("重置: "))
        // 倒计时文案：基于 resetAt 与当前时间差，应为 X天X小时 或更细粒度
        XCTAssertFalse(status.countdownText.isEmpty)
        XCTAssertTrue(status.countdownText.hasPrefix("重置倒计时:"))
    }

    func testCountdownText() throws {
        let now = Date()
        // 2天3小时后的重置
        let in2d3h = now.addingTimeInterval(2 * 86400 + 3 * 3600 + 120)
        let s1 = GPTCreditFetcher.CreditStatus(
            planType: "pro", usedPercent: 50, remainingPercent: 50,
            limitReached: false, resetAt: in2d3h, creditsBalance: nil, fetchedAt: now
        )
        XCTAssertEqual(s1.countdownText, "重置倒计时: 2天3小时")

        // 5小时23分后的重置
        let in5h23m = now.addingTimeInterval(5 * 3600 + 23 * 60 + 30)
        let s2 = GPTCreditFetcher.CreditStatus(
            planType: "pro", usedPercent: 50, remainingPercent: 50,
            limitReached: false, resetAt: in5h23m, creditsBalance: nil, fetchedAt: now
        )
        XCTAssertEqual(s2.countdownText, "重置倒计时: 5小时23分")

        // 12分钟后的重置
        let in12m = now.addingTimeInterval(12 * 60 + 10)
        let s3 = GPTCreditFetcher.CreditStatus(
            planType: "pro", usedPercent: 50, remainingPercent: 50,
            limitReached: false, resetAt: in12m, creditsBalance: nil, fetchedAt: now
        )
        XCTAssertEqual(s3.countdownText, "重置倒计时: 12分钟")

        // 无重置时间
        let s4 = GPTCreditFetcher.CreditStatus(
            planType: "pro", usedPercent: 50, remainingPercent: 50,
            limitReached: false, resetAt: nil, creditsBalance: nil, fetchedAt: now
        )
        XCTAssertEqual(s4.countdownText, "")
        // 无重置时间时状态栏后缀只带剩余
        XCTAssertEqual(s4.countdownSuffix, " ▸ 剩余 50%")
    }

    func testCountdownSuffix() throws {
        let now = Date()
        // 已用尽 + 重置倒计时 2天（用 hasPrefix 避免毫秒级流逝导致的进位抖动）
        let in2d = now.addingTimeInterval(2 * 86400 + 3 * 3600 + 5 * 60)
        let s1 = GPTCreditFetcher.CreditStatus(
            planType: "pro", usedPercent: 100, remainingPercent: 0,
            limitReached: true, resetAt: in2d, creditsBalance: nil, fetchedAt: now
        )
        XCTAssertTrue(s1.countdownSuffix.hasPrefix(" ▸ 已用尽 · 重置2天"))

        // 剩余 65% + 5小时
        let in5h = now.addingTimeInterval(5 * 3600 + 23 * 60 + 5 * 60)
        let s2 = GPTCreditFetcher.CreditStatus(
            planType: "plus", usedPercent: 35, remainingPercent: 65,
            limitReached: false, resetAt: in5h, creditsBalance: nil, fetchedAt: now
        )
        XCTAssertTrue(s2.countdownSuffix.hasPrefix(" ▸ 剩余 65% · 重置5小时"))
    }

    func testParsePartialJSON() {
        let json: [String: Any] = [
            "plan_type": "plus",
            "rate_limit": [
                "limit_reached": false,
                "primary_window": ["used_percent": 35]
            ]
        ]
        let status = GPTCreditFetcher.parse(json: json)
        XCTAssertEqual(status?.planType, "plus")
        XCTAssertEqual(status?.usedPercent, 35)
        XCTAssertEqual(status?.remainingPercent, 65)
        XCTAssertFalse(status?.limitReached ?? true)
        XCTAssertNil(status?.resetAt)
        XCTAssertEqual(status?.summaryText, "PLUS 额度: 剩余 65%")
    }

    func testParseEmpty() {
        XCTAssertNil(GPTCreditFetcher.parse(json: [:]))
    }
}
