#!/usr/bin/env bash
set -Eeuo pipefail

STEP="初始化"

CURRENT_UID="$(id -u)"
TARGET_USER="$(id -un)"
TARGET_UID="$(id -u)"
TARGET_GID="$(id -g)"
TARGET_HOME="${HOME:-}"

# sudo 执行时，仍安装到原普通用户目录
if [ "$CURRENT_UID" -eq 0 ] &&
   [ -n "${SUDO_USER:-}" ] &&
   [ "$SUDO_USER" != "root" ]; then

    TARGET_USER="$SUDO_USER"
    TARGET_UID="$(id -u "$TARGET_USER")"
    TARGET_GID="$(id -g "$TARGET_USER")"
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
fi

MIHOMO_DIR="${MIHOMO_HOME:-$TARGET_HOME/.mihomo}"

case "$MIHOMO_DIR" in
    ""|"/")
        echo "错误：MIHOMO_HOME 不能是空值或根目录。" >&2
        exit 1
        ;;
esac

UI_DIR="$MIHOMO_DIR/ui"
UI_TMP="$MIHOMO_DIR/ui_tmp.$$"
UI_BACKUP="$MIHOMO_DIR/ui_backup.$$"

cleanup() {
    rm -rf -- "$UI_TMP"
}

restore_backup() {
    if [ -e "$UI_BACKUP" ] && [ ! -e "$UI_DIR" ]; then
        mv -- "$UI_BACKUP" "$UI_DIR" || true
    fi
}

on_error() {
    local code=$?

    trap - ERR
    restore_backup

    echo
    echo "========== Web UI 安装失败 =========="
    echo "退出码: $code"
    echo "卡在步骤: $STEP"
    echo "目标用户: $TARGET_USER"
    echo "目标目录: $UI_DIR"
    echo
    echo "重新运行："
    echo "  bash '$TARGET_HOME/.mihomo/install_ui.sh'"
    echo "===================================="

    exit "$code"
}

trap on_error ERR
trap cleanup EXIT

echo "========== MetaCubeXD Web UI 安装器 =========="
echo "执行用户: $(id -un)"
echo "目标用户: $TARGET_USER"
echo "Web UI 目录: $UI_DIR"

STEP="检查基础命令"
echo
echo "[STEP] $STEP"

for cmd in git rm mkdir mv ls head id cut timeout env getent; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "缺少命令: $cmd"

        if [ "$(id -u)" -eq 0 ]; then
            echo "执行：apt update && apt install -y git coreutils"
        elif command -v sudo >/dev/null 2>&1; then
            echo "执行：sudo apt update && sudo apt install -y git coreutils"
        fi

        false
    fi
done

STEP="创建目录"
echo
echo "[STEP] $STEP"

mkdir -p "$MIHOMO_DIR"

if [ "$(id -u)" -eq 0 ] && [ "$TARGET_UID" -ne 0 ]; then
    chown "$TARGET_UID:$TARGET_GID" "$MIHOMO_DIR"
fi

rm -rf -- "$UI_TMP" "$UI_BACKUP"

STEP="下载 Web UI"
echo
echo "[STEP] $STEP"

# 镜像优先，GitHub 最后
REPOS=(
    "https://gh-proxy.com/https://github.com/MetaCubeX/metacubexd.git"
    "https://hub.gitmirror.com/https://github.com/MetaCubeX/metacubexd.git"
    "https://gh.llkk.cc/https://github.com/MetaCubeX/metacubexd.git"
    "https://ghfast.top/https://github.com/MetaCubeX/metacubexd.git"
    "https://github.com/MetaCubeX/metacubexd.git"
)

CLONE_OK=0

for REPO in "${REPOS[@]}"; do
    echo

    if [ "$REPO" = "https://github.com/MetaCubeX/metacubexd.git" ]; then
        echo "尝试：GitHub 原始地址（最后备用）"
    else
        echo "尝试：镜像地址"
    fi

    echo "$REPO"

    rm -rf -- "$UI_TMP"

    if timeout --signal=TERM --kill-after=5s 45s \
        env \
        GIT_TERMINAL_PROMPT=0 \
        GIT_ASKPASS=true \
        GIT_HTTP_LOW_SPEED_LIMIT=1024 \
        GIT_HTTP_LOW_SPEED_TIME=15 \
        git \
        -c http.version=HTTP/1.1 \
        clone \
        --depth=1 \
        --single-branch \
        --branch gh-pages \
        "$REPO" \
        "$UI_TMP"; then

        if [ -f "$UI_TMP/index.html" ]; then
            echo "下载成功。"
            CLONE_OK=1
            break
        fi

        echo "未检测到 index.html，继续下一个源。"
        rm -rf -- "$UI_TMP"
    else
        CODE=$?

        if [ "$CODE" -eq 124 ] || [ "$CODE" -eq 137 ]; then
            echo "该源超过 45 秒无有效响应，已强制终止。"
        else
            echo "该源失败，退出码：$CODE"
        fi

        rm -rf -- "$UI_TMP"
    fi
done

if [ "$CLONE_OK" != "1" ]; then
    echo "所有镜像和 GitHub 原始地址均失败。"
    false
fi

STEP="安装 Web UI"
echo
echo "[STEP] $STEP"

if [ -e "$UI_DIR" ]; then
    mv -- "$UI_DIR" "$UI_BACKUP"
fi

mv -- "$UI_TMP" "$UI_DIR"

if [ "$(id -u)" -eq 0 ] && [ "$TARGET_UID" -ne 0 ]; then
    chown -R "$TARGET_UID:$TARGET_GID" "$UI_DIR"
fi

STEP="验证 Web UI"
echo
echo "[STEP] $STEP"

test -f "$UI_DIR/index.html"
ls -lah "$UI_DIR" | head

rm -rf -- "$UI_BACKUP"

echo
echo "========== Web UI 安装成功 =========="
echo "目标用户: $TARGET_USER"
echo "Web UI 目录: $UI_DIR"
echo "入口文件: $UI_DIR/index.html"
