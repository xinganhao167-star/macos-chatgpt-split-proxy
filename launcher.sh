#!/bin/bash
# Generated as ~/Desktop/ChatGPT代理启动.command. Never terminates an existing session.
set -u
CONFIG_DIR="${SPLIT_PROXY_CONFIG_DIR:-$HOME/Library/Application Support/chatgpt-split-proxy}"
source "$CONFIG_DIR/common.sh" || exit 1
load_config || { echo "代理配置缺失或无效：$CONFIG_FILE" >&2; exit 1; }
[[ -x "$APP_PATH/Contents/MacOS/ChatGPT" ]] || { echo "找不到 ChatGPT 应用：$APP_PATH" >&2; exit 1; }
proxy_reachable || { echo "本地代理不可用：$PROXY_URL" >&2; exit 1; }
if [[ -n "$(main_pid)" ]]; then
  echo "ChatGPT 正在运行。为保护 Codex 任务，请先在应用中手动退出，再运行启动器。" >&2
  exit 2
fi
LOG="$HOME/Library/Logs/chatgpt-proxy-launch.log"
mkdir -p "$(dirname "$LOG")"
HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" ALL_PROXY="$PROXY_URL" \
  "$APP_PATH/Contents/MacOS/ChatGPT" "--proxy-server=$PROXY_URL" >>"$LOG" 2>&1 &
echo "已启动 ChatGPT（${PROXY_URL}）；连接状态请用 diagnose.sh 检查。"
