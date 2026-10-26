#!/bin/bash
# install.sh —— 一键安装 macOS 上的「ChatGPT 走代理、其余直连」分流。
#
# 用法：
#   ./install.sh                          # 默认 127.0.0.1:8080
#   ./install.sh --proxy 127.0.0.1:7897   # 指定本地代理（HTTP 端口）
#   ./install.sh --with-watchdog          # 额外装「代理看门狗」（桌面端裸启动时自动重启）
#   ./install.sh --watchdog-only          # 只装看门狗（已装过主方案的人补装用）
#   ./install.sh --dry-run                # 只打印将要执行的命令，不改动系统
#
# 装完得到：
#   1. ~/proxy-pac/split.pac            分流规则
#   2. LaunchAgent 常驻的 PAC 文件服务器（127.0.0.1:8899）
#   3. ~/Desktop/ChatGPT代理启动.command  带代理启动 ChatGPT 桌面端
#   4.（可选）代理看门狗 LaunchAgent，每分钟检查桌面端是不是裸启动
#   并把系统「自动代理配置」指向该 PAC。

set -euo pipefail

PROXY_HOST="127.0.0.1"
PROXY_PORT="8080"
PAC_PORT="8899"
PAC_DIR="$HOME/proxy-pac"
PAC_FILE="$PAC_DIR/split.pac"
AGENT_LABEL="local.pac-server"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LAUNCHER_PATH="$HOME/Desktop/ChatGPT代理启动.command"
GUARD_LABEL="local.codex-proxy-guard"
GUARD_PLIST="$HOME/Library/LaunchAgents/$GUARD_LABEL.plist"
GUARD_DIR="$HOME/Library/Application Support/codex-proxy-guard"
GUARD_SCRIPT="$GUARD_DIR/guard.sh"
DRY_RUN="0"
WITH_WATCHDOG="0"
WATCHDOG_ONLY="0"

bold() { printf '\033[1;34m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# dry-run 模式下只打印命令
run_cmd() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '  \033[0;90m[dry-run]\033[0m %s\n' "$*"
  else
    eval "$@"
  fi
}

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --proxy)     PROXY="${2:-}"; PROXY_HOST="${PROXY%%:*}"; PROXY_PORT="${PROXY##*:}"; shift 2 ;;
    --pac-port)  PAC_PORT="${2:-}"; shift 2 ;;
    --with-watchdog) WITH_WATCHDOG="1"; shift ;;
    --watchdog-only) WATCHDOG_ONLY="1"; WITH_WATCHDOG="1"; shift ;;
    --dry-run)   DRY_RUN="1"; shift ;;
    -h|--help)   usage ;;
    *)           die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

[ "$(uname)" = "Darwin" ] || die "本脚本只适用于 macOS"

PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"

# 步骤编号：装了看门狗就是 5 步，只装看门狗就是 1 步
TOTAL=4
[ "$WITH_WATCHDOG" = "1" ] && TOTAL=5
[ "$WATCHDOG_ONLY" = "1" ] && TOTAL=1
STEP=0
step() { STEP=$((STEP + 1)); bold "$STEP/$TOTAL $1"; }

bold "安装 macOS ChatGPT 分流方案"
echo "  本地代理：$PROXY_URL"
echo "  PAC 服务：http://127.0.0.1:${PAC_PORT}/split.pac"
[ "$DRY_RUN" = "1" ] && warn "DRY-RUN 模式：不会真的改动系统"

# ---------- 0. 前置检查 ----------
if [ "$WATCHDOG_ONLY" != "1" ]; then
  command -v python3 >/dev/null 2>&1 || die "找不到 python3。执行 xcode-select --install 安装命令行工具后重试"
  if lsof -nP -iTCP:"$PAC_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    warn "端口 ${PAC_PORT} 已被占用，PAC 服务器可能起不来。先执行 ./uninstall.sh 或换个 --pac-port"
  fi
fi
if ! lsof -nP -iTCP:"$PROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  warn "本地代理端口 ${PROXY_PORT} 当前没有监听。安装可以继续，但要等你的代理客户端连上才生效"
fi

