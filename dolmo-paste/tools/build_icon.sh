#!/bin/bash
# 生成 Resources/AppIcon.icns
# 用法: ./tools/build_icon.sh            用代码绘制（和菜单栏剪影同一套几何，默认）
#       ./tools/build_icon.sh <源图.png>  从一张方图加工（裁白边 + 圆角）
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-}"
WORK="build/icon-work"
rm -rf "${WORK}"
mkdir -p "${WORK}/AppIcon.iconset"

if [ -z "${SRC}" ]; then
    echo "==> 绘制 1024 母图（橙子剪影上色）"
    swift tools/draw_icon.swift "${WORK}/icon-1024.png"
else
    [ -f "${SRC}" ] || { echo "找不到源图: ${SRC}"; exit 1; }
    echo "==> 生成 1024 母图（裁白边 + 圆角）"
    swift tools/make_icon.swift "${SRC}" "${WORK}/icon-1024.png"
fi

echo "==> 缩放各尺寸"
ICONSET="${WORK}/AppIcon.iconset"
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
            "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
    SIZE="${spec%%:*}"
    NAME="${spec##*:}"
    sips -z "${SIZE}" "${SIZE}" "${WORK}/icon-1024.png" --out "${ICONSET}/${NAME}.png" >/dev/null
done

echo "==> 打包 icns"
mkdir -p Resources
iconutil -c icns "${ICONSET}" -o Resources/AppIcon.icns

echo "==> 完成: Resources/AppIcon.icns  ($(du -h Resources/AppIcon.icns | cut -f1))"
