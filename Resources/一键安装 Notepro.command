#!/bin/bash
# 一键安装 Notepro.command — 双击我，自动完成安装
# 作用：把 Notepro 装进「应用程序」、移除下载隔离标记、并打开它。
# 这样别人无需手动跑终端命令，也不会被「已损坏 / 身份不明开发者」拦住。

# 切到本脚本所在目录（即 DMG 挂载卷的根目录）
cd "$(dirname "$0")"

APP="Notepro.app"
DEST="/Applications/Notepro.app"

echo "==============================================="
echo "   正在安装 Notepro …"
echo "==============================================="

if [ ! -d "$APP" ]; then
  echo "❌ 没找到 Notepro.app，请确认本脚本和 Notepro.app 在同一个窗口里。"
  echo "按回车键关闭。"; read _; exit 1
fi

# 1) 退出可能在跑的旧实例
pkill -f "Notepro.app/Contents/MacOS/Notepro" 2>/dev/null
sleep 1

# 2) 复制到「应用程序」
echo "▶︎ 复制到 应用程序 …"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

# 3) 移除下载隔离标记（关键：解决「已损坏 / 无法验证」）
echo "▶︎ 解除系统隔离标记 …"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null

# 4) 刷新启动台/聚焦图标索引
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" 2>/dev/null

# 5) 打开
echo "▶︎ 启动 Notepro …"
open "$DEST"

echo ""
echo "✅ 安装完成！菜单栏顶部会出现 ✨ 图标。"
echo "   下一步：点 ✨ →「设置…」填入 DeepSeek API Key。"
echo ""
echo "可以关闭本窗口了。"
