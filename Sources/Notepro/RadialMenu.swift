// RadialMenu.swift — 从浮动按钮向上展开的竖直列表菜单
//
// 按钮在备忘录窗口右下角，菜单从按钮上方向【上】依次展开一列。
// 每行是一个胶囊条（图标 + 文字），右对齐于按钮，宽度统一，从下往上逐条淡入弹出。
// 用无边框透明 NSPanel 承载，点击行执行、点空白关闭。
import AppKit

@MainActor
final class RadialMenu {
    private var panel: NSPanel?
    private var onPick: ((String) -> Void)?
    private var onSettings: (() -> Void)?

    private let rowH: CGFloat = 40       // 每行高度
    private let rowGap: CGFloat = 8      // 行间距
    private let rowW: CGFloat = 168      // 行宽
    private let gapAboveButton: CGFloat = 14   // 第一行离按钮顶部的间距

    /// 在按钮中心 center（屏幕 Cocoa 坐标）上方弹出竖直菜单
    func show(at center: NSPoint,
              buttonDiameter: CGFloat,
              actions: [PromptAction],
              includeSettings: Bool,
              onPick: @escaping (String) -> Void,
              onSettings: @escaping () -> Void) {
        dismiss()
        self.onPick = onPick
        self.onSettings = onSettings

        var items: [(id: String?, name: String, symbol: String)] =
            actions.map { ($0.id, $0.name, $0.isGenerate ? "bubble.left.and.text.bubble.right" : "wand.and.stars") }
        if includeSettings { items.append((nil, "设置", "gearshape")) }

        let n = items.count
        let stackH = CGFloat(n) * rowH + CGFloat(max(0, n - 1)) * rowGap
        let pad: CGFloat = 16   // 画布四周留白（给阴影/动画余量）

        // 画布：宽 = 行宽 + 留白；高 = 列高 + 按钮间距 + 留白
        let canvasW = rowW + pad * 2
        let canvasH = stackH + gapAboveButton + pad * 2
        // 让菜单列的右边缘与按钮右边缘对齐，底部从按钮上方开始
        let originX = center.x + buttonDiameter / 2 - rowW - pad
        let originY = center.y + buttonDiameter / 2 + gapAboveButton - pad
        let frame = NSRect(x: originX, y: originY, width: canvasW, height: canvasH)

        let p = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let canvas = ClickThroughView(frame: NSRect(origin: .zero, size: frame.size))
        canvas.onBackgroundClick = { [weak self] in self?.dismiss() }
        p.contentView = canvas

        // 从底部往上排：i=0 在最下（离按钮最近）
        for (i, item) in items.enumerated() {
            let y = pad + CGFloat(i) * (rowH + rowGap)
            let row = MenuRowView(frame: NSRect(x: pad, y: y, width: rowW, height: rowH),
                                  name: item.name, symbol: item.symbol)
            row.onClick = { [weak self] in
                guard let self else { return }
                let pickedID = item.id
                self.dismiss()
                if let pickedID { self.onPick?(pickedID) } else { self.onSettings?() }
            }
            canvas.addSubview(row)

            // 逐条从下往上淡入 + 轻微上移
            row.wantsLayer = true
            row.layer?.opacity = 0
            let delay = Double(i) * 0.04
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = -12; move.toValue = 0
            move.duration = 0.28
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.05)
            move.beginTime = CACurrentMediaTime() + delay
            move.fillMode = .backwards
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1
            fade.duration = 0.2; fade.beginTime = CACurrentMediaTime() + delay
            fade.fillMode = .backwards
            row.layer?.add(move, forKey: "in")
            row.layer?.add(fade, forKey: "fade")
            row.layer?.opacity = 1
        }

        p.makeKeyAndOrderFront(nil)
        self.panel = p
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// 菜单当前是否在显示（供"再点收回"判断）
    var isShowing: Bool { panel != nil }
}

// MARK: - 点击空白处关闭
private final class ClickThroughView: NSView {
    var onBackgroundClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if hitTest(p) === self { onBackgroundClick?() } else { super.mouseDown(with: event) }
    }
    override var isFlipped: Bool { false }
}

// MARK: - 单行：胶囊背景 + 图标 + 文字
private final class MenuRowView: NSView {
    var onClick: (() -> Void)?
    private let bg = NSView()
    private var tracking: NSTrackingArea?

    init(frame: NSRect, name: String, symbol: String) {
        super.init(frame: frame)
        wantsLayer = true

        // 毛玻璃胶囊背景
        bg.frame = bounds
        bg.wantsLayer = true
        bg.layer?.cornerRadius = bounds.height / 2
        bg.layer?.masksToBounds = false
        bg.layer?.backgroundColor = NSColor(white: 0.14, alpha: 0.92).cgColor
        bg.layer?.shadowColor = NSColor.black.cgColor
        bg.layer?.shadowOpacity = 0.3
        bg.layer?.shadowRadius = 8
        bg.layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(bg)

        // 左侧圆形渐变图标
        let d = bounds.height - 10
        let iconWrap = NSView(frame: NSRect(x: 5, y: 5, width: d, height: d))
        iconWrap.wantsLayer = true
        iconWrap.layer?.cornerRadius = d / 2
        iconWrap.layer?.masksToBounds = true
        let grad = CAGradientLayer()
        grad.frame = iconWrap.bounds
        grad.colors = [NSColor(calibratedRed: 0.45, green: 0.35, blue: 0.95, alpha: 1).cgColor,
                       NSColor(calibratedRed: 0.30, green: 0.55, blue: 0.98, alpha: 1).cgColor]
        grad.startPoint = CGPoint(x: 0, y: 0); grad.endPoint = CGPoint(x: 1, y: 1)
        iconWrap.layer?.insertSublayer(grad, at: 0)
        let icon = NSImageView(frame: iconWrap.bounds)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: name) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            icon.image = img.withSymbolConfiguration(cfg)
            icon.contentTintColor = .white
        }
        icon.imageScaling = .scaleProportionallyDown
        iconWrap.addSubview(icon)
        addSubview(iconWrap)

        // 文字
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .left
        if let cell = label.cell { cell.usesSingleLineMode = true }
        // 文字框高度用实际行高，再整体垂直居中——避免高度占满整行导致文字被裁/错位
        let lh = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: d + 14,
                             y: (bounds.height - lh) / 2,
                             width: bounds.width - d - 22,
                             height: lh)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) {
        bg.layer?.backgroundColor = NSColor(calibratedRed: 0.32, green: 0.40, blue: 0.95, alpha: 0.95).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        bg.layer?.backgroundColor = NSColor(white: 0.14, alpha: 0.92).cgColor
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
