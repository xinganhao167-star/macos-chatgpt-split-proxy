#!/bin/bash
# Install PAC + desktop launcher. Network settings change only when explicitly run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/common.sh"
PAC_DIR="$HOME/proxy-pac"
PAC_FILE="$PAC_DIR/split.pac"
LAUNCHER="$HOME/Desktop/ChatGPT代理启动.command"
AGENT_PLIST="$HOME/Library/LaunchAgents/local.pac-server.plist"
GUARD_PLIST="$HOME/Library/LaunchAgents/local.codex-proxy-guard.plist"
GUARD_DIR="$HOME/Library/Application Support/codex-proxy-guard"
BACKUP_DIR="$CONFIG_DIR/pac-backup"
DRY=0 WATCHDOG=0 WATCHDOG_ONLY=0 AUTO=0
REQUEST_PROXY= REQUEST_PAC=
usage() {
  echo "用法: ./install.sh [--proxy 127.0.0.1:PORT] [--pac-port PORT] [--with-watchdog] [--watchdog-only] [--auto-recover] [--dry-run]"
}
die() { echo "安装失败：$*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --proxy) (($# >= 2)) || die "--proxy 缺少值"; REQUEST_PROXY="$2"; shift 2 ;;
    --pac-port) (($# >= 2)) || die "--pac-port 缺少值"; REQUEST_PAC="$2"; shift 2 ;;
    --with-watchdog) WATCHDOG=1; shift ;;
    --watchdog-only) WATCHDOG=1; WATCHDOG_ONLY=1; shift ;;
    --auto-recover) AUTO=1; WATCHDOG=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数 $1" ;;
  esac
done
[[ "$(uname)" == Darwin ]] || die "仅支持 macOS"
if [[ -f "$CONFIG_FILE" ]]; then
  load_config || die "现有配置无效，请先检查 $CONFIG_FILE"
else
  PROXY_HOST=127.0.0.1 PROXY_PORT=8080 PAC_PORT=8899
fi
if [[ -n "$REQUEST_PROXY" ]]; then
  [[ "$REQUEST_PROXY" =~ ^(127\.0\.0\.1|localhost):([0-9]{1,5})$ ]] || die "代理须为本机 host:port，例如 127.0.0.1:7897"
  PROXY_HOST="${BASH_REMATCH[1]}" PROXY_PORT="${BASH_REMATCH[2]}"
fi
[[ -z "$REQUEST_PAC" ]] || PAC_PORT="$REQUEST_PAC"
valid_port "$PROXY_PORT" && valid_port "$PAC_PORT" || die "端口必须为 1–65535"
[[ "$WATCHDOG_ONLY" == 0 || ( -z "$REQUEST_PROXY" && -z "$REQUEST_PAC" ) ]] || die "--watchdog-only 使用已安装配置，不能改端口"
[[ "$WATCHDOG_ONLY" == 0 || -f "$CONFIG_FILE" ]] || die "尚未安装主方案"
[[ "$WATCHDOG" == 1 || ! -f "$GUARD_PLIST" ]] || WATCHDOG=1
PROXY_URL="http://$PROXY_HOST:$PROXY_PORT"
PAC_URL="http://127.0.0.1:$PAC_PORT/split.pac"
if [[ "$DRY" == 1 ]]; then
  echo "[dry-run] 代理 ${PROXY_URL}；PAC ${PAC_URL}；看门狗=${WATCHDOG}；仅在应用未运行时自动启动=$AUTO"
  echo "[dry-run] 将更新 ${CONFIG_FILE}、PAC、启动器、LaunchAgent；保存各网络服务原 PAC 并设置 $PAC_URL"
  exit 0
fi
[[ "$WATCHDOG_ONLY" == 1 || -x /usr/bin/python3 ]] || die "/usr/bin/python3 不可执行，PAC 服务无法启动"
for cmd in networksetup launchctl nc curl; do command -v "$cmd" >/dev/null || die "缺少 $cmd"; done

