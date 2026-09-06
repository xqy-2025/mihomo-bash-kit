# Mihomo shell helpers. This file is meant to be sourced by Bash.

export MIHOMO_HOME="${MIHOMO_HOME:-$HOME/.mihomo}"

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

export PROXY_ADDR="${PROXY_ADDR:-http://127.0.0.1:6669}"
export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1}"
export no_proxy="$NO_PROXY"

_mihomo_proxy_ready() {
    local port="${PROXY_ADDR##*:}"
    port="${port%%/*}"

    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | grep -Eq ":${port}([[:space:]]|$)"
        return
    fi

    timeout 1 bash -c \
        "exec 3<>/dev/tcp/127.0.0.1/${port}" \
        >/dev/null 2>&1
}

proxy_on() {
    export HTTP_PROXY="$PROXY_ADDR" HTTPS_PROXY="$PROXY_ADDR" ALL_PROXY="$PROXY_ADDR"
    export http_proxy="$PROXY_ADDR" https_proxy="$PROXY_ADDR" all_proxy="$PROXY_ADDR"
    export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1}"
    export no_proxy="$NO_PROXY"
    echo "代理环境已开启：$PROXY_ADDR"
}

proxy_off() {
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
    export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1}"
    export no_proxy="$NO_PROXY"
    echo "代理环境已关闭。"
}

proxy_status() {
    printf 'HTTP_PROXY=%s\n' "${HTTP_PROXY:-未设置}"
    printf 'HTTPS_PROXY=%s\n' "${HTTPS_PROXY:-未设置}"
    printf 'ALL_PROXY=%s\n' "${ALL_PROXY:-未设置}"
    printf 'NO_PROXY=%s\n' "${NO_PROXY:-未设置}"

    if _mihomo_proxy_ready; then
        echo "Mihomo 代理端口正在监听：$PROXY_ADDR"
    else
        echo "Mihomo 代理端口未监听：$PROXY_ADDR"
    fi
}

proxy_test() {
    curl -I -L -sS -x "$PROXY_ADDR" \
        --connect-timeout 8 \
        --max-time 20 \
        -o /dev/null \
        -w 'HTTP_CODE=%{http_code} TIME=%{time_total}s REMOTE_IP=%{remote_ip}\n' \
        https://www.google.com
}

mihomo_start() { bash "$MIHOMO_HOME/mihomo_ctl.sh" start && proxy_on; }
mihomo_stop() { bash "$MIHOMO_HOME/mihomo_ctl.sh" stop; proxy_off; }
mihomo_restart() { bash "$MIHOMO_HOME/mihomo_ctl.sh" restart && proxy_on; }
mihomo_status() { bash "$MIHOMO_HOME/mihomo_ctl.sh" status; }
mihomo_log() { bash "$MIHOMO_HOME/mihomo_ctl.sh" log "$@"; }
mihomo_test() { bash "$MIHOMO_HOME/mihomo_ctl.sh" test; }
mihomo_check() { bash "$MIHOMO_HOME/mihomo_ctl.sh" check; }

alias proxy-on='proxy_on'
alias proxy-off='proxy_off'
alias proxy-status='proxy_status'
alias proxy-test='proxy_test'
alias mihomo-start='mihomo_start'
alias mihomo-stop='mihomo_stop'
alias mihomo-restart='mihomo_restart'
alias mihomo-status='mihomo_status'
alias mihomo-log='mihomo_log'
alias mihomo-test='mihomo_test'
alias mihomo-check='mihomo_check'

# Keep new shells consistent with the actual listener state.
if _mihomo_proxy_ready; then
    export HTTP_PROXY="$PROXY_ADDR" HTTPS_PROXY="$PROXY_ADDR" ALL_PROXY="$PROXY_ADDR"
    export http_proxy="$PROXY_ADDR" https_proxy="$PROXY_ADDR" all_proxy="$PROXY_ADDR"
else
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
fi
