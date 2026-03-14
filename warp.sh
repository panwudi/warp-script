#!/usr/bin/env bash
# WARP Script - Google unlock via Cloudflare WARP (ipset)
# Author:  gzsteven666
# Fork:    flyto <https://github.com/panwudi/warp-script>
#   - Replace redsocks with ipt2socks (Python asyncio fallback)
#   - Fix DNS setup in container / read-only environments
#   - Fix uninstall dnf/yum branch logic
#   - Robustness improvements throughout
# Version: 1.4.2
#
# 使用方法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/panwudi/warp-script/main/warp.sh)

set -euo pipefail

SCRIPT_VERSION="1.4.2"

WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
TPROXY_PORT="${TPROXY_PORT:-12345}"      # was REDSOCKS_PORT

REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/panwudi/warp-script/main/warp.sh}"
REPO_SHA256_URL="${REPO_SHA256_URL:-${REPO_RAW_URL}.sha256}"
LOG_FILE="${LOG_FILE:-/var/log/warp-install.log}"

GAI_MARK="# warp-script: prefer ipv4"
IPSET_NAME="${IPSET_NAME:-warp_google4}"
NAT_CHAIN="${NAT_CHAIN:-WARP_GOOGLE}"
QUIC_CHAIN="${QUIC_CHAIN:-WARP_GOOGLE_QUIC}"

CACHE_DIR="/etc/warp-google"
GOOG_JSON_URL="https://www.gstatic.com/ipranges/goog.json"
IPV4_CACHE_FILE="${CACHE_DIR}/google_ipv4.txt"
DNS_MODE_FILE="${CACHE_DIR}/dns_mode"
TPROXY_BACKEND_FILE="${CACHE_DIR}/tproxy_backend"
DNS_BACKUP_FILE="/etc/resolv.conf.warp-backup"
RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_DROPIN_FILE="${RESOLVED_DROPIN_DIR}/99-warp-cloudflare.conf"

WARP_KEEPALIVE_LOCK="${WARP_KEEPALIVE_LOCK:-/run/warp-keepalive.lock}"
WARP_UPDATE_LOCK="${WARP_UPDATE_LOCK:-/run/warp-google-update.lock}"

# ipt2socks fallback version (used only when GitHub API is unreachable)
IPT2SOCKS_FALLBACK_VER="1.1.3"

STATIC_GOOGLE_IPV4_CIDRS="
8.8.4.0/24
8.8.8.0/24
8.34.208.0/20
8.35.192.0/20
23.236.48.0/20
23.251.128.0/19
34.0.0.0/9
35.184.0.0/13
35.192.0.0/12
35.224.0.0/12
35.240.0.0/13
64.18.0.0/20
64.233.160.0/19
66.102.0.0/20
66.249.64.0/19
70.32.128.0/19
72.14.192.0/18
74.114.24.0/21
74.125.0.0/16
104.132.0.0/14
104.154.0.0/15
104.196.0.0/14
104.237.160.0/19
107.167.160.0/19
107.178.192.0/18
108.59.80.0/20
108.170.192.0/18
108.177.0.0/17
130.211.0.0/16
136.112.0.0/12
142.250.0.0/15
146.148.0.0/17
162.216.148.0/22
162.222.176.0/21
172.110.32.0/21
172.217.0.0/16
172.253.0.0/16
173.194.0.0/16
173.255.112.0/20
192.158.28.0/22
192.178.0.0/15
193.186.4.0/24
199.36.154.0/23
199.36.156.0/24
199.192.112.0/22
199.223.232.0/21
203.208.0.0/14
207.223.160.0/20
208.65.152.0/22
208.68.108.0/22
208.81.188.0/22
208.117.224.0/19
209.85.128.0/17
216.58.192.0/19
216.73.80.0/20
216.239.32.0/19
"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

check_root() {
  [[ ${EUID:-0} -ne 0 ]] && { error "请使用 root 运行"; exit 1; } || true
}

show_banner() {
  clear 2>/dev/null || true
  echo -e "${CYAN}"
  echo "╔════════════════════════════════════════════════════╗"
  echo "║ 🚀 WARP Script - Google Gemini 送中               ║"
  echo "║ v${SCRIPT_VERSION}  github.com/panwudi/warp-script         ║"
  echo "╚════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

OS=""
VERSION=""
CODENAME=""

detect_system() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS="${ID:-}"
    VERSION="${VERSION_ID:-}"
    CODENAME="${VERSION_CODENAME:-}"
  else
    error "无法检测系统"
    exit 1
  fi

  if [[ -z "${CODENAME}" ]]; then
    CODENAME="$(lsb_release -cs 2>/dev/null || true)"
  fi
  if [[ -z "${CODENAME}" ]]; then
    case "${OS}" in
      ubuntu)
        case "${VERSION}" in
          20.04*) CODENAME="focal"  ;;
          22.04*) CODENAME="jammy"  ;;
          24.04*) CODENAME="noble"  ;;
        esac
        ;;
      debian)
        case "${VERSION}" in
          10*) CODENAME="buster"    ;;
          11*) CODENAME="bullseye"  ;;
          12*) CODENAME="bookworm"  ;;
        esac
        ;;
    esac
  fi

  success "系统: ${OS} ${VERSION} (${CODENAME:-unknown})"
}