# A per-install transaction protects an existing installation if a step fails.
TXN="$(mktemp -d)"
declare -a FILES=()
declare -a BACKUP_NEW=()
backup_file() {
  local file="$1" index="${#FILES[@]}"
  FILES+=("$file")
  if [[ -e "$file" ]]; then cp -p "$file" "$TXN/file.$index"; else : > "$TXN/absent.$index"; fi
}
restore_service() {
  local file="$1" svc url enabled
  IFS= read -r svc < "$file"
  url="$(sed -n '2p' "$file")"
  enabled="$(sed -n '3p' "$file")"
  networksetup -setautoproxyurl "$svc" "$url" >/dev/null 2>&1 || true
  [[ "$enabled" == Yes ]] && enabled=on || enabled=off
  networksetup -setautoproxystate "$svc" "$enabled" >/dev/null 2>&1 || true
}
rollback() {
  local i file
  trap - ERR
  for file in "$TXN"/service.*; do [[ -f "$file" ]] && restore_service "$file"; done
  for ((i=0; i<${#FILES[@]}; i++)); do
    file="${FILES[$i]}"
    if [[ -f "$TXN/absent.$i" ]]; then rm -f "$file"; else cp -p "$TXN/file.$i" "$file"; fi
  done
  for file in "${BACKUP_NEW[@]}"; do rm -f "$file"; done
  launchctl bootout "gui/$(id -u)/local.pac-server" 2>/dev/null || true
  [[ -f "$AGENT_PLIST" ]] && launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/local.codex-proxy-guard" 2>/dev/null || true
  [[ -f "$GUARD_PLIST" ]] && launchctl bootstrap "gui/$(id -u)" "$GUARD_PLIST" 2>/dev/null || true
  rm -rf "$TXN"
  echo "安装失败，已尝试恢复本次修改；请检查 PAC 和 LaunchAgent 状态。" >&2
  exit 1
}
trap rollback ERR

if [[ "$WATCHDOG_ONLY" == 0 ]]; then
  LEGACY_INSTALL=0
  [[ -f "$AGENT_PLIST" && -f "$PAC_FILE" ]] && LEGACY_INSTALL=1
  # Snapshot every service BEFORE any write, preserving service names with spaces.
  services_output="$(networksetup -listallnetworkservices)" || die "无法列出网络服务，未修改系统"
  n=0
  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    svc="${svc#\*}"
    state="$(networksetup -getautoproxyurl "$svc")" || die "无法读取 $svc 的原 PAC 状态"
    url="$(printf '%s\n' "$state" | sed -n 's/^URL: //p' | head -1)"
    enabled="$(printf '%s\n' "$state" | sed -n 's/^Enabled: //p' | head -1)"
    [[ "$enabled" == Yes || "$enabled" == No ]] || die "$svc 的 PAC 状态无法解析"
    printf '%s\n%s\n%s\n' "$svc" "$url" "$enabled" > "$TXN/service.$n"
    n=$((n+1))
  done < <(printf '%s\n' "$services_output" | tail -n +2)
  (( n > 0 )) || die "没有找到网络服务，未修改系统"
  mkdir -p "$CONFIG_DIR" "$PAC_DIR" "$HOME/Desktop" "$HOME/Library/LaunchAgents" "$BACKUP_DIR"
  for f in "$CONFIG_FILE" "$CONFIG_DIR/common.sh" "$PAC_FILE" "$LAUNCHER" "$AGENT_PLIST"; do backup_file "$f"; done
  printf 'PROXY_HOST=%s\nPROXY_PORT=%s\nPAC_PORT=%s\n' "$PROXY_HOST" "$PROXY_PORT" "$PAC_PORT" > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  cp "$ROOT/common.sh" "$CONFIG_DIR/common.sh"
  sed "s/PROXY 127\\.0\\.0\\.1:8080/PROXY $PROXY_HOST:$PROXY_PORT/g" "$ROOT/split.pac" > "$PAC_FILE"
  cp "$ROOT/launcher.sh" "$LAUNCHER"
  chmod +x "$LAUNCHER"
  cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.pac-server</string>
<key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>-m</string><string>http.server</string><string>$PAC_PORT</string><string>--bind</string><string>127.0.0.1</string><string>--directory</string><string>$PAC_DIR</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/local.pac-server" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
  served=0
  for attempt in 1 2 3 4 5; do
    response="$(curl --noproxy '*' -fsS --max-time 2 "$PAC_URL" 2>/dev/null || true)"
    if [[ "$response" == *"PROXY $PROXY_HOST:$PROXY_PORT"* ]]; then served=1; break; fi
    sleep 1
  done
  [[ "$served" == 1 ]] || { echo "PAC 服务器未提供预期规则，取消网络设置变更" >&2; false; }
  for file in "$TXN"/service.*; do
    [[ -f "$file" ]] || continue
    IFS= read -r svc < "$file"
    key="$(printf '%s' "$svc" | cksum | awk '{print $1}')"
    if [[ ! -f "$BACKUP_DIR/$key" && ! -f "$BACKUP_DIR/legacy.$key" ]]; then
      old_url="$(sed -n '2p' "$file")"
      if [[ "$LEGACY_INSTALL" == 1 && "$old_url" == http://127.0.0.1:*/split.pac* ]]; then
        printf '%s\n' "$svc" > "$BACKUP_DIR/legacy.$key"
        BACKUP_NEW+=("$BACKUP_DIR/legacy.$key")
        echo "警告：$svc 已使用旧版项目 PAC，无法推断安装前配置；卸载时将保留该服务设置。" >&2
      else
        cp "$file" "$BACKUP_DIR/$key"
        BACKUP_NEW+=("$BACKUP_DIR/$key")
      fi
    fi
    networksetup -setautoproxyurl "$svc" "$PAC_URL"
    networksetup -setautoproxystate "$svc" on
  done
fi

if [[ "$WATCHDOG" == 1 ]]; then
  mkdir -p "$GUARD_DIR" "$HOME/Library/LaunchAgents"
  backup_file "$GUARD_DIR/guard.sh"
  backup_file "$GUARD_DIR/common.sh"
  backup_file "$GUARD_PLIST"
  cp "$ROOT/guard.sh" "$GUARD_DIR/guard.sh"
  cp "$ROOT/common.sh" "$GUARD_DIR/common.sh"
  chmod +x "$GUARD_DIR/guard.sh"
  ARG="<string>$GUARD_DIR/guard.sh</string>"
  [[ "$AUTO" == 1 ]] && ARG="$ARG<string>--auto-recover</string>"
  cat > "$GUARD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.codex-proxy-guard</string>
<key>ProgramArguments</key><array><string>/bin/bash</string>$ARG</array>
<key>StartInterval</key><integer>60</integer><key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>/tmp/local.codex-proxy-guard.out</string>
<key>StandardErrorPath</key><string>/tmp/local.codex-proxy-guard.err</string>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/local.codex-proxy-guard" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$GUARD_PLIST"
fi
trap - ERR
rm -rf "$TXN"
echo "安装完成：代理 ${PROXY_URL}，PAC ${PAC_URL}；看门狗=${WATCHDOG}；安全自动启动=$AUTO"
