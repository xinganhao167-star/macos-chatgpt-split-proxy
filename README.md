# macOS ChatGPT 分流代理

保留系统 PAC 供浏览器分流，使用桌面启动器为 ChatGPT 主进程和 Codex 子进程提供同一个本地 HTTP 代理。不使用 TUN、全局代理或网络扩展。安装脚本会修改 macOS 网络服务的自动代理配置；先用 `--dry-run` 查看计划。

若上游代理同时提供 HTTP 与 SOCKS5 两个入站，建议加 `--with-bridge`：桌面端改走 SOCKS5，可避免 HTTP 入站在该负载下占满一个核（见下文[桌面端为什么要走本地桥](#桌面端为什么要走本地桥实测结论)）。

## 第一次使用

需要 macOS、已安装的 ChatGPT 桌面 App，以及一个正在运行的**本地 HTTP 代理**。下面以代理地址 `127.0.0.1:8080` 为例；如你的代理客户端使用其他端口，请替换安装命令中的地址。

```bash
git clone https://github.com/xinganhao167-star/macos-chatgpt-split-proxy.git
cd macos-chatgpt-split-proxy
./install.sh --proxy 127.0.0.1:8080 --with-watchdog --dry-run
./install.sh --proxy 127.0.0.1:8080 --with-watchdog
```

`--dry-run` 只显示计划；第二次运行会修改系统自动代理设置，并安装默认**只观察、不重启**的看门狗。请先确认输出中的端口和 PAC 地址符合预期。若 ChatGPT 已运行，等当前 Codex 任务结束后在应用内手动退出，再双击桌面的「ChatGPT代理启动.command」；不要为了安装强制结束正在运行的任务。随后运行：

```bash
./diagnose.sh
```

正常情况下，本地代理与 PAC 分别显示 `LOCAL_OK`、`PAC_OK`；应用启动后进程配置可显示 `CONFIG_OK`。诊断始终把实际桌面 WebSocket 状态写为 `WEBSOCKET_UNKNOWN`；这不是安装失败。若需要撤销，请看下方的[卸载与回滚](#卸载与回滚)。脚本不会自动开启 TUN 或全局代理。

## 桌面端为什么要走本地桥（实测结论）

ChatGPT 桌面端直接连**HTTP 代理入站**（示例中的 `8080`）时，代理进程会持续占满一个核、机器发烫；
同一份负载改走**SOCKS5 入站**（`1080`）后几乎不占 CPU。同一台机器、同一个应用版本、相近的连接数
（30 对 35–40），唯一差别是入站类型：

| 桌面端入口 | 实际入站 | 代理进程平均 CPU | 稳态 |
|---|---|---|---|
| `127.0.0.1:8080` | HTTP | 96.2%（峰值 99.3%） | 约 99% 持续不掉 |
| `127.0.0.1:8081` → `1080` | SOCKS5 | 1.4%（峰值 16.3%，仅启动瞬间） | 0.1–0.2% |

因此这不是「长连接太多」，而是 HTTP 入站在桌面端该负载下的实现问题。`--with-bridge` 会安装一个只监听
`127.0.0.1` 的本地 HTTP→SOCKS5 桥（`bridge/http2socks.py`，LaunchAgent `local.split-proxy-bridge`），
桌面端指向桥，浏览器 PAC 仍指向原来的 HTTP 端口。**不改 VPN 模式、不加 TUN、不改路由。**

```bash
./install.sh --with-bridge --socks 127.0.0.1:1080            # 桥默认监听 8081
./install.sh --with-bridge --bridge-port 8082 --socks 127.0.0.1:1080
```

省略 `--with-bridge` 时行为不变：桌面端直接使用 `--proxy` 指定的 HTTP 代理。已启用桥后再执行
`./install.sh`（不带动桥参数）会沿用配置里的桥端口。

## 安装与更新

```bash
./install.sh --dry-run
./install.sh                                  # 默认 127.0.0.1:8080
./install.sh --proxy 127.0.0.1:7897           # 自定义本地 HTTP 代理端口
./install.sh --proxy 127.0.0.1:7897 --pac-port 8900
./install.sh --with-watchdog                  # 每分钟只检查、记日志、告警
./install.sh --watchdog-only                  # 使用已安装配置补装看门狗
```

更新时再次运行安装脚本。省略 `--proxy` / `--pac-port` 会沿用已安装配置，而非退回默认端口。配置保存在 `~/Library/Application Support/chatgpt-split-proxy/config`；PAC、启动器、诊断和看门狗都读取这个配置或由它生成。端口只接受本机 `127.0.0.1` / `localhost` 的 HTTP 代理。PAC 文件服务器固定用 `/usr/bin/python3`，安装前也检查同一路径。

安装器首次修改每个网络服务前记录其 PAC URL 与启用状态。服务名中的空格会完整保留。重复安装不会覆盖原始备份。安装发生错误时会尝试恢复本次改动并报告失败；如果旧版安装没有保存原 PAC，无法推断安装前的值，卸载时会保留该服务的 PAC 与服务器并提醒手工处理。

日常使用：先连接本地 HTTP 代理，再在 Chrome 中访问 [ChatGPT](https://chatgpt.com) 或 [X](https://x.com)；桌面端用 `~/Desktop/ChatGPT代理启动.command` 打开。启动器在代理不可用时拒绝启动；若 ChatGPT 已运行，它会提示你在应用内**手动退出**，不会终止现有进程或 Codex 任务。网页 PAC 会把 OpenAI/ChatGPT 域名及 X 网页所需的 `x.com`、`twitter.com`、`t.co`、`twimg.com` 域名交给本地代理，其余域名直连。`chatgpt.com`、`openai.com` 和 `x.com` 根域名都包含在规则中。

## 看门狗与安全恢复

```bash
./install.sh --with-watchdog
"$HOME/Library/Application Support/codex-proxy-guard/guard.sh" --check
tail -f "$HOME/Library/Logs/codex-proxy-guard.log"
```

默认看门狗**只检测并记录告警**，对错误或未知状态尝试显示 macOS 通知（同类告警最多每 30 分钟一次），绝不会杀死或重启正在运行的 ChatGPT。它核对主进程启动参数、主进程和直接 Codex 子进程的三个非空且精确匹配的代理变量，以及本地代理 TCP 端口。看不到环境、找不到 Codex 子进程或存在多个主进程时报告 `UNKNOWN`。返回码：`0` 为配置检查通过，`1` 为明确错误，`2` 为应用未运行，`3` 为未知。即使返回 0，也**不代表 WebSocket 已连接**。

仅在明确希望“应用未运行时自动启动”时，可用 `./install.sh --with-watchdog --auto-recover`。此模式只在**没有运行中的桌面主进程**、启动器存在、代理端口可达、取得互斥锁且距上次启动至少 30 分钟时运行启动器。它不会终止运行中的应用，也不会尝试猜测 Codex 是否空闲，因此无法自动修复已运行但丢失代理的进程。要关闭自动启动，重新运行 `./install.sh --with-watchdog`。

目前**不建议开启自动恢复**：对正在运行的 Codex 编码任务，无法可靠判断是否可以安全重启。观察模式能保留证据，让用户选择合适的时机手动退出重开。

## 诊断

```bash
./diagnose.sh
```

诊断结果按层区分：

| 标记 | 含义 |
|---|---|
| `LOCAL_OK/BAD` | 本地 HTTP 代理 TCP 端口 |
| `BRIDGE_OK/BAD` | 本地桥是否在监听（仅启用桥时输出） |
| `SOCKS_OK/BAD` | 桥的上游 SOCKS5 是否可达（仅启用桥时输出） |
| `PAC_OK/UNKNOWN` | PAC 服务器与配置端口 |
| `SYSTEM_PAC_OK/UNKNOWN` | macOS 当前自动代理指向 |
| `API_REACHABLE/UNKNOWN` | 经代理请求 ChatGPT 后端的 HTTP 层；403 也仅代表 HTTP 有响应 |
| `CONFIG_OK/BAD/UNKNOWN` | 当前桌面主进程和 Codex 子进程代理配置 |
| `WEBSOCKET_UNKNOWN` | 脚本没有观测实际桌面长连接 |
| `DOCTOR_OK/UNKNOWN` | 临时 `codex doctor` 诊断进程，不能代替当前桌面进程 |

`doctor` 最多运行 15 秒，失败或超时会明确标为 `UNKNOWN`。代理变量或 `--proxy-server` 只证明配置，不证明 API 鉴权或 WebSocket 稳定。诊断不会编辑 `~/.codex/config.toml`、会话、凭证或工作目录。

在 2026-10-26 的一次只读检查中，本机 ChatGPT 主进程由 `/Applications/ChatGPT.app/Contents/MacOS/ChatGPT` 运行，两个直接 Codex 子进程由应用资源目录中的 `codex` 运行，三者均可读到相同代理环境变量。这是当时的状态，不能证明更新后一定保留或一定丢失代理。内置 CLI `0.164.0-alpha.11.1` 的 `features list` 将 `respect_system_proxy` 标为开发中且关闭；[OpenAI 官方配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)没有列出此设置，因此本项目不自动写入该项。`features.network_proxy` 文档描述的是沙箱命令网络代理，不能当成桌面模型 API 流量的修复开关。

## 卸载与回滚

```bash
./uninstall.sh
```

卸载会在当前 PAC 仍指向本项目时恢复每个网络服务安装前保存的 URL 和开关；若用户或其他程序已改动 PAC，则保留当前值并提示。旧版安装没有原始备份时，会保留相关 PAC 服务以免留下失效 URL。卸载不会停止 ChatGPT/Codex 进程，不会删除 Codex 会话或配置。重新安装可重复执行。

## 自动化与真实 Mac 验收

```bash
/usr/bin/python3 -m unittest discover -s tests -v
for f in *.sh; do bash -n "$f" || exit 1; done
```

测试使用临时 HOME 和命令替身，不改变真实网络设置。它覆盖 PAC 域名规则、自定义端口、重复安装与卸载恢复、失败回滚、异常进程状态、诊断失败/超时及自动恢复限制。替身测试**不能证明真实 Codex WebSocket 故障已修复**。

[GitHub Actions](https://github.com/xinganhao167-star/macos-chatgpt-split-proxy/actions) 在 `main` 更新和拉取请求上运行同样的模拟测试与 Shell 语法检查；绿色结果只代表这些自动化检查通过，不代表真实 macOS 网络设置或 Codex 长连接已验收。

真实 Mac 人工验收清单：

1. 在没有正在执行的 Codex 任务时，记录各网络服务 `networksetup -getautoproxyurl "服务名"` 和当前 PAC；先运行 `./install.sh --dry-run`，确认没有目录或网络变更。启用桥时另需确认 `./diagnose.sh` 输出 `BRIDGE_OK` 与 `SOCKS_OK`，并观察桌面端运行时的代理进程 CPU（`ps -o time= -p <pid>` 取两次差值）不随使用持续上升。
2. 用实际本地代理端口安装，确认 `config`、PAC 返回内容及启动器一致；Chrome 访问 `chatgpt.com` 和 `x.com`，确认 X 登录、时间线、图片/视频及 `t.co` 链接可用，同时确认普通国内站点直连正常。
3. 在应用中手动退出后用启动器打开；查看 `./diagnose.sh` 中主进程、Codex 子进程、代理端口和 API 四层结果。用应用内实际 Codex 任务观察长连接一段时间，记录出现 Reconnecting 的时间和日志。
4. 在有 Codex 任务运行时再次点启动器、运行默认看门狗，确认它们只提示/记录，不终止进程。模拟代理断开、启动器缺失和应用未运行，核对 `BAD/UNKNOWN/ABSENT`。
5. 仅在有意测试时开启 `--auto-recover`；确认应用运行中绝不重启，应用未运行时最多启动一次，30 分钟内不会重复启动。
6. 重复安装相同或新端口并检查网页规则；卸载后逐项核对原 PAC URL 与开关恢复。如旧版没有备份，按提示手动处理保留的 PAC。
7. 若要验证“更新或重启导致丢失环境”的假设，在更新前后分别记录主进程和 Codex 子进程的 PID、PPID、可见代理变量及 `--proxy-server`、应用日志与 Reconnecting 时间；不要为了测试强制结束正在运行的任务。
