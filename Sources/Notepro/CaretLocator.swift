// CaretLocator.swift — 用 Accessibility API 读取当前文字插入点（光标）的屏幕坐标
//
// 斜杠菜单要跟着「文字输入点」弹出，而不是鼠标位置。
// 思路：取系统焦点 UI 元素 → 拿它的选区范围 → 用 kAXBoundsForRangeParameterizedAttribute
// 求出该选区在屏幕上的矩形 → 取其左下角作为菜单锚点。
// 读不到（无权限/控件不支持）时返回 nil，由调用方退回鼠标位置。
import AppKit
import ApplicationServices

enum CaretLocator {
    /// 返回文字插入点在屏幕（Cocoa 坐标，原点左下）的位置；失败返回 nil
    static func caretScreenPoint() -> NSPoint? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()

        // 1) 焦点 UI 元素
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        let el = element as! AXUIElement

        // 2) 选区范围（光标处通常是 length=0 的范围）
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rv = rangeValue else { return nil }
        var range = CFRange(location: 0, length: 0)
        AXValueGetValue(rv as! AXValue, .cfRange, &range)

        // 3) 求该范围的屏幕矩形
        var boundsValue: CFTypeRef?
        let axRange = AXValueCreate(.cfRange, &range)!
        let err = AXUIElementCopyParameterizedAttributeValue(
            el, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &boundsValue)
        guard err == .success, let bv = boundsValue else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(bv as! AXValue, .cgRect, &rect)

        // rect 为空（某些控件 length=0 时返回 0 宽高但坐标有效）也能用其原点
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              !(rect.origin.x == 0 && rect.origin.y == 0) else { return nil }

        // 4) CG（原点主屏左上，Y 向下）→ Cocoa（原点主屏左下，Y 向上）
        let primaryH = NSScreen.screens.first?.frame.height ?? (NSScreen.main?.frame.height ?? 0)
        // 取光标矩形的左下角，菜单从这里向上长出更自然
        let cocoaX = rect.minX
        let cocoaY = primaryH - rect.maxY
        return NSPoint(x: cocoaX, y: cocoaY)
    }
}
