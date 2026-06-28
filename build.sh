#!/bin/bash
# build.sh — 编译 Notepro 并打包成可双击运行的 .app
# 用法：./build.sh          （编译 + 打包 + 本地签名）
#       ./build.sh run      （编译打包后直接打开）
#       ./build.sh install  （编译打包后安装到 /Applications 并打开）
set -e
cd "$(dirname "$0")"

APP_NAME="Notepro"
BUILD_CONFIG="release"
APP_DIR="dist/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"

echo "▶︎ 1/4 编译（${BUILD_CONFIG}）…"
swift build -c "${BUILD_CONFIG}"
BIN_PATH="$(swift build -c "${BUILD_CONFIG}" --show-bin-path)/${APP_NAME}"

echo "▶︎ 2/4 组装 .app bundle…"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
cp Info.plist "${APP_DIR}/Contents/Info.plist"
# 拷入应用图标（启动台/设置/应用程序里显示）
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "${RES_DIR}/AppIcon.icns"
fi

echo "▶︎ 3/4 代码签名…"
# 优先用稳定的自签名证书「Notepro Self Signed」——它让 App 在每次重新打包后
# 保持同一个代码身份(cdhash 稳定)，于是【辅助功能授权只需授一次，重打包不会失效】。
# 若证书不存在（换了台机器），自动回退到 ad-hoc（功能可用，但每次重打包要重新授权）。
SIGN_ID="Notepro Self Signed"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID" \
   || security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  echo "   使用稳定身份：$SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" \
    --options runtime --entitlements entitlements.plist "${APP_DIR}"
else
  echo "   未找到自签名证书，回退 ad-hoc（每次重打包需重新授权辅助功能）"
  codesign --force --deep --sign - \
    --options runtime --entitlements entitlements.plist "${APP_DIR}" 2>/dev/null \
    || codesign --force --deep --sign - "${APP_DIR}"
fi

echo "▶︎ 4/4 完成 → ${APP_DIR}"

if [ "$1" == "run" ]; then
  open "${APP_DIR}"
elif [ "$1" == "install" ]; then
  echo "▶︎ 安装到 /Applications…"
  # 先退出正在运行的旧实例，避免覆盖不了
  pkill -f "Notepro.app/Contents/MacOS/Notepro" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "${APP_DIR}" "/Applications/${APP_NAME}.app"
  # 刷新启动台/聚焦索引，让图标和名字立即生效
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "/Applications/${APP_NAME}.app" 2>/dev/null || true
  touch "/Applications/${APP_NAME}.app"
  echo "   已安装 → /Applications/${APP_NAME}.app"
  open "/Applications/${APP_NAME}.app"
elif [ "$1" == "dmg" ]; then
  echo "▶︎ 制作 DMG 安装包…"
  VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist 2>/dev/null || echo 0.0.0)"
  STAGE="$(mktemp -d)"
  cp -R "${APP_DIR}" "${STAGE}/${APP_NAME}.app"
  ln -s /Applications "${STAGE}/Applications"   # 拖拽到 Applications 安装
  # 一键安装脚本（双击自动装 + 去隔离 + 启动，省去手动终端命令）
  if [ -f "Resources/一键安装 Notepro.command" ]; then
    cp "Resources/一键安装 Notepro.command" "${STAGE}/一键安装 Notepro.command"
    chmod +x "${STAGE}/一键安装 Notepro.command"
  fi
  # 附带安装说明
  if [ -f "首次安装说明.md" ]; then
    cp "首次安装说明.md" "${STAGE}/首次安装说明.md"
  fi
  rm -f "dist/${APP_NAME}-${VER}.dmg"
  hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" -ov -format UDZO -fs HFS+ \
    "dist/${APP_NAME}-${VER}.dmg" >/dev/null
  rm -rf "${STAGE}"
  echo "   已生成 → dist/${APP_NAME}-${VER}.dmg"
fi
