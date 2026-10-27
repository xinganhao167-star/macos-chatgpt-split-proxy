#!/bin/bash
# 以 root 安装 ChatGPT SNI 中继：把桌面端那条不认代理的长连接经本地 SOCKS 出境。
#
# 为什么需要它：ChatGPT 桌面端主进程对 codex-cloud-backend.chatgpt.com 有一条
# durable 长连接，既不读 --proxy-server 也不读 HTTP(S)_PROXY。直连被墙后它会无限重连，
# 表现为「一直正在思考/不停重连」，并不断新起 codex 子进程。
# 做法：/etc/hosts 把该域名钉到 127.0.0.1，由本中继从 TLS ClientHello 读出域名，
# 经本地 SOCKS5（默认 Anycast 127.0.0.1:1080）远程解析建连后双向透传。
# 端到端 TLS 原样转发，不做中间人，证书校验不受影响。
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DST_DIR="/Library/Application Support/chatgpt-sni-relay"
PLIST="/Library/LaunchDaemons/local.chatgpt-sni-relay.plist"
HOSTS="/etc/hosts"
HOSTS_BAK="/etc/hosts.bak-chatgpt-sni-relay"
BEGIN_MARK="# >>> chatgpt-split-proxy relay >>>"
END_MARK="# <<< chatgpt-split-proxy relay <<<"

DOMAIN="codex-cloud-backend.chatgpt.com"
LISTEN="127.0.0.1"
PORT="443"
SOCKS="127.0.0.1:1080"
DRY=0

die() { echo "安装失败：$*" >&2; exit 1; }
usage() {
  echo "用法: sudo bash relay/setup-root.sh [--dry-run] [--domain 域名] [--listen 地址] [--port 端口] [--socks 127.0.0.1:1080]"
}
while (($#)); do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --domain) (($# >= 2)) || die "--domain 缺少值"; DOMAIN="$2"; shift 2 ;;
    --listen) (($# >= 2)) || die "--listen 缺少值"; LISTEN="$2"; shift 2 ;;
    --port) (($# >= 2)) || die "--port 缺少值"; PORT="$2"; shift 2 ;;
    --socks) (($# >= 2)) || die "--socks 缺少值"; SOCKS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数 $1" ;;
  esac
done

[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port 必须是数字"
[[ -f "$SRC_DIR/sni-relay.py" ]] || die "找不到 $SRC_DIR/sni-relay.py"

if [[ "$DRY" == 1 ]]; then
  cat <<EOF
[dry-run] 计划安装 SNI 中继（需要 root，本次不做任何修改）：
  域名     $DOMAIN  →  127.0.0.1（写进 /etc/hosts 的标记块，可整块回滚）
  脚本     $SRC_DIR/sni-relay.py → $DST_DIR/sni-relay.py
  守护     ${PLIST}（root，RunAtLoad + KeepAlive，开机自启）
  参数     $LISTEN $PORT $SOCKS
  备份     ${HOSTS_BAK}（仅首次创建；每次安装另存时间戳快照）
  前置     本地 SOCKS $SOCKS 需可用（VPN 连上后才有）
EOF
  exit 0
fi

[[ "$(id -u)" == 0 ]] || die "需要 root：sudo bash relay/setup-root.sh"

SNAP="$(mktemp)"
cp -p "$HOSTS" "$SNAP"
[[ -f "$HOSTS_BAK" ]] || cp -p "$HOSTS" "$HOSTS_BAK"

rollback() {
  local code=$?
  trap - ERR
  echo "安装失败（退出码 ${code}），回滚 hosts 与守护进程" >&2
  launchctl bootout system "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  cat "$SNAP" > "$HOSTS"
  rm -rf "$DST_DIR"
  dscacheutil -flushcache 2>/dev/null || true
  killall -HUP mDNSResponder 2>/dev/null || true
  rm -f "$SNAP"
  exit 1
}
trap rollback ERR

echo "== 1/5 安装中继脚本"
mkdir -p "$DST_DIR"
cp "$SRC_DIR/sni-relay.py" "$DST_DIR/sni-relay.py"
chown root:wheel "$DST_DIR/sni-relay.py"
chmod 755 "$DST_DIR/sni-relay.py"

echo "== 2/5 写 LaunchDaemon"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.chatgpt-sni-relay</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$DST_DIR/sni-relay.py</string>
        <string>$LISTEN</string>
        <string>$PORT</string>
        <string>$SOCKS</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/Library/Logs/chatgpt-sni-relay.log</string>
    <key>StandardErrorPath</key><string>/Library/Logs/chatgpt-sni-relay.log</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

echo "== 3/5 改 /etc/hosts（标记块，可整块回滚）"
cp -p "$HOSTS" "$HOSTS_BAK.$(date +%Y%m%d%H%M%S)"
TMP_HOSTS="$(mktemp)"
# 先删掉旧的标记块与早期脚本留下的裸行，避免重复/冲突
awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  index($0, b) { skip = 1; next }
  index($0, e) { skip = 0; next }
  !skip
' "$HOSTS" | grep -v -x -F "127.0.0.1 $DOMAIN" > "$TMP_HOSTS" || true
{
  cat "$TMP_HOSTS"
  printf '%s\n' "$BEGIN_MARK"
  printf '127.0.0.1 %s\n' "$DOMAIN"
  printf '%s\n' "$END_MARK"
} > "$HOSTS"
rm -f "$TMP_HOSTS"

echo "== 4/5 启动守护进程并刷新 DNS"
launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
dscacheutil -flushcache
killall -HUP mDNSResponder 2>/dev/null || true

echo "== 5/5 验证"
ok=0
for attempt in 1 2 3 4 5; do
  if /usr/bin/nc -z -G 2 "$LISTEN" "$PORT" >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
[[ "$ok" == 1 ]] || die "$LISTEN:$PORT 未在监听"
resolved="$(dscacheutil -q host -a name "$DOMAIN" 2>/dev/null | sed -n 's/^ip_address: //p' | head -1)"
[[ "$resolved" == 127.0.0.1 ]] || echo "警告：$DOMAIN 目前解析为 ${resolved:-未解析}，DNS 缓存可能未刷新" >&2

trap - ERR
rm -f "$SNAP"
echo "完成：$DOMAIN → 127.0.0.1:$PORT → SOCKS ${SOCKS}（日志 /Library/Logs/chatgpt-sni-relay.log）"
echo "卸载：sudo bash $(printf '%q' "$SRC_DIR/teardown-root.sh")"
