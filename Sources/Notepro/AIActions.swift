// AIActions.swift — 抓当前选中文字 → DeepSeek → 替换回写
//
// 流程：备忘录里已选中文字 → 点浮动按钮 → 选动作 →
//   1) 模拟 ⌘C 把选区复制到剪贴板（保留并恢复用户原剪贴板）
//   2) 调 DeepSeek
//   3) 把结果写进剪贴板，模拟 ⌘V 替换掉选区
// 注意：⌘C / ⌘V 的合成按键需要「辅助功能」权限（仅执行动作时需要，按钮本身不需要）。
import AppKit
import Carbon.HIToolbox

@MainActor
enum AIActions {

    /// 当前备忘录窗口的几何（由 AppDelegate 持续更新），用于把结果浮窗贴到 Notes 内部
    static var notesBounds: CGRect?

    /// 由 AppDelegate 注入：打开设置窗口（用户没填 Key 时直接弹设置，而不是报错）
    static var openSettings: (() -> Void)?

    /// 检查是否已填 Key；没填则直接打开设置窗口并返回 false
    private static func ensureAPIKey() -> Bool {
        if !Settings.apiKey.isEmpty { return true }
        openSettings?()
        return false
    }

    /// 对话型动作的 system prompt：包住用户自定义提示词，允许多轮追问、结合上文调整。
    private static func chatSystem(_ act: PromptAction) -> String {
        let base = "你是 Notepro，一个嵌在备忘录里的中文 AI 助手。用户会先给你一段笔记内容并指定任务，之后可能围绕你的回答继续追问。请始终记住本次对话的全部上下文：当用户说“再精简一点”“换个语气”“展开第二条”等时，是在要求你修改 / 延伸你上一条回答，而不是处理新内容。回答简洁、用 Markdown 排版。"
        return base + "\n首轮任务：" + act.prompt
    }

    /// 首轮提问文案：把动作提示词 + 原文组织成一句明确指令
    private static func firstInstruction(_ act: PromptAction, content: String) -> String {
        "\(act.prompt)\n\n以下是内容：\n\n\(content)"
    }

    /// 执行一个动作（按钮路径：处理选中文字）。actionId 为 PromptAction.id
    static func run(actionId: String, onStatus: @escaping (String) -> Void) {
        guard let act = ActionStore.find(id: actionId) else { return }
        guard ensureAPIKey() else { return }   // 没填 Key → 直接弹设置
        // 执行动作要靠合成 ⌘C/⌘V，必须有「辅助功能」权限
        guard ensureAccessibility() else { return }
        onStatus("正在读取选中文字…")

        // 复制选区会阻塞最多 ~1.7s（轮询等剪贴板），放后台线程，避免冻结 App
        DispatchQueue.global(qos: .userInitiated).async {
            let selected = copySelection()
            DispatchQueue.main.async {
                guard let selected, !selected.isEmpty else {
                    alert("没读到选中的文字",
                          "请先在备忘录里选中一段文字，再点 ✨ 按钮选择动作。\n如果刚授权过辅助功能，请重启 Notepro 后再试。")
                    onStatus("")
                    return
                }
                onStatus("正在请求 DeepSeek…")

                if act.isGenerate {
                    // 对话型：开一轮多轮会话（startSession 内部自跑首轮流式，支持后续追问带上下文）
                    ResultWindow.shared.startSession(
                        title: act.name,
                        system: chatSystem(act),
                        firstUser: firstInstruction(act, content: selected),
                        notesBounds: notesBounds)
                    onStatus("完成")
                    return
                }

                // 替换型：一次性改正文
                let client = DeepSeekClient(apiKey: Settings.apiKey,
                                            model: Settings.model,
                                            thinking: Settings.thinkingMode)
                Task {
                    do {
                        let out = try await client.complete(system: act.prompt, user: selected)
                        await MainActor.run {
                            replaceSelection(with: out)
                            onStatus("完成")
                        }
                    } catch {
                        await MainActor.run {
                            alert("处理出错", error.localizedDescription)
                            onStatus("出错")
                        }
                    }
                }
            }
        }
    }

    /// 检查辅助功能权限；没有则弹窗 + 触发系统授权提示，返回 false
    @discardableResult
    private static func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        // 触发系统的“是否允许 Notepro 控制”的提示
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        runModal(title: "需要「辅助功能」权限",
                 body: """
                 Notepro 需要辅助功能权限，才能复制你选中的文字并把 AI 结果替换回去。

                 点「打开系统设置」后，在 辅助功能 列表里把 Notepro 的开关打开
                 （如果列表里有旧的 Notepro，先用减号删掉再重新添加），
                 然后【退出并重新打开 Notepro】再试一次。
                 """,
                 primary: "打开系统设置",
                 secondary: "稍后") {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
        return false
    }

