# macos-chatgpt-split-proxy

> **只让 ChatGPT 走代理，其他一切直连。** macOS 原生方案：不装网络扩展、不改路由表、不接管整机流量。

**English summary** — Route only ChatGPT/OpenAI traffic through a local HTTP proxy (Anycast / Clash / Surge / …) on macOS, while everything else stays direct. Uses the system PAC (auto-proxy) for browsers plus a small launcher that injects proxy settings into the ChatGPT desktop app. No Network Extension, no TUN mode, no root privileges, no account changes.

---

## 为什么需要它

本地代理客户端一般只有三种模式：

| 模式 | 结果 |
|---|---|
| 全局 / TUN | 整机流量走代理：国内站点绕远甚至打不开，出口 IP 全变，账号风控变高 |
| 系统代理 | 浏览器能用，但只认 HTTP 代理设置的客户端要单独配，容易漏 |
| **仅代理（只开本地端口）** | 谁用谁走，最干净 —— 但要自己指定"谁走" |

这个方案在「仅代理」之上，用**系统 PAC**解决浏览器，用**启动器**解决桌面端，其余流量一律直连。

```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│  ChatGPT 网页 (Chrome)  ──┐                              │
│                           ├──▶ 系统 PAC ──▶ 127.0.0.1:8080 │
│  ChatGPT 桌面端 (启动器) ─┘         │         （本地代理）   │
│                                    │                      │
│  百度 / 微信 / 邮件 / 终端 …──▶ DIRECT（直连，出口 IP 不变）│
└──────────────────────────────────────────────────────────┘
```

## 快速开始

```bash
git clone https://github.com/xinganhao167-star/macos-chatgpt-split-proxy.git
cd macos-chatgpt-split-proxy

./install.sh                          # 默认本地代理 127.0.0.1:8080
./install.sh --proxy 127.0.0.1:7897   # Clash Verge 等换端口
./diagnose.sh                         # 一键体检，看看哪一环断了
```

装完日常就两步，**顺序不能反**：

1. 连上代理客户端，**保持「仅代理 / 系统代理关闭」模式**（不要开 TUN、不要开系统代理）。
2. 网页版：直接用 **Chrome** 打开 <https://chatgpt.com>；桌面端：双击桌面上的 **ChatGPT代理启动.command**。

> 没连节点就点启动器 = 应用卡在加载页；连上节点后再点一次即可。

## 装了什么

| 路径 | 作用 |
|---|---|
| `~/proxy-pac/split.pac` | 分流规则：ChatGPT/OpenAI 域名 → `PROXY 127.0.0.1:8080`，其余 `DIRECT` |
| `~/Library/LaunchAgents/local.pac-server.plist` | 常驻 PAC 文件服务器（`python3 -m http.server 8899`），开机自启 |
| `~/Desktop/ChatGPT代理启动.command` | 带代理启动 ChatGPT 桌面端 |
| 系统「自动代理配置」 | 指向 `http://127.0.0.1:8899/split.pac` |

## 原理：为什么非得这么绕

这几条都是实测踩出来的，改任何一条都会翻车。

### 1. PAC 必须用 `http://` 提供，不能用 `file://`

Safari / WebKit **直接忽略** `file://` 的 PAC（只发 DNS 不建 TCP）。用 `http://` 指向本地小服务器才有效。Chrome 两种都认。

### 2. ChatGPT 桌面端要喂**两层**代理

ChatGPT.app 是 Electron 外壳 + 内置 `codex` CLI（Rust）缝在一起的：

- Chromium 外壳只认 `--proxy-server=` 启动参数；
- 内置 CLI **只认环境变量** `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`，而且**不认 `socks5://` 格式** —— 填 SOCKS5 时它会静默直连，然后卡死在加载页。

所以必须**同时**给两层，而且代理地址要写成 `http://`：

```bash
HTTP_PROXY=http://127.0.0.1:8080 \
HTTPS_PROXY=http://127.0.0.1:8080 \
ALL_PROXY=http://127.0.0.1:8080 \
/Applications/ChatGPT.app/Contents/MacOS/ChatGPT --proxy-server=http://127.0.0.1:8080 &
```

另外两个细节：

- 用 `open --args` 传不进去环境变量（`open` 不继承 shell 环境），要**直接跑二进制**；
- ChatGPT 是**单实例**应用，残留进程会占着锁导致"点了没反应 / 窗口打不开"，启动前先 `pkill -15` → 3 秒 → `pkill -9` 清场。

### 3. Safari 实测不遵守 PAC

同一份 PAC，Chrome 秒过，Safari 装死（`file://`、`http://` 都试过）。这是 WebKit 的行为，不是配置写错。

**结论：ChatGPT 网页用 Chrome，Safari 留给国内站点直连。**

### 4. 不用按应用分流工具（比如 ProxyBridge）

按应用分流看起来更优雅，实际踩到一串硬伤：

- 它的本地 SOCKS5 不支持 UDP（`UDP ASSOCIATE` 直接回 `REP=0x07`）；
- 进程名匹配**大小写敏感**（实际进程是小写 `codex`，规则写 `*Codex*` 不生效）；
- 扩展以 root 运行、杀不掉、没有停止按钮，配置**不热重载**；
- 还要在「系统设置」里授权网络扩展。

