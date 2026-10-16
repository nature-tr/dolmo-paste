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
#
# 注意下面两处 `|| true`：pipefail 下 grep 无匹配会返回 1，而缺安装器证书是
# 预期内的分支（脚本本来就该往下走并给出指引），不该被 set -e 当场掐断
echo "==> 编译"
( cd dolmo-paste && swift build -c release --disable-sandbox 2>&1 | tail -20 )

# 发布身份：优先 3rd Party Mac Developer Application，其次 Apple Distribution
IDENTITY=$(security find-identity -v -p codesigning \
  | grep -E '"(3rd Party Mac Developer Application|Apple Distribution)' \
  | head -1 | cut -d'"' -f2 || true)
# 安装器证书和签名证书是两回事：Apple Distribution 只能签 .app，
# 签 .pkg 必须另外有 Mac Installer Distribution。之前这里把 Apple Distribution
# 也算进来，结果 productbuild 报"需要 installer signing identity"才暴露
INSTALLER_IDENTITY=$(security find-identity -v -p codesigning \
  | grep -E '"(3rd Party Mac Developer Installer|Mac Installer Distribution)' \
  | head -1 | cut -d'"' -f2 || true)
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
  # 变量后面紧跟全角字符时 bash 会把它的 UTF-8 字节吞进变量名
  # （"$PROFILE：xxx" 会报 PROFILE: unbound variable），必须写成 ${PROFILE}
  echo "    ✗ 未找到描述文件: ${PROFILE}"
  echo "      Certificates, Identifiers & Profiles → Provisioning Profiles → Mac App Store"
  echo "      为 top.dolmo.paste.app 创建、下载，按上面的文件名放到 AppStore/ 目录"
  echo "      没有它，签名能过但上传 App Store Connect 会被拒，下面只是先验证签名链路"
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
  echo "==> 只产出 .app，未生成 .pkg（上传要的是 .pkg）"
  echo "    ✗ 缺安装器证书。"
  echo "      Xcode → Settings → Accounts → 选中账号 → Manage Certificates → 添加"
  echo "      \"Mac Installer Distribution\"（不是 \"Apple Distribution\"），再重跑本脚本。"
fi
