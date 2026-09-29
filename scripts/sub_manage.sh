#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STEP="初始化"
SUCCESS=0
COMMIT_STARTED=0

# ============================================================
# 识别目标用户
# ============================================================

CURRENT_UID="$(id -u)"
TARGET_USER="$(id -un)"
TARGET_UID="$(id -u)"
TARGET_GID="$(id -g)"
TARGET_HOME="${HOME:-}"

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
    echo "错误：无法确定目标用户 HOME。"
    exit 1
fi

CUSTOM_MIHOMO_HOME=0

if [ -n "${MIHOMO_HOME:-}" ]; then
    CUSTOM_MIHOMO_HOME=1
fi

MIHOMO_DIR="${MIHOMO_HOME:-$TARGET_HOME/.mihomo}"
SUB_FILE="$MIHOMO_DIR/subscriptions.tsv"
CONFIG="$MIHOMO_DIR/config.yaml"
SECRET_FILE="$MIHOMO_DIR/secret"
PROVIDER_DIR="$MIHOMO_DIR/providers"
UI_DIR="$MIHOMO_DIR/ui"

ACTION="${1:-}"

if [ -z "$ACTION" ]; then
    echo "用法："
    echo "  bash ~/.mihomo/sub_manage.sh add 订阅名 url  '订阅链接'"
    echo "  bash ~/.mihomo/sub_manage.sh add 订阅名 file '/本地订阅.yaml'"
    echo "  bash ~/.mihomo/sub_manage.sh del 订阅名"
    echo "  bash ~/.mihomo/sub_manage.sh list"
    exit 1
fi

shift

NAME="${1:-}"
TYPE="${2:-}"
SOURCE="${3:-}"

TXN_DIR=""
SUB_NEW=""
CONFIG_NEW=""

SUB_BACKUP=""
CONFIG_BACKUP=""
HAD_SUB=0
HAD_CONFIG=0

PROVIDER_DEST=""
PROVIDER_BACKUP=""
PROVIDER_CHANGED=0
PROVIDER_HAD_OLD=0

PERMANENT_CONFIG_BACKUP=""

# ============================================================
# 工具函数
# ============================================================

fail() {
    echo "错误：$*" >&2
    return 1
}

yaml_escape() {
    printf '%s' "$1" |
        sed 's/\\/\\\\/g; s/"/\\"/g'
}

get_controller_secret() {
    local value=""

    if [ -n "${MIHOMO_SECRET:-}" ]; then
        value="$MIHOMO_SECRET"
    elif [ -s "$SECRET_FILE" ]; then
        value="$(head -n1 "$SECRET_FILE")"
    else
        value="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
        printf '%s\n' "$value" > "$SECRET_FILE"
        chmod 0600 "$SECRET_FILE"
        echo "已生成 Controller 密钥：$SECRET_FILE" >&2
    fi

    case "$value" in
        *$'\t'*|*$'\n'*|*$'\r'*)
            fail "Controller 密钥不能包含制表符或换行符"
            ;;
    esac

    printf '%s' "$value"
}

