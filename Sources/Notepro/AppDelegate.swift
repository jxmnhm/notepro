// AppDelegate.swift — 菜单栏常驻 + Notes 窗口内浮动 AI 按钮 + 点击弹出选项菜单
import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let tracker = NotesTracker()
    private let floatBtn = FloatingButton()
    private let settingsController = SettingsWindowController()
    private let slashMonitor = SlashMonitor()
    private let liveMarkdown = LiveMarkdown()
    private let radialMenu = RadialMenu()
    private var slashMode = false   // true 时菜单动作走 runSlash（删 / 并处理当前行）

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // 菜单栏 App
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        setupStatusItem()

        // 点浮动按钮 → 弹出 AI 选项菜单
        floatBtn.onClick = { [weak self] anchor in self?.showAIMenu(from: anchor) }

        // 跟踪备忘录：仅当备忘录是前台 App 时显示按钮（最可靠，避免全局悬浮）
        tracker.onUpdate = { [weak self] info in
            guard let self else { return }
            AIActions.notesBounds = info?.bounds
            if let info, info.isFrontmost, info.bounds.width > 0 {
                self.floatBtn.place(in: info.bounds, above: info.windowNumber)
            } else {
                self.floatBtn.hide()
                self.radialMenu.dismiss()   // 备忘录失去前台 → 顺带收起菜单
            }
        }
        tracker.start()

        // 输入 / 时（仅备忘录前台）在鼠标处弹出 AI 菜单
        slashMonitor.onSlash = { [weak self] in self?.showSlashMenu() }
        slashMonitor.start()

        // 实时 Markdown 自动格式化（行首打 # / ## / - [ ] 立即套用备忘录原生格式）
        liveMarkdown.start()

        // 没填 Key 时，AIActions 直接弹设置窗口（而不是报错）
        AIActions.openSettings = { [weak self] in self?.settingsController.show() }
    }

    // MARK: - 斜杠菜单（输入 / 触发，跟随文字插入点弹出）
    private func showSlashMenu() {
        slashMode = true
        let menu = buildAIMenu(includeSettings: false)
        // 优先用文字插入点（光标）位置；读不到再退回鼠标位置
        let loc = CaretLocator.caretScreenPoint() ?? NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: loc, in: nil)
    }

    // MARK: - AI 选项菜单（点击浮动按钮，从按钮上方竖直展开）
    private func showAIMenu(from anchor: NSView) {
        // 再点一次按钮 → 收起（开关式）
        if radialMenu.isShowing { radialMenu.dismiss(); return }
        slashMode = false
        let actions = ActionStore.load()
        let center = floatBtn.centerOnScreen()
        radialMenu.show(
            at: center,
            buttonDiameter: floatBtn.buttonDiameter,
            actions: actions,
            includeSettings: true,
            onPick: { [weak self] actionId in
                self?.slashMode = false
                AIActions.run(actionId: actionId) { _ in }
            },
            onSettings: { [weak self] in self?.settingsController.show() })
    }

    /// 构造 AI 动作菜单（浮动按钮和斜杠共用）。动作从 ActionStore 动态读取，可自定义。
    private func buildAIMenu(includeSettings: Bool) -> NSMenu {
        let menu = NSMenu()
        let actions = ActionStore.load()
        if actions.isEmpty {
            let empty = NSMenuItem(title: "（暂无动作，去设置里添加）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for act in actions {
            let mi = NSMenuItem(title: act.name, action: #selector(runAction(_:)), keyEquivalent: "")
            mi.representedObject = act.id   // 存动作 id
            mi.target = self
            menu.addItem(mi)
        }
        if includeSettings {
            menu.addItem(.separator())
            let s = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: "")
            s.target = self
            menu.addItem(s)
        }
        return menu
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let actionId = sender.representedObject as? String else { return }
        if slashMode {
            AIActions.runSlash(actionId: actionId) { _ in }
        } else {
            AIActions.run(actionId: actionId) { _ in }
        }
    }

    // MARK: - 主菜单（让设置窗口 ⌘V 等可用）
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 Notepro",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }

    // MARK: - 菜单栏图标
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles.rectangle.stack",
                                   accessibilityDescription: "Notepro")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "辅助功能权限…", action: #selector(openA11y), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Notepro", action: #selector(quitApp), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func openSettings() { settingsController.show() }
    @objc private func openA11y() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
