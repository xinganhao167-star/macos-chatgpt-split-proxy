#!/bin/bash
# guard.sh —— ChatGPT / Codex 桌面端「代理看门狗」
#
# 为什么需要它：桌面端不会跟随 macOS 系统代理（PAC），只有启动器注入的
#   HTTP_PROXY/HTTPS_PROXY/ALL_PROXY（给内置 codex CLI 后端）
#   + --proxy-server（给 Chromium/Electron 外壳）
# 才会走代理。而桌面端**自动更新后会自己重启**，重启出来的实例是「裸启动」
# （两个都没有），后端直连被墙的目标，表现为一直 Reconnecting / request timed out。
# 看门狗每分钟检查一次，发现裸启动就自动用启动器带代理重启一次。
#
# 用法：
#   ./guard.sh            常规模式：检查 + 必要时自愈（由 LaunchAgent 每分钟调用）
#   ./guard.sh --check    只体检不动作：打印当前状态并返回 0=健康 1=裸启动 2=没运行
#
# 行为细则：
#   - 进程没在跑                 → 什么都不做
#   - 进程带着代理               → 什么都不做
#   - 裸启动且已存活 ≥120 秒     → 先确认本地代理端口通，再用启动器带代理重启
#   - 30 分钟内已重启 3 次       → 停手并记日志（避免无限重启），需人工介入
#
# 判定「是否带代理」用双信号，因为 macOS 的 ps e 对部分系统二进制读不到环境变量：
#   环境变量可见 → 以 HTTP_PROXY 为准；不可见 → 退回 argv 里的 --proxy-server
#
# 测试/自定义可用环境变量覆盖默认值：
#   GUARD_PROC / GUARD_PROXY_URL / GUARD_MIN_UPTIME / GUARD_LAUNCHER / GUARD_LOG / GUARD_STATE_DIR

set -uo pipefail

PROC="${GUARD_PROC:-ChatGPT}"
PROXY_URL="${GUARD_PROXY_URL:-http://127.0.0.1:8080}"
MIN_UPTIME="${GUARD_MIN_UPTIME:-120}"
LAUNCHER="${GUARD_LAUNCHER:-$HOME/Desktop/ChatGPT代理启动.command}"
LOG="${GUARD_LOG:-$HOME/Library/Logs/codex-proxy-guard.log}"
STATE_DIR="${GUARD_STATE_DIR:-$HOME/Library/Application Support/codex-proxy-guard}"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

HOSTPORT="${PROXY_URL#http://}"
HOST="${HOSTPORT%%:*}"
PORT="${HOSTPORT##*:}"

mkdir -p "$STATE_DIR" "$(dirname "$LOG")" 2>/dev/null

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
}

# 进程是否带着代理：0 = 带，1 = 不带
# 注意：这里刻意不用 `... | grep -q` —— 脚本开了 pipefail，grep 提前退出会让上游
#       收到 SIGPIPE，整条管道被判成失败，判定就会飘。用 read -ra 切词最稳。
has_proxy() {
  local pid="$1" psout argv token
  local -a tokens
  psout="$(ps eww -o command= -p "$pid" 2>/dev/null)"
  read -ra tokens <<< "$psout"

  local env_visible=0 has_proxy_env=0
  for token in "${tokens[@]}"; do
    case "$token" in
      HTTP_PROXY=*) has_proxy_env=1; env_visible=1 ;;
      [A-Za-z_]*=*) env_visible=1 ;;
    esac
  done

  # 环境变量可见 → 以 HTTP_PROXY 为准（可见却没有，就是裸启动）
  if [ "$env_visible" = "1" ]; then
    [ "$has_proxy_env" = "1" ] && return 0
    return 1
  fi

  # 环境变量读不到 → 退回命令行参数
  argv="$(ps -o command= -p "$pid" 2>/dev/null)"
  case "$argv" in
    *--proxy-server=*) return 0 ;;
  esac
  return 1
}

