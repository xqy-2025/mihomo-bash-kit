#!/usr/bin/env bash
set -Eeuo pipefail

STEP="初始化"
INSTALL_PATH=""
TMP_GZ="/tmp/mihomo-${USER:-user}-$$.gz"
TMP_BIN="/tmp/mihomo-${USER:-user}-$$"

cleanup() {
    rm -f "$TMP_GZ" "$TMP_BIN"
}

on_error() {
    local exit_code=$?

    echo
    echo "========== Mihomo 安装失败 =========="
    echo "退出码: $exit_code"
    echo "卡在步骤: $STEP"
    echo

    case "$STEP" in
        "检查基础命令")
            echo "原因：缺少 curl、gzip、install 等基础命令。"
            echo
            echo "Debian / Ubuntu 可执行："
            echo "  sudo apt update"
            echo "  sudo apt install -y curl gzip ca-certificates coreutils"
            ;;
        "检测架构")
            echo "原因：当前 CPU 架构不受支持。"
            echo
            echo "当前架构："
            uname -m 2>/dev/null || true
            echo
            echo "脚本仅支持："
            echo "  x86_64 / amd64"
            echo "  aarch64 / arm64"
            ;;
        "下载 mihomo")
            echo "原因：所有镜像和 GitHub 原始地址均下载失败。"
            echo
            echo "目标文件："
            echo "  ${FILE:-未知}"
            echo
            echo "原始地址："
            echo "  ${ORIGIN_URL:-未知}"
            echo
            echo "建议检查："
            echo "  curl -I https://github.com"
            echo "  cat /etc/resolv.conf"
            ;;
        "校验压缩包")
            echo "原因：下载内容不是有效的 gzip 压缩包。"
            echo "镜像可能返回了 HTML 错误页或验证页面。"
            ;;
        "选择安装位置")
            echo "原因：无法确定可写的安装位置。"
            echo
            echo "检查命令："
            echo "  id"
            echo "  command -v sudo"
            echo "  echo \$HOME"
            ;;
        "安装 mihomo")
            echo "原因：无法将 mihomo 写入目标目录。"
            echo
            echo "目标位置："
            echo "  ${INSTALL_PATH:-未知}"
            echo
            echo "检查命令："
            echo "  id"
            echo "  ls -ld \"$(dirname "${INSTALL_PATH:-/usr/local/bin/mihomo}")\""
            ;;
        "验证 mihomo")
            echo "原因：文件已经安装，但无法正常运行。"
            echo
            echo "检查命令："
            echo "  ls -lah '${INSTALL_PATH:-未知}'"
            echo "  file '${INSTALL_PATH:-未知}'"
            echo "  '${INSTALL_PATH:-未知}' -v"
            ;;
        *)
            echo "未知错误，请查看上方原始报错。"
            ;;
    esac

    echo
    echo "临时文件："
    echo "  $TMP_GZ"
    echo "  $TMP_BIN"
    echo "====================================="

    cleanup
    exit "$exit_code"
}

trap on_error ERR
trap cleanup EXIT

echo "========== Mihomo 安装器 =========="

STEP="检查基础命令"
echo
echo "[STEP] $STEP"

for cmd in uname curl gzip chmod mkdir rm install id dirname; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "缺少命令: $cmd"
        false
    fi
done

STEP="检测架构"
echo
echo "[STEP] $STEP"

ARCH="$(uname -m)"

case "$ARCH" in
    x86_64|amd64)
        MIHOMO_ARCH="amd64"
        ;;
    aarch64|arm64)
        MIHOMO_ARCH="arm64"
        ;;
    *)
        echo "不支持的架构: $ARCH"
        false
        ;;
esac

VER="${MIHOMO_VER:-v1.19.27}"
FILE="mihomo-linux-${MIHOMO_ARCH}-${VER}.gz"
ORIGIN_URL="https://github.com/MetaCubeX/mihomo/releases/download/${VER}/${FILE}"

echo "当前用户: $(id -un)"
echo "用户 UID: $(id -u)"
echo "系统架构: $ARCH"
echo "Mihomo 架构: $MIHOMO_ARCH"
echo "版本: $VER"
echo "文件: $FILE"
echo "原始地址: $ORIGIN_URL"

STEP="下载 mihomo"
echo
echo "[STEP] $STEP"

rm -f "$TMP_GZ"

# 固定下载顺序：先尝试镜像，最后尝试 GitHub 原始地址
MIRRORS=(
    "https://hub.gitmirror.com/"
    "https://gh.llkk.cc/"
    "https://gh-proxy.com/"
    "https://ghfast.top/"
    ""
)

