# Mihomo Bash Kit

一套面向 Linux + Bash 的轻量 Mihomo 安装、订阅和进程管理脚本。

这个仓库只包含通用脚本，不包含任何个人订阅链接、代理节点、Controller 密钥、IP 地址、日志、缓存、Geo 数据库或 Web UI 构建产物。Mihomo 核心、Country.mmdb 和 MetaCubeXD 会在使用时从上游下载。

## 功能

- 安装 Mihomo（支持 `x86_64/amd64` 和 `aarch64/arm64`）
- 下载 Country.mmdb 和 MetaCubeXD Web UI
- 添加、更新、删除和列出 URL/本地文件订阅
- 自动生成并校验 `config.yaml`
- 启动、停止、重启、检查状态、查看日志和测试代理
- 自动接入 `.bashrc`，提供 `mihomo-*` 与 `proxy-*` 命令
- 安装时生成独立 Controller 密钥

## 环境要求

- Linux、Bash
- 常用命令：`curl`、`gzip`、`git`、`coreutils`
- 可选：`sudo`（系统级安装）、`openssl`（生成随机密钥）

Debian/Ubuntu：

```bash
sudo apt update
sudo apt install -y curl gzip git ca-certificates coreutils iproute2
```

## 安装

```bash
git clone git@github.com:xqy-2025/mihomo-bash-kit.git
cd mihomo-bash-kit
./install.sh
source ~/.bashrc
```

安装器会把通用脚本复制到 `${MIHOMO_HOME:-$HOME/.mihomo}`，但会保留该目录中已有的订阅、配置、密钥和运行数据。

然后安装组件：

```bash
bash ~/.mihomo/install_mihomo.sh
bash ~/.mihomo/install_geo.sh
bash ~/.mihomo/install_ui.sh
```

如需把 Mihomo 安装到用户目录而不使用系统目录，可以在没有 `sudo` 的环境运行；脚本会回退到 `~/.local/bin/mihomo`。

## 添加订阅

URL 订阅（请保留引号，避免 shell 解释链接中的特殊字符）：

```bash
bash ~/.mihomo/sub_add.sh my-sub url 'https://example.invalid/subscription?token=REPLACE_ME'
```

本地 Provider 文件：

```bash
bash ~/.mihomo/sub_add.sh local-sub file '/path/to/provider.yaml'
```

查看和删除：

```bash
bash ~/.mihomo/sub_manage.sh list
bash ~/.mihomo/sub_del.sh my-sub
```

URL 会保存在本机的 `~/.mihomo/subscriptions.tsv` 中，`list` 命令不会显示 URL。不要把该文件提交到 Git；仓库的 `.gitignore` 已默认排除它。

## 启动与日常使用

```bash
mihomo-check
mihomo-start
mihomo-status
mihomo-log
mihomo-log -f
mihomo-test
mihomo-restart
mihomo-stop
```

当前终端的代理环境：

```bash
proxy-on
proxy-status
proxy-test
proxy-off
```

默认混合代理地址为 `http://127.0.0.1:6669`，默认 Controller 地址为 `127.0.0.1:9090`，DNS 监听为 `127.0.0.1:1053`。如果修改端口，可在添加/更新订阅时设置：

```bash
MIHOMO_MIXED_PORT=7890 \
MIHOMO_CONTROLLER_PORT=9091 \
MIHOMO_DNS_PORT=1054 \
bash ~/.mihomo/sub_add.sh my-sub url 'https://example.invalid/subscription'
```

同时把 shell 代理地址设置为一致的值，例如加入 `.bashrc`：

```bash
export PROXY_ADDR=http://127.0.0.1:7890
```

## Web UI 与局域网访问

本机 Web UI：

```text
http://127.0.0.1:9090/ui/
```

Controller 密钥保存在：

```text
~/.mihomo/secret
```

默认只允许本机访问。确实需要在可信局域网开放时，用以下环境变量重新添加或更新任意订阅，以重建配置：

```bash
MIHOMO_ALLOW_LAN=true \
MIHOMO_BIND_ADDRESS='*' \
MIHOMO_CONTROLLER_HOST=0.0.0.0 \
bash ~/.mihomo/sub_add.sh my-sub url 'https://example.invalid/subscription'
```

局域网模式会暴露代理端口与 Controller，请确保密钥未泄露，并使用主机防火墙限制可信网段。不要把 Controller 直接暴露到公网。

## 自定义目录

```bash
MIHOMO_HOME="$HOME/apps/mihomo" ./install.sh
```

需要长期使用自定义目录时，在加载 `mihomo.bash` 之前设置并导出 `MIHOMO_HOME`。

## 目录说明

仓库内容：

```text
.
├── install.sh              # 部署脚本并接入 .bashrc
├── shell/mihomo.bash       # Bash 函数与别名
└── scripts/
    ├── install_mihomo.sh   # Mihomo 核心安装器
    ├── install_geo.sh      # Country.mmdb 安装器
    ├── install_ui.sh       # MetaCubeXD 安装器
    ├── mihomo_ctl.sh       # 进程和状态管理
    ├── sub_manage.sh       # 订阅与配置管理
    ├── sub_add.sh          # 添加订阅快捷入口
    └── sub_del.sh          # 删除订阅快捷入口
```

运行后生成但不应提交的内容包括：

```text
config.yaml  subscriptions.tsv  secret  providers/
*.log  *.pid  *.db  Country.mmdb  country.mmdb  ui/
```

## 更新

拉取新版本后重新运行：

```bash
git pull
./install.sh
```

安装器只更新工具脚本和 Bash 集成，不会覆盖已有 `config.yaml`、订阅、Provider、密钥、日志或数据库。

## 发布到 GitHub

确认隐私检查通过后，可执行：

```bash
git init
git add .
git status
git commit -m "Initial public release"
git branch -M main
git remote add origin git@github.com:xqy-2025/mihomo-bash-kit.git
git push -u origin main
```

在 `git status` 和 `git diff --cached` 中再次确认没有 `config.yaml`、`subscriptions.tsv`、`providers/` 或 `secret` 后再推送。

## 上游项目

- Mihomo: <https://github.com/MetaCubeX/mihomo>
- MetaCubeXD: <https://github.com/MetaCubeX/metacubexd>
- Meta rules dat: <https://github.com/MetaCubeX/meta-rules-dat>

本仓库不打包或重新分发上述项目的二进制与数据文件。
