// SettingsView.swift — 设置界面：通用（Key/模型）+ 提示词管理（自定义动作）
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            PromptManagerView()
                .tabItem { Label("提示词管理", systemImage: "wand.and.stars") }
        }
        .frame(width: 520, height: 560)
    }
}

// MARK: - 通用设置
struct GeneralSettingsView: View {
    @State private var apiKey: String = Settings.apiKey
    @State private var model: String = Settings.model
    @State private var thinking: Bool = Settings.thinkingMode
    @State private var liveMD: Bool = Settings.liveMarkdown
    @State private var showKey = false
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DeepSeek API Key").font(.subheadline)
            HStack(spacing: 6) {
                Group {
                    if showKey { TextField("sk-...", text: $apiKey) }
                    else { SecureField("sk-...", text: $apiKey) }
                }
                .textFieldStyle(.roundedBorder)
                Button { showKey.toggle() } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                }.buttonStyle(.plain)
            }

            Text("模型").font(.subheadline)
            Picker("", selection: $model) {
                Text("deepseek-v4-flash（快速 · 性价比高）").tag("deepseek-v4-flash")
                Text("deepseek-v4-pro（更强 · 复杂任务）").tag("deepseek-v4-pro")
            }.pickerStyle(.radioGroup).labelsHidden()

            Toggle("开启思考模式（reasoning，更慢更准）", isOn: $thinking).font(.caption)

            Divider()
            Toggle(isOn: $liveMD) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实时 Markdown 格式化")
                    Text("在备忘录里行首打 # / ## / ### / - [ ] 加空格，立即套用原生标题、清单格式")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: liveMD) { _ in Settings.liveMarkdown = liveMD }

            Divider()
            Text("用法：备忘录里选中文字点 ✨ 按钮，或输入 / 唤出菜单。动作可在「提示词管理」里自定义。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Link("申请 API Key", destination: URL(string: "https://platform.deepseek.com/")!).font(.caption)
                Spacer()
                if saved { Text("已保存").font(.caption).foregroundStyle(.green) }
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
            }
            Spacer()
        }
        .padding(20)
    }

    private func save() {
        Settings.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.model = model
        Settings.thinkingMode = thinking
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
    }
}

// MARK: - 提示词管理（自定义动作）
struct PromptManagerView: View {
    @State private var actions: [PromptAction] = ActionStore.load()
    @State private var selectedID: String?

    var body: some View {
        HSplitView {
            // 左侧：动作列表 + 增删
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(actions) { act in
                        HStack {
                            Image(systemName: act.isGenerate ? "bubble.left.and.text.bubble.right" : "arrow.triangle.2.circlepath")
                                .foregroundStyle(act.isGenerate ? .purple : .blue)
                                .font(.caption)
                            Text(act.name.isEmpty ? "（未命名）" : act.name)
                        }.tag(act.id)
                    }
                    .onMove { from, to in
                        actions.move(fromOffsets: from, toOffset: to)
                        persist()
                    }
                }
                .listStyle(.sidebar)

                HStack(spacing: 0) {
                    Button { addAction() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).frame(width: 30, height: 26)
                    Divider().frame(height: 16)
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless).frame(width: 30, height: 26)
                        .disabled(selectedID == nil)
                    Spacer()
                    Menu {
                        Button("恢复默认动作", action: resetDefaults)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).frame(width: 40)
                }
                .padding(.horizontal, 4)
                .frame(height: 28)
                .background(Color(NSColor.windowBackgroundColor))
            }
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 240)

            // 右侧：编辑选中的动作
            Group {
                if let idx = editingIndex {
                    ActionEditor(action: bindingForAction(at: idx), onChange: persist)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "wand.and.stars").font(.largeTitle).foregroundStyle(.secondary)
                        Text("选择左侧动作来编辑，或点 + 新增").foregroundStyle(.secondary).font(.callout)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var editingIndex: Int? {
        guard let id = selectedID else { return nil }
        return actions.firstIndex { $0.id == id }
    }

    private func bindingForAction(at idx: Int) -> Binding<PromptAction> {
        Binding(get: { actions[idx] }, set: { actions[idx] = $0 })
    }

    private func addAction() {
        let new = PromptAction(name: "新动作", prompt: "在这里写提示词，告诉 AI 怎么处理选中的文字。",
                               isGenerate: false, selectAll: false)
        actions.append(new)
        selectedID = new.id
        persist()
    }

    private func removeSelected() {
        guard let id = selectedID else { return }
        actions.removeAll { $0.id == id }
        selectedID = actions.first?.id
        persist()
    }

    private func resetDefaults() {
        actions = ActionStore.defaults
        selectedID = actions.first?.id
        persist()
    }

    private func persist() { ActionStore.save(actions) }
}

// MARK: - 单个动作编辑器
struct ActionEditor: View {
    @Binding var action: PromptAction
    var onChange: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("菜单名称").font(.subheadline).bold()
                TextField("如：润色文字", text: $action.name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: action.name) { _ in onChange() }

                Text("提示词").font(.subheadline).bold()
                TextEditor(text: $action.prompt)
                    .font(.system(size: 13))
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                    .onChange(of: action.prompt) { _ in onChange() }
                Text("告诉 AI 如何处理你选中的文字。例如「把这段改写成小红书风格的文案，加 emoji」。")
                    .font(.caption).foregroundStyle(.secondary)

                Divider()

                Toggle(isOn: $action.isGenerate) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("在独立窗口显示结果")
                        Text(action.isGenerate ? "生成型：弹对话窗，不改正文，可追问（适合总结、问答）"
                                               : "替换型：直接替换选中文字（适合润色、翻译）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.onChange(of: action.isGenerate) { _ in onChange() }

                Toggle(isOn: $action.selectAll) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("斜杠触发时默认选中全文")
                        Text(action.selectAll ? "输入 / 选此动作时，自动选中整篇笔记（适合总结、提取待办）"
                                              : "输入 / 选此动作时，自动选中光标所在的最近一段")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.onChange(of: action.selectAll) { _ in onChange() }

                Spacer()
            }
            .padding(20)
        }
    }
}