# ---------------------------------------------------------------------------
# 容器环境检测
# ---------------------------------------------------------------------------
_in_container() {
  [[ -f /.dockerenv ]]          && return 0
  [[ -f /run/.containerenv ]]   && return 0
  grep -qE 'lxc|docker|container|kubepods' /proc/1/cgroup 2>/dev/null && return 0
  # systemd-detect-virt
  local virt
  virt="$(systemd-detect-virt --container 2>/dev/null || true)"
  [[ "${virt}" != "none" && -n "${virt}" ]] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# DNS 配置  —  兼容容器/只读/immutable resolv.conf
# ---------------------------------------------------------------------------

# chattr +i 检测（V2bX 等脚本常见操作）
_resolv_is_immutable() {
  command_exists lsattr || return 1
  lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'
}

_resolv_clear_immutable() {
  chattr -i /etc/resolv.conf 2>/dev/null || true
}

_resolv_set_immutable() {
  chattr +i /etc/resolv.conf 2>/dev/null || true
}

setup_cloudflare_dns() {
  info "配置 Cloudflare DNS..."
  mkdir -p "${CACHE_DIR}"

  # 1. systemd-resolved (非容器优先)
  if ! _in_container && command_exists systemctl \
      && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved\.service' \
      && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    mkdir -p "${RESOLVED_DROPIN_DIR}"
    cat > "${RESOLVED_DROPIN_FILE}" <<'EOF_DNS'
[Resolve]
DNS=1.1.1.1 1.0.0.1
FallbackDNS=1.1.1.1 1.0.0.1
DNSStubListener=yes
EOF_DNS
    if command_exists resolvectl; then
      while read -r iface; do
        [[ -n "${iface}" ]] || continue
        resolvectl dns "${iface}" 1.1.1.1 1.0.0.1 >/dev/null 2>&1 || true
      done < <(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | sort -u)
    fi
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
    echo "resolved" > "${DNS_MODE_FILE}"
    success "已通过 systemd-resolved 配置 DNS"
    return 0
  fi

  # 2. 直写 /etc/resolv.conf — 需处理三种阻塞场景：
  #    a) symlink（由系统/容器 runtime 管理）
  #    b) 目录只读（容器 bind mount）
  #    c) chattr +i immutable（V2bX 等脚本设置）

  if [[ -L /etc/resolv.conf ]]; then
    warn "resolv.conf 是符号链接 (由系统管理)，跳过直写"
    echo "skip" > "${DNS_MODE_FILE}"
    return 0
  fi

  # 尝试原子写入测试文件到同目录（检测目录只读）
  local test_file="/etc/.warp-dns-test.$$"
  if ! touch "${test_file}" 2>/dev/null; then
    warn "resolv.conf 目录不可写（容器只读挂载？），跳过 DNS 配置"
    echo "skip" > "${DNS_MODE_FILE}"
    return 0
  fi
  rm -f "${test_file}"

  # 检测并临时解除 immutable 属性
  local was_immutable=0
  if _resolv_is_immutable; then
    info "resolv.conf 有 chattr +i 属性（可能由 V2bX 等设置），临时解除..."
    _resolv_clear_immutable
    was_immutable=1
  fi

  # 最终写入测试（排除未知原因的不可写）
  if ! cp /dev/null /etc/.warp-resolv-write-test.$$ 2>/dev/null; then
    warn "resolv.conf 仍不可写，跳过 DNS 配置"
    [[ ${was_immutable} -eq 1 ]] && _resolv_set_immutable
    echo "skip" > "${DNS_MODE_FILE}"
    return 0
  fi
  rm -f /etc/.warp-resolv-write-test.$$

  cp /etc/resolv.conf "${DNS_BACKUP_FILE}" 2>/dev/null || true
  # 记录原始 immutable 状态，卸载时据此恢复
  echo "${was_immutable}" > "${CACHE_DIR}/resolv_was_immutable"

  cat > /etc/resolv.conf <<'EOF_RESOLV'
nameserver 1.1.1.1
nameserver 1.0.0.1
options timeout:2 attempts:3 rotate
EOF_RESOLV

  # 如果原来是 immutable，写完后重新加锁，防止其他脚本覆盖我们的 DNS 配置
  if [[ ${was_immutable} -eq 1 ]]; then
    _resolv_set_immutable
    success "DNS 已配置为 Cloudflare (已重新加 chattr +i)"
  else
    success "DNS 已配置为 Cloudflare (1.1.1.1)"
  fi
  echo "file" > "${DNS_MODE_FILE}"
}

restore_dns() {
  local mode=""
  mode="$(cat "${DNS_MODE_FILE}" 2>/dev/null || echo skip)"

  case "${mode}" in
    resolved)
      if command_exists resolvectl; then
        while read -r iface; do
          [[ -n "${iface}" ]] || continue
          resolvectl revert "${iface}" >/dev/null 2>&1 || true
        done < <(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | sort -u)
      fi
      rm -f "${RESOLVED_DROPIN_FILE}"
      command_exists systemctl && systemctl restart systemd-resolved >/dev/null 2>&1 || true
      ;;
    file)
      if [[ -f "${DNS_BACKUP_FILE}" ]]; then
        # 先确保可写（安装时已解除 immutable，但恢复前需再次确认）
        _resolv_clear_immutable 2>/dev/null || true
        mv "${DNS_BACKUP_FILE}" /etc/resolv.conf 2>/dev/null || true
        echo "已恢复原 DNS 配置"
      fi
      # 如果原来有 immutable 属性，恢复它
      local was_imm
      was_imm="$(cat "${CACHE_DIR}/resolv_was_immutable" 2>/dev/null || echo 0)"
      if [[ "${was_imm}" == "1" ]]; then
        _resolv_set_immutable
        info "已恢复 resolv.conf chattr +i 属性"
      fi
      rm -f "${CACHE_DIR}/resolv_was_immutable"
      ;;
    skip) ;;  # nothing to do
  esac
  rm -f "${DNS_MODE_FILE}"
}