find_mihomo() {
    local candidate=""

    if [ -n "${MIHOMO_BIN_OVERRIDE:-}" ] \
        && [ -x "$MIHOMO_BIN_OVERRIDE" ]; then

        printf '%s\n' "$MIHOMO_BIN_OVERRIDE"
        return 0
    fi

    candidate="$(command -v mihomo 2>/dev/null || true)"

    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    for candidate in \
        "/usr/local/bin/mihomo" \
        "/usr/bin/mihomo" \
        "$TARGET_HOME/.local/bin/mihomo" \
        "/root/.local/bin/mihomo"; do

        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

subscription_exists() {
    local name="$1"
    local file="$2"

    awk -F '\t' -v name="$name" '
        $1 == name {
            found=1
        }
        END {
            exit(found ? 0 : 1)
        }
    ' "$file"
}

restore_transaction() {
    set +e

    if [ "$COMMIT_STARTED" = "1" ]; then
        echo "正在恢复订阅和配置文件..."

        if [ "$HAD_SUB" = "1" ] && [ -f "$SUB_BACKUP" ]; then
            cp -a -- "$SUB_BACKUP" "$SUB_FILE"
        else
            rm -f -- "$SUB_FILE"
        fi

        if [ "$HAD_CONFIG" = "1" ] && [ -f "$CONFIG_BACKUP" ]; then
            cp -a -- "$CONFIG_BACKUP" "$CONFIG"
        else
            rm -f -- "$CONFIG"
        fi
    fi

    if [ "$PROVIDER_CHANGED" = "1" ]; then
        echo "正在恢复 Provider 文件..."

        if [ "$PROVIDER_HAD_OLD" = "1" ] \
            && [ -f "$PROVIDER_BACKUP" ]; then

            cp -a -- "$PROVIDER_BACKUP" "$PROVIDER_DEST"
        else
            rm -f -- "$PROVIDER_DEST"
        fi
    fi
}

cleanup() {
    if [ -n "$TXN_DIR" ]; then
        rm -rf -- "$TXN_DIR"
    fi
}

on_error() {
    local exit_code=$?

    trap - ERR
    restore_transaction

    echo
    echo "========== 订阅操作失败 =========="
    echo "退出码: $exit_code"
    echo "卡在步骤: $STEP"
    echo "操作类型: $ACTION"
    echo "目标用户: $TARGET_USER"
    echo "Mihomo 目录: $MIHOMO_DIR"
    echo
    echo "检查命令："
    echo "  ls -lah '$MIHOMO_DIR' 2>/dev/null || true"
    echo "  cat '$SUB_FILE' 2>/dev/null || true"
    echo "  mihomo -d '$MIHOMO_DIR' -t"
    echo "=================================="

    exit "$exit_code"
}

trap on_error ERR
trap cleanup EXIT

# ============================================================
# 统一生成 config.yaml
# ============================================================

generate_config() {
    local subscriptions_file="$1"
    local output_file="$2"

    local escaped_ui
    local escaped_secret
    local escaped_bind
    local escaped_controller_host
    local escaped_dns_host
    local allow_lan
    local bind_address
    local controller_host
    local dns_host
    local dns_port
    local mixed_port
    local controller_port

    escaped_ui="$(yaml_escape "$UI_DIR")"
    escaped_secret="$(yaml_escape "$(get_controller_secret)")"

    allow_lan="${MIHOMO_ALLOW_LAN:-false}"
    bind_address="${MIHOMO_BIND_ADDRESS:-127.0.0.1}"
    controller_host="${MIHOMO_CONTROLLER_HOST:-127.0.0.1}"
    dns_host="${MIHOMO_DNS_HOST:-127.0.0.1}"
    dns_port="${MIHOMO_DNS_PORT:-1053}"
    mixed_port="${MIHOMO_MIXED_PORT:-6669}"
    controller_port="${MIHOMO_CONTROLLER_PORT:-9090}"

    if [ "$allow_lan" != "true" ] && [ "$allow_lan" != "false" ]; then
        fail "MIHOMO_ALLOW_LAN 必须是 true 或 false"
    fi

    case "$bind_address$controller_host$dns_host" in
        *$'\t'*|*$'\n'*|*$'\r'*)
            fail "监听地址不能包含制表符或换行符"
            ;;
    esac

    escaped_bind="$(yaml_escape "$bind_address")"
    escaped_controller_host="$(yaml_escape "$controller_host")"
    escaped_dns_host="$(yaml_escape "$dns_host")"

    printf '%s' "$mixed_port" |
        grep -Eq '^[0-9]+$' ||
        fail "MIHOMO_MIXED_PORT 必须是数字"

    printf '%s' "$controller_port" |
        grep -Eq '^[0-9]+$' ||
        fail "MIHOMO_CONTROLLER_PORT 必须是数字"

    printf '%s' "$dns_port" |
        grep -Eq '^[0-9]+$' ||
        fail "MIHOMO_DNS_PORT 必须是数字"

    cat > "$output_file" <<YAML
mixed-port: ${mixed_port}
allow-lan: ${allow_lan}
bind-address: "${escaped_bind}"
mode: rule
log-level: info
ipv6: false

external-controller: "${escaped_controller_host}:${controller_port}"
secret: "${escaped_secret}"
external-ui: "${escaped_ui}"

external-controller-cors:
  allow-origins:
    - '*'
  allow-private-network: true

geox-url:
  mmdb: "https://hub.gitmirror.com/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb"
  geoip: "https://hub.gitmirror.com/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
  geosite: "https://hub.gitmirror.com/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
  asn: "https://hub.gitmirror.com/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb"

profile:
  store-selected: true
  store-fake-ip: true

dns:
  enable: true
  listen: "${escaped_dns_host}:${dns_port}"
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
  fallback:
    - 8.8.8.8
    - 1.1.1.1
  fallback-filter:
    geoip: true
    geoip-code: CN
YAML

    if [ -s "$subscriptions_file" ]; then
        echo >> "$output_file"
        echo "proxy-providers:" >> "$output_file"

        while IFS=$'\t' read -r PNAME PTYPE PSOURCE; do
            [ -z "${PNAME:-}" ] && continue
            [ -z "${PTYPE:-}" ] && continue
            [ -z "${PSOURCE:-}" ] && continue

            case "$PTYPE" in
                url)
                    local escaped_url
                    escaped_url="$(yaml_escape "$PSOURCE")"

                    cat >> "$output_file" <<YAML
  ${PNAME}:
    type: http
    url: "${escaped_url}"
    interval: 86400
    path: ./providers/${PNAME}.yaml
    override:
      additional-prefix: "[${PNAME}] "
    health-check:
      enable: true
      interval: 300
      url: http://www.gstatic.com/generate_204
