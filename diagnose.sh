#!/bin/bash
# Read-only checks. Separate configuration, local listener, API and WebSocket.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/common.sh" || exit 1
if ! load_config; then
  echo "UNKNOWN 安装配置缺失或无效：$CONFIG_FILE"
  exit 1
fi
echo "配置：代理上游 ${PROXY_URL}；桌面端入口 ${CLIENT_URL}；PAC http://127.0.0.1:$PAC_PORT/split.pac"
if proxy_reachable; then
  echo "LOCAL_OK 本地代理 TCP 端口可达"
else
  echo "LOCAL_BAD 本地代理 TCP 端口不可达"
fi
if [[ -n "${BRIDGE_PORT:-}" ]]; then
  if nc -z -G 2 127.0.0.1 "$BRIDGE_PORT" >/dev/null 2>&1; then
    echo "BRIDGE_OK 本地桥 127.0.0.1:$BRIDGE_PORT 在监听（上游 SOCKS ${SOCKS_URL}）"
  else
    echo "BRIDGE_BAD 本地桥 127.0.0.1:$BRIDGE_PORT 未监听；桌面端会走直连，需检查 LaunchAgent"
  fi
  if nc -z -G 2 "$SOCKS_HOST" "$SOCKS_PORT" >/dev/null 2>&1; then
    echo "SOCKS_OK 上游 SOCKS $SOCKS_URL 可达"
  else
    echo "SOCKS_BAD 上游 SOCKS $SOCKS_URL 不可达；先连上 VPN"
  fi
fi
PAC_URL="http://127.0.0.1:$PAC_PORT/split.pac"
PAC="$(curl --noproxy '*' -fsS --max-time 3 "$PAC_URL" 2>/dev/null)"
if [[ "$PAC" == *"PROXY $PROXY_HOST:$PROXY_PORT"* ]]; then
  echo "PAC_OK PAC 服务器及规则使用配置端口"
else
  echo "PAC_UNKNOWN 无法读取 PAC 或规则端口不一致"
fi
RELAY_PLIST="/Library/LaunchDaemons/local.chatgpt-sni-relay.plist"
if [[ -f "$RELAY_PLIST" ]]; then
  if /usr/bin/nc -z -G 2 127.0.0.1 443 >/dev/null 2>&1; then
    echo "RELAY_OK SNI 中继在 127.0.0.1:443 监听（接管那条不认代理的长连接）"
  else
    echo "RELAY_BAD 中继已安装但 443 未监听；看 /Library/Logs/chatgpt-sni-relay.log"
  fi
elif grep -q 'codex-cloud-backend.chatgpt.com' /etc/hosts 2>/dev/null; then
  echo "RELAY_UNKNOWN /etc/hosts 有该域名，但没找到本项目的中继 plist"
else
  echo "RELAY_ABSENT 未安装 SNI 中继；桌面端那条长连接会直连"
fi
SYS="$(scutil --proxy 2>/dev/null || true)"
if [[ "$SYS" == *"ProxyAutoConfigEnable : 1"* && "$SYS" == *"$PAC_URL"* ]]; then
  echo "SYSTEM_PAC_OK 系统自动代理指向本方案"
else
  echo "SYSTEM_PAC_UNKNOWN 系统 PAC 未指向本方案，或无法读取"
fi
api_result="$(curl --noproxy '' -x "$CLIENT_URL" -sS -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 12 https://chatgpt.com/backend-api/ 2>/dev/null)"
api_exit=$?
if [[ "$api_exit" == 0 && "$api_result" =~ ^[1-5][0-9][0-9]$ ]]; then
  echo "API_REACHABLE 代理到 ChatGPT 后端返回 HTTP ${api_result}（不代表已鉴权或 WebSocket 稳定）"
else
  echo "API_UNKNOWN 后端探测失败或超时（curl 状态 ${api_exit}）"
fi
"$ROOT/guard.sh" --check || true
echo "WEBSOCKET_UNKNOWN 未检测实际桌面 WebSocket 会话；代理环境和 doctor 结果不能证明长连接稳定"
CLI="$APP_PATH/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
if [[ -x "$CLI" && -x /usr/bin/python3 ]]; then
  echo "临时 doctor：以下结果仅属于新启动的诊断进程，不代表现有桌面进程"
  HTTP_PROXY="$CLIENT_URL" HTTPS_PROXY="$CLIENT_URL" ALL_PROXY="$CLIENT_URL" \
  SPLIT_PROXY_DOCTOR_TIMEOUT="${SPLIT_PROXY_DOCTOR_TIMEOUT:-15}" /usr/bin/python3 - "$CLI" <<'PY'
import os, subprocess, sys
try:
    timeout = max(1, min(30, int(os.environ["SPLIT_PROXY_DOCTOR_TIMEOUT"])))
except ValueError:
    timeout = 15
try:
    p = subprocess.run([sys.argv[1], "doctor"], env=os.environ.copy(),
                       capture_output=True, text=True, timeout=timeout)
except subprocess.TimeoutExpired:
    print(f"DOCTOR_UNKNOWN 诊断超时（{timeout} 秒）")
except OSError as e:
    print(f"DOCTOR_UNKNOWN 无法启动：{e}")
else:
    print(f"DOCTOR_{'OK' if p.returncode == 0 else 'UNKNOWN'} 退出码 {p.returncode}")
    for line in (p.stdout + p.stderr).splitlines():
        if any(word in line.lower() for word in ("proxy env", "inference url", "websocket", "respect system proxy")):
            print("  " + line[:300])
PY
else
  echo "DOCTOR_UNKNOWN 未找到内置 Codex CLI 或 /usr/bin/python3"
fi