# ---------------------------------------------------------------------------
# 依赖安装  —  不再依赖 redsocks 包
# ---------------------------------------------------------------------------
install_prereqs() {
  info "安装依赖..."
  case "${OS}" in
    ubuntu|debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1 || true
      local pkgs="curl ca-certificates gnupg lsb-release iptables ipset python3 dnsutils util-linux cron"
      # shellcheck disable=SC2086
      if ! apt-get install -y ${pkgs} >/dev/null 2>&1; then
        # 逐包安装，跳过失败的可选包
        for pkg in ${pkgs}; do
          apt-get install -y "${pkg}" >/dev/null 2>&1 || warn "跳过可选包: ${pkg}"
        done
      fi
      ;;
    centos|rhel|rocky|almalinux|fedora)
      local pm="yum"
      command_exists dnf && pm="dnf"
      "${pm}" install -y epel-release >/dev/null 2>&1 || true
      local pkgs="curl ca-certificates iptables ipset python3 bind-utils util-linux cronie"
      for pkg in ${pkgs}; do
        "${pm}" install -y "${pkg}" >/dev/null 2>&1 || warn "跳过可选包: ${pkg}"
      done
      ;;
    *)
      error "不支持的系统：${OS}"
      exit 1
      ;;
  esac
  success "依赖安装完成"
}

# ---------------------------------------------------------------------------
# 内核模块 & iptables 检查
# ---------------------------------------------------------------------------
ensure_kernel_modules() {
  for mod in ip_set ip_set_hash_net xt_set nf_nat; do
    modprobe "${mod}" 2>/dev/null || true
  done
}

check_iptables() {
  if ! command_exists iptables; then
    error "iptables 未找到，透明代理无法工作"
    return 1
  fi
  if ! iptables -t nat -L >/dev/null 2>&1; then
    warn "iptables nat 表不可用 —— 请确认容器有 NET_ADMIN capability"
  fi
}

# ---------------------------------------------------------------------------
# WARP 客户端安装
# ---------------------------------------------------------------------------
install_warp_client() {
  if command_exists warp-cli; then
    success "已检测到 warp-cli，跳过安装"
    return 0
  fi

  info "安装 Cloudflare WARP..."
  case "${OS}" in
    ubuntu|debian)
      export DEBIAN_FRONTEND=noninteractive
      local arch
      arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
      install -m 0755 -d /usr/share/keyrings
      curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
      [[ -z "${CODENAME}" ]] && { error "无法获取 CODENAME"; return 1; } || true
      echo "deb [arch=${arch} signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ ${CODENAME} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list
      apt-get update -y >/dev/null 2>&1
      apt-get install -y -o Dpkg::Options::="--force-confdef" \
                         -o Dpkg::Options::="--force-confold" \
                         cloudflare-warp >/dev/null 2>&1 || {
        error "WARP 安装失败"; return 1
      }
      ;;
    centos|rhel|rocky|almalinux|fedora)
      rpm --import https://pkg.cloudflareclient.com/pubkey.gpg 2>/dev/null || true
      cat > /etc/yum.repos.d/cloudflare-warp.repo <<'EOF_REPO'
[cloudflare-warp]
name=Cloudflare WARP
baseurl=https://pkg.cloudflareclient.com/rpm
enabled=1
gpgcheck=1
gpgkey=https://pkg.cloudflareclient.com/pubkey.gpg
EOF_REPO
      local pm="yum"
      command_exists dnf && pm="dnf"
      "${pm}" install -y cloudflare-warp || { error "WARP 安装失败"; return 1; }
      ;;
    *)
      error "不支持的系统：${OS}"; return 1 ;;
  esac

  command_exists warp-cli || { error "未找到 warp-cli"; return 1; }
  systemctl enable --now warp-svc >/dev/null 2>&1 || true
  success "WARP 就绪"
}

configure_warp() {
  info "配置 WARP proxy 模式..."
  warp-cli --accept-tos registration new >/dev/null 2>&1 \
    || warp-cli --accept-tos register >/dev/null 2>&1 || true
  warp-cli --accept-tos tunnel protocol set MASQUE >/dev/null 2>&1 \
    || warp-cli tunnel protocol set MASQUE >/dev/null 2>&1 || true
  warp-cli --accept-tos mode proxy >/dev/null 2>&1 \
    || warp-cli mode proxy >/dev/null 2>&1 || true
  warp-cli --accept-tos proxy port "${WARP_PROXY_PORT}" >/dev/null 2>&1 \
    || warp-cli proxy port "${WARP_PROXY_PORT}" >/dev/null 2>&1 || true
  warp-cli --accept-tos connect >/dev/null 2>&1 \
    || warp-cli connect >/dev/null 2>&1 || true
  sleep 2
  local status
  status=$(warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null || echo "未知")
  info "WARP 状态：${status}"
}

setup_gai_conf() {
  if ! grep -qF "${GAI_MARK}" /etc/gai.conf 2>/dev/null; then
    { echo "${GAI_MARK}"; echo "precedence ::ffff:0:0/96  100"; } >> /etc/gai.conf
    success "已配置 IPv4 优先"
  fi
}

# ---------------------------------------------------------------------------
# 透明代理组件  —  ipt2socks (主) / Python asyncio (备)
# ---------------------------------------------------------------------------

# 验证下载的文件是否为 ELF 可执行文件
_is_elf() {
  local f="$1"
  [[ -f "${f}" ]] || return 1
  local magic
  magic="$(od -An -N4 -tx1 "${f}" 2>/dev/null | tr -d ' \n' | head -c8)"
  [[ "${magic}" == "7f454c46" ]]
}

# 尝试从 GitHub Releases 下载 ipt2socks 静态二进制
# ipt2socks: https://github.com/zfl9/ipt2socks
# 专为 iptables REDIRECT → SOCKS5 透明代理设计，轻量活跃维护
_try_install_ipt2socks() {
  local arch
  arch="$(uname -m)"
  local arch_key
  case "${arch}" in
    x86_64)         arch_key="x86_64"  ;;
    aarch64|arm64)  arch_key="aarch64" ;;
    *)
      info "架构 ${arch} 无 ipt2socks 预编译包"
      return 1
      ;;
  esac

  info "尝试下载 ipt2socks (${arch_key})..."
  local tmp
  tmp="$(mktemp)"

  # 先尝试 GitHub API 获取最新 release 资产链接
  local download_url=""
  local api_json
  api_json="$(curl -fsSL --max-time 15 \
    "https://api.github.com/repos/zfl9/ipt2socks/releases/latest" 2>/dev/null || true)"

  if [[ -n "${api_json}" ]]; then
    download_url="$(printf '%s' "${api_json}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for a in d.get('assets', []):
        n = a.get('name', '')
        if '${arch_key}' in n and not n.endswith('.sha256') and not n.endswith('.md5'):
            print(a['browser_download_url'])
            break
