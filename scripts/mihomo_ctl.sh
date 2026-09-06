#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# ============================================================
# sudo 默认兼容
#
# 普通用户执行：
#   bash ~/.mihomo/mihomo_ctl.sh start
#
# 普通用户通过 sudo 执行：
#   sudo bash ~/.mihomo/mihomo_ctl.sh start
#
# 第二种情况会自动切回原普通用户，避免：
#   mihomo.log / mihomo.pid 变成 root 所有
#
# 如果显式指定 MIHOMO_HOME，则视为系统级操作，不切回普通用户：
#   sudo MIHOMO_HOME=/etc/mihomo bash ~/.mihomo/mihomo_ctl.sh start
# ============================================================

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
ORIGINAL_ARGS=("$@")

if [ "$(id -u)" -eq 0 ] \
    && [ -n "${SUDO_USER:-}" ] \
    && [ "${SUDO_USER}" != "root" ] \
    && [ -z "${MIHOMO_HOME:-}" ]; then

    TARGET_SUDO_USER="$SUDO_USER"

    echo "检测到 sudo 调用，将切换回原用户运行：$TARGET_SUDO_USER"

    exec sudo -u "$TARGET_SUDO_USER" -H \
        env PATH="$PATH" \
        bash "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
fi

# ============================================================
# 路径
# ============================================================

TARGET_USER="$(id -un)"
TARGET_UID="$(id -u)"
TARGET_HOME="${HOME:?无法确定 HOME 目录}"

MIHOMO_DIR="${MIHOMO_HOME:-$TARGET_HOME/.mihomo}"
CONFIG="$MIHOMO_DIR/config.yaml"
LOG_FILE="$MIHOMO_DIR/mihomo.log"
PID_FILE="$MIHOMO_DIR/mihomo.pid"

MIHOMO_BIN=""
PROXY_PORT="6669"
CONTROLLER_PORT="9090"
SECRET=""

# ============================================================
# 通用函数
# ============================================================

fail() {
    echo "错误：$*" >&2
    exit 1
}

need_cmd() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        fail "缺少命令：$cmd"
    fi
}

trim_value() {
    local value="$1"

    # 删除首尾空白
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    # 删除一层单双引号
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "$value"
}

read_config_value() {
    local key="$1"
    local default_value="${2:-}"
    local line=""
    local value=""

    if [ ! -f "$CONFIG" ]; then
        printf '%s' "$default_value"
        return
    fi

    line="$(
        grep -m1 -E "^[[:space:]]*${key}[[:space:]]*:" \
            "$CONFIG" 2>/dev/null || true
    )"

    if [ -z "$line" ]; then
        printf '%s' "$default_value"
        return
    fi

    value="${line#*:}"
    trim_value "$value"
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

load_runtime_config() {
    local controller=""

    PROXY_PORT="$(
        read_config_value \
            "mixed-port" \
            "${MIHOMO_PROXY_PORT:-6669}"
    )"

    controller="$(
        read_config_value \
            "external-controller" \
            "127.0.0.1:${MIHOMO_CONTROLLER_PORT:-9090}"
    )"

    # 去除可能存在的协议前缀
    controller="${controller#http://}"
    controller="${controller#https://}"

    CONTROLLER_PORT="${controller##*:}"

    SECRET="$(
        read_config_value \
            "secret" \
            "${MIHOMO_SECRET:-}"
    )"

    if ! printf '%s' "$PROXY_PORT" | grep -Eq '^[0-9]+$'; then
        echo "警告：配置中的 mixed-port 无效，使用默认端口 6669。"
        PROXY_PORT="6669"
    fi

    if ! printf '%s' "$CONTROLLER_PORT" | grep -Eq '^[0-9]+$'; then
        echo "警告：配置中的 Controller 端口无效，使用默认端口 9090。"
        CONTROLLER_PORT="9090"
    fi
}

read_pid_file() {
    local pid=""

    [ -f "$PID_FILE" ] || return 1

    pid="$(cat "$PID_FILE" 2>/dev/null || true)"

    if ! printf '%s' "$pid" | grep -Eq '^[0-9]+$'; then
        return 1
    fi

    printf '%s\n' "$pid"
}

pid_alive() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
}

pid_matches_instance() {
    local pid="$1"
    local cmdline=""

    [ -r "/proc/$pid/cmdline" ] || return 1

    cmdline="$(
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true
    )"

    [[ "$cmdline" == *"mihomo"* ]] || return 1

    if [[ "$cmdline" == *"-d $MIHOMO_DIR"* ]] \
        || [[ "$cmdline" == *"-d=$MIHOMO_DIR"* ]]; then
        return 0
    fi

    return 1
}

