// FloatingButton.swift — 画在备忘录窗口【内部】右下角的悬浮 AI 按钮
//
// 用一个极小的无边框、可点击但不抢焦点的窗口（NSPanel），定位到 Notes 窗口内部右下角。
// 点击它弹出 AI 选项菜单。窗口跟随 Notes 移动/缩放/前后台切换。
import AppKit

@MainActor
final class FloatingButton {
    private let panel: NSPanel
    private let button: NSButton
    private let diameter: CGFloat = 46
    private let margin: CGFloat = 18      // 离窗口右下角的内边距

    /// 点击按钮的回调（由外部弹菜单）
    var onClick: ((NSView) -> Void)?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: diameter, height: diameter),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = false
        panel.level = .normal                 // 普通层级：不再全局置顶
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        // 只在当前 Space 出现，不再 canJoinAllSpaces（那会让它像全局浮层）
        panel.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]

        // 圆形渐变按钮
        button = NSButton(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.title = ""
        button.wantsLayer = true
        button.imagePosition = .imageOnly
        if let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            button.image = img.withSymbolConfiguration(cfg)
            button.contentTintColor = .white
        }
        styleLayer(button.layer!)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        host.addSubview(button)
        panel.contentView = host

        button.target = self
        button.action = #selector(clicked)
    }

    private func styleLayer(_ layer: CALayer) {
        layer.cornerRadius = diameter / 2
        layer.masksToBounds = true
        let grad = CAGradientLayer()
        grad.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        grad.colors = [NSColor(calibratedRed: 0.45, green: 0.35, blue: 0.95, alpha: 1).cgColor,
                       NSColor(calibratedRed: 0.30, green: 0.55, blue: 0.98, alpha: 1).cgColor]
        grad.startPoint = CGPoint(x: 0, y: 0)
        grad.endPoint = CGPoint(x: 1, y: 1)
        grad.cornerRadius = diameter / 2
        layer.insertSublayer(grad, at: 0)
    }

    @objc private func clicked() {
        onClick?(button)
    }

    /// 把按钮定位到 Notes 窗口内部右下角，并把它 order 到 Notes 窗口正上方一层。
    /// notesBounds 为 CG 全局显示坐标（原点=主屏左上角，Y 向下）；notesWindowNumber 为 Notes 主窗口号。
    func place(in notesBounds: CGRect, above notesWindowNumber: Int) {
        // CG（原点主屏左上，Y 向下）→ Cocoa（原点主屏左下，Y 向上）。
        // 翻转基准必须是【主屏高度】，不能用所有屏幕 maxY 的最大值——
        // 多屏（尤其第二块屏在上方）时后者会把屏幕叠加高度算进去，导致按钮越跑越远。
        let primaryH = NSScreen.screens.first?.frame.height ?? (NSScreen.main?.frame.height ?? 0)
        let cocoaX = notesBounds.maxX - diameter - margin
        let cocoaY = primaryH - notesBounds.maxY + margin   // 窗口底边往上留 margin
        panel.setFrameOrigin(NSPoint(x: cocoaX, y: cocoaY))
        if !panel.isVisible { panel.orderFront(nil) }
        // 关键：紧贴 Notes 窗口上方一层。Notes 被别的窗口盖住时，按钮也随之被盖住。
        if notesWindowNumber > 0 {
            panel.order(.above, relativeTo: notesWindowNumber)
        }
    }

    func show() { if !panel.isVisible { panel.orderFront(nil) } }
    func hide()  { if panel.isVisible { panel.orderOut(nil) } }
    var isVisible: Bool { panel.isVisible }

    /// 按钮直径（供扇形/竖直菜单定位）
    var buttonDiameter: CGFloat { diameter }

    /// 按钮中心在屏幕坐标系（Cocoa，原点左下）的位置——供菜单锚定
    func centerOnScreen() -> NSPoint {
        let f = panel.frame
        return NSPoint(x: f.midX, y: f.midY)
    }
}
