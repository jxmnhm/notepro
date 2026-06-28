// SettingsWindowController.swift — 标准设置窗口（输入正常，⌘V 可用）
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if let w = window {
            activate(); w.makeKeyAndOrderFront(nil); w.center(); return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        w.title = "Notepro 设置"
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 460, height: 460)
        w.contentView = NSHostingView(rootView: SettingsView())
        w.center()
        w.delegate = self
        window = w
        activate()
        w.makeKeyAndOrderFront(nil)
    }

    private func activate() {
        NSApp.setActivationPolicy(.regular)   // 临时变前台 App 才能接收键盘
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // 关闭后回到菜单栏模式
    }
}