# ---------- 1. PAC 文件 ----------
install_core() {
step "写入 PAC 文件"
mkdir -p "$PAC_DIR"
if [ "$DRY_RUN" = "1" ]; then
  printf '  \033[0;90m[dry-run]\033[0m 写入 %s（把 PROXY %s 替换进模板）\n' "$PAC_FILE" "$PROXY_HOST:$PROXY_PORT"
else
  sed "s/PROXY 127\.0\.0\.1:8080/PROXY ${PROXY_HOST}:${PROXY_PORT}/g" "$(dirname "$0")/split.pac" > "$PAC_FILE"
fi
ok "$PAC_FILE"

# ---------- 2. PAC 文件服务器（LaunchAgent）----------
step "配置 PAC 文件服务器（开机自启）"
mkdir -p "$HOME/Library/LaunchAgents"
if [ "$DRY_RUN" = "1" ]; then
  printf '  \033[0;90m[dry-run]\033[0m 写入 %s\n' "$AGENT_PLIST"
else
  cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>-m</string>
        <string>http.server</string>
        <string>${PAC_PORT}</string>
        <string>--bind</string>
        <string>127.0.0.1</string>
        <string>--directory</string>
        <string>${PAC_DIR}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/${AGENT_LABEL}.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/${AGENT_LABEL}.err</string>
</dict>
</plist>
PLIST
fi
run_cmd "launchctl bootout gui/\$(id -u)/${AGENT_LABEL} 2>/dev/null || true"
run_cmd "launchctl bootstrap gui/\$(id -u) '${AGENT_PLIST}'"
run_cmd "launchctl enable gui/\$(id -u)/${AGENT_LABEL}"
ok "$AGENT_PLIST"

# ---------- 3. 系统自动代理指向 PAC ----------
step "设置系统自动代理（PAC）"
SERVICES="$(networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//')"
for svc in $SERVICES; do
  [ -z "$svc" ] && continue
  if run_cmd "networksetup -setautoproxyurl '${svc}' 'http://127.0.0.1:${PAC_PORT}/split.pac'"; then
    run_cmd "networksetup -setautoproxystate '${svc}' on"
    ok "$svc → http://127.0.0.1:${PAC_PORT}/split.pac"
  else
    warn "$svc 设置失败，可能需要管理员权限：sudo networksetup -setautoproxyurl '${svc}' 'http://127.0.0.1:${PAC_PORT}/split.pac'"
  fi
done

# ---------- 4. ChatGPT 桌面端启动器 ----------
step "生成 ChatGPT 桌面端启动器"
if [ "$DRY_RUN" = "1" ]; then
  printf '  \033[0;90m[dry-run]\033[0m 写入 %s（代理 %s）\n' "$LAUNCHER_PATH" "$PROXY_URL"
else
  mkdir -p "$HOME/Desktop"
  cat > "$LAUNCHER_PATH" <<LAUNCHER
#!/bin/bash
# 用本地代理启动 ChatGPT / Codex 桌面端；其余应用不受影响。
# 生成自 macos-chatgpt-split-proxy
#
# 为什么必须用它启动：桌面端不跟随 macOS 系统代理（PAC），
# 只有注入 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY + --proxy-server 才会走代理。
# 桌面端自动更新后会自己重启成"裸启动"，那时就会一直 Reconnecting —— 重开一次即可。

PROXY_URL="${PROXY_URL}"
APP="/Applications/ChatGPT.app"
LOG="/tmp/chatgpt-proxy-launch.log"

if [ ! -d "\$APP" ]; then
  echo "找不到 \$APP，请先安装 ChatGPT 桌面端。" | tee -a "\$LOG"
  read -r -p "按回车键关闭…" _
  exit 1
fi

# 代理没起来就别启动了，否则应用会一直卡在加载页
if ! nc -z -G 2 \$(echo "\$PROXY_URL" | sed 's#http://##; s#:# #') 2>/dev/null; then
  echo "本地代理 \$PROXY_URL 没有响应。请先连上你的代理客户端再点我。" | tee -a "\$LOG"
  read -r -p "按回车键关闭…" _
  exit 1
fi

# 清掉残留进程：ChatGPT 是单实例，残留进程会占着锁导致窗口打不开
pkill -15 -f '/Applications/ChatGPT.app' 2>/dev/null
sleep 3
pkill -9 -f '/Applications/ChatGPT.app' 2>/dev/null
sleep 1

# 两层代理都要给：
#   --proxy-server       给 Chromium/Electron 外壳
#   HTTP_PROXY 等变量   给内置的 codex CLI(Rust) 后端，它不认 socks5://，只认 http://
HTTP_PROXY="\$PROXY_URL" \\
HTTPS_PROXY="\$PROXY_URL" \\
ALL_PROXY="\$PROXY_URL" \\
"\$APP/Contents/MacOS/ChatGPT" --proxy-server="\$PROXY_URL" >>"\$LOG" 2>&1 &

sleep 3
MAIN="\$(pgrep -x ChatGPT | head -1)"
# 校验：环境变量可见就看 HTTP_PROXY；读不到环境变量就退回 argv 里的 --proxy-server
PSOUT="\$(ps eww -o command= -p "\$MAIN" 2>/dev/null)"
if printf '%s' "\$PSOUT" | tr ' ' '\\n' | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; then
  HAS_PROXY="\$(printf '%s' "\$PSOUT" | tr ' ' '\\n' | grep -c '^HTTP_PROXY=')"
else
  HAS_PROXY="\$(ps -o command= -p "\$MAIN" 2>/dev/null | grep -c -- '--proxy-server=')"
fi
if [ -n "\$MAIN" ] && [ "\${HAS_PROXY:-0}" -gt 0 ]; then
  echo "已带代理启动（\$PROXY_URL）。如果窗口里还在转圈，等几秒再看。"
else
  echo "启动异常：应用没拿到代理环境变量，试试再点一次。"
fi

exit 0
LAUNCHER
  chmod +x "$LAUNCHER_PATH"
fi
ok "$LAUNCHER_PATH"
}

