#!/bin/bash
# Default: observe and alert. --auto-recover may only start an absent app.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh" || exit 3
LOG="${GUARD_LOG:-$HOME/Library/Logs/codex-proxy-guard.log}"
LAUNCHER="${GUARD_LAUNCHER:-$HOME/Desktop/ChatGPT代理启动.command}"
STATE_DIR="${GUARD_STATE_DIR:-$CONFIG_DIR/guard-state}"
MODE="${1:-}"
case "$MODE" in ''|--check|--auto-recover) ;; *) echo "用法: guard.sh [--check|--auto-recover]" >&2; exit 3 ;; esac

log() {
  [[ "$MODE" == --check ]] && return
  mkdir -p "$(dirname "$LOG")"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}
report() {
  echo "$1"
  log "$1"
  if [[ "$MODE" != --check && ( "$2" == 1 || "$2" == 3 ) ]]; then
    mkdir -p "$STATE_DIR"
    local previous="" timestamp=0 now
    if [[ -f "$STATE_DIR/last_alert" ]]; then
      read -r previous timestamp < "$STATE_DIR/last_alert"
    fi
    [[ "$timestamp" =~ ^[0-9]+$ ]] || timestamp=0
    now="$(date +%s)"
    if [[ "$previous" != "$2" || $((now - timestamp)) -ge 1800 ]]; then
      printf '%s %s\n' "$2" "$now" > "$STATE_DIR/last_alert.$$"
      mv "$STATE_DIR/last_alert.$$" "$STATE_DIR/last_alert"
      osascript -e 'display notification "代理状态异常，请查看 codex-proxy-guard.log" with title "ChatGPT 代理看门狗"' >/dev/null 2>&1 || true
    fi
  fi
  exit "$2"
}
load_config || report "UNKNOWN 配置缺失或无效" 3
PIDS="$(main_pid)"
[[ -z "$PIDS" ]] && {
  [[ "$MODE" == --auto-recover ]] || report "ABSENT 桌面端未运行" 2
  [[ -x "$LAUNCHER" ]] || report "UNKNOWN 启动器不存在或不可执行" 3
  proxy_reachable || report "UNKNOWN 本地代理不可用" 3
  mkdir -p "$STATE_DIR"
  if ! mkdir "$STATE_DIR/lock" 2>/dev/null; then
    report "UNKNOWN 已有恢复检查运行" 3
  fi
  trap 'rmdir "$STATE_DIR/lock" 2>/dev/null || true' EXIT
  [[ -z "$(main_pid)" ]] || report "UNKNOWN 桌面端刚刚启动，取消恢复" 3
  NOW="$(date +%s)"
  LAST=0
  [[ -f "$STATE_DIR/last_launch" ]] && read -r LAST < "$STATE_DIR/last_launch"
  [[ "$LAST" =~ ^[0-9]+$ ]] || LAST=0
  (( NOW - LAST >= 1800 )) || report "UNKNOWN 30 分钟冷却中" 3
  printf '%s\n' "$NOW" > "$STATE_DIR/last_launch"
  "$LAUNCHER" >/dev/null 2>&1 || report "UNKNOWN 启动器失败，未终止任何进程" 3
  report "STARTED 桌面端原本未运行，已通过启动器启动" 0
}
[[ "$PIDS" != *$'\n'* ]] || report "UNKNOWN 发现多个桌面主进程" 3
STATE=0
process_proxy_state "$PIDS" main || STATE=$?
case "$STATE" in
  1) report "BAD 主进程代理配置缺失或与 $PROXY_URL 不一致；请手动退出后用启动器重开" 1 ;;
  2) report "UNKNOWN 无法读取主进程完整代理环境" 3 ;;
esac
CHILDREN="$(codex_children "$PIDS")"
[[ -n "$CHILDREN" ]] || report "UNKNOWN 未找到 Codex 子进程，无法验证代理继承" 3
while IFS= read -r child; do
  STATE=0
  process_proxy_state "$child" codex || STATE=$?
  case "$STATE" in
    1) report "BAD Codex 子进程 $child 代理配置缺失或错误；仅告警，不重启" 1 ;;
    2) report "UNKNOWN 无法读取 Codex 子进程 $child 的代理环境" 3 ;;
  esac
done <<< "$CHILDREN"
proxy_reachable || report "BAD 进程配置正确，但本地代理不可达" 1
report "CONFIG_OK 主进程及 Codex 子进程代理配置一致，本地代理可达；API/WebSocket 状态未知" 0
