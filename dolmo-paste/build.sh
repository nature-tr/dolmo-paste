#!/bin/bash
# 构建 dolmo paste 并打包成 .app
set -euo pipefail
cd "$(dirname "$0")"

echo "==> 编译 (release)"
swift build -c release --disable-sandbox 2>&1 | tail -40

APP_NAME="dolmo paste.app"
APP_DIR="build/${APP_NAME}"

echo "==> 打包 ${APP_DIR}"
rm -rf build
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp ".build/release/DolmoPaste" "${APP_DIR}/Contents/MacOS/DolmoPaste"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

echo "==> 签名"
# 辅助功能等 TCC 权限认的是签名身份，不是二进制本身：
# ad-hoc 签名每次构建指纹都变，授权就会失效；必须用真证书（稳定身份）签名。
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | cut -d'"' -f2)
if [ -n "$IDENTITY" ]; then
    echo "    使用证书: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "${APP_DIR}"
else
    echo "    未找到 Apple Development 证书，退回 ad-hoc（用固定 DR 让权限只按 Bundle ID 匹配）"
    codesign --force --deep --sign - --requirements '=designated => identifier "top.dolmo.paste.app"' "${APP_DIR}"
fi

echo "==> 完成: $(pwd)/${APP_DIR}"
echo "    安装: cp -r \"build/${APP_NAME}\" /Applications/"
