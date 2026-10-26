#!/bin/bash
# Read-only checks. Separate configuration, local listener, API and WebSocket.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/common.sh" || exit 1
if ! load_config; then
  echo "UNKNOWN 安装配置缺失或无效：$CONFIG_FILE"
  exit 1
fi
echo "配置：${PROXY_URL}；PAC http://127.0.0.1:$PAC_PORT/split.pac"
if proxy_reachable; then
  echo "LOCAL_OK 本地代理 TCP 端口可达"
else
  echo "LOCAL_BAD 本地代理 TCP 端口不可达"
fi
PAC_URL="http://127.0.0.1:$PAC_PORT/split.pac"
PAC="$(curl --noproxy '*' -fsS --max-time 3 "$PAC_URL" 2>/dev/null)"
if [[ "$PAC" == *"PROXY $PROXY_HOST:$PROXY_PORT"* ]]; then
  echo "PAC_OK PAC 服务器及规则使用配置端口"
else
  echo "PAC_UNKNOWN 无法读取 PAC 或规则端口不一致"
fi
SYS="$(scutil --proxy 2>/dev/null || true)"
if [[ "$SYS" == *"ProxyAutoConfigEnable : 1"* && "$SYS" == *"$PAC_URL"* ]]; then
  echo "SYSTEM_PAC_OK 系统自动代理指向本方案"
else
  echo "SYSTEM_PAC_UNKNOWN 系统 PAC 未指向本方案，或无法读取"
fi
api_result="$(curl --noproxy '' -x "$PROXY_URL" -sS -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 12 https://chatgpt.com/backend-api/ 2>/dev/null)"
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
  HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" ALL_PROXY="$PROXY_URL" \
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