# 进程已存活多少秒
uptime_of() {
  local pid="$1" elapsed
  # 注意：macOS 的 ps 没有 etimes 关键字（那是 GNU/Linux 的），这里用 etime 自己换算
  #      etime 形如 00:12 / 01:02:03 / 1-00:00:00
  elapsed="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
  echo "$elapsed" | awk -F'[-:]' '{
    if (NF == 4) print $1*86400 + $2*3600 + $3*60 + $4;
    else if (NF == 3) print $1*3600 + $2*60 + $3;
    else if (NF == 2) print $1*60 + $2;
    else print 0;
  }'
}

PID="$(pgrep -x "$PROC" | head -1)"

# 1) 没在运行
if [ -z "$PID" ]; then
  rm -f "$STATE_DIR/first_seen"
  if [ "$CHECK_ONLY" = "1" ]; then
    echo "桌面端没在运行"
    exit 2
  fi
  exit 0
fi

# 2) 已经带代理 → 健康
if has_proxy "$PID"; then
  rm -f "$STATE_DIR/first_seen"
  if [ "$CHECK_ONLY" = "1" ]; then
    echo "健康：PID $PID 带着代理"
    exit 0
  fi
  exit 0
fi

UPTIME="$(uptime_of "$PID")"
case "$UPTIME" in
  ''|*[!0-9]*) UPTIME=0 ;;
esac

if [ "$CHECK_ONLY" = "1" ]; then
  echo "裸启动：PID $PID 没有任何代理（已存活 ${UPTIME}s）"
  exit 1
fi

# 3) 裸启动：等满 MIN_UPTIME 再处理（避免误杀刚启动、还在握手的实例）
if [ "$UPTIME" -lt "$MIN_UPTIME" ]; then
  if [ ! -f "$STATE_DIR/first_seen" ]; then
    date +%s > "$STATE_DIR/first_seen"
    log "发现裸启动（已存活 ${UPTIME}s），等满 ${MIN_UPTIME}s 再处理"
  fi
  exit 0
fi

# 代理本身没起来 → 无从重启，等下一轮
if ! nc -z -G 2 "$HOST" "$PORT" 2>/dev/null; then
  log "本地代理 $PROXY_URL 没响应，暂不重启（等代理连上再处理）"
  exit 0
fi

# 4) 限流：30 分钟内最多重启 3 次
NOW="$(date +%s)"
KEEP=$(( NOW - 1800 ))
: > "$STATE_DIR/restarts.new"
if [ -f "$STATE_DIR/restarts" ]; then
  while read -r ts; do
    case "$ts" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$ts" -gt "$KEEP" ] && printf '%s\n' "$ts" >> "$STATE_DIR/restarts.new"
  done < "$STATE_DIR/restarts"
fi
COUNT="$(wc -l < "$STATE_DIR/restarts.new" | tr -d ' ')"
if [ "${COUNT:-0}" -ge 3 ]; then
  mv "$STATE_DIR/restarts.new" "$STATE_DIR/restarts"
  log "30 分钟内已重启 ${COUNT} 次，暂停自动处理，请手动双击桌面启动器"
  exit 0
fi
printf '%s\n' "$NOW" >> "$STATE_DIR/restarts.new"
mv "$STATE_DIR/restarts.new" "$STATE_DIR/restarts"

log "裸启动已持续 ${UPTIME}s，用启动器带代理重启"

if [ -x "$LAUNCHER" ]; then
  "$LAUNCHER" >/dev/null 2>&1
else
  log "找不到可执行的启动器（$LAUNCHER），只清理不重启"
  pkill -15 -f '/Applications/ChatGPT.app' 2>/dev/null
  sleep 3
  pkill -9 -f '/Applications/ChatGPT.app' 2>/dev/null
fi

sleep 3
NEWPID="$(pgrep -x "$PROC" | head -1)"
if [ -n "$NEWPID" ] && has_proxy "$NEWPID"; then
  log "已恢复：PID $NEWPID 带着代理（HTTP_PROXY/--proxy-server）"
else
  log "警告：重启后仍未检测到代理，启动器或代理口可能有问题"
fi
