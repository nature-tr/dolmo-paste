#!/bin/bash
# 打 Mac App Store 上架包：.app（3rd Party Mac Developer 签名 + 嵌入式描述文件）→ .pkg
#
# 前置（只需做一次）：
#   1. developer.apple.com 已付费并接受协议
#   2. Xcode → Settings → Accounts 登录同一账号，让 Xcode 自动创建：
#        - "Apple Distribution" / "3rd Party Mac Developer Application" 证书
#        - "3rd Party Mac Developer Installer" 证书
#        - App ID top.dolmo.paste.app 的 Mac App Store 描述文件
#   3. 把描述文件下载后放到同目录，命名为 DolmoPaste.provisionprofile
#
# 用法: ./AppStore/build_appstore.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
STORE="$ROOT/AppStore"
APP="$STORE/build/dolmo paste.app"
PROFILE="$STORE/DolmoPaste.provisionprofile"

# --disable-sandbox 关的是 SwiftPM 的编译沙盒（此环境下不关会 sandbox_apply 失败）；
# 上架要的「应用沙盒」来自 entitlements + codesign，和这个开关无关
echo "==> 编译"
( cd dolmo-paste && swift build -c release --disable-sandbox 2>&1 | tail -20 )

# 发布身份：优先 3rd Party Mac Developer Application，其次 Apple Distribution
IDENTITY=$(security find-identity -v -p codesigning \
  | grep -E '"(3rd Party Mac Developer Application|Apple Distribution)' \
  | head -1 | cut -d'"' -f2)
INSTALLER_IDENTITY=$(security find-identity -v -p codesigning \
  | grep -E '"(3rd Party Mac Developer Installer|Apple Distribution)' \
  | head -1 | cut -d'"' -f2)
if [ -z "$IDENTITY" ]; then
  echo "✗ 没找到发布证书。"
  echo "  Xcode → Settings → Accounts → 选中账号 → Manage Certificates → 添加"
  echo "  \"Apple Distribution\" 和 \"Mac Installer Distribution\"，再重跑本脚本。"
  exit 1
fi
echo "    签名身份: $IDENTITY"
echo "    安装器身份: ${INSTALLER_IDENTITY:-未找到}"

echo "==> 组装 ${APP}"
rm -rf "$STORE/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "dolmo-paste/.build/release/DolmoPaste" "$APP/Contents/MacOS/DolmoPaste"
cp "$STORE/Info-AppStore.plist" "$APP/Contents/Info.plist"
cp "dolmo-paste/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

if [ -f "$PROFILE" ]; then
  echo "    嵌入描述文件"
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
else
  echo "    ⚠ 未找到 $PROFILE：先签名，但上传前必须补上描述文件"
fi

echo "==> 用 entitlements 签名"
codesign --force --timestamp=none --options runtime \
  --entitlements "$STORE/DolmoPaste.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> 校验（沙盒必须开、Bundle ID 必须匹配）"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "app-sandbox" \
  && echo "    ✓ 沙盒已开启" || echo "    ✗ 沙盒缺失"

if [ -n "$INSTALLER_IDENTITY" ]; then
  echo "==> 打 .pkg"
  productbuild --component "$APP" /Applications \
    --sign "$INSTALLER_IDENTITY" \
    "$STORE/build/dolmo-paste.pkg"
  echo "==> 完成: $STORE/build/dolmo-paste.pkg"
  echo "    Xcode → Open Developer Tool → Transporter，拖入上传"
  echo "    或: xcrun altool --upload-app -f \"$STORE/build/dolmo-paste.pkg\" -t macos --apiKey <key> --apiIssuer <issuer>"
else
  echo "==> 完成: $APP（缺安装器证书，未生成 .pkg）"
fi
