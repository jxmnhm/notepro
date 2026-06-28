// ResultWindow.swift — 生成型动作的结果 / 对话浮窗
//
// 形态：可拖动、可调整大小的标准面板（.titled + .resizable）。
//   • 上半部：对话记录（把整段会话渲染成 Markdown 富文本，只读可选）
//   • 下半部：输入框 + 发送，支持就当前结果继续追问（多轮对话）
//   • 工具栏：复制最后回复 / 插入正文 / 加载指示
// 复制/插入用的是「最后一条 AI 回复的原始 Markdown」，干净可用。
import AppKit

@MainActor
final class ResultWindow: NSObject, NSWindowDelegate {
    static let shared = ResultWindow()

    /// 让输入框能获得键盘焦点的可成为 key 的面板
    private final class ChatPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private var panel: ChatPanel!
    private var titleLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var transcriptView: NSTextView!
    private var transcriptScroll: NSScrollView!
    private var inputField: NSTextField!
    private var sendButton: NSButton!
    private var copyButton: NSButton!
    private var insertButton: NSButton!
    private var reminderButton: NSButton!

    // 对话历史（含 system）。流式时最后一条 assistant 边收边更新。
    private var messages: [DeepSeekClient.Message] = []
    private var lastAssistant = ""     // 最后一条 AI 回复原文（复制/插入用）
    private var streamingBuffer = ""   // 当前流式累积
    private var isStreaming = false

    private override init() { super.init(); build() }

