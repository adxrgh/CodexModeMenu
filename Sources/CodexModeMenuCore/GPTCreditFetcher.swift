import Foundation

/// 只读获取 ChatGPT 账号的 GPT/Codex 套餐额度。
///
/// 数据源：https://chatgpt.com/backend-api/wham/usage
/// 认证：~/.codex/auth.json 里的 ChatGPT access_token（与 Codex 本身同一登录态）。
/// 本类型只读查询，不修改任何外部状态。
public struct GPTCreditFetcher {
    public static let authURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/auth.json")
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public struct CreditStatus {
        public let planType: String?
        public let usedPercent: Int
        public let remainingPercent: Int
        public let limitReached: Bool
        public let resetAt: Date?
        public let creditsBalance: String?
        public let fetchedAt: Date

        public var summaryText: String {
            let plan = planType?.uppercased() ?? "GPT"
            if limitReached && remainingPercent <= 0 {
                return "\(plan) 额度: 已用尽"
            }
            return "\(plan) 额度: 剩余 \(remainingPercent)%"
        }

        /// 距离重置时间的倒计时文案（动态，随当前时间变化）。
        /// 示例：1天14小时 / 5小时23分 / 12分钟
        public var countdownText: String {
            guard let resetAt else { return "" }
            let seconds = max(0, Int(resetAt.timeIntervalSinceNow))
            if seconds <= 0 { return "重置倒计时: 即将重置" }
            let days = seconds / 86400
            let hours = (seconds % 86400) / 3600
            let minutes = max(1, (seconds % 3600) / 60)
            if days > 0 {
                return "重置倒计时: \(days)天\(hours)小时"
            } else if hours > 0 {
                return "重置倒计时: \(hours)小时\(minutes)分"
            } else {
                return "重置倒计时: \(minutes)分钟"
            }
        }

        public var detailText: String {
            let plan = planType?.uppercased() ?? "GPT"
            var parts = ["\(plan) 额度: 已用 \(usedPercent)% / 剩余 \(remainingPercent)%"]
            if !countdownText.isEmpty {
                parts.append(countdownText)
            }
            if let resetAt {
                parts.append("重置: \(Self.formatDate(resetAt))")
            }
            if let creditsBalance, creditsBalance != "0" {
                parts.append("Credits: \(creditsBalance)")
            }
            return parts.joined(separator: " · ")
        }

        private static func formatDate(_ date: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "MM-dd HH:mm"
            return f.string(from: date)
        }
    }

    /// 同步读取 auth.json 中的 access_token（只读）。
    public static func readAccessToken() -> String? {
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    /// 查询额度。失败返回 nil（不抛错）。
    /// 网络：默认 URLSession.shared —— macOS 自动读取系统代理（Clash Party 7890），
    /// 与 ChatGPT.app 同一网络路径，无需手动指定代理。
    /// 容错：最多重试 3 次（应对代理节点临时抖动）。
    /// 可选传入 token：测试时注入；缺省时从 auth.json 读取。
    public static func fetch(token: String? = nil, timeout: TimeInterval = 12, retries: Int = 3) -> CreditStatus? {
        guard let accessToken = token ?? readAccessToken() else {
            return nil
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "OAI-Language")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/126.0",
            forHTTPHeaderField: "User-Agent"
        )

        for attempt in 0..<max(1, retries) {
            if let status = performSingleRequest(request: request, timeout: timeout) {
                return status
            }
            if attempt < retries - 1 {
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
        return nil
    }

    private static func performSingleRequest(request: URLRequest, timeout: TimeInterval) -> CreditStatus? {
        // 同步请求（调用方已在后台队列执行）：用 dataTask + semaphore 等待。
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?

        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout)

        guard resultError == nil,
              let data = resultData,
              let http = resultResponse as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        return parse(json: json, fetchedAt: Date())
    }

    static func parse(json: [String: Any], fetchedAt: Date = Date()) -> CreditStatus? {
        // 空响应 / 无 rate_limit 视为无数据。
        guard json["rate_limit"] is [String: Any] || json["credits"] is [String: Any] else {
            return nil
        }
        let planType = json["plan_type"] as? String
        let rateLimit = json["rate_limit"] as? [String: Any]
        let primary = rateLimit?["primary_window"] as? [String: Any]
        let limitReached = rateLimit?["limit_reached"] as? Bool ?? false
        let usedPercent = (primary?["used_percent"] as? NSNumber)?.intValue ?? 0
        let resetAtEpoch = (primary?["reset_at"] as? NSNumber)?.doubleValue ?? 0
        let credits = json["credits"] as? [String: Any]
        let balance = credits?["balance"] as? String

        return CreditStatus(
            planType: planType,
            usedPercent: usedPercent,
            remainingPercent: max(0, 100 - usedPercent),
            limitReached: limitReached,
            resetAt: resetAtEpoch > 0 ? Date(timeIntervalSince1970: resetAtEpoch) : nil,
            creditsBalance: balance,
            fetchedAt: fetchedAt
        )
    }
}