get_managed_pid() {
    local pid=""

    pid="$(read_pid_file || true)"

    [ -n "$pid" ] || return 1

    if pid_alive "$pid" && pid_matches_instance "$pid"; then
        printf '%s\n' "$pid"
        return 0
    fi

    # PID 文件已经失效
    rm -f "$PID_FILE"
    return 1
}

find_matching_pids() {
    ps -eo pid=,uid=,args= |
        while read -r pid uid args; do
            [ "$uid" = "$TARGET_UID" ] || continue

            case "$args" in
                *mihomo*"-d $MIHOMO_DIR"*|*mihomo*"-d=$MIHOMO_DIR"*)
                    printf '%s\n' "$pid"
                    ;;
            esac
        done
}

write_pid_file() {
    local pid="$1"
    local temp_pid="$PID_FILE.tmp.$$"

    printf '%s\n' "$pid" > "$temp_pid"
    chmod 0600 "$temp_pid"
    mv -f "$temp_pid" "$PID_FILE"
}

# ============================================================
# 基础与配置检查
# ============================================================

check_basic() {
    echo "========== 基础检查 =========="
    echo "执行用户: $TARGET_USER"
    echo "用户 UID: $TARGET_UID"
    echo "配置目录: $MIHOMO_DIR"
    echo

    for cmd in \
        grep \
        kill \
        nohup \
        ps \
        sleep \
        tail \
        tr; do

        need_cmd "$cmd"
    done

    mkdir -p "$MIHOMO_DIR"

    if [ ! -w "$MIHOMO_DIR" ]; then
        fail "当前用户无法写入配置目录：$MIHOMO_DIR"
    fi

    MIHOMO_BIN="$(find_mihomo || true)"

    if [ -z "$MIHOMO_BIN" ]; then
        echo "错误：mihomo 未安装或不在 PATH 中。"
        echo
        echo "可执行："
        echo "  bash '$MIHOMO_DIR/install_mihomo.sh'"
        exit 1
    fi

    if [ ! -f "$CONFIG" ]; then
        echo "错误：配置文件不存在："
        echo "  $CONFIG"
        echo
        echo "请先添加订阅生成配置。"
        exit 1
    fi

    if [ ! -f "$MIHOMO_DIR/ui/index.html" ]; then
        echo "警告：Web UI 不存在："
        echo "  $MIHOMO_DIR/ui/index.html"
        echo
        echo "可执行："
        echo "  bash '$MIHOMO_DIR/install_ui.sh'"
        echo
    fi

    if [ ! -f "$MIHOMO_DIR/Country.mmdb" ] \
        && [ ! -f "$MIHOMO_DIR/country.mmdb" ]; then

        echo "警告：MMDB 文件不存在。"
        echo
        echo "可执行："
        echo "  bash '$MIHOMO_DIR/install_geo.sh'"
        echo
    fi

    echo "Mihomo 路径：$MIHOMO_BIN"
    "$MIHOMO_BIN" -v || true
    echo
}

check_config() {
    echo "========== 配置检查 =========="

    if [ -z "$MIHOMO_BIN" ]; then
        MIHOMO_BIN="$(find_mihomo || true)"
    fi

    [ -n "$MIHOMO_BIN" ] || fail "找不到 Mihomo 可执行文件"
    [ -f "$CONFIG" ] || fail "配置文件不存在：$CONFIG"

    "$MIHOMO_BIN" -d "$MIHOMO_DIR" -t

    load_runtime_config

    if [ "$SECRET" = "change-this-secret" ]; then
        echo
        echo "警告：Controller 仍在使用默认密钥 change-this-secret。"
        echo "必须更换，不要长期暴露 0.0.0.0:9090。"
    fi

    echo
}

# ============================================================
# 启动
# ============================================================

