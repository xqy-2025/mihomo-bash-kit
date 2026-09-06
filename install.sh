#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
    pwd
)"

MIHOMO_DIR="${MIHOMO_HOME:-$HOME/.mihomo}"
BASHRC_FILE="${BASHRC_FILE:-$HOME/.bashrc}"
BLOCK_START="# >>> mihomo-bash-kit >>>"
BLOCK_END="# <<< mihomo-bash-kit <<<"

case "$MIHOMO_DIR" in
    ""|"/")
        echo "错误：MIHOMO_HOME 不能是空值或根目录。" >&2
        exit 1
        ;;
esac

for file in \
    install_mihomo.sh \
    install_geo.sh \
    install_ui.sh \
    mihomo_ctl.sh \
    sub_add.sh \
    sub_del.sh \
    sub_manage.sh; do

    if [ ! -f "$SCRIPT_DIR/scripts/$file" ]; then
        echo "错误：发布包缺少 scripts/$file" >&2
        exit 1
    fi
done

install -d -m 0700 "$MIHOMO_DIR"

for file in "$SCRIPT_DIR"/scripts/*.sh; do
    install -m 0755 "$file" "$MIHOMO_DIR/$(basename "$file")"
done

install -m 0644 "$SCRIPT_DIR/shell/mihomo.bash" "$MIHOMO_DIR/mihomo.bash"

if [ ! -s "$MIHOMO_DIR/secret" ]; then
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 24 > "$MIHOMO_DIR/secret"
    else
        od -An -N24 -tx1 /dev/urandom | tr -d ' \n' > "$MIHOMO_DIR/secret"
        printf '\n' >> "$MIHOMO_DIR/secret"
    fi
    chmod 0600 "$MIHOMO_DIR/secret"
    echo "已生成 Controller 密钥：$MIHOMO_DIR/secret"
else
    chmod 0600 "$MIHOMO_DIR/secret"
    echo "保留已有 Controller 密钥：$MIHOMO_DIR/secret"
fi

touch "$BASHRC_FILE"

if grep -Fq "$BLOCK_START" "$BASHRC_FILE"; then
    echo "Bash 集成已经存在，未重复写入：$BASHRC_FILE"
else
    {
        printf '\n%s\n' "$BLOCK_START"
        printf '[ -f "${MIHOMO_HOME:-$HOME/.mihomo}/mihomo.bash" ] && . "${MIHOMO_HOME:-$HOME/.mihomo}/mihomo.bash"\n'
        printf '%s\n' "$BLOCK_END"
    } >> "$BASHRC_FILE"
    echo "已写入 Bash 集成：$BASHRC_FILE"
fi

echo
echo "Mihomo Bash Kit 安装完成。"
echo "配置目录：$MIHOMO_DIR"
echo
echo "下一步："
echo "  source '$BASHRC_FILE'"
echo "  bash '$MIHOMO_DIR/install_mihomo.sh'"
echo "  bash '$MIHOMO_DIR/sub_add.sh' my-sub url '你的订阅链接'"
echo "  mihomo-check"
echo "  mihomo-start"
