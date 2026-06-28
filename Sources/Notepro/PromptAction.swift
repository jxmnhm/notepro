// PromptAction.swift — 可自定义的 AI 动作模型 + 持久化存储
//
// 每个动作 = 菜单名 + 提示词 + 两个行为开关（是否弹窗 / 斜杠时是否选全文）。
// 用户可在设置里无限增删改，存进 UserDefaults（JSON）。首次启动用内置 6 个默认动作种子。
import Foundation

struct PromptAction: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String          // 菜单显示名，如「润色文字」
    var prompt: String        // 提示词（指令）
    var isGenerate: Bool      // true=生成型(弹对话窗，不改正文)；false=替换型(直接改正文)
    var selectAll: Bool       // 斜杠触发时：true=默认选全文；false=默认选最近一段

    init(id: String = UUID().uuidString, name: String, prompt: String,
         isGenerate: Bool, selectAll: Bool) {
        self.id = id; self.name = name; self.prompt = prompt
        self.isGenerate = isGenerate; self.selectAll = selectAll
    }
}

@MainActor
enum ActionStore {
    private static let key = "np_actions_v1"
    private static let seededKey = "np_actions_seeded"   // 是否已写入过种子（区分"从没设置"和"用户清空"）

    /// 内置默认动作（首次启动 / 用户清空后恢复用）
    static var defaults: [PromptAction] {
        [
            .init(name: "润色文字",
                  prompt: "在不改变原意的前提下润色这段文字，使其通顺专业。只输出润色后的文字。",
                  isGenerate: false, selectAll: false),
            .init(name: "翻译成英文",
                  prompt: "Translate the user's text into natural, fluent English. Output only the translation.",
                  isGenerate: false, selectAll: false),
            .init(name: "翻译成中文",
                  prompt: "把用户的文字翻译成自然流畅的中文。只输出译文。",
                  isGenerate: false, selectAll: false),
            .init(name: "续写",
                  prompt: "延续这段文字的风格和主题，自然地继续写下去。只输出续写的内容。",
                  isGenerate: false, selectAll: false),
            .init(name: "总结要点",
                  prompt: "把用户给的内容提炼成清晰的要点列表，保留关键信息。",
                  isGenerate: true, selectAll: false),
            .init(name: "提取待办",
                  prompt: "从用户给的内容里提取所有待办事项，用 Markdown 复选框列表输出。",
                  isGenerate: true, selectAll: true),
        ]
    }

    /// 读取全部动作。
    /// 关键：只在【从未初始化过】时才写入默认种子；一旦初始化过，
    /// 即便用户把动作全删空，也尊重"空"，不再用默认值复活。
    static func load() -> [PromptAction] {
        let d = UserDefaults.standard
        if !d.bool(forKey: seededKey) {
            save(defaults)
            d.set(true, forKey: seededKey)
            return defaults
        }
        guard let data = d.data(forKey: key),
              let arr = try? JSONDecoder().decode([PromptAction].self, from: data)
        else { return [] }
        return arr   // 可能为空数组（用户主动清空），原样返回
    }

    static func save(_ actions: [PromptAction]) {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(actions) {
            d.set(data, forKey: key)
            d.set(true, forKey: seededKey)   // 写过即视为已初始化
        }
    }

    static func find(id: String) -> PromptAction? {
        load().first { $0.id == id }
    }

    static func resetToDefaults() { save(defaults) }
}