if [ "$WATCHDOG_ONLY" != "1" ]; then
  install_core
fi

# ---------- 5. 代理看门狗（可选）----------
if [ "$WITH_WATCHDOG" = "1" ]; then
  step "安装代理看门狗（桌面端裸启动时自动重启）"
  if [ "$DRY_RUN" = "1" ]; then
    printf '  \033[0;90m[dry-run]\033[0m 写入 %s 与 %s\n' "$GUARD_SCRIPT" "$GUARD_PLIST"
  else
    mkdir -p "$GUARD_DIR" "$HOME/Library/LaunchAgents"
    cp "$(dirname "$0")/guard.sh" "$GUARD_SCRIPT"
    chmod +x "$GUARD_SCRIPT"
    cat > "$GUARD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${GUARD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${GUARD_SCRIPT}</string>
    </array>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>/tmp/${GUARD_LABEL}.out</string>
    <key>StandardErrorPath</key>
    <string>/tmp/${GUARD_LABEL}.err</string>
</dict>
</plist>
PLIST
  fi
  run_cmd "launchctl bootout gui/\$(id -u)/${GUARD_LABEL} 2>/dev/null || true"
  run_cmd "launchctl bootstrap gui/\$(id -u) '${GUARD_PLIST}'"
  run_cmd "launchctl enable gui/\$(id -u)/${GUARD_LABEL}"
  ok "$GUARD_SCRIPT"
  ok "$GUARD_PLIST"
else
  warn "没装看门狗。桌面端自动更新后如果一直 Reconnecting，执行 ./install.sh --watchdog-only 补装"
fi

# ---------- 完成 ----------
if [ "$WATCHDOG_ONLY" = "1" ]; then
  bold "看门狗安装完成"
else
  bold "安装完成"
fi
cat <<EOF

  日常两步，顺序不能反：
    1) 先连上你的代理客户端（Anycast / Clash / Surge 等），确认本地 HTTP 端口 ${PROXY_PORT} 已监听
    2) 网页版：直接用 Chrome 打开 https://chatgpt.com （系统 PAC 已生效，只有 ChatGPT 域名走代理）
       桌面端：双击桌面上的「ChatGPT代理启动.command」
EOF
if [ "$WITH_WATCHDOG" = "1" ]; then
cat <<EOF

  看门狗每 60 秒检查一次桌面端是否裸启动，裸启动满 120 秒就自动带代理重启
  日志：~/Library/Logs/codex-proxy-guard.log
  单次体检：${GUARD_SCRIPT} --check
EOF
fi
cat <<EOF

  自检：./diagnose.sh
  卸载：./uninstall.sh
EOF