start_mihomo() {
    local pid=""
    local existing_pids=""

    check_basic
    check_config

    echo "========== 启动 Mihomo =========="

    pid="$(get_managed_pid || true)"

    if [ -n "$pid" ]; then
        echo "Mihomo 已经由当前脚本启动。"
        echo "PID: $pid"
        echo
        status_mihomo
        return 0
    fi

    existing_pids="$(find_matching_pids || true)"

    if [ -n "$existing_pids" ]; then
        echo "检测到相同配置目录对应的 Mihomo 进程："
        echo "$existing_pids"
        echo
        echo "拒绝重复启动。"

        pid="$(printf '%s\n' "$existing_pids" | head -n1)"
        write_pid_file "$pid"
        return 0
    fi

    touch "$LOG_FILE"
    chmod 0600 "$LOG_FILE"

    nohup "$MIHOMO_BIN" \
        -d "$MIHOMO_DIR" \
        >> "$LOG_FILE" 2>&1 \
        < /dev/null &

    pid=$!
    write_pid_file "$pid"

    echo "启动命令已提交，PID: $pid"

    # 最多等待约 5 秒
    for _ in {1..20}; do
        if pid_alive "$pid"; then
            sleep 0.25
        else
            break
        fi

        if pid_matches_instance "$pid"; then
            echo
            echo "Mihomo 启动成功。"
            status_mihomo
            return 0
        fi
    done

    echo
    echo "Mihomo 启动失败。"
    rm -f "$PID_FILE"

    echo
    echo "最近日志："
    tail -100 "$LOG_FILE" 2>/dev/null || true
    exit 1
}

# ============================================================
# 停止
# ============================================================

stop_mihomo() {
    local pid=""
    local pids=""
    local still_running=""
    local waited=0

    echo "========== 停止 Mihomo =========="

    pid="$(get_managed_pid || true)"

    if [ -n "$pid" ]; then
        pids="$pid"
    else
        pids="$(find_matching_pids || true)"
    fi

    if [ -z "$pids" ]; then
        rm -f "$PID_FILE"
        echo "当前配置目录对应的 Mihomo 未运行。"
        return 0
    fi

    echo "准备停止 PID："
    printf '%s\n' "$pids"

    while read -r pid; do
        [ -n "$pid" ] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done <<< "$pids"

    # 等待最多 5 秒
    while [ "$waited" -lt 10 ]; do
        still_running=""

        while read -r pid; do
            [ -n "$pid" ] || continue

            if pid_alive "$pid"; then
                still_running="${still_running}${pid}"$'\n'
            fi
        done <<< "$pids"

        if [ -z "$still_running" ]; then
            break
        fi

        sleep 0.5
        waited=$((waited + 1))
    done

    if [ -n "$still_running" ]; then
        echo "普通停止超时，强制停止以下 PID："
        printf '%s' "$still_running"

        while read -r pid; do
            [ -n "$pid" ] || continue
            kill -KILL "$pid" 2>/dev/null || true
        done <<< "$still_running"
    fi

    rm -f "$PID_FILE"
    echo "Mihomo 已停止。"
}

restart_mihomo() {
    stop_mihomo
    sleep 1
    start_mihomo
}

# ============================================================
# 状态
# ============================================================

status_mihomo() {
    local pid=""
    local pids=""
    local curl_args=()

    load_runtime_config

    echo "========== Mihomo 实例 =========="
    echo "用户: $TARGET_USER"
    echo "配置目录: $MIHOMO_DIR"

    pid="$(get_managed_pid || true)"

    if [ -n "$pid" ]; then
        echo "状态: 运行中"
        echo "PID: $pid"

        ps -p "$pid" \
            -o pid,ppid,user,stat,lstart,etime,args \
            2>/dev/null || true
    else
        pids="$(find_matching_pids || true)"

        if [ -n "$pids" ]; then
            echo "状态: 运行中，但 PID 文件缺失或失效"
            echo "匹配 PID："
            printf '%s\n' "$pids"
        else
            echo "状态: 未运行"
        fi
    fi

    echo
    echo "========== 监听端口 =========="

    if command -v ss >/dev/null 2>&1; then
        ss -lntp 2>/dev/null |
            grep -E ":${PROXY_PORT}([[:space:]]|$)|:${CONTROLLER_PORT}([[:space:]]|$)" \
            || echo "未检测到 ${PROXY_PORT} / ${CONTROLLER_PORT} 端口监听"
    else
        echo "没有安装 ss，无法检查监听端口。"
        echo "Ubuntu 可安装：sudo apt install -y iproute2"
    fi

    echo
    echo "========== 配置关键项 =========="

    if [ -f "$CONFIG" ]; then
        grep -nE \
            "^[[:space:]]*(mixed-port|external-controller|secret|external-ui|proxy-providers|proxy-groups|rules)[[:space:]]*:" \
            "$CONFIG" |
            sed -E \
                's/^([0-9]+:[[:space:]]*secret[[:space:]]*:).*/\1 "***"/' \
            || true
    else
        echo "配置文件不存在：$CONFIG"
    fi

    echo
    echo "========== Web UI =========="

    if [ -f "$MIHOMO_DIR/ui/index.html" ]; then
        echo "Web UI 存在："
        echo "  $MIHOMO_DIR/ui/index.html"
        echo
        echo "本机访问地址："
        echo "  http://127.0.0.1:${CONTROLLER_PORT}/ui/"
    else
        echo "Web UI 不存在。"
    fi

    echo
    echo "========== Controller API =========="

    if ! command -v curl >/dev/null 2>&1; then
        echo "没有安装 curl，无法测试 Controller API。"
        return 0
    fi

    curl_args=(
        -sS
        --connect-timeout 3
        --max-time 8
    )

    if [ -n "$SECRET" ]; then
        curl_args+=(
            -H
            "Authorization: Bearer ${SECRET}"
        )
    fi

    if curl "${curl_args[@]}" \
        "http://127.0.0.1:${CONTROLLER_PORT}/configs" \
        2>/dev/null |
        head -c 2000; then

        echo
    else
        echo "Controller API 暂不可访问。"
    fi
}

