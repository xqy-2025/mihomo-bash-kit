#!/usr/bin/env bash
set -Eeuo pipefail

STEP="初始化"

CURRENT_UID="$(id -u)"
TARGET_USER="$(id -un)"
TARGET_UID="$(id -u)"
TARGET_GID="$(id -g)"
TARGET_HOME="${HOME:-}"

# ------------------------------------------------------------
# 识别目标用户
#
# 普通用户直接运行：
#   安装到该用户的 ~/.mihomo
#
# root 直接运行：
#   安装到 /root/.mihomo
#
# 普通用户通过 sudo 运行：
#   根据 SUDO_USER 找回原用户，仍安装到原用户目录
# ------------------------------------------------------------

if [ "$CURRENT_UID" -eq 0 ] \
    && [ -n "${SUDO_USER:-}" ] \
    && [ "${SUDO_USER}" != "root" ]; then

    TARGET_USER="$SUDO_USER"
    TARGET_UID="$(id -u "$TARGET_USER")"
    TARGET_GID="$(id -g "$TARGET_USER")"

    if command -v getent >/dev/null 2>&1; then
        TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    else
        TARGET_HOME="/home/$TARGET_USER"
    fi
fi

if [ -z "${TARGET_HOME:-}" ] || [ "$TARGET_HOME" = "/" ]; then
    echo "无法确定目标用户的 HOME 目录。"
    exit 1
fi

# 可使用 MIHOMO_HOME 指定其他配置目录，例如：
# MIHOMO_HOME=/etc/mihomo bash install_geo.sh
MIHOMO_DIR="${MIHOMO_HOME:-$TARGET_HOME/.mihomo}"

COUNTRY_UPPER="$MIHOMO_DIR/Country.mmdb"
COUNTRY_LOWER="$MIHOMO_DIR/country.mmdb"

TMP_FILE="/tmp/Country-${TARGET_USER}-$$.mmdb"
BACKUP_UPPER="/tmp/Country-${TARGET_USER}-$$.backup"
BACKUP_LOWER="/tmp/country-${TARGET_USER}-$$.backup"

INSTALL_SUCCESS=0

cleanup() {
    rm -f -- "$TMP_FILE"

    if [ "$INSTALL_SUCCESS" = "1" ]; then
        rm -f -- "$BACKUP_UPPER" "$BACKUP_LOWER"
    fi
}

restore_backup() {
    if [ -f "$BACKUP_UPPER" ]; then
        echo "正在恢复原 Country.mmdb..."
        cp -f -- "$BACKUP_UPPER" "$COUNTRY_UPPER" 2>/dev/null || true
    fi

    if [ -f "$BACKUP_LOWER" ]; then
        echo "正在恢复原 country.mmdb..."
        cp -f -- "$BACKUP_LOWER" "$COUNTRY_LOWER" 2>/dev/null || true
    fi
}

on_error() {
    local exit_code=$?

    trap - ERR
    restore_backup

    echo
    echo "========== GeoIP/MMDB 安装失败 =========="
    echo "退出码: $exit_code"
    echo "卡在步骤: $STEP"
    echo
    echo "执行用户: $(id -un)"
    echo "目标用户: $TARGET_USER"
    echo "目标目录: $MIHOMO_DIR"
    echo

    case "$STEP" in
        "检查基础命令")
            echo "原因：缺少 curl、stat、install 等基础命令。"
            echo

            if [ "$(id -u)" -eq 0 ]; then
                echo "请执行："
                echo "  apt update"
                echo "  apt install -y curl ca-certificates coreutils"
            elif command -v sudo >/dev/null 2>&1; then
                echo "请执行："
                echo "  sudo apt update"
                echo "  sudo apt install -y curl ca-certificates coreutils"
            else
                echo "当前用户没有 sudo 权限，请联系管理员安装依赖。"
            fi
            ;;

        "创建目录")
            echo "原因：无法创建 Mihomo 配置目录。"
            echo
            echo "检查命令："
            echo "  ls -ld '$TARGET_HOME'"
            echo "  ls -ld '$MIHOMO_DIR' 2>/dev/null || true"
            ;;

        "下载 Country.mmdb")
            echo "原因：所有镜像和 GitHub 原始地址均下载失败。"
            echo
            echo "建议检查："
            echo "  curl -I https://github.com"
            echo "  cat /etc/resolv.conf"
            echo "  env | grep -i proxy"
            ;;

        "校验下载文件")
            echo "原因：下载文件无效、过小，或者可能是 HTML 错误页面。"
            echo
            echo "临时文件："
            echo "  $TMP_FILE"
            ;;

        "备份原文件")
            echo "原因：无法备份现有 MMDB 文件。"
            ;;

        "安装 MMDB")
            echo "原因：无法把 MMDB 写入目标目录。"
            echo
            echo "目标文件："
            echo "  $COUNTRY_UPPER"
            echo "  $COUNTRY_LOWER"
            ;;

        "修复文件权限")
            echo "原因：文件已安装，但无法修复文件归属。"
            echo
            echo "目标用户："
            echo "  $TARGET_USER:$TARGET_GID"
            ;;

        "验证文件")
            echo "原因：安装后的文件不存在或文件大小异常。"
            ;;

        *)
            echo "发生未知错误，请查看上方原始错误。"
            ;;
    esac

    echo
    echo "调试命令："
    echo "  ls -lah '$MIHOMO_DIR' 2>/dev/null || true"
    echo "  stat '$COUNTRY_UPPER' 2>/dev/null || true"
    echo "  stat '$COUNTRY_LOWER' 2>/dev/null || true"
    echo
    echo "重新运行："
    echo "  bash '$TARGET_HOME/.mihomo/install_geo.sh'"
    echo "========================================"

    exit "$exit_code"
}

