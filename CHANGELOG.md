# 变更记录

## 2026-10-27（续）

### 新增：SNI 中继正式入库（`relay/`）

桌面端主进程对 `codex-cloud-backend.chatgpt.com` 的 durable 长连接既不读 `--proxy-server`
也不读代理环境变量，直连被墙会导致「一直正在思考 / 不停重连」并不断新起 codex 子进程。
中继把该域名经 `/etc/hosts` 引到本机 443，再从 TLS ClientHello 读 SNI、经本地 SOCKS 透传
（不做中间人，证书校验不受影响）。

- `relay/setup-root.sh`：新增 `--dry-run`、`--domain/--listen/--port/--socks`；
  `/etc/hosts` 改为**标记块**写入（可整块回滚），会清理早期脚本留下的裸行；
  安装后校验监听与域名解析，任一步失败自动回滚 hosts 与守护进程。
- `relay/teardown-root.sh`：新增。停止并删除守护进程与脚本，只删自己的标记块。
- `install.sh --with-relay`：打印需要 root 的安装命令，不自行提权。
- `uninstall.sh`：提醒中继属于 root 组件，需单独卸载。
- `diagnose.sh`：新增 `RELAY_OK / RELAY_BAD / RELAY_UNKNOWN / RELAY_ABSENT` 一行。
- README 增加该组件的原因、安装、卸载与限制说明。

注意：中继是**单个域名**的补丁，且绑定 443 需要 root；它解决的是「连不上/反复重连」，
与本文件上一条的本地桥（解决 CPU 占满）是两个不同的问题，两者都需要。

## 2026-10-27

### 新增：桌面端改走本地 HTTP→SOCKS 桥（桌面端 CPU 问题）

实测（同一台机器、同一个应用版本、相近连接数 30 对 35–40，唯一差别是入站类型）：

| 桌面端入口 | 实际入站 | 代理进程平均 CPU | 稳态 |
|---|---|---|---|
| `127.0.0.1:8080` | HTTP | 96.2%（峰值 99.3%） | 约 99% 持续不掉、机器发烫 |
| `127.0.0.1:8081` → `1080` | SOCKS5 | 1.4%（峰值 16.3%，仅启动瞬间） | 0.1–0.2% |

结论：不是「长连接太多」，而是 HTTP 入站在桌面端该负载下的实现问题。

- 新增 `bridge/http2socks.py`：只监听 `127.0.0.1` 的 HTTP→SOCKS5 桥，支持 CONNECT 与绝对 URI、
  带 idle 超时；`split_hostport()` 处理无端口地址与 `[::1]:port`。
- `install.sh` 新增 `--with-bridge` / `--bridge-port` / `--socks`，安装 LaunchAgent
  `local.split-proxy-bridge`；配置新增 `BRIDGE_PORT` / `SOCKS_HOST` / `SOCKS_PORT`。
  **不传 `--with-bridge` 时行为完全不变。**
- `common.sh` 定义 `CLIENT_URL`（桌面端实际入口 = 启用桥时的桥地址），看门狗按入口比对。
- `launcher.sh` / `diagnose.sh` 使用入口；诊断新增 `BRIDGE_OK/BRIDGE_BAD`、`SOCKS_OK/SOCKS_BAD`。
- `uninstall.sh` 一并卸载桥（plist、脚本、LaunchAgent）。
- README 增加「桌面端为什么要走本地桥（实测结论）」与对应验收项。

### 修复：启动器为桌面端设置 NO_PROXY

桥日志显示桌面端会把 `127.0.0.1:27124`（Obsidian MCP）等**本地回环**连接也送进 SOCKS，
既多一次出境往返，也把本地服务交给代理。启动器补 `NO_PROXY=127.0.0.1,localhost,::1`；
不含任何境外域名，不影响 CLI 走代理。实测桥日志中 `127.0.0.1` 类 CONNECT 由有变 0。

### 修复：桥解析不带端口的 HTTP 目标时崩溃

普通 HTTP 请求（绝对 URI，如 `http://edgedl.me.gvt1.com/path`）没有端口，
用 `rpartition(":")` 会把主机名当成端口，抛
`ValueError: invalid literal for int() with base 10`，该条连接直接断开。
改为 `split_hostport()`：有端口才按端口解析，否则用默认端口（HTTP 80 / CONNECT 443），
并兼容 `[::1]:8080`；补 4 组回归用例。修复后该请求返回 404（目标可达）。