YAML
                    ;;

                file)
                    cat >> "$output_file" <<YAML
  ${PNAME}:
    type: file
    path: ./providers/${PNAME}.yaml
    override:
      additional-prefix: "[${PNAME}] "
    health-check:
      enable: true
      interval: 300
      url: http://www.gstatic.com/generate_204
YAML
                    ;;

                *)
                    fail "发现无效订阅类型：$PTYPE"
                    ;;
            esac
        done < "$subscriptions_file"
    fi

    cat >> "$output_file" <<'YAML'

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - DIRECT
YAML

    if [ -s "$subscriptions_file" ]; then
        echo "    use:" >> "$output_file"

        while IFS=$'\t' read -r PNAME PTYPE PSOURCE; do
            [ -z "${PNAME:-}" ] && continue
            echo "      - ${PNAME}" >> "$output_file"
        done < "$subscriptions_file"
    fi

    cat >> "$output_file" <<'YAML'

  - name: Auto
    type: url-test
    proxies:
      - DIRECT
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 80
YAML

    if [ -s "$subscriptions_file" ]; then
        echo "    use:" >> "$output_file"

        while IFS=$'\t' read -r PNAME PTYPE PSOURCE; do
            [ -z "${PNAME:-}" ] && continue
            echo "      - ${PNAME}" >> "$output_file"
        done < "$subscriptions_file"
    fi

    cat >> "$output_file" <<'YAML'

  - name: Final
    type: select
    proxies:
      - Proxy
      - Auto
      - DIRECT

rules:
  - DOMAIN-SUFFIX,google.com,Proxy
  - DOMAIN-SUFFIX,gstatic.com,Proxy
  - DOMAIN-SUFFIX,github.com,Proxy
  - DOMAIN-SUFFIX,githubusercontent.com,Proxy
  - DOMAIN-SUFFIX,openai.com,Proxy
  - DOMAIN-SUFFIX,chatgpt.com,Proxy
  - DOMAIN-SUFFIX,anthropic.com,Proxy
  - DOMAIN-SUFFIX,claude.ai,Proxy
  - GEOIP,CN,DIRECT
  - MATCH,Final
YAML
}

# ============================================================
# list 操作不需要写入文件
# ============================================================

if [ "$ACTION" = "list" ]; then
    echo "========== Mihomo 订阅列表 =========="
    echo "配置目录: $MIHOMO_DIR"
    echo

    if [ ! -s "$SUB_FILE" ]; then
        echo "当前没有订阅。"
        exit 0
    fi

    printf '%-24s %-8s %s\n' "NAME" "TYPE" "SOURCE"
    printf '%-24s %-8s %s\n' "------------------------" "--------" "------"

    while IFS=$'\t' read -r PNAME PTYPE PSOURCE; do
        [ -z "${PNAME:-}" ] && continue

        if [ "$PTYPE" = "url" ]; then
            DISPLAY_SOURCE="已隐藏"
        else
            DISPLAY_SOURCE="$PSOURCE"
        fi

        printf '%-24s %-8s %s\n' \
            "$PNAME" \
            "$PTYPE" \
            "$DISPLAY_SOURCE"
    done < "$SUB_FILE"

    exit 0
fi

if [ "$ACTION" != "add" ] && [ "$ACTION" != "del" ]; then
    echo "错误：操作只能是 add、del 或 list。"
    exit 1
fi

# ============================================================
# 参数与依赖检查
# ============================================================

STEP="检查参数"
echo "========== Mihomo 订阅管理器 =========="
echo
echo "操作类型: $ACTION"
echo "执行用户: $(id -un)"
echo "目标用户: $TARGET_USER"
echo "Mihomo 目录: $MIHOMO_DIR"