trap on_error ERR
trap cleanup EXIT

echo "========== GeoIP/MMDB 下载器 =========="
echo
echo "执行用户: $(id -un)"
echo "执行 UID: $(id -u)"
echo "目标用户: $TARGET_USER"
echo "目标 UID: $TARGET_UID"
echo "目标 HOME: $TARGET_HOME"
echo "Mihomo 目录: $MIHOMO_DIR"

STEP="检查基础命令"
echo
echo "[STEP] $STEP"

for cmd in curl cp ls mkdir rm stat install id cut head grep; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "缺少命令: $cmd"
        false
    fi
done

STEP="创建目录"
echo
echo "[STEP] $STEP"

mkdir -p "$MIHOMO_DIR"

# sudo 执行时，把目录归属交还给原普通用户
if [ "$(id -u)" -eq 0 ] && [ "$TARGET_UID" -ne 0 ]; then
    chown "$TARGET_UID:$TARGET_GID" "$MIHOMO_DIR"
fi

STEP="下载 Country.mmdb"
echo
echo "[STEP] $STEP"

ORIGIN_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb"

# 固定顺序：镜像优先，GitHub 原始地址最后
URLS=(
    "https://hub.gitmirror.com/$ORIGIN_URL"
    "https://gh.llkk.cc/$ORIGIN_URL"
    "https://gh-proxy.com/$ORIGIN_URL"
    "https://ghfast.top/$ORIGIN_URL"
    "$ORIGIN_URL"
)

rm -f -- "$TMP_FILE"

DOWNLOAD_OK=0

for URL in "${URLS[@]}"; do
    echo

    if [ "$URL" = "$ORIGIN_URL" ]; then
        echo "尝试下载：GitHub 原始地址（最后备用）"
    else
        echo "尝试下载：镜像地址"
    fi

    echo "$URL"

    rm -f -- "$TMP_FILE"

    if curl -fL \
        --connect-timeout 15 \
        --max-time 300 \
        --retry 2 \
        --retry-delay 2 \
        --retry-all-errors \
        --output "$TMP_FILE" \
        "$URL"; then

        if [ ! -s "$TMP_FILE" ]; then
            echo "下载文件为空，继续尝试下一个源。"
            continue
        fi

        SIZE="$(stat -c '%s' "$TMP_FILE")"
        echo "下载文件大小: $SIZE bytes"

        if [ "$SIZE" -le 100000 ]; then
            echo "文件过小，可能不是有效 MMDB，继续尝试下一个源。"
            rm -f -- "$TMP_FILE"
            continue
        fi

        # 粗略检测是否下载到了 HTML 页面
        if head -c 512 "$TMP_FILE" |
            grep -Eiq '<!doctype[[:space:]]+html|<html|<head|<body'; then

            echo "检测到 HTML 页面，不是有效 MMDB，继续下一个源。"
            rm -f -- "$TMP_FILE"
            continue
        fi

        echo "下载成功。"
        DOWNLOAD_OK=1
        break
    else
        CURL_CODE=$?
        echo "该源下载失败，curl 退出码: $CURL_CODE"
        rm -f -- "$TMP_FILE"
    fi
done

if [ "$DOWNLOAD_OK" != "1" ]; then
    echo "所有 GeoIP/MMDB 下载源均失败。"
    false