PAC + 启动器这两步不需要 root、不需要授权、不装扩展。

### 5. 直连时 ChatGPT 域名会被污染

不开代理时 `chatgpt.com` 解析到 `31.13.73.9`（Facebook 段），连接会被 TCP 重置。这是墙的行为，不是本机问题。

### 6. 桌面端会自己更新并重启自己 —— 这是最隐蔽的坑

Codex/ChatGPT 桌面端会**自动更新内置的 core**（比如 26.1021 → 26.1025），更新完**重启自身**。而它重启时是 launchd 拉起的，拿不到你启动器里的代理环境变量，于是变成裸直连 —— 表现就是**突然开始一直 `Reconnecting` / `request timed out`**，而此时代理客户端明明是好的、网页也正常。

判断方法（Codex 自带体检）：

```bash
/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex doctor
```

看 Connectivity 段：

```
✓ network      no proxy env vars          ← 没有代理环境 = 裸启动
    respect system proxy     disabled      ← Codex 默认不跟随系统 PAC
    managed proxy            not configured
⚠ ChatGPT inference URL  https://chatgpt.com/backend-api/… request timed out (required)
```

`doctor` 里 `proxy env vars present HTTP_PROXY, HTTPS_PROXY, ALL_PROXY` + `websocket connected` 才算真的通了。

顺带两个坑：

- Codex **默认不跟随 macOS 系统代理（PAC）**，所以浏览器能用不代表桌面端能用；
- 想在 `~/.codex/config.toml` 里写 `[network] respect_system_proxy = true` 是**无效的**，当前版本不认这个键，设置页会直接提示 `Codex is ignoring 1 unrecognized configuration setting`。`network.proxy_url` / `network.socks_url` 是**沙箱执行器**的网络代理键，不作用于模型 API 流量。

**结论：桌面端一旦出现连不上，先退出、用启动器重开，而不是去折腾代理客户端。**

## 常见症状 → 处理

| 症状 | 原因 | 处理 |
|---|---|---|
| 桌面端一直转圈 / `Reconnecting` / `request timed out` | 实例是裸启动的（没带代理环境） | 退出后用桌面启动器重开；`codex doctor` 看 `proxy env vars` 有没有值 |
| 桌面端点了没反应 | 残留进程占单实例锁 | `pkill -15 -f '/Applications/ChatGPT.app'; sleep 3; pkill -9 -f '/Applications/ChatGPT.app'` |
| 网页能开、桌面端不行 | 只配了 PAC，桌面端不吃 PAC | 用桌面启动器启动 |
| ChatGPT 网页打不开 | Safari 不认 PAC | 换 Chrome |
| 国内站点变慢 / 打不开 | 代理客户端开了 TUN 或系统代理 | 切回「仅代理」模式 |
| `curl` 测 chatgpt.com 返回 403 | Cloudflare 人机验证 | 浏览器里正常打开即可，不算被墙（看响应头有没有 `cf-mitigated`） |
| 出口 IP 和代理出口一样 | 代理客户端开了全局模式 | 切回「仅代理」模式 |
| 换了节点还是不通 | 节点本身不可用 | 换节点；`curl -x http://127.0.0.1:8080 https://chatgpt.com/` 验证 |

## 常见客户端的本地端口

`./install.sh --proxy host:port` 指定：

| 客户端 | HTTP 端口 | SOCKS5 端口 |
|---|---|---|
| Anycast（仅代理模式） | **8080** | 1080 |
| ClashX / Clash for Windows | 7890 | 7891 |
| Clash Verge / Verge Rev | 7897 | 7898 |
| Surge | 6152 | 6153 |
| V2RayU | 1087 | 1080 |
| sing-box | 2080 | 2080 |

> 注意部分客户端的 SOCKS5 端口不支持 UDP，也不支持 IPv6 目标 —— 本方案的启动器一律用 **HTTP 端口**，就是为了避开这两个坑。

## 已知限制

- **Safari 走不了这套分流**（WebKit 不遵守 PAC），ChatGPT 网页请用 Chrome。
- PAC 服务器依赖 `python3`（macOS 自带的 `/usr/bin/python3` 若未安装，执行 `xcode-select --install`）。
- 需要手动连代理客户端节点；本方案不代替代理客户端本身。
- 极少数客户端的本地端口会变，用 `lsof -nP -iTCP -sTCP:LISTEN` 或 `diagnose.sh` 确认。

## 安全与合规

- 本项目**不修改** ChatGPT 客户端、不绕过任何账号验证、不做批量注册。
- 账号风控的真正变量是**出口 IP 的稳定性**：频繁换地区、换 IP 才容易触发风控，固定一个稳定节点比什么都管用。
- 分流的判据很简单：**直连查 IP 显示国内家宽、对话流量走境外出口**，两个身份同时存在，说明分流生效，不是异常。
- `diagnose.sh` 里的出口 IP 查询会访问 `api.ipify.org` / `ip.3322.net` / `myip.ipip.net` 之一，属于第三方服务，介意的话可以跳过第 ④ 步。

## License

MIT
