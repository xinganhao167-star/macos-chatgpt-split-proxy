#!/bin/bash
# diagnose.sh —— 一键体检：分流到底通没通、哪一环断了。
# 只做只读检查，不会改动任何网络设置。

set -uo pipefail

PROXY_HOST="127.0.0.1"
PROXY_PORT="${PROXY_PORT:-8080}"
PAC_PORT="${PAC_PORT:-8899}"

bold() { printf '\033[1;34m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }
note() { printf '    \033[0;90m%s\033[0m\n' "$*"; }

echo
bold "① 本地代理端口"
for p in "$PROXY_PORT" 1080 7890 7897 6152 1087; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    proc="$(lsof -nP -iTCP:"$p" -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | head -1 | xargs -I{} ps -o comm= -p {} 2>/dev/null | xargs)"
    ok "端口 $p 有监听 ${proc:+（$proc）}"
  fi
done
if ! lsof -nP -iTCP:"$PROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  bad "端口 $PROXY_PORT 没有代理在监听 —— 先连上你的代理客户端"
fi

echo
bold "② 系统自动代理（PAC）"
if scutil --proxy | grep -q "ProxyAutoConfigEnable : 1"; then
  url="$(scutil --proxy | awk '/ProxyAutoConfigURLString/{print $3}')"
  ok "PAC 已启用：$url"
  case "$url" in
    *"$PAC_PORT"*) ok "指向本方案启动的 PAC 服务器（端口 $PAC_PORT）" ;;
    *) warn "指向的不是本方案的 PAC 服务器，检查一下是否被别的工具改过" ;;
  esac
else
  bad "PAC 未启用 —— 执行 ./install.sh"
fi
if scutil --proxy | grep -q "SOCKSEnable : 1"; then
  warn "系统 SOCKS 代理处于开启状态，整机流量可能仍被接管，建议关掉"
fi

echo
bold "③ PAC 文件服务器"
if curl -fsS --max-time 3 "http://127.0.0.1:$PAC_PORT/split.pac" >/dev/null 2>&1; then
  ok "http://127.0.0.1:$PAC_PORT/split.pac 可访问"
else
  bad "PAC 文件取不到 —— 检查 LaunchAgent：launchctl list | grep pac-server"
fi

echo
bold "④ 出口 IP"
# 直连时国外 IP 查询站点常常不可达，多试几个，拿到能用的就行
get_ip() { # $1=是否走代理
  local url ip
  for url in "https://api.ipify.org" "https://ip.3322.net" "https://myip.ipip.net"; do
    if [ "$1" = "proxy" ]; then
      ip="$(curl -s --max-time 10 -x "http://$PROXY_HOST:$PROXY_PORT" "$url" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)"
    else
      ip="$(curl -s --max-time 10 "$url" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)"
    fi
    [ -n "$ip" ] && { echo "$ip"; return; }
  done
}
direct_ip="$(get_ip direct)"
proxy_ip="$(get_ip proxy)"
[ -n "$direct_ip" ] && ok "直连出口：$direct_ip" || warn "直连出口取不到（国外查询站点被墙属正常，不影响分流）"
[ -n "$proxy_ip" ] && ok "代理出口：$proxy_ip" || bad "代理出口取不到 —— 代理没通"
if [ -n "$direct_ip" ] && [ -n "$proxy_ip" ] && [ "$direct_ip" != "$proxy_ip" ]; then
  ok "两个出口不同，分流逻辑生效"
elif [ -n "$direct_ip" ] && [ "$direct_ip" = "$proxy_ip" ]; then
  warn "两个出口相同 —— 说明流量没真正走代理，检查代理客户端是否开了全局/TUN 模式"
fi

echo
bold "⑤ ChatGPT 可达性"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -x "http://$PROXY_HOST:$PROXY_PORT" https://chatgpt.com/ 2>/dev/null)"
case "$code" in
  200|301|302) ok "经代理访问 chatgpt.com 返回 $code" ;;
  403)
    warn "chatgpt.com 返回 403"
    if curl -sI --max-time 20 -x "http://$PROXY_HOST:$PROXY_PORT" https://chatgpt.com/ 2>/dev/null | grep -qi "cf-mitigated"; then
      note "带 cf-mitigated 头 = Cloudflare 人机验证，浏览器里正常打开即可，不算被墙"
    else
      note "没有 cf-mitigated 头，多半是被重置或 IP 被拒，换节点再试"
    fi
    ;;
  000) bad "经代理访问 chatgpt.com 超时 —— 代理端口通但目标不可达，换节点/换协议" ;;
  "")  bad "请求失败" ;;
  *)   warn "chatgpt.com 返回 $code" ;;
esac

echo
bold "⑥ ChatGPT 桌面端残留进程"
# 只数主进程（辅助进程名字带 "ChatGPT Helper"），主进程多于一个 = 有残留占着单实例锁
leftover="$(pgrep -x ChatGPT 2>/dev/null | wc -l | tr -d ' ')"
if [ "${leftover:-0}" -le 1 ]; then
  ok "没有多余的 ChatGPT 主进程"
else
  warn "$leftover 个 ChatGPT 主进程，窗口可能打不开（单实例锁被占）"
  note "清理：pkill -15 -f '/Applications/ChatGPT.app'; sleep 3; pkill -9 -f '/Applications/ChatGPT.app'"
fi

echo