if [ -z "$NAME" ]; then
    fail "没有提供订阅名称"
fi

if ! printf '%s' "$NAME" |
    grep -Eq '^[A-Za-z0-9_.-]+$'; then

    fail "订阅名只能使用英文、数字、下划线、点和短横线"
fi

if [ "$ACTION" = "add" ]; then
    if [ -z "$TYPE" ] || [ -z "$SOURCE" ]; then
        fail "add 操作必须提供订阅类型和来源"
    fi

    if [ "$TYPE" != "url" ] && [ "$TYPE" != "file" ]; then
        fail "订阅类型只能是 url 或 file"
    fi

    case "$SOURCE" in
        *$'\t'*|*$'\n'*|*$'\r'*)
            fail "订阅来源不能包含制表符或换行符"
            ;;
    esac

    if [ "$TYPE" = "url" ]; then
        printf '%s' "$SOURCE" |
            grep -Eq '^https?://' ||
            fail "URL 必须以 http:// 或 https:// 开头"
    fi

    if [ "$TYPE" = "file" ] && [ ! -f "$SOURCE" ]; then
        fail "本地订阅文件不存在：$SOURCE"
    fi
fi

STEP="检查基础命令"

for cmd in \
    awk \
    cat \
    chmod \
    cp \
    cut \
    date \
    grep \
    head \
    id \
    install \
    mkdir \
    mktemp \
    mv \
    od \
    realpath \
    rm \
    sed \
    tr; do

    if ! command -v "$cmd" >/dev/null 2>&1; then
        fail "缺少命令：$cmd"
    fi
done

# ============================================================
# 创建事务目录
# ============================================================

STEP="创建目录"

mkdir -p "$MIHOMO_DIR" "$PROVIDER_DIR"

chmod 0700 "$MIHOMO_DIR" "$PROVIDER_DIR" 2>/dev/null || true

TXN_DIR="$(mktemp -d "$MIHOMO_DIR/.subscription-txn.XXXXXX")"

SUB_NEW="$TXN_DIR/subscriptions.tsv"
CONFIG_NEW="$TXN_DIR/config.yaml"

SUB_BACKUP="$TXN_DIR/subscriptions.old"
CONFIG_BACKUP="$TXN_DIR/config.old"
PROVIDER_BACKUP="$TXN_DIR/provider.old"

if [ -f "$SUB_FILE" ]; then
    cp -a -- "$SUB_FILE" "$SUB_NEW"
else
    : > "$SUB_NEW"
fi

# ============================================================
# add 操作
# ============================================================

if [ "$ACTION" = "add" ]; then
    STEP="更新订阅记录"

    awk -F '\t' -v name="$NAME" \
        '$1 != name {print}' \
        "$SUB_NEW" > "$TXN_DIR/subscriptions.filtered"

    printf '%s\t%s\t%s\n' \
        "$NAME" \
        "$TYPE" \
        "$SOURCE" >> "$TXN_DIR/subscriptions.filtered"

    mv -f -- "$TXN_DIR/subscriptions.filtered" "$SUB_NEW"

    if [ "$TYPE" = "file" ]; then
        STEP="安装本地订阅"

        SOURCE="$(realpath "$SOURCE")"
        PROVIDER_DEST="$PROVIDER_DIR/${NAME}.yaml"

        if [ -f "$PROVIDER_DEST" ]; then
            cp -a -- "$PROVIDER_DEST" "$PROVIDER_BACKUP"
            PROVIDER_HAD_OLD=1
        fi

        install -m 0600 \
            "$SOURCE" \
            "$TXN_DIR/provider.new"

        mv -f \
            "$TXN_DIR/provider.new" \
            "$PROVIDER_DEST"

        PROVIDER_CHANGED=1

        # TSV 中只记录最终保存位置
        awk -F '\t' -v OFS='\t' \
            -v name="$NAME" \
            -v source="$PROVIDER_DEST" '
                $1 == name {
                    $3=source
                }
                {
                    print
                }
            ' "$SUB_NEW" > "$TXN_DIR/subscriptions.final"

        mv -f \
            "$TXN_DIR/subscriptions.final" \
            "$SUB_NEW"
    fi
fi

# ============================================================
# del 操作
# ============================================================

if [ "$ACTION" = "del" ]; then
    STEP="检查订阅是否存在"

    if ! subscription_exists "$NAME" "$SUB_NEW"; then
        echo
        echo "订阅不存在，不做任何修改：$NAME"
        exit 0
    fi

    STEP="删除订阅记录"

    awk -F '\t' -v name="$NAME" \
        '$1 != name {print}' \
        "$SUB_NEW" > "$TXN_DIR/subscriptions.filtered"

    mv -f \
        "$TXN_DIR/subscriptions.filtered" \
        "$SUB_NEW"

    PROVIDER_DEST="$PROVIDER_DIR/${NAME}.yaml"
