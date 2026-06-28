// LiveMarkdown.swift — 实时 Markdown 自动格式化
//
// 卖点功能：在备忘录里行首打出 Markdown 标记（如「# 」），立刻套用备忘录的原生格式
// （标题变大变粗）。原理：用可拦截的 CGEventTap 跟踪「当前行行首已输入的字符」，
// 当用户打到触发空格、且行首正好是某个 Markdown 前缀时：
//   1) 拦截（吞掉）这个空格
//   2) 合成 N 次退格删掉已打的标记符号（如「#」「-」「[ ]」）
//   3) 合成备忘录原生格式快捷键（标题=⇧⌘H/T/J、清单=⇧⌘L、引用=⇧⌘B 等）
// 注入的合成事件打上特殊 userData 标记，被本监听器自己忽略，避免递归。
import AppKit
import Carbon.HIToolbox

final class LiveMarkdown {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let notesBundleID = "com.apple.Notes"

    // 本程序注入事件的标记值，回环时跳过
    private let injectedField: Int64 = 0x4E50          // "NP"
    private let injectedMagic: Int64 = 0x4E50_4D44     // 任意独特值

    // 当前行行首缓冲（只跟踪到第一个空格前的"前缀候选"）
    private var lineBuffer = ""
    private var atLineStart = true   // 光标是否在行首区域（还没打过正文）

