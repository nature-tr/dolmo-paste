#!/bin/bash
# 上传 .pkg 到 App Store Connect
#
# 前置：先跑 ./build_appstore.sh 产出 build/dolmo-paste.pkg，
#       并且 App Store Connect 里已经建好 top.dolmo.paste.app 这个 App 记录。
#
# 两种认证方式，二选一：
#
#   A. App Store Connect API Key（推荐，密码不用明文出现在命令里）
#      1) App Store Connect → 用户与访问 → 密钥 → 生成（权限选 App Manager 或 Developer）
#      2) 下载的 AuthKey_XXXXXXXXXX.p8 放到下面任一位置：
#           ./private_keys/        ~/private_keys/        ~/.private_keys/
#      3) 记下 KEY ID 和 ISSUER ID，然后：
#           export ASC_API_KEY=XXXXXXXXXX
#           export ASC_API_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#           ./AppStore/upload_appstore.sh
#
#   B. Apple ID + App 专用密码
#      1) appleid.apple.com → 登录 → App 专用密码 → 生成一个
#      2) ./AppStore/upload_appstore.sh  然后按提示输入
#
# 用法: ./AppStore/upload_appstore.sh
set -euo pipefail
cd "$(dirname "$0")"
PKG="build/dolmo-paste.pkg"

if [ ! -f "$PKG" ]; then
  echo "✗ 找不到 $PKG"
  echo "  先跑一遍: ./AppStore/build_appstore.sh"
  exit 1
fi

echo "==> 待上传: $PKG ($(du -h "$PKG" | cut -f1 | tr -d ' '))"

if [ -n "${ASC_API_KEY:-}" ] && [ -n "${ASC_API_ISSUER:-}" ]; then
  echo "==> 方式 A：App Store Connect API Key"
  FOUND=""
  for d in ./private_keys "$HOME/private_keys" "$HOME/.private_keys"; do
    if [ -f "$d/AuthKey_${ASC_API_KEY}.p8" ]; then FOUND="$d/AuthKey_${ASC_API_KEY}.p8"; break; fi
  done
  if [ -z "$FOUND" ]; then
    echo "✗ 找不到私钥文件 AuthKey_${ASC_API_KEY}.p8"
    echo "  放到以下任一目录：./private_keys/  ~/private_keys/  ~/.private_keys/"
    exit 1
  fi
  echo "    私钥: $FOUND"
  echo "==> 上传中，别中断（通常 1–5 分钟）"
  xcrun altool --upload-app -f "$PKG" -t macos \
    --apiKey "$ASC_API_KEY" --apiIssuer "$ASC_API_ISSUER"
  exit 0
fi

echo "==> 方式 B：Apple ID + App 专用密码"
echo "    （没生成的话去 appleid.apple.com → 登录 → App 专用密码）"
printf "Apple ID: "
read -r APPLEID
printf "App 专用密码: "
read -rs PASSWORD
echo
if [ -z "$APPLEID" ] || [ -z "$PASSWORD" ]; then
  echo "✗ 没填完整"
  exit 1
fi

echo "==> 上传中，别中断（通常 1–5 分钟）"
# 密码走 --password 参数而不是环境变量，避免出现在 shell 历史里
xcrun altool --upload-app -f "$PKG" -t macos \
  --username "$APPLEID" --password "$PASSWORD"
