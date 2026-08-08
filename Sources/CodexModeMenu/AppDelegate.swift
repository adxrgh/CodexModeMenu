import AppKit
import CodexModeMenuCore


/// 历史会话引用：id + 会话原目录（用于 resume 时 cd 到原目录，避免目录选择交互界面）。
private struct SessionRef {
    let id: String
    let cwd: String?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let refreshInterval: TimeInterval = 2.0
    private static let creditRefreshInterval: TimeInterval = 60.0
    private static let codexBundleIdentifier = "com.openai.codex"
    private static let chatGPTAppURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    private static let clientModeJSONURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/codex-deepseek-go/client-mode.json")

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var creditTimer: Timer?
    private var currentMode = CodexConfigParser.parse()
    /// 当前状态栏基础标题（模式标题，不含额度后缀）
    private var lastBaseTitle = ""
    /// 额度后缀（如 " ▸ 剩余 0%"），刷新完成后更新
    private var lastCreditSuffix = ""
    private var descriptionItem: NSMenuItem?
    private var historyMenu: NSMenu?
    private var creditItem: NSMenuItem?
    private var creditRefreshInFlight = false
    private var lastCreditText = "GPT 额度: 加载中…"
    /// 最近一次成功获取的额度状态，用于本地动态刷新重置倒计时（不重复请求接口）。
    private var lastCreditStatus: GPTCreditFetcher.CreditStatus?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        startTimer()
        startCreditTimer()
        refreshGPTCredit()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        lastBaseTitle = currentMode.title
        item.button?.title = currentMode.title
        statusItem = item

        let menu = NSMenu()
        menu.delegate = self

        let description = NSMenuItem(title: currentMode.detailDescription, action: nil, keyEquivalent: "")
        description.isEnabled = false
        descriptionItem = description
        menu.addItem(description)

