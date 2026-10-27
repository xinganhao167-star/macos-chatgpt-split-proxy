#!/bin/bash
# 以 root 卸载 SNI 中继：撤掉 LaunchDaemon，并从 /etc/hosts 删除本项目的标记块。
# 只删自己的标记块，不会碰你在 /etc/hosts 里的其他条目。
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DST_DIR="/Library/Application Support/chatgpt-sni-relay"
PLIST="/Library/LaunchDaemons/local.chatgpt-sni-relay.plist"
HOSTS="/etc/hosts"
BEGIN_MARK="# >>> chatgpt-split-proxy relay >>>"
END_MARK="# <<< chatgpt-split-proxy relay <<<"
DOMAIN="codex-cloud-backend.chatgpt.com"
DRY=0

die() { echo "卸载失败：$*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --domain) (($# >= 2)) || die "--domain 缺少值"; DOMAIN="$2"; shift 2 ;;
    -h|--help) echo "用法: sudo bash relay/teardown-root.sh [--dry-run] [--domain 域名]"; exit 0 ;;
    *) die "未知参数 $1" ;;
  esac
done

if [[ "$DRY" == 1 ]]; then
  cat <<EOF
[dry-run] 计划卸载 SNI 中继（需要 root，本次不做任何修改）：
  停止并删除  $PLIST
  删除目录    $DST_DIR
  删除 hosts 中的标记块（$BEGIN_MARK … ${END_MARK}）及早期裸行 127.0.0.1 $DOMAIN
  保留        /etc/hosts 的其他内容不动
EOF
  exit 0
fi

[[ "$(id -u)" == 0 ]] || die "需要 root：sudo bash relay/teardown-root.sh"

SNAP="$(mktemp)"
cp -p "$HOSTS" "$SNAP"
trap 'echo "卸载失败，正在恢复 /etc/hosts" >&2; cat "$SNAP" > "$HOSTS"; rm -f "$SNAP"; exit 1' ERR

echo "== 1/4 停止守护进程"
launchctl bootout system "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

echo "== 2/4 删除中继脚本"
rm -rf "$DST_DIR"

echo "== 3/4 清理 /etc/hosts"
TMP_HOSTS="$(mktemp)"
awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  index($0, b) { skip = 1; next }
  index($0, e) { skip = 0; next }
  !skip
' "$HOSTS" | grep -v -x -F "127.0.0.1 $DOMAIN" > "$TMP_HOSTS" || true
cat "$TMP_HOSTS" > "$HOSTS"
rm -f "$TMP_HOSTS"

echo "== 4/4 刷新 DNS"
trap - ERR
rm -f "$SNAP"
dscacheutil -flushcache
killall -HUP mDNSResponder 2>/dev/null || true

echo "已卸载：$DOMAIN 不再指向 127.0.0.1；hosts 备份仍在 /etc/hosts.bak-chatgpt-sni-relay*"
