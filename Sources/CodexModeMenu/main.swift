import AppKit

// 菜单栏应用入口：LSUIElement 等价行为（仅菜单栏，不占 Dock）。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
