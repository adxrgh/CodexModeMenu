import AppKit
import CodexModeMenuCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let refreshInterval: TimeInterval = 2.0
    private static let codexBundleIdentifier = "com.openai.codex"
    private static let chatGPTAppURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    private static let clientModeJSONURL = URL(fileURLWithPath: "/Users/bob/.codex/codex-deepseek-go/client-mode.json")

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var currentMode = CodexConfigParser.parse()
    private var descriptionItem: NSMenuItem?

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
        // 菜单打开时刷新“当前模式说明”。
        refreshMode()
    }
}
