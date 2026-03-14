# 🚀 WARP Script — Google Gemini 送中

> **Fork of [gzsteven666/warp-script](https://github.com/gzsteven666/warp-script) by [flyto](https://github.com/panwudi)**
>
> 原作者并没有留下文档，这份 README 由 fork 补充。

---

## 这是什么？

在中国大陆的服务器上，访问 Google / Gemini API 会被 GFW 拦截。  
这个脚本在服务器上安装 **Cloudflare WARP**，并通过 **iptables ipset 透明代理**，将所有发往 Google IP 段的 TCP 流量自动经 WARP 转发——其他流量完全不受影响。

安装完成后，服务器上任何程序（curl、Python SDK、Node.js 等）访问 Google / Gemini，**无需改代码、无需设置环境变量**，直接就通。

**为什么叫"Google Gemini 送中"？**  
WARP 在墙内落地，让 Google/Gemini 的流量"送进"中国服务器——反向穿透，形象贴切 😄

---

## 工作原理

```
你的程序
    │  TCP → Google IP (如 142.250.x.x:443)
    ▼
iptables OUTPUT 链
    │  match: ipset warp_google4
    │  action: REDIRECT → 127.0.0.1:12345
    ▼
warp-tproxy (ipt2socks / Python asyncio)
    │  读取 SO_ORIGINAL_DST 获取原始目标
    │  SOCKS5 CONNECT 请求
    ▼
Cloudflare WARP SOCKS5 Proxy (:40000)
    │
    ▼
  Google / Gemini ✓

iptables QUIC 阻断：UDP 443 → REJECT（强制走 TCP/TLS，避免 QUIC 绕过）
```

### 核心组件

| 组件 | 作用 |
|---|---|
| `cloudflare-warp` | WARP 客户端，提供 SOCKS5 代理 (port 40000) |
| `ipt2socks` | 透明 TCP 代理：REDIRECT 拦截 → SOCKS5 转发 |
| `ipset warp_google4` | Google 全量 IPv4 段，热更新不中断服务 |
| `iptables WARP_GOOGLE` | NAT REDIRECT 规则链 |
| `iptables WARP_GOOGLE_QUIC` | 阻断 QUIC (UDP 443) 防止绕过 |
| `warp-keepalive.timer` | 每 10 分钟检测并自愈 |

### 透明代理后端选择

安装时自动探测：

1. **ipt2socks**（首选）：C 编写的静态二进制，专为 `iptables REDIRECT → SOCKS5` 设计，活跃维护。从 GitHub Releases 自动下载，支持 x86_64 / aarch64。
2. **Python asyncio tproxy**（fallback）：当 ipt2socks 下载失败时启用，纯 stdlib，无额外依赖。

---

## 系统要求

- OS：Ubuntu 20.04 / 22.04 / 24.04，Debian 11 / 12，CentOS/Rocky/AlmaLinux 8+
- 架构：x86_64 / aarch64
- 权限：root
- 网络：服务器本身需能访问 Cloudflare（WARP 注册需要）
- 容器：支持有 `NET_ADMIN` capability 的 Docker / LXC 容器

---

## 快速安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/panwudi/warp-script/main/warp.sh)
```

选择 `1. 安装/升级` 即可。

### 非交互式安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/panwudi/warp-script/main/warp.sh) --install
```

### 自定义端口

```bash
WARP_PROXY_PORT=40001 TPROXY_PORT=12346 \
  bash <(curl -fsSL .../warp.sh) --install
```

---

## 管理命令

安装完成后使用 `warp` 命令管理：

```
warp status    # 查看 WARP 状态 + iptables 规则 + 后端进程
warp start     # 启动
warp stop      # 停止（断开 WARP，清除 iptables 规则）
warp restart   # 重启
warp test      # 测试 Google / Gemini 连通性
warp ip        # 显示直连 IP 与 WARP IP（确认 WARP 已接管）
warp update    # 从 gstatic.com 更新 Google IP 段并重载
warp upgrade   # 升级脚本本体（含 SHA256 校验）
warp uninstall # 完整卸载，恢复原始 DNS 配置
```

### 常用验证

```bash
# 验证 Google 走了 WARP
warp test

# 查看 WARP 节点位置（warp=on 表示已接管）
curl https://www.cloudflare.com/cdn-cgi/trace | grep -E "warp|loc"

# 直接测试 Gemini API（需要有效 API Key）
curl -s "https://generativelanguage.googleapis.com/v1/models?key=YOUR_KEY" | head -c 200
```

---

## 配置文件位置

| 路径 | 说明 |
|---|---|
| `/etc/warp-google/` | 运行时数据目录 |
| `/etc/warp-google/google_ipv4.txt` | 缓存的 Google IP 段 |
| `/etc/warp-google/tproxy_backend` | 当前透明代理后端 (`ipt2socks` / `python`) |
| `/etc/warp-google/dns_mode` | DNS 配置模式 (`resolved` / `file` / `skip`) |
| `/etc/systemd/system/warp-tproxy.service` | 透明代理服务 |
| `/etc/systemd/system/warp-google.service` | 主服务（开机自启） |
| `/etc/systemd/system/warp-keepalive.timer` | 自愈检测 timer |
| `/usr/local/bin/warp` | 管理命令 |
| `/usr/local/bin/warp-google` | 内部管理脚本 |
| `/usr/local/bin/ipt2socks` | 透明代理二进制（如已安装） |

---

## 故障排查

### `warp test` 返回非 200

```bash
# 1. 检查 WARP 是否连接
warp-cli status

# 2. 检查 SOCKS5 代理是否通
curl -x socks5h://127.0.0.1:40000 https://www.google.com -v

# 3. 检查透明代理进程
systemctl status warp-tproxy

# 4. 检查 iptables 规则
iptables -t nat -S WARP_GOOGLE
ipset list warp_google4 | head -5

# 5. 手动重启
warp restart
```

### DNS 配置跳过（容器环境）

在 Docker/LXC 容器中，`/etc/resolv.conf` 通常由容器 runtime 管理，脚本会自动检测并跳过修改（输出 `[WARN] resolv.conf 是符号链接，跳过直写`）。这是正常行为，不影响透明代理功能。如需在容器内使用特定 DNS，请在容器启动时配置。

### ipset 报错 `Module ip_set not found`

```bash
# 手动加载内核模块
modprobe ip_set ip_set_hash_net xt_set
# 或检查内核是否支持
grep ip_set /boot/config-$(uname -r) 2>/dev/null || zcat /proc/config.gz | grep ip_set
```

### 容器缺少 NET_ADMIN

```bash
# Docker 运行时需要
docker run --cap-add NET_ADMIN ...
# 或 docker-compose
cap_add:
  - NET_ADMIN
```

### ipt2socks 下载失败（网络受限环境）

脚本会自动 fallback 到 Python asyncio tproxy，功能相同。查看当前后端：

```bash
cat /etc/warp-google/tproxy_backend
```

如果想手动安装 ipt2socks 后切换：

```bash
# 下载对应架构的二进制到 /usr/local/bin/ipt2socks
# 然后重新安装脚本即可
bash <(curl -fsSL .../warp.sh) --install
```

---

## Fork 变更日志

### v1.4.2 (flyto fork)

- **核心**：用 [ipt2socks](https://github.com/zfl9/ipt2socks) 替换停更的 redsocks 作为透明代理后端；Python asyncio tproxy 作为自动 fallback
- **修复**：DNS 配置在容器/只读环境下的 `Operation not permitted` 错误（symlink 检测 + 写权限探测）
- **修复**：卸载时 dnf/yum 分支判断逻辑错误（原脚本 `command -v dnf && dnf remove ... || yum remove ...` 在 dnf 存在但 remove 失败时会错误地再执行 yum）
- **修复**：安装依赖移除对 `redsocks` 包的依赖（该包在部分发行版不存在导致整体安装失败）
- **修复**：卸载清单补全（新增 ipt2socks、warp-tproxy-py、warp-tproxy.service）
- **改进**：依赖安装改为逐包安装，单个可选包失败不中断整体流程
- **改进**：`warp test` 增加 Gemini 连通性测试
- **改进**：内核模块自动加载（ip_set、xt_set 等）
- **改进**：Banner 更新，加入项目名称

---

## 注意事项

- 本脚本仅转发 **Google 公开 IP 段**的流量，其他流量直连，不影响服务器正常网络
- WARP 免费账户有流量限制，高并发场景建议使用 WARP Teams / Zero Trust
- Google IP 段通过 `warp update` 从 `gstatic.com` 实时更新，静态兜底列表覆盖主要 IP 段
- 服务器重启后自动恢复（`warp-google.service` 开机自启）

---

## 致谢

- [gzsteven666/warp-script](https://github.com/gzsteven666/warp-script) — 原始脚本作者
- [zfl9/ipt2socks](https://github.com/zfl9/ipt2socks) — 透明 SOCKS5 代理组件
- [Cloudflare WARP](https://1.1.1.1/) — WARP 客户端
