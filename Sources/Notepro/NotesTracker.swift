// NotesTracker.swift — 用 CGWindowList 跟踪「备忘录」窗口的位置、大小、层级与可见性
//
// 关键：CGWindowListCopyWindowInfo 拿窗口的 owner 名 / bounds / windowNumber，【不需要任何权限】。
// 用 windowNumber 让我们的浮动按钮 order 到 Notes 窗口正上方一层 —— 这样别的窗口盖住 Notes 时，
// 按钮也会一起被盖住（不再是全局置顶）。
import AppKit

struct NotesWindowInfo: Equatable {
    var bounds: CGRect      // 屏幕坐标（左上原点，CG 习惯）
    var windowNumber: Int   // Notes 主窗口的 CGWindowID
    var isFrontmost: Bool   // 备忘录是否是当前最前台 App（决定按钮显隐，最可靠）
}

final class NotesTracker {
    /// 回调：nil 表示备忘录没运行/没可见窗口；否则给出窗口几何 + 窗口号 + 是否前台
    var onUpdate: ((NotesWindowInfo?) -> Void)?

    private var timer: Timer?
    private var last: NotesWindowInfo?
    private let ownerNames: Set<String> = ["备忘录", "Notes"]
    private let notesBundleID = "com.apple.Notes"

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer?.tolerance = 0.02
        RunLoop.main.add(timer!, forMode: .common)
        tick()
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// 备忘录是否当前最前台 App（不需要任何权限）
    private func notesIsFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == notesBundleID
    }

    private func tick() {
        let info = currentNotesWindow()
        // 始终回调：点选 Notes 会改变前后台/层级，需每帧重判显隐 + 重新压到 Notes 上方
        last = info
        onUpdate?(info)
    }

    /// 找到备忘录最靠前的普通窗口（layer==0），返回其几何/窗口号 + 是否前台
    private func currentNotesWindow() -> NotesWindowInfo? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let front = notesIsFrontmost()
        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }   // 只看普通窗口层
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"],
                  let width = b["Width"], let height = b["Height"] else { continue }
            if ownerNames.contains(owner), width > 200, height > 200 {
                let num = w[kCGWindowNumber as String] as? Int ?? 0
                let rect = CGRect(x: x, y: y, width: width, height: height)
                return NotesWindowInfo(bounds: rect, windowNumber: num, isFrontmost: front)
            }
        }
        return nil
    }

    deinit { stop() }
}