except Exception:
    pass
" 2>/dev/null || true)"
  fi

  # 备用：拼接已知版本 URL
  if [[ -z "${download_url}" ]]; then
    download_url="https://github.com/zfl9/ipt2socks/releases/download/\
v${IPT2SOCKS_FALLBACK_VER}/ipt2socks_v${IPT2SOCKS_FALLBACK_VER}_linux_${arch_key}"
  fi

  if ! curl -fsSL --max-time 60 "${download_url}" -o "${tmp}" 2>/dev/null; then
    rm -f "${tmp}"
    warn "ipt2socks 下载失败"
    return 1
  fi

  if ! _is_elf "${tmp}"; then
    rm -f "${tmp}"
    warn "ipt2socks 下载内容非 ELF 二进制（网络/CDN 问题？）"
    return 1
  fi

  install -m 755 "${tmp}" /usr/local/bin/ipt2socks
  rm -f "${tmp}"
  success "ipt2socks 安装完成"
  return 0
}

# Python asyncio fallback —— 仅当 ipt2socks 不可用时使用
# 端口在 install 时由 bash 变量展开，运行时无需任何 env var
_write_python_tproxy() {
  info "写入 Python asyncio tproxy (fallback)..."
  # TPROXY_PORT 和 WARP_PROXY_PORT 在此处由外层 bash 展开
  cat > /usr/local/bin/warp-tproxy-py <<PYEOF
#!/usr/bin/env python3
"""warp-tproxy-py — asyncio transparent SOCKS5 redirector (fallback)
Listen : 127.0.0.1:${TPROXY_PORT}
Forward: socks5://127.0.0.1:${WARP_PROXY_PORT}
"""
import asyncio, socket, struct, signal, sys

_LISTEN = ('127.0.0.1', ${TPROXY_PORT})
_SOCKS5 = ('127.0.0.1', ${WARP_PROXY_PORT})
_SO_ORIG_DST = 80   # SOL_IP / SO_ORIGINAL_DST

def _get_orig_dst(sock):
    raw  = sock.getsockopt(socket.IPPROTO_IP, _SO_ORIG_DST, 16)
    port = struct.unpack_from('!H', raw, 2)[0]
    ip   = socket.inet_ntoa(raw[4:8])
    return ip, port

async def _pipe(reader, writer):
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError, OSError):
        pass
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass

async def _socks5_handshake(reader, writer, dst_ip, dst_port):
    writer.write(b'\\x05\\x01\\x00')
    await writer.drain()
    resp = await asyncio.wait_for(reader.readexactly(2), timeout=10)
    if resp != b'\\x05\\x00':
        raise ConnectionError(f'socks5 auth: {resp!r}')
    req = b'\\x05\\x01\\x00\\x01' + socket.inet_aton(dst_ip) + struct.pack('!H', dst_port)
    writer.write(req)
    await writer.drain()
    resp = await asyncio.wait_for(reader.readexactly(10), timeout=10)
    if resp[1] != 0:
        raise ConnectionError(f'socks5 connect: {resp!r}')

async def _handle(cli_r, cli_w):
    srv_r = srv_w = None
    try:
        sock = cli_w.get_extra_info('socket')
        dst_ip, dst_port = _get_orig_dst(sock)
        srv_r, srv_w = await asyncio.wait_for(
            asyncio.open_connection(*_SOCKS5), timeout=10)
        await _socks5_handshake(srv_r, srv_w, dst_ip, dst_port)
        await asyncio.gather(_pipe(cli_r, srv_w), _pipe(srv_r, cli_w))
    except Exception as e:
        import logging
        logging.debug('warp-tproxy-py: %s', e)
    finally:
        for w in (cli_w, srv_w):
            if w:
                try:
                    w.close()
                    await w.wait_closed()
                except Exception:
                    pass

async def _serve():
    loop = asyncio.get_running_loop()
    stop = loop.create_future()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, lambda: stop.set_result(None) if not stop.done() else None)
    srv = await asyncio.start_server(_handle, *_LISTEN, reuse_address=True)
    print(f'warp-tproxy-py {_LISTEN[0]}:{_LISTEN[1]} -> socks5://{_SOCKS5[0]}:{_SOCKS5[1]}',
          flush=True)
    async with srv:
        await stop

if __name__ == '__main__':
    asyncio.run(_serve())
PYEOF
  chmod +x /usr/local/bin/warp-tproxy-py
}

# 安装透明代理组件，决定使用哪个后端
install_tproxy_backend() {
  info "安装透明代理组件..."
  mkdir -p "${CACHE_DIR}"

  # 停掉旧版本遗留的 redsocks（如有）
  systemctl stop redsocks 2>/dev/null || true
  pkill -x redsocks 2>/dev/null || true

  local backend="python"  # default fallback

  if _try_install_ipt2socks; then
    backend="ipt2socks"
  else
    warn "使用 Python asyncio tproxy 作为透明代理后端"
    _write_python_tproxy
  fi

  echo "${backend}" > "${TPROXY_BACKEND_FILE}"

  # 写 systemd service（ExecStart 根据后端决定）
  info "创建 warp-tproxy.service (backend=${backend})..."
  local exec_start
  if [[ "${backend}" == "ipt2socks" ]]; then
    exec_start="/usr/local/bin/ipt2socks -4 -b 127.0.0.1 -l ${TPROXY_PORT} -s 127.0.0.1 -p ${WARP_PROXY_PORT} -j 2"
  else
    exec_start="/usr/local/bin/warp-tproxy-py"
  fi

  cat > /etc/systemd/system/warp-tproxy.service <<EOF_SVC
[Unit]
Description=WARP transparent proxy (${backend})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${exec_start}
Restart=always
RestartSec=3
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SVC

  systemctl daemon-reload
  systemctl enable --now warp-tproxy >/dev/null 2>&1 || true
  success "透明代理就绪 (${backend})"
}

