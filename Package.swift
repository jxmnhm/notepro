// swift-tools-version:5.9
// Notepro — 贴在 Apple Notes 旁边的 AI 伴随窗（菜单栏常驻 + 悬浮入口 + DeepSeek）
import PackageDescription

let package = Package(
    name: "Notepro",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Notepro",
            path: "Sources/Notepro"
        )
    ]
)