fi

chmod 0600 "$SUB_NEW"

# ============================================================
# 生成和测试配置
# ============================================================

STEP="生成配置"

generate_config "$SUB_NEW" "$CONFIG_NEW"
chmod 0600 "$CONFIG_NEW"

STEP="测试配置"

MIHOMO_BIN="$(find_mihomo || true)"

if [ -n "$MIHOMO_BIN" ]; then
    echo
    echo "正在使用 Mihomo 测试新配置："
    echo "  $MIHOMO_BIN"

    "$MIHOMO_BIN" \
        -d "$MIHOMO_DIR" \
        -f "$CONFIG_NEW" \
        -t

    echo "配置测试通过。"
else
    echo
    echo "警告：没有找到 mihomo，跳过配置语法测试。"
fi

# ============================================================
# 备份并提交
# ============================================================

STEP="备份原配置"

if [ -f "$SUB_FILE" ]; then
    cp -a -- "$SUB_FILE" "$SUB_BACKUP"
    HAD_SUB=1
fi

if [ -f "$CONFIG" ]; then
    cp -a -- "$CONFIG" "$CONFIG_BACKUP"
    HAD_CONFIG=1

    PERMANENT_CONFIG_BACKUP="$CONFIG.bak.$(date +%Y%m%d_%H%M%S).$$"
    cp -a -- "$CONFIG" "$PERMANENT_CONFIG_BACKUP"
fi

STEP="提交订阅和配置"
COMMIT_STARTED=1

mv -f -- "$SUB_NEW" "$SUB_FILE"
mv -f -- "$CONFIG_NEW" "$CONFIG"

chmod 0600 "$SUB_FILE" "$CONFIG"

# 删除订阅后再清理 Provider。
# 配置测试阶段保留旧 Provider，避免事务中途破坏文件。
if [ "$ACTION" = "del" ] && [ -f "$PROVIDER_DEST" ]; then
    STEP="删除 Provider 文件"

    cp -a -- "$PROVIDER_DEST" "$PROVIDER_BACKUP"
    PROVIDER_HAD_OLD=1

    rm -f -- "$PROVIDER_DEST"
    PROVIDER_CHANGED=1
fi

# ============================================================
# 修复 sudo 场景下的所有权
# ============================================================

STEP="修复文件权限"

if [ "$(id -u)" -eq 0 ] \
    && [ "$TARGET_UID" -ne 0 ] \
    && [ "$CUSTOM_MIHOMO_HOME" = "0" ]; then

    chown "$TARGET_UID:$TARGET_GID" \
        "$MIHOMO_DIR" \
        "$PROVIDER_DIR" \
        "$SUB_FILE" \
        "$CONFIG"

    chown -R "$TARGET_UID:$TARGET_GID" "$PROVIDER_DIR"

    if [ -f "$SECRET_FILE" ]; then
        chown "$TARGET_UID:$TARGET_GID" "$SECRET_FILE"
        chmod 0600 "$SECRET_FILE"
    fi

    if [ -n "$PERMANENT_CONFIG_BACKUP" ] \
        && [ -e "$PERMANENT_CONFIG_BACKUP" ]; then

        chown "$TARGET_UID:$TARGET_GID" \
            "$PERMANENT_CONFIG_BACKUP"
    fi
fi

SUCCESS=1
COMMIT_STARTED=0
PROVIDER_CHANGED=0

echo
echo "========== 订阅操作成功 =========="

if [ "$ACTION" = "add" ]; then
    echo "操作: 添加或更新"
    echo "名称: $NAME"
    echo "类型: $TYPE"

    if [ "$TYPE" = "url" ]; then
        echo "来源: 已隐藏，避免泄露 Token"
    else
        echo "来源: $PROVIDER_DEST"
    fi
else
    echo "操作: 删除"
    echo "名称: $NAME"
    echo "Provider: $PROVIDER_DEST"
fi

echo
echo "订阅文件："
echo "  $SUB_FILE"
echo
echo "配置文件："
echo "  $CONFIG"

if [ -n "$PERMANENT_CONFIG_BACKUP" ]; then
    echo
    echo "旧配置备份："
    echo "  $PERMANENT_CONFIG_BACKUP"
fi