# ---------------------------------------------------------------------------
# warp-google 管理脚本
# ---------------------------------------------------------------------------
write_warp_google() {
  info "创建 /usr/local/bin/warp-google..."
  mkdir -p "${CACHE_DIR}"

  cat > /usr/local/bin/warp-google <<'WARPGOOGLEEOF'
#!/usr/bin/env bash
set -euo pipefail

WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
TPROXY_PORT="${TPROXY_PORT:-12345}"

IPSET_NAME="${IPSET_NAME:-warp_google4}"
NAT_CHAIN="${NAT_CHAIN:-WARP_GOOGLE}"
QUIC_CHAIN="${QUIC_CHAIN:-WARP_GOOGLE_QUIC}"

CACHE_DIR="/etc/warp-google"
GOOG_JSON_URL="https://www.gstatic.com/ipranges/goog.json"
IPV4_CACHE_FILE="${CACHE_DIR}/google_ipv4.txt"
UPDATE_LOCK="${WARP_UPDATE_LOCK:-/run/warp-google-update.lock}"

STATIC_GOOGLE_IPV4_CIDRS="
8.8.4.0/24
8.8.8.0/24
8.34.208.0/20
8.35.192.0/20
23.236.48.0/20
23.251.128.0/19
34.0.0.0/9
35.184.0.0/13
35.192.0.0/12
35.224.0.0/12
35.240.0.0/13
64.18.0.0/20
64.233.160.0/19
66.102.0.0/20
66.249.64.0/19
70.32.128.0/19
72.14.192.0/18
74.114.24.0/21
74.125.0.0/16
104.132.0.0/14
104.154.0.0/15
104.196.0.0/14
104.237.160.0/19
107.167.160.0/19
107.178.192.0/18
108.59.80.0/20
108.170.192.0/18
108.177.0.0/17
130.211.0.0/16
136.112.0.0/12
142.250.0.0/15
146.148.0.0/17
162.216.148.0/22
162.222.176.0/21
172.110.32.0/21
172.217.0.0/16
172.253.0.0/16
173.194.0.0/16
173.255.112.0/20
192.158.28.0/22
192.178.0.0/15
193.186.4.0/24
199.36.154.0/23
199.36.156.0/24
199.192.112.0/22
199.223.232.0/21
203.208.0.0/14
207.223.160.0/20
208.65.152.0/22
208.68.108.0/22
208.81.188.0/22
208.117.224.0/19
209.85.128.0/17
216.58.192.0/19
216.73.80.0/20
216.239.32.0/19
"

_info() { echo "[warp-google] $*"; }

_warp_connect() {
  warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true
}

_tproxy_start() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart warp-tproxy >/dev/null 2>&1 \
      || systemctl start warp-tproxy >/dev/null 2>&1 || true
  fi
}

_tproxy_stop() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop warp-tproxy >/dev/null 2>&1 || true
  fi
}

_tproxy_active() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet warp-tproxy 2>/dev/null && echo "运行中 (systemd)" && return
  fi
  echo "未运行"
}

_ensure_ipset() {
  for mod in ip_set ip_set_hash_net xt_set; do
    modprobe "${mod}" 2>/dev/null || true
  done
  ipset create "${IPSET_NAME}" hash:net family inet -exist
}

_load_ipv4_list() {
  if [[ -s "${IPV4_CACHE_FILE}" ]]; then
    cat "${IPV4_CACHE_FILE}"
  else
    echo "${STATIC_GOOGLE_IPV4_CIDRS}"
  fi
}

_ipset_apply() {
  _ensure_ipset
  local tmp_set="${IPSET_NAME}_tmp"
  ipset create "${tmp_set}" hash:net family inet -exist
  ipset flush "${tmp_set}" 2>/dev/null || true

  while IFS= read -r cidr; do
    [[ -z "${cidr}" ]] && continue
    ipset add "${tmp_set}" "${cidr}" -exist 2>/dev/null || true
  done < <(_load_ipv4_list)

  ipset swap "${tmp_set}" "${IPSET_NAME}" 2>/dev/null || true
  ipset destroy "${tmp_set}" 2>/dev/null || true
}

_iptables_apply() {
  iptables -t nat    -D OUTPUT -j "${NAT_CHAIN}"  2>/dev/null || true
  iptables -t nat    -F "${NAT_CHAIN}"             2>/dev/null || true
  iptables -t nat    -X "${NAT_CHAIN}"             2>/dev/null || true
  iptables -t filter -D OUTPUT -j "${QUIC_CHAIN}" 2>/dev/null || true
  iptables -t filter -F "${QUIC_CHAIN}"            2>/dev/null || true
  iptables -t filter -X "${QUIC_CHAIN}"            2>/dev/null || true

  iptables -t nat -N "${NAT_CHAIN}" 2>/dev/null || true
  iptables -t nat -F "${NAT_CHAIN}"
  iptables -t nat -A "${NAT_CHAIN}" -p tcp \
    -m set --match-set "${IPSET_NAME}" dst \
    -j REDIRECT --to-ports "${TPROXY_PORT}"
  iptables -t nat -I OUTPUT 1 -j "${NAT_CHAIN}"

  iptables -t filter -N "${QUIC_CHAIN}" 2>/dev/null || true
  iptables -t filter -F "${QUIC_CHAIN}"
  iptables -t filter -A "${QUIC_CHAIN}" -p udp --dport 443 \
    -m set --match-set "${IPSET_NAME}" dst -j REJECT
  iptables -t filter -I OUTPUT 1 -j "${QUIC_CHAIN}"
}

