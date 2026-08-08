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