        // GPT 额度行：只读显示 ChatGPT 套餐额度（每周用量/重置时间），点击可立即刷新。
        let credit = NSMenuItem(title: lastCreditText, action: #selector(refreshGPTCredit(_:)), keyEquivalent: "")
        credit.target = self
        creditItem = credit
        menu.addItem(credit)
        menu.addItem(.separator())

        menu.addItem(makeItem(title: "切换到 GPT 主控模式", action: #selector(switchToGPT(_:))))
        menu.addItem(makeItem(title: "切换到 DeepSeek 全量模式", action: #selector(switchToDeepSeek(_:))))
        menu.addItem(.separator())

        // 历史对话子菜单：点击打开（菜单打开时动态填充）
        let history = NSMenuItem(title: "历史对话", action: nil, keyEquivalent: "")
        let historyMenu = NSMenu()
        history.submenu = historyMenu
        self.historyMenu = historyMenu
        menu.addItem(history)
        menu.addItem(.separator())

        menu.addItem(makeItem(title: "打开 Codex", action: #selector(openCodex(_:))))
        menu.addItem(makeItem(title: "打开模式记录", action: #selector(openClientModeJSON(_:))))
        menu.addItem(.separator())

        menu.addItem(makeItem(title: "退出菜单栏工具", action: #selector(quitApp(_:))))

        item.menu = menu
    }

    private func makeItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func startTimer() {
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshMode()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refreshMode()
    }

    /// 额度独立定时器：避免跟随 2 秒 tick 频繁请求 wham/usage。
    private func startCreditTimer() {
        let timer = Timer(timeInterval: Self.creditRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshGPTCredit(nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.creditTimer = timer
    }

    /// 统一更新状态栏标题：基础标题（模式）+ 额度后缀。
    /// 只在标题实际变化时赋值，避免每 tick 重置导致闪烁。
    private func updateStatusTitle() {
        let base = lastBaseTitle.isEmpty ? currentMode.title : lastBaseTitle
        let title = base + lastCreditSuffix
        if statusItem?.button?.title != title {
            statusItem?.button?.title = title
        }
    }

    private func refreshMode() {
        currentMode = CodexConfigParser.parse()
        let newBase = currentMode.title
        if newBase != lastBaseTitle {
            lastBaseTitle = newBase
            updateStatusTitle()
        }
        descriptionItem?.title = currentMode.detailDescription
        // 倒计时是本地时间差，跟随 tick 动态刷新菜单文案（无需重新请求接口）
        refreshCreditCountdownIfNeeded()
    }

    /// 有缓存额度时，用当前时间重算重置倒计时，并同步更新菜单项文案与状态栏标题。
    /// 跟随 2 秒 tick 调用，倒计时秒级走动且不重复请求接口。
    private func refreshCreditCountdownIfNeeded() {
        guard let status = lastCreditStatus else { return }
        let title = status.summaryText + " · " + status.countdownText
        if creditItem?.title != title {
            creditItem?.title = title
        }
        // 状态栏标题附上额度与倒计时：Codex•DS ▸ 剩余 0% · 重置 2天6小时
        let suffix = status.countdownSuffix
        if lastCreditSuffix != suffix {
            lastCreditSuffix = suffix
            updateStatusTitle()
        }
    }

    // MARK: - GPT 额度

    /// 刷新 GPT 额度显示。网络请求放到后台队列，完成后再回主线程更新菜单项。
    /// showSpinner=true 时（用户点击/启动）先把文案切到“加载中”，否则保留上一次值。
    @objc private func refreshGPTCredit(_ sender: Any? = nil) {
        let showSpinner = sender != nil || creditItem?.title.contains("加载中") == true
        guard !creditRefreshInFlight else { return }
        creditRefreshInFlight = true
        if showSpinner {
            creditItem?.title = "GPT 额度: 加载中…"
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = GPTCreditFetcher.fetch()
            DispatchQueue.main.async {
                guard let self else { return }
                self.creditRefreshInFlight = false
                if let status {
                    self.lastCreditStatus = status
                    self.lastCreditText = status.summaryText
                    // 统一由 refreshCreditCountdownIfNeeded 更新菜单项与状态栏标题
                    self.refreshCreditCountdownIfNeeded()
                } else {
                    self.lastCreditStatus = nil
                    self.lastCreditText = "GPT 额度: 未获取"
                    self.creditItem?.title = "GPT 额度: 未获取"
                    if !self.lastCreditSuffix.isEmpty {
                        self.lastCreditSuffix = ""
                        self.updateStatusTitle()
                    }
                }
            }
        }
    }

    // MARK: - 切换动作

    @objc private func switchToGPT(_ sender: Any?) {
        performSwitch(to: .gpt)
    }

    @objc private func switchToDeepSeek(_ sender: Any?) {
        performSwitch(to: .deepseek)
    }

    private func performSwitch(to kind: CodexModeKind) {
        guard confirmSwitch(to: kind) else { return }

        let result = CodexModeSwitcher.switchMode(to: kind)
        guard result.isSuccess else {
            let message = result.error.isEmpty ? result.output : result.error
            showAlert(title: "切换失败", message: message.isEmpty ? "未知错误（退出码 \(result.exitCode)）" : message)
            return
        }
        relaunchCodex()
    }

    private func confirmSwitch(to kind: CodexModeKind) -> Bool {
        let modeName = kind == .gpt ? "GPT 主控" : "DeepSeek 全量"
        let alert = NSAlert()
        alert.messageText = "切换模式"
        alert.informativeText = "确定要切换到 \(modeName) 模式吗？切换成功后将重启 Codex。"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - 历史对话

    /// 刷新“历史对话”子菜单内容（菜单打开时调用），按项目分组。
    private func refreshHistoryMenu() {
        guard let menu = historyMenu else { return }
        menu.removeAllItems()

        let groups = CodexSessionStore.listGroupedSessions(
            options: .init(limit: 60, perProjectLimit: 6)
        )
        let total = groups.reduce(0) { $0 + $1.sessions.count }
        if groups.isEmpty || total == 0 {
            let empty = NSMenuItem(title: "暂无历史对话", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            menu.addItem(.separator())
            menu.addItem(makeItem(title: "刷新列表", action: #selector(refreshHistory(_:))))
            return
        }

        for group in groups {
            let projectItem = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu()

            if group.sessions.count == 1 {
                // 单条时直接显示为可点击项，减少一层嵌套。
                let session = group.sessions[0]
                let item = NSMenuItem(title: displayTitle(for: session), action: #selector(resumeSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = SessionRef(id: session.id, cwd: session.cwd)
                submenu.addItem(item)
            } else {
                for session in group.sessions {
                    let item = NSMenuItem(title: displayTitle(for: session), action: #selector(resumeSession(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = SessionRef(id: session.id, cwd: session.cwd)
                    submenu.addItem(item)
                }
            }

            projectItem.submenu = submenu
            menu.addItem(projectItem)
        }

        menu.addItem(.separator())
        menu.addItem(makeItem(title: "刷新列表", action: #selector(refreshHistory(_:))))
    }

    private func displayTitle(for session: CodexSession) -> String {
        let mode = session.modeLabel
        let time = shortTimeString(session.updatedAt)
        var title = session.title
        // 控制菜单宽度：标题截断到约 36 个字符
        if title.count > 36 {
            title = String(title.prefix(36)) + "…"
        }
        return "[\(mode)] \(title)  \(time)"
    }

    private func shortTimeString(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    @objc private func resumeSession(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? SessionRef, !ref.id.isEmpty else {
            return
        }
        openInCodexApp(sessionID: ref.id)
    }

    @objc private func refreshHistory(_ sender: Any?) {
        refreshHistoryMenu()
    }

    /// 直接在 Codex 桌面应用（ChatGPT.app）内打开/继续本地会话。
    /// 通过官方 deep link codex://threads/<session-id>：
    /// App 主进程会把该 URL 解析为本地会话（localConversation 路由），
    /// 读取本地 rollout 后导航到 /local/<conversationId> 并 resume。
    /// 该路径读取 ~/.codex/sessions 本地文件，不依赖 ChatGPT 登录 token，
    /// 因此在 DeepSeek 全量模式下同样可用（2026-08-07 已在 App 日志验证：
    /// thread/read → thread/resume → maybe_resume_success，routePath=/local/<id>）。
    private func openInCodexApp(sessionID: String) {
        guard let url = URL(string: "codex://threads/\(sessionID)") else {
            showAlert(title: "打开会话失败", message: "无法构造会话链接")
            return
        }
        let didOpen = NSWorkspace.shared.open(url)
        if !didOpen {
            showAlert(title: "打开会话失败", message: "Codex 无法打开该会话链接")
        }
    }

    // MARK: - 重启 Codex / 打开外部目标

    private func relaunchCodex() {
        let bundleIdentifier = Self.codexBundleIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            app.terminate()
        }

        // 在后台等待退出（最多 5 秒），避免阻塞主线程菜单。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
                    break
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            DispatchQueue.main.async {
                self?.openChatGPTApp()
            }
        }
    }

    private func openChatGPTApp() {
        NSWorkspace.shared.openApplication(
            at: Self.chatGPTAppURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error = error {
                NSLog("打开 ChatGPT.app 失败：%@", error.localizedDescription)
            }
        }
    }

    @objc private func openCodex(_ sender: Any?) {
        // Codex 现已整合进 ChatGPT.app：直接打开它。
        openChatGPTApp()
    }

    @objc private func openClientModeJSON(_ sender: Any?) {
        NSWorkspace.shared.open(Self.clientModeJSONURL)
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // 菜单打开时刷新“当前模式说明”与“历史对话”列表。
        refreshMode()
        refreshHistoryMenu()
    }
}