    // 压缩标记（去掉所有空格后）→ 备忘录原生格式快捷键
    // 备忘录默认快捷键：大标题=⇧⌘T(0x11) 标题=⇧⌘H(0x04) 小标题=⇧⌘J(0x26)
    //                  清单=⇧⌘L(0x25) 等宽=⇧⌘M(0x2E)
    // 关键：匹配时把用户输入里的空格全部去掉再比对，于是 -[] / -[ ] / - [ ] / [] / [ ]
    //       这些写法都归一成 "-[]" 或 "[]"，无需穷举每一种空格组合。
    private struct Rule { let keyCode: CGKeyCode; let flags: CGEventFlags }
    private let canonical: [String: Rule] = [
        "#":   Rule(keyCode: 0x11, flags: [.maskShift, .maskCommand]),   // # → 大标题 T
        "##":  Rule(keyCode: 0x04, flags: [.maskShift, .maskCommand]),   // ## → 标题 H
        "###": Rule(keyCode: 0x26, flags: [.maskShift, .maskCommand]),   // ### → 小标题 J
        "-[]": Rule(keyCode: 0x25, flags: [.maskShift, .maskCommand]),   // -[] / - [ ] … → 清单 L
        "[]":  Rule(keyCode: 0x25, flags: [.maskShift, .maskCommand]),   // [] / [ ] → 清单 L
        ">":   Rule(keyCode: 0x2E, flags: [.maskShift, .maskCommand]),   // > → 等宽 M（备忘录无引用样式）
        "```": Rule(keyCode: 0x2E, flags: [.maskShift, .maskCommand]),   // ``` → 等宽 M（备忘录无代码块）
    ]

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,                 // 可拦截/改写（不是 listenOnly）
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<LiveMarkdown>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else { return }

        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil; runLoopSource = nil
        lineBuffer = ""; atLineStart = true
    }

    private func notesIsFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == notesBundleID
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        // 功能关闭 / 备忘录不在前台：直接放行并复位
        guard Settings.liveMarkdown, notesIsFrontmost() else {
            lineBuffer = ""; atLineStart = true
            return pass
        }
        // 跳过本程序自己注入的事件，避免递归
        if event.getIntegerValueField(.eventSourceUserData) == injectedMagic {
            return pass
        }
        guard type == .keyDown else { return pass }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // 带 Command/Control/Option 的组合键：先看是不是「粘贴一份 Markdown 待办」
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            lineBuffer = ""; atLineStart = true
            // ⌘V 且剪贴板是 Markdown 待办清单 → 拦截，转成纯文本粘贴 + 原生复选框
            if Int(keyCode) == kVK_ANSI_V,
               flags.contains(.maskCommand),
               !flags.contains(.maskShift), !flags.contains(.maskControl), !flags.contains(.maskAlternate),
               let raw = NSPasteboard.general.string(forType: .string),
               isChecklistMarkdown(raw) {
                pasteAsChecklist(raw)
                return nil   // 吞掉这次 ⌘V，由我们自己粘
            }
            return pass
        }

        // 回车 / 方向键 / 删除：复位行首跟踪
        switch Int(keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            lineBuffer = ""; atLineStart = true; return pass
        case kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow:
            lineBuffer = ""; atLineStart = false; return pass
        case kVK_Delete:
            if !lineBuffer.isEmpty { lineBuffer.removeLast() }
            return pass
        default: break
        }

        // 取输入字符
        var len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &chars)
        guard len > 0 else { return pass }
        let s = String(utf16CodeUnits: chars, count: len)

        // 只在行首区域跟踪
        guard atLineStart else { return pass }

        // 触发字符：空格。检查"已输入内容去掉空格后"是否命中某个标记
        if s == " " {
            let key = normalizeMarker(lineBuffer)
            if let rule = canonical[key] {
                // 命中！删掉已输入的标记字符（含其中的空格），套用原生格式，吞掉这个收尾空格
                applyFormat(markerLength: lineBuffer.count, rule: rule)
                lineBuffer = ""; atLineStart = false
                return nil
            }
            // 空格但没命中：是不是某个标记的"中间空格"（如 "- [ ]" 里的空格）？
            // 只要 lineBuffer 去空格后仍是某标记的前缀，就保留空格继续累积
            if canonical.keys.contains(where: { $0.hasPrefix(key) && !key.isEmpty }) {
                lineBuffer += s
                return pass
            }
            // 否则空格照常输入，结束行首跟踪
            lineBuffer = ""; atLineStart = false
            return pass
        }

        // 普通字符：去空格后仍是某标记的前缀就继续累积，否则停止跟踪
        let candidate = normalizeMarker(lineBuffer + s)
        if !candidate.isEmpty,
           canonical.keys.contains(where: { $0.hasPrefix(candidate) }) {
            lineBuffer += s
            return pass
        }

        atLineStart = false
        lineBuffer = ""
        return pass
    }

    /// 归一化标记：去掉空格 + 中文方括号【】→英文[]，于是 -【】/-[ ]/- [ ] 都等价
    private func normalizeMarker(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "")
         .replacingOccurrences(of: "【", with: "[")
         .replacingOccurrences(of: "】", with: "]")
    }

    // MARK: - 粘贴 Markdown 待办 → 原生圆圈复选框
    /// 判断剪贴板文本是否为待办清单：至少 1 行 - [ ]，且任务行占多数
    private func isChecklistMarkdown(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        var task = 0
        for l in lines {
            // 中文方括号【】也算
            let low = l.lowercased().replacingOccurrences(of: "【", with: "[")
                                    .replacingOccurrences(of: "】", with: "]")
            if low.hasPrefix("- [ ]") || low.hasPrefix("- [x]")
                || low.hasPrefix("-[ ]") || low.hasPrefix("-[x]")
                || low.hasPrefix("[ ]") || low.hasPrefix("[x]") { task += 1 }
        }
        return task >= 1 && task * 2 >= lines.count   // 过半是任务行
    }

    /// 把 Markdown 待办剥成纯文本逐条粘贴，并转成备忘录原生清单（⇧⌘L）
    private func pasteAsChecklist(_ raw: String) {
        // 提取每条待办文字（去掉 - [ ] 等标记），过滤空行
        var items: [String] = []
        for line in raw.components(separatedBy: "\n") {
            // 先把中文方括号归一成英文，再剥标记
            var t = line.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "【", with: "[")
                        .replacingOccurrences(of: "】", with: "]")
            guard !t.isEmpty else { continue }
            let low = t.lowercased()
            for p in ["- [ ] ", "- [x] ", "- [ ]", "- [x]", "-[ ] ", "-[x] ", "-[ ]", "-[x]", "[ ] ", "[x] ", "[ ]", "[x]", "- ", "* ", "• "] {
                if low.hasPrefix(p) { t = String(t.dropFirst(p.count)); break }
            }
            t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if !t.isEmpty { items.append(t) }
        }
        guard !items.isEmpty else { return }
        let plain = items.joined(separator: "\n")
        let lineCount = items.count

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            // 1) 写入纯文本到剪贴板（注入标记让我们自己的 ⌘V 不被再次拦截）
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(plain, forType: .string)
            usleep(40_000)
            // 2) 注入 ⌘V 粘贴纯文本
            self.postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            usleep(180_000)   // 等粘贴落地
            // 3) 选中刚粘贴的这几行：从末尾 Shift+Up×(行数-1) 再 Shift+Cmd+Left 选到首行行首
            for _ in 0..<(lineCount - 1) {
                self.postKey(CGKeyCode(kVK_UpArrow), flags: .maskShift)
                usleep(30_000)
            }
            self.postKey(CGKeyCode(kVK_LeftArrow), flags: [.maskShift, .maskCommand])
            usleep(90_000)
            // 4) ⇧⌘L 转成原生清单（圆圈复选框）
            self.postKey(CGKeyCode(0x25), flags: [.maskShift, .maskCommand])
            usleep(80_000)
            // 5) 取消选区，光标回末尾
            self.postKey(CGKeyCode(kVK_RightArrow), flags: [])
        }
    }

    /// 删掉已输入的 markerLength 个标记字符，并合成备忘录原生格式快捷键
    private func applyFormat(markerLength: Int, rule: Rule) {
        // 整段放后台线程，给足时序间隔；标记字符必须先被备忘录渲染完才能删，
        // 否则会出现"偶尔触发"——删除赶在字符落地之前，什么都没删到。
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            usleep(45_000)   // 等被吞的空格被丢弃 + 标记字符在备忘录里落地
            // 1) 逐个退格删掉已打的标记符号（如 "#"、"- [ ]"）
            for _ in 0..<markerLength {
                self.postKey(CGKeyCode(kVK_Delete), flags: [])
                usleep(30_000)
            }
            usleep(45_000)   // 给备忘录把删除处理完的缓冲
            // 2) 套用备忘录原生格式快捷键
            self.postKey(rule.keyCode, flags: rule.flags)
        }
    }

    /// 合成按键（打上注入标记，回环时跳过）
    private func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        if !flags.isEmpty { down?.flags = flags; up?.flags = flags }
        down?.setIntegerValueField(.eventSourceUserData, value: injectedMagic)
        up?.setIntegerValueField(.eventSourceUserData, value: injectedMagic)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    deinit { stop() }
}