_iptables_clean() {
  iptables -t nat    -D OUTPUT -j "${NAT_CHAIN}"  2>/dev/null || true
  iptables -t nat    -F "${NAT_CHAIN}"             2>/dev/null || true
  iptables -t nat    -X "${NAT_CHAIN}"             2>/dev/null || true
  iptables -t filter -D OUTPUT -j "${QUIC_CHAIN}" 2>/dev/null || true
  iptables -t filter -F "${QUIC_CHAIN}"            2>/dev/null || true
  iptables -t filter -X "${QUIC_CHAIN}"            2>/dev/null || true
}

do_update() {
  exec 200>"${UPDATE_LOCK}"
  flock -n 200 || { _info "已有更新任务在执行，跳过"; return 0; }

  _info "更新 Google IP 段..."
  mkdir -p "${CACHE_DIR}"
  local tmp
  tmp="$(mktemp)"

  local ok=0
  curl -fsSL -x "socks5h://127.0.0.1:${WARP_PROXY_PORT}" --max-time 30 \
    "${GOOG_JSON_URL}" -o "${tmp}" 2>/dev/null && ok=1
  if [[ ${ok} -eq 0 ]]; then
    curl -fsSL --max-time 30 "${GOOG_JSON_URL}" -o "${tmp}" 2>/dev/null && ok=1
  fi

  if [[ ${ok} -eq 0 ]]; then
    _info "下载失败，继续使用现有列表"
    rm -f "${tmp}"
    return 1
  fi

  python3 -c "
import json, sys
with open('${tmp}', encoding='utf-8') as f:
    data = json.load(f)
prefixes = sorted({p['ipv4Prefix'] for p in data.get('prefixes',[]) if 'ipv4Prefix' in p})
print('\n'.join(prefixes))
" > "${IPV4_CACHE_FILE}" 2>/dev/null \
  || grep -oE '"ipv4Prefix"\s*:\s*"[^"]+"' "${tmp}" \
       | sed -E 's/.*"([^"]+)".*/\1/' | sort -u > "${IPV4_CACHE_FILE}"

  rm -f "${tmp}"

  if [[ -s "${IPV4_CACHE_FILE}" ]]; then
    _info "已更新：$(wc -l < "${IPV4_CACHE_FILE}") 条 IP 段"
  else
    _info "解析失败，继续使用静态列表"
    return 1
  fi
}

do_start() {
  _info "启动..."
  _warp_connect
  _tproxy_start
  _ipset_apply
  _iptables_apply
  _info "完成"
}

do_stop() {
  _info "停止..."
  _tproxy_stop
  _iptables_clean
  _info "完成"
}

do_status() {
  echo "=== ipset ==="
  ipset list "${IPSET_NAME}" 2>/dev/null | head -n 15 || echo "不存在"
  echo
  echo "=== NAT 规则 ==="
  iptables -t nat -S "${NAT_CHAIN}" 2>/dev/null || echo "无"
  echo
  echo "=== QUIC 阻断 ==="
  iptables -t filter -S "${QUIC_CHAIN}" 2>/dev/null || echo "无"
  echo
  echo "=== 透明代理进程 ==="
  _tproxy_active
  echo
  echo "=== 后端 ==="
  cat /etc/warp-google/tproxy_backend 2>/dev/null || echo "未知"
}

case "${1:-}" in
  update)  do_update ;;
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; sleep 0.5; do_start ;;
  status)  do_status ;;
  *) echo "用法: warp-google {update|start|stop|restart|status}" ;;
esac
WARPGOOGLEEOF

  chmod +x /usr/local/bin/warp-google
  success "warp-google 已创建"
}

