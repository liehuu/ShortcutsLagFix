#!/bin/bash
# ShortcutsLagFix 构建脚本
#
# 设计要点（每条都对应一次真实踩坑）：
#   1. 必须 arm64 + arm64e 双切片。用户在 arm64e 设备上，
#      单 arm64 切片会被加载器直接跳过 —— 表现为"装了完全没反应"，
#      极易误判成代码 bug。
#   2. arm64e ABI 自 iOS 14 起变更，低版本 target 编不出可用产物，
#      所以 arm64e 用独立的 -target arm64e-apple-ios15.0。
#   3. RootHide 加载器跳过无签名 dylib → 必须 adhoc 签名。
#   4. install_name 指向 RootHide 的 .jbroot 布局。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="${ROOT}/ShortcutsLagFix"
OUT="${ROOT}/build"
STAGE="${ROOT}/layout"
DYLIB_NAME="ShortcutsLagFix"
MIN_IOS="15.0"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos -f clang)"
LIPO="$(xcrun -f lipo)"
CODESIGN="$(xcrun -f codesign)"

echo "[build] SDK      = ${SDK}"
echo "[build] clang    = ${CLANG}"

mkdir -p "${OUT}"

SOURCES=(
    "${SRC}/SLFMain.m"
    "${SRC}/SLFCore.m"
    "${SRC}/SLFWatchdog.m"
    "${SRC}/SLFHooks.m"
)

for f in "${SOURCES[@]}"; do
    if [ ! -f "$f" ]; then
        echo "[build][FATAL] 源文件缺失: $f" >&2
        exit 1
    fi
done

COMMON_FLAGS=(
    -fobjc-arc
    -fmodules
    -O2
    -Wall
    -Wno-unused-function
    -Wno-deprecated-declarations
    -Wno-nullability-completeness
    -isysroot "${SDK}"
    -framework Foundation
    -framework UIKit
    -framework QuartzCore
    -framework CoreFoundation
    -dynamiclib
)

# ---- arm64 ----
echo "[build] 编译 arm64 ..."
"${CLANG}" \
    -target arm64-apple-ios${MIN_IOS} \
    "${COMMON_FLAGS[@]}" \
    -install_name "@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/${DYLIB_NAME}.dylib" \
    -o "${OUT}/${DYLIB_NAME}-arm64.dylib" \
    "${SOURCES[@]}"

# ---- arm64e ----
echo "[build] 编译 arm64e ..."
"${CLANG}" \
    -target arm64e-apple-ios14.0 \
    "${COMMON_FLAGS[@]}" \
    -install_name "@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/${DYLIB_NAME}.dylib" \
    -o "${OUT}/${DYLIB_NAME}-arm64e.dylib" \
    "${SOURCES[@]}"

# ---- 合并 ----
echo "[build] lipo 合并 ..."
"${LIPO}" -create \
    -output "${OUT}/${DYLIB_NAME}.dylib" \
    "${OUT}/${DYLIB_NAME}-arm64.dylib" \
    "${OUT}/${DYLIB_NAME}-arm64e.dylib"

echo "[build] lipo -info:"
"${LIPO}" -info "${OUT}/${DYLIB_NAME}.dylib"
"${LIPO}" -detailed_info "${OUT}/${DYLIB_NAME}.dylib" | grep -E "architecture|align" || true

# ---- 硬闸门：架构必须双切片 ----
ARCH_INFO="$("${LIPO}" -info "${OUT}/${DYLIB_NAME}.dylib")"
if ! echo "${ARCH_INFO}" | grep -q "arm64"; then
    echo "[build][FATAL] 产物不含 arm64" >&2
    exit 1
fi
if ! echo "${ARCH_INFO}" | grep -q "arm64e"; then
    echo "[build][FATAL] 产物不含 arm64e —— 在用户 arm64e 设备上会静默失效，拒绝交付" >&2
    exit 1
fi

# ---- adhoc 签名 ----
echo "[build] adhoc 签名 ..."
"${CODESIGN}" --force --sign - "${OUT}/${DYLIB_NAME}.dylib"
"${CODESIGN}" -dv "${OUT}/${DYLIB_NAME}.dylib" 2>&1 | head -5 || true

# ---- 布置到 layout ----
echo "[build] 布置 layout ..."
DL_DIR="${STAGE}/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "${DL_DIR}"
cp -f "${OUT}/${DYLIB_NAME}.dylib" "${DL_DIR}/${DYLIB_NAME}.dylib"

# ★ 绝对不在 layout 里放 var/ 目录。
# dpkg 以 root 解包，这些目录会变成 root:wheel 755，而快捷指令 App 跑在
# mobile 用户下，建不了文件 —— 结果就是「日志目录存在但一条日志都没有」。
# /var/mobile 下的一切都由 postinst 创建并 chown 给 mobile。
# 这里主动清掉历史残留，避免有人手工建过之后又被打进包里。
if [ -e "${STAGE}/var" ]; then
    echo "[build] 清理 layout/var（不得进 data.tar）..."
    rm -rf "${STAGE}/var"
fi

# 校验过滤配置存在且含目标 bundle
if [ ! -f "${DL_DIR}/${DYLIB_NAME}.plist" ]; then
    echo "[build][FATAL] 缺少注入过滤 plist，插件永远不会被加载" >&2
    exit 1
fi
if ! grep -q "com.apple.shortcuts" "${DL_DIR}/${DYLIB_NAME}.plist"; then
    echo "[build][FATAL] 过滤 plist 未包含 com.apple.shortcuts" >&2
    exit 1
fi

# postinst 负责创建日志目录并 chown 给 mobile，缺了它日志就写不出来
if [ ! -f "${STAGE}/DEBIAN/postinst" ]; then
    echo "[build][FATAL] 缺少 DEBIAN/postinst（负责 chown 日志目录）" >&2
    exit 1
fi
if ! grep -q "Logs/ShortcutsLagFix" "${STAGE}/DEBIAN/postinst"; then
    echo "[build][FATAL] postinst 未提及日志目录" >&2
    exit 1
fi

echo "[build] OK -> ${OUT}/${DYLIB_NAME}.dylib"