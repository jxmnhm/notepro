# Notepro · 备忘录里的浮动 AI 按钮

在「备忘录」窗口**内部右下角**有一个浮动的 ✨ 按钮。点它，弹出 AI 选项菜单（总结/润色/翻译/提取待办/续写）。选中一段文字后点动作，AI 处理结果会**直接替换你选中的文字**。

按钮跟着备忘录窗口走：移动、缩放、切换窗口，它都贴在右下角；切到别的 App 就自动隐藏。

## 怎么实现"在 Notes 里"的按钮

macOS 不让你把控件注入别的 App 的代码，但可以用一个**独立的无边框浮层窗口**（borderless + nonactivating NSPanel，floating 层级），实时定位到备忘录窗口内部右下角。视觉上它就是备忘录里的一个按钮。

窗口跟随用 **CGWindowList** 实现 —— 拿备忘录窗口的位置和大小，**不需要任何权限**。所以按钮一定能显示。

执行 AI 动作时（抓选区 → DeepSeek → 替换），靠模拟 ⌘C / ⌘V，**这一步需要「辅助功能」权限**。

## 构建与运行

```bash
./build.sh        # 编译 + 打包 dist/Notepro.app + 本地签名
./build.sh run    # 同上并打开
```

## 首次使用

1. 打开 Notepro，菜单栏出现 ✨ →「设置…」填入 DeepSeek API Key、选模型、保存。
2. 打开「备忘录」—— 右下角出现浮动 ✨ 按钮。
3. 选中一段文字 → 点 ✨ 按钮 → 选一个动作。
4. 第一次执行动作时，系统会要「辅助功能」权限（用于读取选区并替换），授权后再点一次。
5. AI 结果替换掉你选中的文字。

## 源码结构

```
Sources/Notepro/
├── AppDelegate.swift              菜单栏 + 组装跟踪器/按钮/菜单
├── NotesTracker.swift             CGWindowList 跟踪备忘录窗口（无需权限）
├── FloatingButton.swift           备忘录窗口内的浮动圆形按钮
├── AIActions.swift                ⌘C 抓选区 → DeepSeek → ⌘V 替换
├── DeepSeekClient.swift           DeepSeek V4 API 客户端
├── Settings.swift / SettingsView.swift / SettingsWindowController.swift  设置
```

## 已知边界

- ad-hoc 签名仅供本机；分发需 Apple 开发者证书签名 + 公证。每次重新打包 ad-hoc 身份会变，之前授的辅助功能权限可能要重勾。
- 中文系统备忘录的窗口 owner 名是「备忘录」，英文系统是「Notes」，两者都已适配。
- 执行动作依赖 ⌘C/⌘V，需辅助功能权限；按钮的显示与跟随不需要。
