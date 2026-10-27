#!/bin/bash
# Generated as ~/Desktop/ChatGPT代理启动.command. Never terminates an existing session.
set -u
CONFIG_DIR="${SPLIT_PROXY_CONFIG_DIR:-$HOME/Library/Application Support/chatgpt-split-proxy}"
source "$CONFIG_DIR/common.sh" || exit 1
load_config || { echo "代理配置缺失或无效：$CONFIG_FILE" >&2; exit 1; }
[[ -x "$APP_PATH/Contents/MacOS/ChatGPT" ]] || { echo "找不到 ChatGPT 应用：$APP_PATH" >&2; exit 1; }
client_reachable || {
  if [[ -n "${BRIDGE_PORT:-}" ]]; then
    echo "本地桥不可用：${CLIENT_URL}（上游 SOCKS ${SOCKS_URL}）。" >&2
    echo "先确认 VPN 已连上，并检查 LaunchAgent local.split-proxy-bridge。" >&2
  else
    echo "本地代理不可用：$CLIENT_URL" >&2
  fi
  exit 1
}
if [[ -n "$(main_pid)" ]]; then
  echo "ChatGPT 正在运行。为保护 Codex 任务，请先在应用中手动退出，再运行启动器。" >&2
  exit 2
fi
LOG="$HOME/Library/Logs/chatgpt-proxy-launch.log"
mkdir -p "$(dirname "$LOG")"
# NO_PROXY 只为挡回环：本地 MCP / 本地端口不该绕道境外出口。
HTTP_PROXY="$CLIENT_URL" HTTPS_PROXY="$CLIENT_URL" ALL_PROXY="$CLIENT_URL" \
NO_PROXY="127.0.0.1,localhost,::1" no_proxy="127.0.0.1,localhost,::1" \
  "$APP_PATH/Contents/MacOS/ChatGPT" "--proxy-server=$CLIENT_URL" >>"$LOG" 2>&1 &
if [[ -n "${BRIDGE_PORT:-}" ]]; then
  echo "已启动 ChatGPT（经本地桥 ${CLIENT_URL} → SOCKS ${SOCKS_URL}）；连接状态请用 diagnose.sh 检查。"
else
  echo "已启动 ChatGPT（${CLIENT_URL}）；连接状态请用 diagnose.sh 检查。"
fi
