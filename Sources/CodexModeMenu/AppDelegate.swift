import AppKit
import CodexModeMenuCore


/// 历史会话引用：id + 会话原目录（用于 resume 时 cd 到原目录，避免目录选择交互界面）。
private struct SessionRef {
    let id: String
    let cwd: String?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let refreshInterval: TimeInterval = 2.0
    private static let codexBundleIdentifier = "com.openai.codex"
    private static let chatGPTAppURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    private static let clientModeJSONURL = URL(fileURLWithPath: "/Users/bob/.codex/codex-deepseek-go/client-mode.json")
    private static let codexBinaryPath = "/Applications/ChatGPT.app/Contents/Resources/codex"

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var currentMode = CodexConfigParser.parse()
    private var descriptionItem: NSMenuItem?
    private var historyMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        startTimer()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = currentMode.title
        statusItem = item

        let menu = NSMenu()
        menu.delegate = self

        let description = NSMenuItem(title: currentMode.detailDescription, action: nil, keyEquivalent: "")
        description.isEnabled = false
        descriptionItem = description
        menu.addItem(description)
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

    private func refreshMode() {
        currentMode = CodexConfigParser.parse()
        statusItem?.button?.title = currentMode.title
        descriptionItem?.title = currentMode.detailDescription
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
        openTerminalResume(sessionID: ref.id, cwd: ref.cwd)
    }

    @objc private func refreshHistory(_ sender: Any?) {
        refreshHistoryMenu()
    }

    /// 用 Terminal 打开一个真实终端窗口，运行 codex resume <id>。
    /// 先 cd 到会话原目录（避免 codex resume 的目录选择交互界面），
    /// 并跳过 hooks 审查界面（hooks 来源已在 config 中声明，属用户自有配置）。
    /// DeepSeek 全量模式下同样可用（resume 读取本地会话，不依赖登录态）。
    private func openTerminalResume(sessionID: String, cwd: String?) {
        let codexPath = Self.codexBinaryPath
        var command = "\(codexPath) resume --dangerously-bypass-hook-trust \(sessionID)"
        if let cwd, !cwd.isEmpty {
            command = "cd \(shellQuote(cwd)) && \(command)"
        }
        let script = "do script \"\(command)\""
        let source = "tell application \\\"Terminal\\\"\nactivate\n\(script)\nend tell"

        var error: NSDictionary?
        let appleScript = NSAppleScript(source: source)
        appleScript?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "无法打开终端"
            showAlert(title: "打开终端失败", message: message)
        }
    }

    /// 对路径做 shell 单引号转义（用于 AppleScript 字符串内嵌的 shell 命令）。
    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