DOWNLOAD_OK=0

for PREFIX in "${MIRRORS[@]}"; do
    URL="${PREFIX}${ORIGIN_URL}"

    echo

    if [ -z "$PREFIX" ]; then
        echo "尝试下载：GitHub 原始地址（最后备用）"
    else
        echo "尝试下载：镜像 $PREFIX"
    fi

    echo "下载地址：$URL"

    rm -f "$TMP_GZ"

    if curl -fL \
        --connect-timeout 15 \
        --max-time 300 \
        --retry 2 \
        --retry-delay 2 \
        --retry-all-errors \
        -o "$TMP_GZ" \
        "$URL"; then

        if [ -s "$TMP_GZ" ]; then
            echo "下载完成。"
            DOWNLOAD_OK=1
            break
        fi

        echo "下载文件为空，继续尝试下一个源。"
    else
        echo "该源下载失败，继续尝试下一个源。"
    fi
done

if [ "$DOWNLOAD_OK" != "1" ]; then
    echo "所有镜像和 GitHub 原始地址均下载失败。"
    false
fi

STEP="校验压缩包"
echo
echo "[STEP] $STEP"

ls -lh "$TMP_GZ"
gzip -t "$TMP_GZ"
echo "gzip 校验通过。"

echo "正在解压..."

rm -f "$TMP_BIN"
gzip -dc "$TMP_GZ" > "$TMP_BIN"
chmod 0755 "$TMP_BIN"

STEP="选择安装位置"
echo
echo "[STEP] $STEP"

INSTALL_MODE=""

if [ "$(id -u)" -eq 0 ]; then
    # root：直接安装到系统目录
    INSTALL_PATH="/usr/local/bin/mihomo"
    INSTALL_MODE="root"

elif command -v sudo >/dev/null 2>&1; then
    # 普通用户且存在 sudo：优先安装到系统目录
    echo "检测到普通用户和 sudo，将请求 sudo 权限。"

    if sudo -v; then
        INSTALL_PATH="/usr/local/bin/mihomo"
        INSTALL_MODE="sudo"
    else
        echo "sudo 授权失败，退回用户目录安装。"
        INSTALL_PATH="$HOME/.local/bin/mihomo"
        INSTALL_MODE="user"
    fi

else
    # 普通用户且没有 sudo：安装到用户目录
    INSTALL_PATH="$HOME/.local/bin/mihomo"
    INSTALL_MODE="user"
fi

echo "安装模式: $INSTALL_MODE"
echo "安装位置: $INSTALL_PATH"

STEP="安装 mihomo"
echo
echo "[STEP] $STEP"

case "$INSTALL_MODE" in
    root)
        mkdir -p "$(dirname "$INSTALL_PATH")"
        install -m 0755 "$TMP_BIN" "$INSTALL_PATH"
        ;;

    sudo)
        sudo mkdir -p "$(dirname "$INSTALL_PATH")"
        sudo install -m 0755 "$TMP_BIN" "$INSTALL_PATH"
        ;;

    user)
        mkdir -p "$(dirname "$INSTALL_PATH")"
        install -m 0755 "$TMP_BIN" "$INSTALL_PATH"

        # 保证 ~/.local/bin 在 Bash 的 PATH 中
        PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            export PATH="$HOME/.local/bin:$PATH"
        fi

        if [ -f "$HOME/.bashrc" ]; then
            if ! grep -Fqx "$PATH_LINE" "$HOME/.bashrc"; then
                {
                    echo
                    echo '# 用户本地程序目录'
                    echo "$PATH_LINE"
                } >> "$HOME/.bashrc"
            fi
        else
            printf '%s\n' "$PATH_LINE" > "$HOME/.bashrc"
        fi
        ;;

    *)
        echo "未知安装模式: $INSTALL_MODE"
        false
        ;;
esac

STEP="验证 mihomo"
echo
echo "[STEP] $STEP"

if [ ! -x "$INSTALL_PATH" ]; then
    echo "目标文件不存在或没有执行权限：$INSTALL_PATH"
    false
fi

"$INSTALL_PATH" -v

echo
echo "========== Mihomo 安装成功 =========="
echo "当前用户: $(id -un)"
echo "安装模式: $INSTALL_MODE"
echo "安装位置: $INSTALL_PATH"
echo "脚本位置: $HOME/.mihomo/install_mihomo.sh"

if [ "$INSTALL_MODE" = "user" ]; then
    echo
    echo "当前使用用户级安装。"
    echo "如果当前终端直接执行 mihomo 找不到命令，请执行："
    echo
    echo "  source ~/.bashrc"
    echo
fi