fi

STEP="校验下载文件"
echo
echo "[STEP] $STEP"

test -s "$TMP_FILE"

FINAL_SIZE="$(stat -c '%s' "$TMP_FILE")"

if [ "$FINAL_SIZE" -le 100000 ]; then
    echo "文件大小不符合要求：$FINAL_SIZE bytes"
    false
fi

echo "下载文件校验通过。"
echo "文件大小: $FINAL_SIZE bytes"

STEP="备份原文件"
echo
echo "[STEP] $STEP"

rm -f -- "$BACKUP_UPPER" "$BACKUP_LOWER"

if [ -f "$COUNTRY_UPPER" ]; then
    cp -f -- "$COUNTRY_UPPER" "$BACKUP_UPPER"
    echo "已备份原文件：$COUNTRY_UPPER"
fi

if [ -f "$COUNTRY_LOWER" ]; then
    cp -f -- "$COUNTRY_LOWER" "$BACKUP_LOWER"
    echo "已备份原文件：$COUNTRY_LOWER"
fi

STEP="安装 MMDB"
echo
echo "[STEP] $STEP"

# 普通用户直接运行，或者目标目录可写
if [ -w "$MIHOMO_DIR" ]; then
    install -m 0644 "$TMP_FILE" "$COUNTRY_UPPER"
    install -m 0644 "$TMP_FILE" "$COUNTRY_LOWER"

# 普通用户指定了不可写目录，但有 sudo
elif [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    echo "目标目录不可直接写入，将请求 sudo 权限。"

    sudo install -d -m 0755 "$MIHOMO_DIR"
    sudo install -m 0644 "$TMP_FILE" "$COUNTRY_UPPER"
    sudo install -m 0644 "$TMP_FILE" "$COUNTRY_LOWER"

# root
elif [ "$(id -u)" -eq 0 ]; then
    install -d -m 0755 "$MIHOMO_DIR"
    install -m 0644 "$TMP_FILE" "$COUNTRY_UPPER"
    install -m 0644 "$TMP_FILE" "$COUNTRY_LOWER"

else
    echo "没有目标目录写入权限，也无法使用 sudo。"
    false
fi

STEP="修复文件权限"
echo
echo "[STEP] $STEP"

# sudo bash 启动时，文件应交还给原普通用户
if [ "$(id -u)" -eq 0 ] && [ "$TARGET_UID" -ne 0 ]; then
    chown "$TARGET_UID:$TARGET_GID" "$COUNTRY_UPPER"
    chown "$TARGET_UID:$TARGET_GID" "$COUNTRY_LOWER"
    chown "$TARGET_UID:$TARGET_GID" "$MIHOMO_DIR"

# 普通用户通过脚本内部 sudo 写入默认用户目录
elif [ "$TARGET_UID" -ne 0 ] && [ "$MIHOMO_DIR" = "$TARGET_HOME/.mihomo" ]; then
    if [ "$(stat -c '%u' "$COUNTRY_UPPER")" -ne "$TARGET_UID" ]; then
        sudo chown "$TARGET_UID:$TARGET_GID" \
            "$COUNTRY_UPPER" \
            "$COUNTRY_LOWER" \
            "$MIHOMO_DIR"
    fi
fi

STEP="验证文件"
echo
echo "[STEP] $STEP"

test -s "$COUNTRY_UPPER"
test -s "$COUNTRY_LOWER"

UPPER_SIZE="$(stat -c '%s' "$COUNTRY_UPPER")"
LOWER_SIZE="$(stat -c '%s' "$COUNTRY_LOWER")"

if [ "$UPPER_SIZE" -le 100000 ] || [ "$LOWER_SIZE" -le 100000 ]; then
    echo "安装后的文件大小异常。"
    false
fi

if [ "$UPPER_SIZE" -ne "$LOWER_SIZE" ]; then
    echo "两个文件大小不一致。"
    false
fi

ls -lh "$COUNTRY_UPPER" "$COUNTRY_LOWER"

INSTALL_SUCCESS=1
rm -f -- "$BACKUP_UPPER" "$BACKUP_LOWER"

echo
echo "========== GeoIP/MMDB 安装成功 =========="
echo "目标用户: $TARGET_USER"
echo "Mihomo 目录: $MIHOMO_DIR"
echo
echo "文件位置："
echo "  $COUNTRY_UPPER"
echo "  $COUNTRY_LOWER"
echo
echo "文件大小："
echo "  $UPPER_SIZE bytes"