# ---------------------------------------------------------------------------
# warp 管理命令
# ---------------------------------------------------------------------------
write_warp_cli() {
  info "创建 /usr/local/bin/warp..."

  cat > /usr/local/bin/warp <<EOF_WARPCLI
#!/usr/bin/env bash
set -euo pipefail

WARP_PROXY_PORT="${WARP_PROXY_PORT}"
REPO_RAW_URL="${REPO_RAW_URL}"
REPO_SHA256_URL="${REPO_SHA256_URL}"
GAI_MARK="${GAI_MARK}"
SCRIPT_VERSION="${SCRIPT_VERSION}"
DNS_MODE_FILE="${DNS_MODE_FILE}"
RESOLVED_DROPIN_FILE="${RESOLVED_DROPIN_FILE}"
SHA256SUM_BIN="\$(command -v sha256sum 2>/dev/null || command -v shasum 2>/dev/null || true)"

_verify_checksum() {
  local file="\$1" sum_file="\$2"
  if [[ "\${WARP_SKIP_CHECKSUM:-0}" == "1" ]]; then
    echo "[warp] 已跳过校验 (WARP_SKIP_CHECKSUM=1)"; return 0
  fi
  [[ -n "\${SHA256SUM_BIN}" ]] || { echo "[warp] 未找到 sha256 工具" >&2; return 1; }
  local expected actual
  expected="\$(awk '{print \$1}' "\${sum_file}" | head -n1)"
  [[ -n "\${expected}" ]] || { echo "[warp] 校验文件格式无效" >&2; return 1; }
  if [[ "\${SHA256SUM_BIN}" == *shasum ]]; then
    actual="\$(shasum -a 256 "\${file}" | awk '{print \$1}')"
  else
    actual="\$(sha256sum "\${file}" | awk '{print \$1}')"
  fi
  [[ "\${actual}" == "\${expected}" ]] || {
    echo "[warp] SHA256 校验失败 (expected=\${expected} actual=\${actual})" >&2; return 1
  }
  echo "[warp] SHA256 校验通过"
}

case "\${1:-}" in
  status)
    echo "=== WARP 状态 ==="
    warp-cli status 2>/dev/null || echo "未运行"
    echo
    /usr/local/bin/warp-google status
    ;;
  start)
    warp-cli connect 2>/dev/null || true
    /usr/local/bin/warp-google start
    ;;
  stop)
    /usr/local/bin/warp-google stop || true
    warp-cli disconnect 2>/dev/null || true
    ;;
  restart)
    /usr/local/bin/warp-google restart
    ;;
  test)
    echo "=== Google 连接测试 ==="
    curl -s --max-time 10 -o /dev/null -w "HTTP 状态码: %{http_code}\\n" https://www.google.com || echo "失败"
    echo
    echo "=== Gemini 连接测试 ==="
    curl -s --max-time 10 -o /dev/null -w "HTTP 状态码: %{http_code}\\n" https://gemini.google.com || echo "失败"
    echo
    echo "=== WARP Trace ==="
    curl -s --max-time 10 -x "socks5h://127.0.0.1:\${WARP_PROXY_PORT}" \
      https://www.cloudflare.com/cdn-cgi/trace | grep -E "^(warp|loc)=" || echo "未检测到"
    ;;
  ip)
    echo "直连 IP:"
    curl -4 -s --max-time 8 ip.sb || echo "获取失败"
    echo
    echo "WARP IP:"
    curl -s --max-time 8 -x "socks5h://127.0.0.1:\${WARP_PROXY_PORT}" ip.sb || echo "获取失败"
    echo
    ;;
  update)
    /usr/local/bin/warp-google update
    /usr/local/bin/warp-google restart
    ;;
  upgrade)
    echo "[warp] 升级中..."
    local_tmp="\$(mktemp)"
    sum_tmp="\$(mktemp)"
    trap "rm -f '\${local_tmp}' '\${sum_tmp}'" EXIT

    curl -fsSL "\${REPO_RAW_URL}"    -o "\${local_tmp}" || { echo "[warp] 下载失败" >&2; exit 1; }
    curl -fsSL "\${REPO_SHA256_URL}" -o "\${sum_tmp}"   || { echo "[warp] 校验文件下载失败" >&2; exit 1; }

    _verify_checksum "\${local_tmp}" "\${sum_tmp}" || exit 1
    bash -n "\${local_tmp}" || { echo "[warp] 语法检查失败" >&2; exit 1; }
    chmod +x "\${local_tmp}"
    bash "\${local_tmp}" --install
    echo "[warp] 升级完成"
    ;;
  uninstall)
    read -r -p "确定要卸载 WARP？[y/N]: " confirm
    [[ "\${confirm}" =~ ^[Yy]\$ ]] || { echo "已取消"; exit 0; }

    echo "正在卸载..."
    /usr/local/bin/warp-google stop 2>/dev/null || true
    warp-cli disconnect 2>/dev/null || true

    for svc in warp-keepalive.timer warp-keepalive.service warp-google.service \
                warp-tproxy.service warp-svc.service; do
      systemctl disable --now "\${svc}" 2>/dev/null || true
    done

    rm -f /etc/systemd/system/warp-keepalive.timer
    rm -f /etc/systemd/system/warp-keepalive.service
    rm -f /etc/systemd/system/warp-google.service
    rm -f /etc/systemd/system/warp-tproxy.service
    systemctl daemon-reload 2>/dev/null || true

    rm -f /usr/local/bin/warp-google
    rm -f /usr/local/bin/warp-keepalive
    rm -f /usr/local/bin/ipt2socks
    rm -f /usr/local/bin/warp-tproxy-py
    rm -rf /etc/warp-google

    iptables -t nat    -D OUTPUT -j WARP_GOOGLE      2>/dev/null || true
    iptables -t nat    -F WARP_GOOGLE                 2>/dev/null || true
    iptables -t nat    -X WARP_GOOGLE                 2>/dev/null || true
    iptables -t filter -D OUTPUT -j WARP_GOOGLE_QUIC 2>/dev/null || true
    iptables -t filter -F WARP_GOOGLE_QUIC            2>/dev/null || true
    iptables -t filter -X WARP_GOOGLE_QUIC            2>/dev/null || true
    ipset destroy warp_google4 2>/dev/null || true

    sed -i "/\${GAI_MARK}/,+1d" /etc/gai.conf 2>/dev/null || true

    # DNS 恢复
    if [[ -f "\${DNS_MODE_FILE}" ]]; then
      _dns_mode="\$(cat "\${DNS_MODE_FILE}" 2>/dev/null || echo skip)"
      case "\${_dns_mode}" in
        resolved)
          rm -f "\${RESOLVED_DROPIN_FILE}"
          systemctl restart systemd-resolved 2>/dev/null || true
          ;;
        file)
          # 先解除 immutable（如有），再恢复备份
          chattr -i /etc/resolv.conf 2>/dev/null || true
          if [[ -f /etc/resolv.conf.warp-backup ]]; then
            mv /etc/resolv.conf.warp-backup /etc/resolv.conf 2>/dev/null || true
            echo "已恢复原 DNS 配置"
          fi
          # 如果原来有 immutable 属性，恢复它
          _was_imm="\$(cat "${CACHE_DIR}/resolv_was_immutable" 2>/dev/null || echo 0)"
          if [[ "\${_was_imm}" == "1" ]]; then
            chattr +i /etc/resolv.conf 2>/dev/null || true
            echo "已恢复 resolv.conf chattr +i 属性"
          fi
          rm -f "${CACHE_DIR}/resolv_was_immutable"
          ;;
        skip) ;;
      esac
      rm -f "\${DNS_MODE_FILE}"
    fi

    # 卸载 cloudflare-warp 包
    if [[ -f /etc/os-release ]]; then
      # shellcheck disable=SC1091
      source /etc/os-release
      case "\${ID:-}" in
        ubuntu|debian)
          apt-get remove -y cloudflare-warp 2>/dev/null || true
          rm -f /etc/apt/sources.list.d/cloudflare-client.list
          rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
          apt-get update -y >/dev/null 2>&1 || true
          ;;
        centos|rhel|rocky|almalinux|fedora)
          if command -v dnf >/dev/null 2>&1; then
            dnf remove -y cloudflare-warp 2>/dev/null || true
          else
            yum remove -y cloudflare-warp 2>/dev/null || true
          fi
          rm -f /etc/yum.repos.d/cloudflare-warp.repo
          ;;
      esac
    fi

    rm -f /usr/local/bin/warp
    echo "卸载完成"
    ;;
  *)
    echo "WARP 管理工具 v\${SCRIPT_VERSION} (Google Gemini 送中)"
    echo
    echo "用法: warp <命令>"
    echo
    echo "  status    查看状态"
    echo "  start     启动"
    echo "  stop      停止"
    echo "  restart   重启"
    echo "  test      测试 Google / Gemini 连通性"
    echo "  ip        查看直连 IP 与 WARP IP"
    echo "  update    更新 Google IP 段"
    echo "  upgrade   升级脚本（含 SHA256 校验）"
    echo "  uninstall 完整卸载"
    ;;