    // MARK: - 斜杠模式：删掉刚输入的「/」，按动作配置选取上下文
    /// 由「输入 / 弹菜单」触发。actionId 为 PromptAction.id。
    ///   1) 先按一次退格删掉用户刚打的「/」
    ///   2) 按动作的 selectAll 选取上下文：true→全文（⌘A）；false→最近一段（选到段首）
    ///   3) 替换型替换选区；生成型弹对话窗
    static func runSlash(actionId: String, onStatus: @escaping (String) -> Void) {
        guard let act = ActionStore.find(id: actionId) else { return }
        guard ensureAPIKey() else { return }   // 没填 Key → 直接弹设置
        guard ensureAccessibility() else { return }
        onStatus("正在读取…")

        // 整个流程含多次合成按键 + 轮询等剪贴板，放后台线程避免冻结 App
        DispatchQueue.global(qos: .userInitiated).async {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes")
                .first?.activate()
            usleep(150_000)

            // 1) 删掉刚输入的「/」
            key(kVK_Delete, flags: [])
            usleep(70_000)

            // 2) 按动作配置选取上下文
            let pb = NSPasteboard.general
            pb.clearContents()
            let before = pb.changeCount
            if act.selectAll {
                key(kVK_ANSI_A, cmd: true)              // 全文
                usleep(90_000)
            } else {
                key(kVK_UpArrow, flags: [.maskShift, .maskAlternate])  // 最近一段（选到段首）
                usleep(80_000)
            }

            // 3) 复制选区——轮询等剪贴板真正更新
            key(kVK_ANSI_C, cmd: true)
            var lineText = ""
            for _ in 0..<20 {
                usleep(50_000)
                if pb.changeCount != before, let s = pb.string(forType: .string) {
                    lineText = s; break
                }
            }
            // 没抓到内容（如空行/选区落空）→ 全选兜底，保证"没选就全文聊"
            if lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pb.clearContents()
                let before2 = pb.changeCount
                key(kVK_ANSI_A, cmd: true)
                usleep(90_000)
                key(kVK_ANSI_C, cmd: true)
                for _ in 0..<20 {
                    usleep(50_000)
                    if pb.changeCount != before2, let s = pb.string(forType: .string) {
                        lineText = s; break
                    }
                }
            }

            DispatchQueue.main.async {
                onStatus("正在请求 DeepSeek…")

                let userText = lineText.isEmpty ? "（请根据上下文处理）" : lineText
                if act.isGenerate {
                    // 对话型：取消选区把光标移回行尾，再开一轮多轮会话
                    key(kVK_RightArrow, flags: [])
                    ResultWindow.shared.startSession(
                        title: act.name,
                        system: chatSystem(act),
                        firstUser: firstInstruction(act, content: userText),
                        notesBounds: notesBounds)
                    onStatus("完成")
                    return
                }

                // 替换型：一次性替换选区
                let client = DeepSeekClient(apiKey: Settings.apiKey,
                                            model: Settings.model,
                                            thinking: Settings.thinkingMode)
                Task {
                    do {
                        let out = try await client.complete(system: act.prompt, user: userText)
                        await MainActor.run {
                            replaceSelection(with: out)           // 选区仍在 → 直接替换
                            onStatus("完成")
                        }
                    } catch {
                        await MainActor.run {
                            alert("处理出错", error.localizedDescription)
                            onStatus("出错")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 选区复制 / 替换
    /// 复制当前选区；若没有选中任何文字，自动全选（⌘A）再复制——"选中就局部，没选就全文"。
    private static func copySelection() -> String? {
        let pb = NSPasteboard.general
        // 让备忘录回到前台
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes")
            .first?.activate()
        usleep(180_000)   // 给焦点/选区恢复留足时间（录屏时系统更忙）

        // 第一轮：直接复制当前选区
        if let s = copyOnce(pb), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        // 没选中 → 全选再复制（默认全文聊）
        key(kVK_ANSI_A, cmd: true)
        usleep(90_000)
        if let s = copyOnce(pb), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        return nil
    }

    /// 发一次 ⌘C 并轮询等剪贴板更新（最多 ~1.2s）
    private static func copyOnce(_ pb: NSPasteboard) -> String? {
        pb.clearContents()
        let before = pb.changeCount
        key(kVK_ANSI_C, cmd: true)
        for _ in 0..<24 {
            usleep(50_000)
            if pb.changeCount != before,
               let s = pb.string(forType: .string),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        return pb.string(forType: .string)
    }

    private static func replaceSelection(with text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes")
            .first?.activate()
        usleep(180_000)
        key(kVK_ANSI_V, cmd: true)   // 粘贴 = 替换当前选区
        usleep(150_000)
    }

    // MARK: - 合成按键
    private static func key(_ code: Int, cmd: Bool) {
        key(code, flags: cmd ? .maskCommand : [])
    }
    private static func key(_ code: Int, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: false)
        if !flags.isEmpty { down?.flags = flags; up?.flags = flags }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - 剪贴板备份/恢复
    private static func backup(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        pb.pasteboardItems?.compactMap { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        } ?? []
    }

    private static func alert(_ title: String, _ body: String) {
        runModal(title: title, body: body, primary: "知道了", secondary: nil, onPrimary: nil)
    }

    /// 统一弹窗。关键：菜单栏 App(.accessory) + 非激活面板下，直接 runModal 的对话框
    /// 无法成为 key window，按钮点不动。这里临时切到 .regular 并激活，弹完再切回 .accessory；
    /// 并用 async 让菜单先收起，避免在菜单事件里同步弹模态导致卡死。
    private static func runModal(title: String,
                                 body: String,
                                 primary: String,
                                 secondary: String?,
                                 onPrimary: (() -> Void)?) {
        DispatchQueue.main.async {
            let prevPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            let a = NSAlert()
            a.messageText = title
            a.informativeText = body
            a.addButton(withTitle: primary)
            if let secondary { a.addButton(withTitle: secondary) }

            // 把 alert 窗口提到最前并设为 key，保证按钮可点
            a.window.level = .modalPanel
            a.window.makeKeyAndOrderFront(nil)
            let resp = a.runModal()

            if prevPolicy != .regular { NSApp.setActivationPolicy(prevPolicy) }
            if resp == .alertFirstButtonReturn { onPrimary?() }
        }
    }
}
