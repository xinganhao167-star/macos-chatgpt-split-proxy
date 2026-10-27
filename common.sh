#!/bin/bash
# Shared, data-only configuration and conservative process checks.
CONFIG_DIR="${SPLIT_PROXY_CONFIG_DIR:-$HOME/Library/Application Support/chatgpt-split-proxy}"
CONFIG_FILE="$CONFIG_DIR/config"
APP_PATH="${SPLIT_PROXY_APP_PATH:-/Applications/ChatGPT.app}"

valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# BRIDGE_PORT 为空 = 未启用本地桥，桌面端直接使用 PROXY_URL。
load_config() {
  local key value
  PROXY_HOST= PROXY_PORT= PAC_PORT= BRIDGE_PORT= SOCKS_HOST= SOCKS_PORT=
  [[ -f "$CONFIG_FILE" ]] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      PROXY_HOST) PROXY_HOST="$value" ;;
      PROXY_PORT) PROXY_PORT="$value" ;;
      PAC_PORT) PAC_PORT="$value" ;;
      BRIDGE_PORT) BRIDGE_PORT="$value" ;;
      SOCKS_HOST) SOCKS_HOST="$value" ;;
      SOCKS_PORT) SOCKS_PORT="$value" ;;
      '') ;;
      *) return 1 ;;
    esac
  done < "$CONFIG_FILE"
  [[ "$PROXY_HOST" == 127.0.0.1 || "$PROXY_HOST" == localhost ]] || return 1
  valid_port "$PROXY_PORT" && valid_port "$PAC_PORT" || return 1
  PROXY_URL="http://$PROXY_HOST:$PROXY_PORT"
  if [[ -n "$BRIDGE_PORT" ]]; then
    valid_port "$BRIDGE_PORT" || return 1
    [[ -n "$SOCKS_HOST" ]] || SOCKS_HOST=127.0.0.1
    valid_port "${SOCKS_PORT:-1080}" || return 1
    SOCKS_PORT="${SOCKS_PORT:-1080}"
    SOCKS_URL="$SOCKS_HOST:$SOCKS_PORT"
    CLIENT_URL="http://127.0.0.1:$BRIDGE_PORT"
  else
    SOCKS_URL= CLIENT_URL="$PROXY_URL"
  fi
}

proxy_reachable() {
  nc -z -G 2 "$PROXY_HOST" "$PROXY_PORT" >/dev/null 2>&1
}

# 桌面端实际使用的入口：启用桥时是桥，否则就是 PROXY_URL。
client_reachable() {
  nc -z -G 2 127.0.0.1 "${BRIDGE_PORT:-$PROXY_PORT}" >/dev/null 2>&1
}

# Return 0=configured, 1=wrong/missing, 2=unreadable or incomplete.
# A Chromium argument never proves the Rust Codex child inherited proxy variables.
process_proxy_state() {
  local pid="$1" role="$2" out argv key value found=0 visible=0
  out="$(ps eww -o command= -p "$pid" 2>/dev/null)" || return 2
  argv="$(ps -o command= -p "$pid" 2>/dev/null)" || return 2
  [[ -n "$out" && -n "$argv" ]] || return 2
  [[ "$out" =~ [[:space:]][A-Za-z_][A-Za-z_0-9]*= ]] && visible=1
  (( visible )) || return 2
  for key in HTTP_PROXY HTTPS_PROXY ALL_PROXY; do
    found=0
    for value in $out; do
      if [[ "$value" == "$key="* ]]; then
        found=1
        [[ "${value#*=}" == "$CLIENT_URL" ]] || return 1
      fi
    done
    (( found )) || return 1
  done
  if [[ "$role" == main ]]; then
    [[ "$argv" == *"--proxy-server=$CLIENT_URL"* ]] || return 1
  fi
  return 0
}

main_pid() {
  local pid exe
  while read -r pid exe; do
    [[ "$exe" == "$APP_PATH/Contents/MacOS/ChatGPT" ]] && printf '%s\n' "$pid"
  done < <(ps -axo pid=,comm= 2>/dev/null || true)
}

codex_children() {
  local pid="$1" child parent exe
  while read -r child parent exe; do
    [[ "$parent" == "$pid" && "$exe" == "$APP_PATH/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" ]] && printf '%s\n' "$child"
  done < <(ps -axo pid=,ppid=,comm= 2>/dev/null || true)
}