# ============================================================
# 日志
# ============================================================

log_mihomo() {
    local mode="${1:-}"

    if [ ! -f "$LOG_FILE" ]; then
        echo "日志文件不存在："
        echo "  $LOG_FILE"
        exit 0
    fi

    if [ "$mode" = "-f" ] || [ "$mode" = "follow" ]; then
        tail -f "$LOG_FILE"
    else
        tail -100 "$LOG_FILE"
    fi
}

# ============================================================
# 代理测试
# ============================================================

test_proxy() {
    load_runtime_config
    need_cmd curl

    echo "使用代理："
    echo "  http://127.0.0.1:${PROXY_PORT}"
    echo

    echo "========== 代理测试：Google =========="

    curl -I -L -sS \
        -x "http://127.0.0.1:${PROXY_PORT}" \
        --connect-timeout 8 \
        --max-time 20 \
        -o /dev/null \
        -w "Google: HTTP_CODE=%{http_code} TIME=%{time_total}s REMOTE_IP=%{remote_ip}\n" \
        https://www.google.com \
        || echo "Google 代理测试失败"

    echo
    echo "========== 代理测试：ChatGPT =========="

    curl -I -L -sS \
        -x "http://127.0.0.1:${PROXY_PORT}" \
        --connect-timeout 8 \
        --max-time 20 \
        -o /dev/null \
        -w "ChatGPT: HTTP_CODE=%{http_code} TIME=%{time_total}s REMOTE_IP=%{remote_ip}\n" \
        https://chatgpt.com \
        || echo "ChatGPT 代理测试失败"

    echo
    echo "========== API 测试：OpenAI =========="

    curl -I -sS \
        -x "http://127.0.0.1:${PROXY_PORT}" \
        --connect-timeout 8 \
        --max-time 20 \
        -o /dev/null \
        -w "OpenAI API: HTTP_CODE=%{http_code} TIME=%{time_total}s REMOTE_IP=%{remote_ip}\n" \
        https://api.openai.com \
        || echo "OpenAI API 代理测试失败"
}

show_usage() {
    echo "用法："
    echo "  bash ~/.mihomo/mihomo_ctl.sh start"
    echo "  bash ~/.mihomo/mihomo_ctl.sh stop"
    echo "  bash ~/.mihomo/mihomo_ctl.sh restart"
    echo "  bash ~/.mihomo/mihomo_ctl.sh status"
    echo "  bash ~/.mihomo/mihomo_ctl.sh check"
    echo "  bash ~/.mihomo/mihomo_ctl.sh log"
    echo "  bash ~/.mihomo/mihomo_ctl.sh log -f"
    echo "  bash ~/.mihomo/mihomo_ctl.sh test"
    echo
    echo "系统级目录示例："
    echo "  sudo MIHOMO_HOME=/etc/mihomo \\"
    echo "    bash ~/.mihomo/mihomo_ctl.sh start"
}

case "${1:-}" in
    start)
        start_mihomo
        ;;

    stop)
        stop_mihomo
        ;;

    restart)
        restart_mihomo
        ;;

    status)
        status_mihomo
        ;;

    check)
        check_basic
        check_config
        ;;

    log)
        log_mihomo "${2:-}"
        ;;

    test)
        test_proxy
        ;;

    *)
        show_usage
        exit 1
        ;;
esac
