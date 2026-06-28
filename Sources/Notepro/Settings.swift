// Settings.swift — 读写 UserDefaults 的轻量设置（ServiceProvider 与 SettingsView 共用）
import Foundation

enum Settings {
    private static let d = UserDefaults.standard

    static var apiKey: String {
        get { d.string(forKey: "ds_api_key") ?? "" }
        set { d.set(newValue, forKey: "ds_api_key") }
    }
    static var model: String {
        get {
            let m = d.string(forKey: "ds_model") ?? "deepseek-v4-flash"
            // 迁移已废弃名
            if m == "deepseek-chat" || m == "deepseek-reasoner" { return "deepseek-v4-flash" }
            return m
        }
        set { d.set(newValue, forKey: "ds_model") }
    }
    static var thinkingMode: Bool {
        get { d.bool(forKey: "ds_thinking") }
        set { d.set(newValue, forKey: "ds_thinking") }
    }

    /// 实时 Markdown 自动格式化：在备忘录里打 # / ## / - [ ] 等立即套用原生格式。默认开。
    static var liveMarkdown: Bool {
        get { d.object(forKey: "np_live_md") == nil ? true : d.bool(forKey: "np_live_md") }
        set { d.set(newValue, forKey: "np_live_md") }
    }
}
