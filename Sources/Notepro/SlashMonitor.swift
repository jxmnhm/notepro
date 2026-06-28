// SlashMonitor.swift — 监听键盘，在备忘录前台时检测「/」输入（方案 A）
//
// 用 CGEventTap 以 listenOnly 方式监听 keyDown（不拦截、不改变你的输入）。
// 仅当备忘录是前台 App 且按下的字符是 "/" 时，回调通知 AppDelegate 在鼠标处弹 AI 菜单。
// 需要「辅助功能」权限——与执行 AI 动作用的是同一个权限，已授过即可。
import AppKit
import Carbon.HIToolbox

final class SlashMonitor {
    /// 检测到备忘录里输入「/」时回调（主线程）
    var onSlash: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let notesBundleID = "com.apple.Notes"

    func start() {
        // 已在运行就不重复装
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,                 // 只听不改，绝不影响正常打字
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<SlashMonitor>.fromOpaque(refcon).takeUnretainedValue()
                me.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return  // 没权限时 tapCreate 返回 nil，静默失败（执行动作时会引导授权）
        }

        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    private func notesIsFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == notesBundleID
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // tap 偶尔会被系统禁用（超时/输入过载），自动重启
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown, notesIsFrontmost() else { return }
        // 忽略带 Command/Control/Option 的组合键，只认纯粹的 "/"
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            return
        }
        // 读取实际输入的字符
        var len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &chars)
        guard len > 0 else { return }
        let s = String(utf16CodeUnits: chars, count: len)
        if s == "/" {
            DispatchQueue.main.async { [weak self] in self?.onSlash?() }
        }
    }

    deinit { stop() }
}
