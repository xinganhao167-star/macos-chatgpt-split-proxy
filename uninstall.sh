#!/bin/bash
# Restore PAC state captured by install.sh. Never reset unknown user settings.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/common.sh"
BACKUP_DIR="$CONFIG_DIR/pac-backup"
PAC_DIR="$HOME/proxy-pac"
PAC_FILE="$PAC_DIR/split.pac"
LAUNCHER="$HOME/Desktop/ChatGPT代理启动.command"
AGENT_PLIST="$HOME/Library/LaunchAgents/local.pac-server.plist"
GUARD_PLIST="$HOME/Library/LaunchAgents/local.codex-proxy-guard.plist"
GUARD_DIR="$HOME/Library/Application Support/codex-proxy-guard"
BRIDGE_PLIST="$HOME/Library/LaunchAgents/local.split-proxy-bridge.plist"
BRIDGE_DIR="$CONFIG_DIR/bridge"
[[ "$(uname)" == Darwin ]] || { echo "仅支持 macOS" >&2; exit 1; }
if ! load_config; then
  if [[ ! -e "$AGENT_PLIST" && ! -e "$GUARD_PLIST" && ! -e "$BRIDGE_PLIST" && ! -e "$PAC_FILE" && ! -e "$LAUNCHER" ]]; then
    echo "本方案已卸载，无需重复操作。"
    exit 0
  fi
  echo "安装配置不存在或无效；为避免覆盖用户网络设置，停止卸载。" >&2
  exit 1
fi
PAC_URL="http://127.0.0.1:$PAC_PORT/split.pac"
KEEP_SERVER=0
for legacy in "$BACKUP_DIR"/legacy.*; do
  [[ -f "$legacy" ]] || continue
  KEEP_SERVER=1
  IFS= read -r svc < "$legacy"
  echo "警告：$svc 是旧版安装，原 PAC 未记录；保留其设置及 PAC 服务器。" >&2
done
for file in "$BACKUP_DIR"/[0-9]*; do
  [[ -f "$file" ]] || continue
  IFS= read -r svc < "$file"
  previous_url="$(sed -n '2p' "$file")"
  previous_state="$(sed -n '3p' "$file")"
  [[ "$previous_state" == Yes ]] && previous_state=on || previous_state=off
  current="$(networksetup -getautoproxyurl "$svc" 2>/dev/null || true)"
  current_url="$(printf '%s\n' "$current" | sed -n 's/^URL: //p' | head -1)"
  if [[ "$current_url" != "$PAC_URL" ]]; then
    [[ "$current_url" == "$PAC_URL"* ]] && KEEP_SERVER=1
    echo "警告：$svc 的 PAC 已由其他程序更改，保留当前设置。" >&2
    continue
  fi
  networksetup -setautoproxyurl "$svc" "$previous_url"
  networksetup -setautoproxystate "$svc" "$previous_state"
  echo "已恢复 $svc 的原 PAC 状态"
done
launchctl bootout "gui/$(id -u)/local.split-proxy-bridge" 2>/dev/null || true
rm -f "$BRIDGE_PLIST"
rm -rf "$BRIDGE_DIR"
launchctl bootout "gui/$(id -u)/local.codex-proxy-guard" 2>/dev/null || true
rm -f "$GUARD_PLIST" "$GUARD_DIR/guard.sh" "$GUARD_DIR/common.sh"
if [[ "$KEEP_SERVER" == 0 ]]; then
  launchctl bootout "gui/$(id -u)/local.pac-server" 2>/dev/null || true
  rm -f "$AGENT_PLIST" "$PAC_FILE"
  rmdir "$PAC_DIR" 2>/dev/null || true
  rm -f "$CONFIG_FILE" "$CONFIG_DIR/common.sh"
  rm -rf "$BACKUP_DIR"
  rmdir "$CONFIG_DIR" 2>/dev/null || true
fi
rm -f "$LAUNCHER"
RELAY_PLIST="/Library/LaunchDaemons/local.chatgpt-sni-relay.plist"
if [[ -f "$RELAY_PLIST" ]] || grep -q 'chatgpt-split-proxy relay' /etc/hosts 2>/dev/null; then
  echo "提醒：SNI 中继仍未卸载（root 安装，不在本脚本范围内）。" >&2
  echo "      sudo bash \"$ROOT/relay/teardown-root.sh\"" >&2
fi
echo "卸载完成。正在运行的 ChatGPT/Codex 未受影响。"