    // MARK: - 构建
    private func build() {
        let initial = NSRect(x: 0, y: 0, width: 420, height: 520)
        panel = ChatPanel(
            contentRect: initial,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = "Notepro"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 360)
        panel.delegate = self

        let content = NSView(frame: initial)
        panel.contentView = content

        // 标题（左上，盖在透明标题栏区）
        titleLabel = NSTextField(labelWithString: "Notepro")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        content.addSubview(titleLabel)

        // 加载指示 + 状态
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        content.addSubview(spinner)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        content.addSubview(statusLabel)

        // 对话记录
        transcriptScroll = NSScrollView()
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.borderType = .noBorder
        transcriptView = NSTextView()
        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.drawsBackground = false
        transcriptView.textContainerInset = NSSize(width: 6, height: 6)
        // 让文本宽度跟随滚动视图（表格/换行随窗口缩放正确重排）
        transcriptView.isVerticallyResizable = true
        transcriptView.isHorizontallyResizable = false
        transcriptView.autoresizingMask = [.width]
        transcriptView.textContainer?.widthTracksTextView = true
        transcriptScroll.documentView = transcriptView
        content.addSubview(transcriptScroll)

        // 工具栏：复制 / 插入 / 新建提醒
        copyButton = makeButton("复制", symbol: "doc.on.doc", action: #selector(copyResult))
        content.addSubview(copyButton)
        insertButton = makeButton("插入正文", symbol: "text.insert", action: #selector(insertResult))
        content.addSubview(insertButton)
        reminderButton = makeButton("新建提醒", symbol: "checklist", action: #selector(createReminders))
        reminderButton.isHidden = true   // 仅当结果是待办清单时显示
        content.addSubview(reminderButton)

        // 输入行：输入框 + 发送
        inputField = NSTextField()
        inputField.placeholderString = "继续追问，比如：再精简一点 / 换种语气…"
        inputField.font = .systemFont(ofSize: 13)
        inputField.bezelStyle = .roundedBezel
        inputField.target = self
        inputField.action = #selector(send)   // 回车发送
        content.addSubview(inputField)

        sendButton = NSButton(title: "发送", target: self, action: #selector(send))
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        content.addSubview(sendButton)

        setActionsEnabled(false)
        layout()
    }

    private func makeButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let b = NSButton(title: "  " + title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading
        return b
    }

    // MARK: - 布局（窗口缩放时重排）
    private func layout() {
        guard let content = panel.contentView else { return }
        let b = content.bounds
        let pad: CGFloat = 14
        let top = b.maxY

        titleLabel.frame = NSRect(x: pad, y: top - 30, width: 200, height: 18)
        spinner.frame = NSRect(x: b.maxX - 130, y: top - 29, width: 14, height: 14)
        statusLabel.frame = NSRect(x: b.maxX - 110, y: top - 30, width: 96, height: 16)

        // 底部输入行
        let inputH: CGFloat = 26
        let sendW: CGFloat = 60
        inputField.frame = NSRect(x: pad, y: 14, width: b.width - pad * 2 - sendW - 8, height: inputH)
        sendButton.frame = NSRect(x: b.maxX - pad - sendW, y: 12, width: sendW, height: 30)

        // 工具栏（输入行上方）
        let toolY = 14 + inputH + 10
        copyButton.frame = NSRect(x: pad, y: toolY, width: 78, height: 26)
        insertButton.frame = NSRect(x: pad + 84, y: toolY, width: 92, height: 26)
        reminderButton.frame = NSRect(x: pad + 182, y: toolY, width: 92, height: 26)

        // 对话记录占中间
        let transTop = top - 38
        let transBottom = toolY + 26 + 10
        transcriptScroll.frame = NSRect(x: pad, y: transBottom,
                                        width: b.width - pad * 2,
                                        height: max(60, transTop - transBottom))
    }

    func windowDidResize(_ notification: Notification) { layout() }

    private func setActionsEnabled(_ on: Bool) {
        copyButton.isEnabled = on
        insertButton.isEnabled = on
        // 提醒按钮：仅当结果是待办清单时显示并可用
        let (_, isChecklist, _) = Self.toNotesPlain(lastAssistant)
        reminderButton.isHidden = !(on && isChecklist)
        reminderButton.isEnabled = on && isChecklist
    }

    // MARK: - 对话记录渲染
    /// 把整段会话（跳过 system）渲染成富文本：用户问句加「你」标签，AI 回复渲染 Markdown。
    private func renderTranscript() {
        let out = NSMutableAttributedString()
        for msg in messages where msg.role != "system" {
            if msg.role == "user" {
                let head = NSAttributedString(string: "你\n", attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 11),
                    .foregroundColor: NSColor.systemBlue])
                out.append(head)
                out.append(NSAttributedString(string: msg.content + "\n\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor]))
            } else {
                let head = NSAttributedString(string: "Notepro\n", attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 11),
                    .foregroundColor: NSColor.systemPurple])
                out.append(head)
                out.append(MarkdownRenderer.attributed(from: msg.content))
                out.append(NSAttributedString(string: "\n\n"))
            }
        }
        // 正在流式的 assistant 片段（尚未写进 messages）
        if isStreaming {
            let head = NSAttributedString(string: "Notepro\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 11),
                .foregroundColor: NSColor.systemPurple])
            out.append(head)
            out.append(MarkdownRenderer.attributed(from: streamingBuffer))
        }
        transcriptView.textStorage?.setAttributedString(out)
        transcriptView.scrollToEndOfDocument(nil)
    }

    // MARK: - 对外接口（首轮：由 AIActions 触发）
    /// 开启一轮新会话并立即跑首轮流式。system 用对话型 prompt，firstUser 是首轮指令。
    /// 首轮和后续追问走【完全相同】的 messages 路径，保证上下文连续。
    func startSession(title: String, system: String, firstUser: String, notesBounds: CGRect?) {
        panel.title = "Notepro · \(title)"
        titleLabel.stringValue = title
        messages = [.init(role: "system", content: system),
                    .init(role: "user", content: firstUser)]
        lastAssistant = ""
        streamingBuffer = ""
        transcriptView.string = ""
        renderTranscript()
        setActionsEnabled(false)
        position(in: notesBounds)
        NSApp.activate(ignoringOtherApps: true)   // 让输入框可输入
        panel.makeKeyAndOrderFront(nil)
        runTurn()   // 首轮也走 messages 全量路径
    }

    /// 跑一轮：把当前 messages 全量发给模型，流式回填。首轮和追问共用。
    private func runTurn() {
        guard !Settings.apiKey.isEmpty else { statusLabel.stringValue = "未设置 API Key"; return }
        let client = DeepSeekClient(apiKey: Settings.apiKey, model: Settings.model,
                                    thinking: Settings.thinkingMode)
        let history = messages
        beginStreaming()
        Task {
            do {
                _ = try await client.streamMessages(history) { piece in
                    Task { @MainActor in self.appendStreaming(piece) }
                }
                await MainActor.run { self.finishStreaming() }
            } catch {
                await MainActor.run { self.showError(error.localizedDescription) }
            }
        }
    }

    /// 流式开始
    func beginStreaming() {
        isStreaming = true
        streamingBuffer = ""
        spinner.startAnimation(nil)
        statusLabel.stringValue = "生成中…"
        setActionsEnabled(false)
        renderTranscript()
    }
    /// 流式追加
    func appendStreaming(_ piece: String) {
        streamingBuffer += piece
        renderTranscript()
    }
    /// 流式结束：落库为一条 assistant 消息
    func finishStreaming() {
        isStreaming = false
        spinner.stopAnimation(nil)
        statusLabel.stringValue = "完成"
        lastAssistant = streamingBuffer
        if !streamingBuffer.isEmpty {
            messages.append(.init(role: "assistant", content: streamingBuffer))
        }
        streamingBuffer = ""
        renderTranscript()
        setActionsEnabled(!lastAssistant.isEmpty)
    }
    /// 出错
    func showError(_ message: String) {
        isStreaming = false
        spinner.stopAnimation(nil)
        statusLabel.stringValue = "出错"
        streamingBuffer = ""
        renderTranscript()
        let alert = NSAttributedString(string: "\n出错：\(message)\n",
            attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 12)])
        transcriptView.textStorage?.append(alert)
    }

    private func position(in notesBounds: CGRect?) {
        // CG 全局坐标（原点主屏左上，Y 向下）→ Cocoa（原点主屏左下，Y 向上）。
        // 翻转基准用【主屏高度】，多屏时才不会算偏。
        let primaryH = NSScreen.screens.first?.frame.height ?? (NSScreen.main?.frame.height ?? 0)
        let w = panel.frame.width, h = panel.frame.height
        if let bb = notesBounds {
            let x = bb.maxX - w - 20
            let cocoaY = primaryH - bb.minY - h - 20
            panel.setFrameOrigin(NSPoint(x: x, y: cocoaY))
        } else if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.midX - w / 2, y: vf.midY - h / 2))
        }
    }

    // MARK: - 二次追问
    @objc private func send() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard !Settings.apiKey.isEmpty else { statusLabel.stringValue = "未设置 API Key"; return }
        inputField.stringValue = ""
        messages.append(.init(role: "user", content: text))
        renderTranscript()
        runTurn()   // 复用首轮的全量 messages 路径，天然带上下文
    }

    // MARK: - 按钮动作
    @objc private func copyResult() {
        guard !lastAssistant.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lastAssistant, forType: .string)
        statusLabel.stringValue = "已复制"
    }

    @objc private func insertResult() {
        guard !lastAssistant.isEmpty else { return }

        // 把 Markdown 清理成备忘录能干净显示的纯文本，并判断是否为待办清单
        let (plain, isChecklist, lineCount) = Self.toNotesPlain(lastAssistant)

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(plain, forType: .string)
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes")
            .first?.activate()
        usleep(150_000)

        // ⌘V 粘贴
        sendKey(0x09, flags: .maskCommand)   // V
        usleep(150_000)

        if isChecklist && lineCount > 0 {
            // 选中刚粘贴的这几行：从末尾 Shift+Up 上选 (行数-1) 次，再 Shift+Cmd+Left 选到首行行首
            for _ in 0..<(lineCount - 1) {
                sendKey(0x7E, flags: [.maskShift])   // Up
                usleep(25_000)
            }
            sendKey(0x7B, flags: [.maskShift, .maskCommand])  // Left → 行首
            usleep(80_000)
            // ⌘⇧L 转成备忘录原生清单（圆圈复选框）
            sendKey(0x25, flags: [.maskShift, .maskCommand])  // L
            usleep(80_000)
            // 取消选区，光标回到末尾
            sendKey(0x7C, flags: [])   // Right
            statusLabel.stringValue = "已插入并转为清单"
        } else {
            statusLabel.stringValue = "已插入备忘录"
        }
    }

    // MARK: - 新建提醒事项（待办清单 → 系统「提醒事项」App）
    @objc private func createReminders() {
        guard !lastAssistant.isEmpty else { return }
        // 从最后一条回复里抽出待办文字（去掉 - [ ] 等标记）
        let items = Self.checklistItems(lastAssistant)
        guard !items.isEmpty else { statusLabel.stringValue = "没有可提取的待办"; return }

        statusLabel.stringValue = "正在写入提醒事项…"
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Self.addToReminders(items)
            DispatchQueue.main.async {
                self.statusLabel.stringValue = ok ? "已添加 \(items.count) 条提醒" : "写入提醒失败"
            }
        }
    }

    /// 从 Markdown 里提取待办条目文字（每个任务项一条）
    static func checklistItems(_ md: String) -> [String] {
        var items: [String] = []
        for raw in md.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            let lower = t.lowercased()
            var text = ""
            if lower.hasPrefix("- [ ] ") || lower.hasPrefix("- [x] ") {
                text = String(t.dropFirst(6))
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
                text = String(t.dropFirst(2))
            } else { continue }
            text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if !text.isEmpty { items.append(text) }
        }
        return items
    }

    /// 用 AppleScript 把条目写入「提醒事项」App 的默认列表
    static func addToReminders(_ items: [String]) -> Bool {
        // 转义双引号与反斜杠，拼成 AppleScript 字符串数组
        let escaped = items.map { $0.replacingOccurrences(of: "\\", with: "\\\\")
                                     .replacingOccurrences(of: "\"", with: "\\\"") }
        let listLiteral = escaped.map { "\"\($0)\"" }.joined(separator: ", ")
        let script = """
        tell application "Reminders"
            set theItems to {\(listLiteral)}
            repeat with t in theItems
                make new reminder with properties {name:(t as string)}
            end repeat
        end tell
        """
        var error: NSDictionary?
        if let s = NSAppleScript(source: script) {
            s.executeAndReturnError(&error)
            return error == nil
        }
        return false
    }

    /// 合成按键
    private func sendKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        if !flags.isEmpty { down?.flags = flags; up?.flags = flags }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Markdown → 备忘录纯文本。返回(纯文本, 是否待办清单, 非空行数)。
    /// 去掉 - [ ] / 列表符号 / # / ** / ` 等标记，让备忘录显示干净文字；
    /// 若每一非空行都是 - [ ] 任务项，则判定为清单，供调用方转原生复选框。
    static func toNotesPlain(_ md: String) -> (String, Bool, Int) {
        let rawLines = md.components(separatedBy: "\n")
        var out: [String] = []
        var nonEmpty = 0
        var taskLines = 0
        for raw in rawLines {
            var line = raw
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { out.append(""); continue }
            nonEmpty += 1
            // 任务项 - [ ] / - [x]
            let lower = t.lowercased()
            if lower.hasPrefix("- [ ] ") || lower.hasPrefix("- [x] ") {
                taskLines += 1
                line = String(t.dropFirst(6))
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
                line = String(t.dropFirst(2))
            } else if let h = t.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                line = String(t[h.upperBound...])   // 去标题井号
            } else {
                line = t
            }
            // 去行内 ** 和 `
            line = line.replacingOccurrences(of: "**", with: "")
                       .replacingOccurrences(of: "`", with: "")
            out.append(line)
        }
        let isChecklist = nonEmpty > 0 && taskLines == nonEmpty
        // 清单转换时，按非空行数选取
        return (out.joined(separator: "\n"), isChecklist, nonEmpty)
    }
}