esac
EOF_WARPCLI

  chmod +x /usr/local/bin/warp
  success "warp 管理命令已创建"
}

# ---------------------------------------------------------------------------
# Keepalive
# ---------------------------------------------------------------------------
write_keepalive() {
  info "创建 keepalive (systemd timer，每 10 分钟)..."

  cat > /usr/local/bin/warp-keepalive <<KEEPALIVE_EOF
#!/usr/bin/env bash
set -euo pipefail
WARP_PROXY_PORT="${WARP_PROXY_PORT}"
LOCK_FILE="${WARP_KEEPALIVE_LOCK}"
LOG_TAG="warp-keepalive"

exec 9>"\${LOCK_FILE}"
flock -n 9 || exit 0

_restart_tproxy() {
  systemctl restart warp-tproxy >/dev/null 2>&1 && return 0
  logger -t "\${LOG_TAG}" "warp-tproxy restart failed"
  return 1
}

# 检查 WARP SOCKS5
if ! curl -s --max-time 10 -x "socks5h://127.0.0.1:\${WARP_PROXY_PORT}" \
     -o /dev/null https://www.google.com; then
  logger -t "\${LOG_TAG}" "WARP proxy unreachable, reconnecting..."
  warp-cli disconnect 2>/dev/null || true
  sleep 2
  warp-cli connect   2>/dev/null || true
  sleep 3
fi

# 检查透明代理
if ! curl -s --max-time 10 -o /dev/null https://www.google.com; then
  logger -t "\${LOG_TAG}" "transparent proxy down, restarting warp-tproxy..."
  _restart_tproxy \
    && logger -t "\${LOG_TAG}" "restarted ok" \
    || logger -t "\${LOG_TAG}" "restart failed"
fi
KEEPALIVE_EOF
  chmod +x /usr/local/bin/warp-keepalive

  cat > /etc/systemd/system/warp-keepalive.service <<'SVC_EOF'
[Unit]
Description=WARP keepalive check
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-keepalive
SVC_EOF

  cat > /etc/systemd/system/warp-keepalive.timer <<'TIMER_EOF'
[Unit]
Description=Run WARP keepalive every 10 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

  systemctl daemon-reload
  systemctl enable --now warp-keepalive.timer >/dev/null 2>&1 || true
  success "keepalive 已配置"
}

write_systemd_service() {
  cat > /etc/systemd/system/warp-google.service <<'EOF_WARP_SERVICE'
[Unit]
Description=WARP Google Transparent Proxy
After=network-online.target warp-svc.service warp-tproxy.service
Wants=network-online.target warp-svc.service warp-tproxy.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/warp-google start
ExecStop=/usr/local/bin/warp-google stop

[Install]
WantedBy=multi-user.target
EOF_WARP_SERVICE

  systemctl daemon-reload
  systemctl enable warp-google 2>/dev/null || true
  success "warp-google.service 已创建"
}

# ---------------------------------------------------------------------------
# 主安装流程
# ---------------------------------------------------------------------------
do_install() {
  show_banner
  info "开始安装 v${SCRIPT_VERSION}..."
  log "install v${SCRIPT_VERSION}"

  install_prereqs
  ensure_kernel_modules
  check_iptables
  setup_cloudflare_dns
  install_warp_client
  setup_gai_conf
  install_tproxy_backend
  write_warp_google
  write_warp_cli
  write_keepalive
  write_systemd_service
  configure_warp

  /usr/local/bin/warp-google update || warn "Google IP 更新失败，使用静态列表"
  /usr/local/bin/warp-google start  || true

  echo
  success "安装完成"
  echo -e "\n管理命令: ${GREEN}warp {status|start|stop|restart|test|ip|update|upgrade|uninstall}${NC}\n"

  echo -e "${CYAN}测试连接...${NC}"
  sleep 2
  local code
  code=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.google.com || echo "000")
  if [[ "${code}" == "200" ]]; then
    success "Google 连接成功 ✓"
  else
    warn "Google 测试返回: ${code} (WARP 可能仍在初始化，稍后运行 'warp test' 验证)"
  fi
}

do_status() {
  command_exists warp && warp status || echo "未安装"
}

show_menu() {
  echo -e "${YELLOW}请选择操作:${NC}\n"
  echo -e "  ${GREEN}1.${NC} 安装/升级"
  echo -e "  ${GREEN}2.${NC} 卸载"
  echo -e "  ${GREEN}3.${NC} 查看状态"
  echo -e "  ${GREEN}0.${NC} 退出\n"

  read -r -p "请输入选项 [0-3]: " choice
  case "${choice}" in
    1) do_install ;;
    2) /usr/local/bin/warp uninstall 2>/dev/null || warn "请先安装" ;;
    3) do_status ;;
    0) echo "再见"; exit 0 ;;
    *) error "无效选项" ;;
  esac
}

main() {
  check_root
  detect_system
  case "${1:-}" in
    --install|install) do_install ;;
    --status|status)   do_status  ;;
    *)                 show_banner; show_menu ;;
  esac
}

main "$@"
