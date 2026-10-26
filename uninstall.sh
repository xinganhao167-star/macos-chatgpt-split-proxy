#!/bin/bash
# uninstall.sh —— 撤销 install.sh 做的所有改动。
# 不删除你的代理客户端（Anycast / Clash 等），只清理本方案留下的东西。

set -uo pipefail

PAC_PORT="8899"
PAC_DIR="$HOME/proxy-pac"
AGENT_LABEL="local.pac-server"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LAUNCHER_PATH="$HOME/Desktop/ChatGPT代理启动.command"
GUARD_LABEL="local.codex-proxy-guard"
GUARD_PLIST="$HOME/Library/LaunchAgents/$GUARD_LABEL.plist"
GUARD_DIR="$HOME/Library/Application Support/codex-proxy-guard"
GUARD_LOG="$HOME/Library/Logs/codex-proxy-guard.log"

bold() { printf '\033[1;34m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }

bold "卸载 macOS ChatGPT 分流方案"

# 1. 系统自动代理
SERVICES="$(networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//')"
for svc in $SERVICES; do
  [ -z "$svc" ] && continue
  networksetup -setautoproxyurl "$svc" "" >/dev/null 2>&1
  networksetup -setautoproxystate "$svc" off >/dev/null 2>&1
  ok "已清空 $svc 的自动代理"
done

# 2. PAC 服务器
launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
[ -f "$AGENT_PLIST" ] && rm -f "$AGENT_PLIST" && ok "已移除 $AGENT_PLIST"

# 3. 看门狗
launchctl bootout "gui/$(id -u)/$GUARD_LABEL" 2>/dev/null || true
[ -f "$GUARD_PLIST" ] && rm -f "$GUARD_PLIST" && ok "已移除 $GUARD_PLIST"
[ -d "$GUARD_DIR" ] && rm -rf "$GUARD_DIR" && ok "已删除 $GUARD_DIR"
[ -f "$GUARD_LOG" ] && rm -f "$GUARD_LOG" && ok "已删除 $GUARD_LOG"

# 4. 文件
[ -d "$PAC_DIR" ] && rm -rf "$PAC_DIR" && ok "已删除 $PAC_DIR"
[ -f "$LAUNCHER_PATH" ] && rm -f "$LAUNCHER_PATH" && ok "已删除 $LAUNCHER_PATH"

echo
bold "完成。"
echo "  如果你还想清掉系统设置里残留的扩展项，请到："
echo "    系统设置 → 通用 → 登录项与扩展 → 扩展（按类别）→ 网络扩展"
echo "  另外确认你的代理客户端处于「仅代理 / 系统代理关闭」模式，否则整机流量仍会被接管。"
