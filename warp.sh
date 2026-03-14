#!/usr/bin/env bash
# WARP Script - Google Gemini 送中
# Original Author : gzsteven666
# Fork            : FLYTOex NetWork <https://github.com/panwudi/warp-script>
#   v1.5.0  Port-conflict auto-resolve · Registration reuse
#           Single-source ENV file · Backward-compat uninstall
#           Layered diagnostics · Green success banner
#
# 使用方法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/panwudi/warp-script/main/warp.sh)

set -euo pipefail

SCRIPT_VERSION="1.5.0"

# ---------------------------------------------------------------------------
# 运行时配置文件 — 端口的唯一真相来源
# 安装时写入，所有组件运行时 source，不再写死
# ---------------------------------------------------------------------------
ENV_FILE="/etc/warp-google/env"

# 默认值（会被 ENV_FILE 覆盖）
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
TPROXY_PORT="${TPROXY_PORT:-12345}"
# 向后兼容旧版本 REDSOCKS_PORT 变量
[[ -z "${TPROXY_PORT:-}" && -n "${REDSOCKS_PORT:-}" ]] && TPROXY_PORT="${REDSOCKS_PORT}"

# 若已有 env 文件，优先读取（升级场景）
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}" 2>/dev/null || true

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

# ---------------------------------------------------------------------------
# 颜色 & 日志
# ---------------------------------------------------------------------------
_R='\033[1;31m' _Y='\033[1;33m' _G='\033[1;32m'
_C='\033[1;36m' _M='\033[1;35m' _W='\033[1;37m'
_B='\033[0;34m' RED='\033[0;31m' GREEN='\033[0;32m'
YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

check_root() {
  [[ ${EUID:-0} -ne 0 ]] && { error "请使用 root 运行"; exit 1; } || true
}

# ---------------------------------------------------------------------------
# Banner — FLYTOex NetWork
# ---------------------------------------------------------------------------
show_banner() {
  clear 2>/dev/null || true
  echo -e "${_C}┌─────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${_C}│${NC}                                                             ${_C}│${NC}"
  echo -e "${_C}│${NC}  ${_R}▄████${NC} ${_Y}▄█${NC}   ${_G}▀██${NC} ${_C}▄▄▄▄█████▄${NC} ${_M}▄██████${NC} ${_W}███████${NC} ${_R}██${NC} ${_Y}██${NC}             ${_C}│${NC}"
  echo -e "${_C}│${NC}  ${_R}██${NC}    ${_Y}██${NC}    ${_G}██${NC} ${_C}   ██   ${NC}  ${_M}██    ██${NC} ${_W}██   ${NC}   ${_R}██${NC} ${_Y}██${NC}             ${_C}│${NC}"
  echo -e "${_C}│${NC}  ${_R}█████${NC} ${_Y}██${NC}    ${_G}██${NC} ${_C}   ██   ${NC}  ${_M}██    ██${NC} ${_W}█████${NC}   ${_R}████${NC}               ${_C}│${NC}"
  echo -e "${_C}│${NC}  ${_R}██${NC}    ${_Y}██${NC}    ${_G}██${NC} ${_C}   ██   ${NC}  ${_M}██    ██${NC} ${_W}██   ${NC}   ${_R}██${NC} ${_Y}██${NC}             ${_C}│${NC}"
  echo -e "${_C}│${NC}  ${_R}██${NC}    ${_Y}████████${NC} ${_C}   ██   ${NC}  ${_M}████████${NC} ${_W}███████${NC} ${_R}██${NC}  ${_Y}██${NC}             ${_C}│${NC}"
  echo -e "${_C}│${NC}                                                             ${_C}│${NC}"
  echo -e "${_C}│${NC}  ${_W}NetWork${NC}  ${_C}·${NC}  ${_G}WARP Script${NC}  ${_C}·${NC}  ${_Y}Google Gemini 送中${NC}              ${_C}│${NC}"
  echo -e "${_C}│${NC}  ${_W}v${SCRIPT_VERSION}${NC}  ${_C}·${NC}  ${_B}github.com/panwudi/warp-script${NC}                    ${_C}│${NC}"
  echo -e "${_C}│${NC}                                                             ${_C}│${NC}"
  echo -e "${_C}└─────────────────────────────────────────────────────────────┘${NC}"
  echo
}

# ---------------------------------------------------------------------------
# 系统检测
# ---------------------------------------------------------------------------
OS="" VERSION="" CODENAME=""

detect_system() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS="${ID:-}" VERSION="${VERSION_ID:-}" CODENAME="${VERSION_CODENAME:-}"
  else
    error "无法检测系统"; exit 1
  fi
  [[ -z "${CODENAME}" ]] && CODENAME="$(lsb_release -cs 2>/dev/null || true)"
  if [[ -z "${CODENAME}" ]]; then
    case "${OS}" in
      ubuntu) case "${VERSION}" in
        20.04*) CODENAME="focal" ;; 22.04*) CODENAME="jammy" ;;
        24.04*) CODENAME="noble" ;; esac ;;
      debian) case "${VERSION}" in
        10*) CODENAME="buster" ;; 11*) CODENAME="bullseye" ;;
        12*) CODENAME="bookworm" ;; esac ;;
    esac
  fi
  success "系统: ${OS} ${VERSION} (${CODENAME:-unknown})"
}

# ---------------------------------------------------------------------------
# 容器检测
# ---------------------------------------------------------------------------
_in_container() {
  [[ -f /.dockerenv ]]        && return 0
  [[ -f /run/.containerenv ]] && return 0
  grep -qE 'lxc|docker|container|kubepods' /proc/1/cgroup 2>/dev/null && return 0
  local virt; virt="$(systemd-detect-virt --container 2>/dev/null || true)"
  [[ "${virt}" != "none" && -n "${virt}" ]] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# resolv.conf helpers — symlink / 只读目录 / chattr +i 三种场景
# ---------------------------------------------------------------------------
_resolv_is_immutable() {
  command_exists lsattr || return 1
  lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'
}
_resolv_clear_immutable() { chattr -i /etc/resolv.conf 2>/dev/null || true; }
_resolv_set_immutable()   { chattr +i /etc/resolv.conf 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# DNS 配置
# ---------------------------------------------------------------------------
setup_cloudflare_dns() {
  info "配置 Cloudflare DNS..."
  mkdir -p "${CACHE_DIR}"

  # 1. systemd-resolved（非容器）
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

  # 2. 直写 resolv.conf — 三重阻塞检测
  if [[ -L /etc/resolv.conf ]]; then
    warn "resolv.conf 是符号链接（由系统管理），跳过直写"
    echo "skip" > "${DNS_MODE_FILE}"; return 0
  fi

  # 目录可写性探测
  local test_file="/etc/.warp-dns-test.$$"
  if ! touch "${test_file}" 2>/dev/null; then
    warn "resolv.conf 目录不可写（容器只读挂载？），跳过 DNS 配置"
    echo "skip" > "${DNS_MODE_FILE}"; return 0
  fi
  rm -f "${test_file}"

  # chattr +i 检测（V2bX 等脚本常见操作）
  local was_immutable=0
  if _resolv_is_immutable; then
    info "resolv.conf 有 chattr +i 属性（可能由 V2bX 等设置），临时解除..."
    _resolv_clear_immutable; was_immutable=1
  fi

  # 最终写入
  cp /etc/resolv.conf "${DNS_BACKUP_FILE}" 2>/dev/null || true
  echo "${was_immutable}" > "${CACHE_DIR}/resolv_was_immutable"
  cat > /etc/resolv.conf <<'EOF_RESOLV'
nameserver 1.1.1.1
nameserver 1.0.0.1
options timeout:2 attempts:3 rotate
EOF_RESOLV

  # 写完重新加锁，保护我们的 DNS 不被其他脚本覆盖
  if [[ ${was_immutable} -eq 1 ]]; then
    _resolv_set_immutable
    success "DNS 已配置为 Cloudflare（chattr +i 已重新加锁）"
  else
    success "DNS 已配置为 Cloudflare (1.1.1.1)"
  fi
  echo "file" > "${DNS_MODE_FILE}"
}

restore_dns() {
  local mode=""; mode="$(cat "${DNS_MODE_FILE}" 2>/dev/null || echo skip)"
  case "${mode}" in
    resolved)
      if command_exists resolvectl; then
        while read -r iface; do
          [[ -n "${iface}" ]] || continue
          resolvectl revert "${iface}" >/dev/null 2>&1 || true
        done < <(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | sort -u)
      fi
      rm -f "${RESOLVED_DROPIN_FILE}"
      command_exists systemctl && systemctl restart systemd-resolved >/dev/null 2>&1 || true ;;
    file)
      _resolv_clear_immutable 2>/dev/null || true
      [[ -f "${DNS_BACKUP_FILE}" ]] && mv "${DNS_BACKUP_FILE}" /etc/resolv.conf 2>/dev/null || true
      local was_imm; was_imm="$(cat "${CACHE_DIR}/resolv_was_immutable" 2>/dev/null || echo 0)"
      [[ "${was_imm}" == "1" ]] && { _resolv_set_immutable; info "已恢复 resolv.conf chattr +i 属性"; }
      rm -f "${CACHE_DIR}/resolv_was_immutable"
      echo "已恢复原 DNS 配置" ;;
    skip) ;;
  esac
  rm -f "${DNS_MODE_FILE}"
}

# ---------------------------------------------------------------------------
# 依赖安装（不依赖 redsocks 包）
# ---------------------------------------------------------------------------
install_prereqs() {
  info "安装依赖..."
  case "${OS}" in
    ubuntu|debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1 || true
      local pkgs="curl ca-certificates gnupg lsb-release iptables ipset python3 dnsutils util-linux cron"
      for pkg in ${pkgs}; do
        apt-get install -y "${pkg}" >/dev/null 2>&1 || warn "跳过可选包: ${pkg}"
      done ;;
    centos|rhel|rocky|almalinux|fedora)
      local pm="yum"; command_exists dnf && pm="dnf"
      "${pm}" install -y epel-release >/dev/null 2>&1 || true
      for pkg in curl ca-certificates iptables ipset python3 bind-utils util-linux cronie; do
        "${pm}" install -y "${pkg}" >/dev/null 2>&1 || warn "跳过可选包: ${pkg}"
      done ;;
    *) error "不支持的系统：${OS}"; exit 1 ;;
  esac
  success "依赖安装完成"
}

ensure_kernel_modules() {
  for mod in ip_set ip_set_hash_net xt_set nf_nat; do
    modprobe "${mod}" 2>/dev/null || true
  done
}

check_iptables() {
  command_exists iptables || { error "iptables 未找到"; return 1; }
  iptables -t nat -L >/dev/null 2>&1 \
    || warn "iptables nat 表不可用 —— 请确认容器有 NET_ADMIN capability"
}

# ---------------------------------------------------------------------------
# WARP 客户端安装
# ---------------------------------------------------------------------------
install_warp_client() {
  if command_exists warp-cli; then
    success "已检测到 warp-cli，跳过安装"; return 0
  fi
  info "安装 Cloudflare WARP..."
  case "${OS}" in
    ubuntu|debian)
      export DEBIAN_FRONTEND=noninteractive
      local arch; arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
      install -m 0755 -d /usr/share/keyrings
      curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
      [[ -z "${CODENAME}" ]] && { error "无法获取 CODENAME"; return 1; }
      echo "deb [arch=${arch} signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ ${CODENAME} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list
      apt-get update -y >/dev/null 2>&1
      apt-get install -y -o Dpkg::Options::="--force-confdef" \
                         -o Dpkg::Options::="--force-confold" \
                         cloudflare-warp >/dev/null 2>&1 || { error "WARP 安装失败"; return 1; } ;;
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
      local pm="yum"; command_exists dnf && pm="dnf"
      "${pm}" install -y cloudflare-warp || { error "WARP 安装失败"; return 1; } ;;
    *) error "不支持的系统：${OS}"; return 1 ;;
  esac
  command_exists warp-cli || { error "未找到 warp-cli"; return 1; }
  systemctl enable --now warp-svc >/dev/null 2>&1 || true
  success "WARP 就绪"
}

# ---------------------------------------------------------------------------
# WARP 配置 — 注册复用 + 端口冲突三段处理
# ---------------------------------------------------------------------------

# 检测 ss 中是否有外部进程占用端口
_port_held_externally() {
  local port="$1"
  # warp-svc 绑定的端口不会出现在 ss 的 TCP LISTEN 里（它是 SOCKS5 内部状态）
  # 如果 ss 里有东西，一定是外部进程
  ss -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]"
}

# 找一个可用的代理端口
# 返回值写入全局 WARP_PROXY_PORT
_find_free_proxy_port() {
  local port="${WARP_PROXY_PORT}"
  local limit=$((port + 20))
  while [[ ${port} -lt ${limit} ]]; do
    if ! _port_held_externally "${port}"; then
      WARP_PROXY_PORT="${port}"; return 0
    fi
    local holder_pid; holder_pid="$(ss -tlnp 2>/dev/null \
      | grep ":${port}[[:space:]]" | grep -oP 'pid=\K[0-9]+' | head -1 || true)"
    local holder_name=""; [[ -n "${holder_pid}" ]] \
      && holder_name="$(cat /proc/${holder_pid}/comm 2>/dev/null || true)"
    warn "端口 ${port} 被 ${holder_name:-未知进程}(pid=${holder_pid:-?}) 占用，尝试 $((port+1))..."
    port=$((port + 1))
  done
  WARP_PROXY_PORT="${port}"
  warn "未找到完全空闲的端口，将尝试使用 ${port}"
}

configure_warp() {
  info "配置 WARP proxy 模式..."

  # --- 注册：有则复用，无则新建 ---
  local reg_ok=0
  warp-cli --accept-tos registration show >/dev/null 2>&1 && reg_ok=1 \
    || warp-cli registration show >/dev/null 2>&1 && reg_ok=1 || true
  if [[ ${reg_ok} -eq 0 ]]; then
    info "未找到 WARP 注册，创建新注册..."
    warp-cli --accept-tos registration new >/dev/null 2>&1 \
      || warp-cli --accept-tos register >/dev/null 2>&1 || true
  else
    info "复用现有 WARP 注册"
  fi

  # --- 模式 & 协议 ---
  warp-cli --accept-tos tunnel protocol set MASQUE >/dev/null 2>&1 \
    || warp-cli tunnel protocol set MASQUE >/dev/null 2>&1 || true
  warp-cli --accept-tos mode proxy >/dev/null 2>&1 \
    || warp-cli mode proxy >/dev/null 2>&1 || true

  # --- 端口冲突处理 ---
  # 外部进程占用：_find_free_proxy_port 处理
  _find_free_proxy_port

  # 连接 + 端口冲突重试（最多 3 次）
  # warp-svc 的"port already bound"是内部状态，ss 看不到，需重启 warp-svc 清除
  local attempt=0 connected=0 status=""
  while [[ ${attempt} -lt 3 && ${connected} -eq 0 ]]; do
    info "设置代理端口: ${WARP_PROXY_PORT}（第 $((attempt+1)) 次尝试）"
    warp-cli --accept-tos proxy port "${WARP_PROXY_PORT}" >/dev/null 2>&1 \
      || warp-cli proxy port "${WARP_PROXY_PORT}" >/dev/null 2>&1 || true
    warp-cli --accept-tos connect >/dev/null 2>&1 \
      || warp-cli connect >/dev/null 2>&1 || true

    # 轮询等待连接，最多 20 秒
    local i
    for i in $(seq 1 20); do
      status="$(warp-cli --accept-tos status 2>/dev/null \
               || warp-cli status 2>/dev/null || echo '')"
      if echo "${status}" | grep -qi 'Connected'; then
        connected=1; break
      fi
      sleep 1; printf "."
    done
    echo

    if [[ ${connected} -eq 1 ]]; then break; fi

    # 判断是否端口冲突错误
    if echo "${status}" | grep -qi 'proxy port'; then
      if [[ ${attempt} -eq 0 ]]; then
        # 第一次：warp-svc 自占 → 重启释放
        info "检测到端口 ${WARP_PROXY_PORT} 被 warp-svc 内部状态占用，重启 warp-svc..."
        systemctl restart warp-svc >/dev/null 2>&1 || true
        sleep 3
      else
        # 第二次：换端口
        WARP_PROXY_PORT=$((WARP_PROXY_PORT + 1))
        warn "切换到端口 ${WARP_PROXY_PORT}..."
      fi
    fi
    attempt=$((attempt + 1))
  done

  if [[ ${connected} -eq 1 ]]; then
    success "WARP 已连接，使用端口 ${WARP_PROXY_PORT}"
    # 验证 SOCKS5
    if ss -tlnp 2>/dev/null | grep -q ":${WARP_PROXY_PORT}"; then
      success "SOCKS5 代理端口 ${WARP_PROXY_PORT} 已监听"
    fi
  else
    warn "WARP 连接失败，当前状态: ${status:-未知}"
    warn "可能原因：服务器无法访问 Cloudflare 端点，或注册未完成"
    warn "安装完成后运行 'warp test' 进行逐层诊断"
  fi

  # --- 保存最终端口到 ENV_FILE ---
  _save_env
}

# 将当前端口配置写入 ENV_FILE（各组件运行时 source 它）
_save_env() {
  mkdir -p "${CACHE_DIR}"
  cat > "${ENV_FILE}" <<EOF_ENV
# warp-script runtime config — auto-generated, do not edit manually
WARP_PROXY_PORT=${WARP_PROXY_PORT}
TPROXY_PORT=${TPROXY_PORT}
EOF_ENV
  success "端口配置已写入 ${ENV_FILE}  (WARP_PROXY_PORT=${WARP_PROXY_PORT}  TPROXY_PORT=${TPROXY_PORT})"
}

setup_gai_conf() {
  if ! grep -qF "${GAI_MARK}" /etc/gai.conf 2>/dev/null; then
    { echo "${GAI_MARK}"; echo "precedence ::ffff:0:0/96  100"; } >> /etc/gai.conf
    success "已配置 IPv4 优先"
  fi
}

# ---------------------------------------------------------------------------
# 透明代理 — ipt2socks（主）/ Python asyncio（备）
# 所有端口在运行时从 ENV_FILE 读取，不再写死
# ---------------------------------------------------------------------------

_is_elf() {
  local f="$1"; [[ -f "${f}" ]] || return 1
  local magic; magic="$(od -An -N4 -tx1 "${f}" 2>/dev/null | tr -d ' \n' | head -c8)"
  [[ "${magic}" == "7f454c46" ]]
}

_try_install_ipt2socks() {
  local arch; arch="$(uname -m)"
  local arch_key
  case "${arch}" in
    x86_64)        arch_key="x86_64"  ;;
    aarch64|arm64) arch_key="aarch64" ;;
    *) info "架构 ${arch} 无 ipt2socks 预编译包"; return 1 ;;
  esac

  # 跳过重复安装
  if [[ -x /usr/local/bin/ipt2socks ]]; then
    success "ipt2socks 已存在，跳过下载"; return 0
  fi

  info "下载 ipt2socks (${arch_key})..."
  local tmp; tmp="$(mktemp)"
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
            print(a['browser_download_url']); break
except Exception: pass
" 2>/dev/null || true)"
  fi
  [[ -z "${download_url}" ]] && \
    download_url="https://github.com/zfl9/ipt2socks/releases/download/\
v${IPT2SOCKS_FALLBACK_VER}/ipt2socks_v${IPT2SOCKS_FALLBACK_VER}_linux_${arch_key}"

  if ! curl -fsSL --max-time 60 "${download_url}" -o "${tmp}" 2>/dev/null; then
    rm -f "${tmp}"; warn "ipt2socks 下载失败"; return 1
  fi
  if ! _is_elf "${tmp}"; then
    rm -f "${tmp}"; warn "ipt2socks 下载内容非 ELF"; return 1
  fi
  install -m 755 "${tmp}" /usr/local/bin/ipt2socks
  rm -f "${tmp}"
  success "ipt2socks 安装完成"
}

# Python asyncio fallback（端口通过 ENV_FILE 注入，不写死）
_write_python_tproxy() {
  info "写入 Python asyncio tproxy (fallback)..."
  cat > /usr/local/bin/warp-tproxy-py <<'PYEOF'
#!/usr/bin/env python3
"""warp-tproxy-py — asyncio transparent SOCKS5 redirector (fallback)
Ports sourced from /etc/warp-google/env at startup.
"""
import asyncio, os, socket, struct, signal, sys

def _load_env():
    env_file = '/etc/warp-google/env'
    cfg = {}
    try:
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, v = line.split('=', 1)
                    cfg[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return cfg

_cfg = _load_env()
_LISTEN = ('127.0.0.1', int(_cfg.get('TPROXY_PORT', os.environ.get('TPROXY_PORT', 12345))))
_SOCKS5 = ('127.0.0.1', int(_cfg.get('WARP_PROXY_PORT', os.environ.get('WARP_PROXY_PORT', 40000))))
_SO_ORIG_DST = 80

def _get_orig_dst(sock):
    raw  = sock.getsockopt(socket.IPPROTO_IP, _SO_ORIG_DST, 16)
    port = struct.unpack_from('!H', raw, 2)[0]
    ip   = socket.inet_ntoa(raw[4:8])
    return ip, port

async def _pipe(reader, writer):
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk: break
            writer.write(chunk); await writer.drain()
    except (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError, OSError):
        pass
    finally:
        try: writer.close(); await writer.wait_closed()
        except Exception: pass

async def _socks5_handshake(reader, writer, dst_ip, dst_port):
    writer.write(b'\x05\x01\x00'); await writer.drain()
    resp = await asyncio.wait_for(reader.readexactly(2), timeout=10)
    if resp != b'\x05\x00': raise ConnectionError(f'socks5 auth: {resp!r}')
    req = b'\x05\x01\x00\x01' + socket.inet_aton(dst_ip) + struct.pack('!H', dst_port)
    writer.write(req); await writer.drain()
    resp = await asyncio.wait_for(reader.readexactly(10), timeout=10)
    if resp[1] != 0: raise ConnectionError(f'socks5 connect: {resp!r}')

async def _handle(cli_r, cli_w):
    srv_r = srv_w = None
    try:
        sock = cli_w.get_extra_info('socket')
        dst_ip, dst_port = _get_orig_dst(sock)
        srv_r, srv_w = await asyncio.wait_for(asyncio.open_connection(*_SOCKS5), timeout=10)
        await _socks5_handshake(srv_r, srv_w, dst_ip, dst_port)
        await asyncio.gather(_pipe(cli_r, srv_w), _pipe(srv_r, cli_w))
    except Exception as e:
        import logging; logging.debug('warp-tproxy-py: %s', e)
    finally:
        for w in (cli_w, srv_w):
            if w:
                try: w.close(); await w.wait_closed()
                except Exception: pass

async def _serve():
    loop = asyncio.get_running_loop()
    stop = loop.create_future()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig,
            lambda: stop.set_result(None) if not stop.done() else None)
    srv = await asyncio.start_server(_handle, *_LISTEN, reuse_address=True)
    print(f'warp-tproxy-py {_LISTEN[0]}:{_LISTEN[1]} -> socks5://{_SOCKS5[0]}:{_SOCKS5[1]}',
          flush=True)
    async with srv: await stop

if __name__ == '__main__':
    asyncio.run(_serve())
PYEOF
  chmod +x /usr/local/bin/warp-tproxy-py
}

install_tproxy_backend() {
  info "安装透明代理组件..."
  mkdir -p "${CACHE_DIR}"

  # 清理旧版本 redsocks（向后兼容 v1.4.x 之前）
  systemctl stop redsocks 2>/dev/null || true
  systemctl disable redsocks 2>/dev/null || true
  pkill -x redsocks 2>/dev/null || true
  rm -f /etc/redsocks.conf /etc/systemd/system/redsocks.service

  local backend="python"
  _try_install_ipt2socks && backend="ipt2socks"
  [[ "${backend}" == "python" ]] && {
    warn "使用 Python asyncio tproxy 作为透明代理后端"
    _write_python_tproxy
  }
  echo "${backend}" > "${TPROXY_BACKEND_FILE}"

  # Service 使用 EnvironmentFile= 读取端口，不写死
  local exec_start
  if [[ "${backend}" == "ipt2socks" ]]; then
    exec_start='/usr/local/bin/ipt2socks -4 -b 127.0.0.1 -l ${TPROXY_PORT} -s 127.0.0.1 -p ${WARP_PROXY_PORT} -j 2'
  else
    exec_start='/usr/local/bin/warp-tproxy-py'
  fi

  cat > /etc/systemd/system/warp-tproxy.service <<EOF_SVC
[Unit]
Description=WARP transparent proxy (${backend})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
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
# warp-google 管理脚本（运行时 source ENV_FILE）
# ---------------------------------------------------------------------------
write_warp_google() {
  info "创建 /usr/local/bin/warp-google..."
  mkdir -p "${CACHE_DIR}"

  cat > /usr/local/bin/warp-google <<'WARPGOOGLEEOF'
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/warp-google/env"
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}" || true

# 向后兼容旧版本
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
TPROXY_PORT="${TPROXY_PORT:-${REDSOCKS_PORT:-12345}}"
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
  command -v systemctl >/dev/null 2>&1 \
    && { systemctl restart warp-tproxy >/dev/null 2>&1 || systemctl start warp-tproxy >/dev/null 2>&1 || true; }
}

_tproxy_stop() {
  command -v systemctl >/dev/null 2>&1 && systemctl stop warp-tproxy >/dev/null 2>&1 || true
}

_ensure_ipset() {
  for mod in ip_set ip_set_hash_net xt_set; do modprobe "${mod}" 2>/dev/null || true; done
  ipset create "${IPSET_NAME}" hash:net family inet -exist
}

_load_ipv4_list() {
  [[ -s "${IPV4_CACHE_FILE}" ]] && cat "${IPV4_CACHE_FILE}" || echo "${STATIC_GOOGLE_IPV4_CIDRS}"
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
  exec 200>"${UPDATE_LOCK}"; flock -n 200 || { _info "已有更新任务，跳过"; return 0; }
  _info "更新 Google IP 段..."
  mkdir -p "${CACHE_DIR}"
  local tmp; tmp="$(mktemp)"; local ok=0
  curl -fsSL -x "socks5h://127.0.0.1:${WARP_PROXY_PORT}" --max-time 30 \
    "${GOOG_JSON_URL}" -o "${tmp}" 2>/dev/null && ok=1
  [[ ${ok} -eq 0 ]] && curl -fsSL --max-time 30 "${GOOG_JSON_URL}" -o "${tmp}" 2>/dev/null && ok=1
  if [[ ${ok} -eq 0 ]]; then _info "下载失败，使用现有列表"; rm -f "${tmp}"; return 1; fi
  python3 -c "
import json, sys
with open('${tmp}', encoding='utf-8') as f: data = json.load(f)
prefixes = sorted({p['ipv4Prefix'] for p in data.get('prefixes',[]) if 'ipv4Prefix' in p})
print('\n'.join(prefixes))
" > "${IPV4_CACHE_FILE}" 2>/dev/null \
  || grep -oE '"ipv4Prefix"\s*:\s*"[^"]+"' "${tmp}" \
       | sed -E 's/.*"([^"]+)".*/\1/' | sort -u > "${IPV4_CACHE_FILE}"
  rm -f "${tmp}"
  [[ -s "${IPV4_CACHE_FILE}" ]] \
    && _info "已更新：$(wc -l < "${IPV4_CACHE_FILE}") 条 IP 段" \
    || { _info "解析失败，使用静态列表"; return 1; }
}

do_start() {
  _info "启动 (WARP_PROXY_PORT=${WARP_PROXY_PORT} TPROXY_PORT=${TPROXY_PORT})..."
  _warp_connect; _tproxy_start; _ipset_apply; _iptables_apply
  _info "完成"
}

do_stop() {
  _info "停止..."; _tproxy_stop; _iptables_clean; _info "完成"
}

do_status() {
  echo "=== ipset ===" ; ipset list "${IPSET_NAME}" 2>/dev/null | head -n 15 || echo "不存在"
  echo; echo "=== NAT 规则 ===" ; iptables -t nat    -S "${NAT_CHAIN}"  2>/dev/null || echo "无"
  echo; echo "=== QUIC 阻断 ===" ; iptables -t filter -S "${QUIC_CHAIN}" 2>/dev/null || echo "无"
  echo; echo "=== 透明代理进程 ==="
  command -v systemctl >/dev/null 2>&1 \
    && { systemctl is-active --quiet warp-tproxy && echo "运行中 (systemd)" || echo "未运行"; } \
    || echo "未知"
  echo; echo "=== 后端 ===" ; cat /etc/warp-google/tproxy_backend 2>/dev/null || echo "未知"
  echo; echo "=== 端口配置 ===" ; cat "${ENV_FILE}" 2>/dev/null || echo "未初始化"
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

  # 注意：此处 heredoc 使用 'EOF_WARPCLI' 带引号，内部 $ 不展开（由运行时处理）
  # 但部分变量（REPO_URL, GAI_MARK 等在安装时确定的值）用 \$ 手动转义写死
  cat > /usr/local/bin/warp <<WARPCLIEOF
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/warp-google/env"
[[ -f "\${ENV_FILE}" ]] && source "\${ENV_FILE}" || true
WARP_PROXY_PORT="\${WARP_PROXY_PORT:-40000}"
TPROXY_PORT="\${TPROXY_PORT:-12345}"

REPO_RAW_URL="${REPO_RAW_URL}"
REPO_SHA256_URL="${REPO_SHA256_URL}"
GAI_MARK="${GAI_MARK}"
SCRIPT_VERSION="${SCRIPT_VERSION}"
DNS_MODE_FILE="${DNS_MODE_FILE}"
RESOLVED_DROPIN_FILE="${RESOLVED_DROPIN_FILE}"
CACHE_DIR="${CACHE_DIR}"
SHA256SUM_BIN="\$(command -v sha256sum 2>/dev/null || command -v shasum 2>/dev/null || true)"

_G='\033[1;32m' _Y='\033[1;33m' _C='\033[1;36m' _W='\033[1;37m' _N='\033[0m'

_verify_checksum() {
  local file="\$1" sum_file="\$2"
  [[ "\${WARP_SKIP_CHECKSUM:-0}" == "1" ]] && { echo "[warp] 跳过校验"; return 0; }
  [[ -n "\${SHA256SUM_BIN}" ]] || { echo "[warp] 未找到 sha256 工具" >&2; return 1; }
  local expected actual
  expected="\$(awk '{print \$1}' "\${sum_file}" | head -n1)"
  [[ -n "\${expected}" ]] || { echo "[warp] 校验文件无效" >&2; return 1; }
  if [[ "\${SHA256SUM_BIN}" == *shasum ]]; then
    actual="\$(shasum -a 256 "\${file}" | awk '{print \$1}')"
  else
    actual="\$(sha256sum "\${file}" | awk '{print \$1}')"
  fi
  [[ "\${actual}" == "\${expected}" ]] || {
    echo "[warp] SHA256 不匹配 (expected=\${expected} actual=\${actual})" >&2; return 1
  }
  echo "[warp] SHA256 校验通过"
}

case "\${1:-}" in
  status)
    # ── 关键状态：Google 连通性（最重要，放最上面）──
    _google_ok=0
    if curl -s --max-time 6 -o /dev/null -w "%{http_code}" https://www.google.com 2>/dev/null \
       | grep -q "200"; then
      _google_ok=1
    fi

    echo
    if [[ ${_google_ok} -eq 1 ]]; then
      echo -e "\${_G}╔══════════════════════════════════════════════════╗\${_N}"
      echo -e "\${_G}║  ✓  Google / Gemini  已连通                      ║\${_N}"
      echo -e "\${_G}╚══════════════════════════════════════════════════╝\${_N}"
    else
      echo -e "\033[1;31m╔══════════════════════════════════════════════════╗\033[0m"
      echo -e "\033[1;31m║  ✗  Google / Gemini  未连通                      ║\033[0m"
      echo -e "\033[1;31m╚══════════════════════════════════════════════════╝\033[0m"
      echo -e "    \${_Y}提示: 运行 'warp test' 查看逐层诊断\${_N}"
    fi
    echo

    # ── WARP 客户端状态 ──
    _warp_st="\$(warp-cli status 2>/dev/null || echo '未运行')"
    if echo "\${_warp_st}" | grep -qi 'Connected'; then
      echo -e "  WARP    \${_G}● 已连接\${_N}  端口 \${WARP_PROXY_PORT}"
    else
      echo -e "  WARP    \033[1;31m● 未连接\033[0m  (\${_warp_st##*:})"
    fi

    # ── 透明代理状态 ──
    if systemctl is-active --quiet warp-tproxy 2>/dev/null; then
      _backend="\$(cat /etc/warp-google/tproxy_backend 2>/dev/null || echo '?')"
      echo -e "  tproxy  \${_G}● 运行中\${_N}  backend=\${_backend}  :\${TPROXY_PORT}"
    else
      echo -e "  tproxy  \033[1;31m● 未运行\033[0m"
    fi

    # ── ipset 条目数 ──
    _cnt="\$(ipset list warp_google4 2>/dev/null | grep -c '/' || echo 0)"
    if [[ "\${_cnt}" -gt 0 ]]; then
      echo -e "  ipset   \${_G}● \${_cnt} 条 Google IP 段\${_N}"
    else
      echo -e "  ipset   \033[1;31m● 空\033[0m"
    fi

    # ── iptables 规则 ──
    if iptables -t nat -S WARP_GOOGLE 2>/dev/null | grep -q REDIRECT; then
      echo -e "  iptables \${_G}● REDIRECT 规则已加载\${_N}"
    else
      echo -e "  iptables \033[1;31m● 规则缺失\033[0m"
    fi
    echo
    echo -e "  \${_Y}详细诊断: warp test  |  原始日志: warp debug\${_N}"
    echo ;;
  start)
    warp-cli connect 2>/dev/null || true
    /usr/local/bin/warp-google start ;;
  stop)
    /usr/local/bin/warp-google stop || true
    warp-cli disconnect 2>/dev/null || true ;;
  restart) /usr/local/bin/warp-google restart ;;
  test)
    ok=1
    echo "--- [1] WARP 客户端状态 ---"
    warp_status="\$(warp-cli status 2>/dev/null || echo '无法获取')"
    echo "\${warp_status}"
    if echo "\${warp_status}" | grep -qi 'Connected'; then echo "  \${_G}✓ WARP 已连接\${_N}"
    else echo "  ✗ WARP 未连接 — 尝试: warp-cli connect"; ok=0; fi
    echo

    echo "--- [2] SOCKS5 端口监听 (:\${WARP_PROXY_PORT}) ---"
    if ss -tlnp 2>/dev/null | grep -q ":\${WARP_PROXY_PORT}"; then echo "  \${_G}✓ 端口监听中\${_N}"
    else echo "  ✗ 未监听"; ok=0; fi
    echo

    echo "--- [3] SOCKS5 直连测试 (绕过透明代理) ---"
    socks_code="\$(curl -s --max-time 10 -x "socks5h://127.0.0.1:\${WARP_PROXY_PORT}" \
-o /dev/null -w '%{http_code}' https://www.google.com 2>/dev/null || echo '000')"
    echo "  HTTP: \${socks_code}"
    if [[ "\${socks_code}" == "200" ]]; then echo "  \${_G}✓ SOCKS5 → Google 正常\${_N}"
    else echo "  ✗ SOCKS5 不通"; ok=0; fi
    echo

    echo "--- [4] warp-tproxy 进程 ---"
    if systemctl is-active --quiet warp-tproxy 2>/dev/null; then
      echo "  \${_G}✓ 运行中 (backend: \$(cat /etc/warp-google/tproxy_backend 2>/dev/null || echo unknown))\${_N}"
    else echo "  ✗ 未运行 — systemctl restart warp-tproxy"; ok=0; fi
    echo

    echo "--- [5] iptables 规则 ---"
    if iptables -t nat -S WARP_GOOGLE 2>/dev/null | grep -q REDIRECT; then echo "  \${_G}✓ REDIRECT 规则存在\${_N}"
    else echo "  ✗ 规则缺失 — warp-google start"; ok=0; fi
    echo

    echo "--- [6] ipset 条目数 ---"
    cnt="\$(ipset list warp_google4 2>/dev/null | grep -c '/' || echo 0)"
    if [[ "\${cnt}" -gt 0 ]]; then echo "  \${_G}✓ \${cnt} 条 Google IP 段\${_N}"
    else echo "  ✗ ipset 为空 — warp update"; ok=0; fi
    echo

    echo "--- [7] 透明代理端到端测试 ---"
    e2e_code="\$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' https://www.google.com 2>/dev/null || echo '000')"
    gem_code="\$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' https://gemini.google.com 2>/dev/null || echo '000')"
    echo "  Google  HTTP \${e2e_code}"
    echo "  Gemini  HTTP \${gem_code}"
    if [[ "\${e2e_code}" == "200" ]]; then echo "  \${_G}✓ 透明代理正常\${_N}"
    else echo "  ✗ 透明代理不通"; ok=0; fi
    echo

    echo "--- [8] WARP 节点信息 ---"
    curl -s --max-time 10 -x "socks5h://127.0.0.1:\${WARP_PROXY_PORT}" \
      https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
      | grep -E "^(warp|loc|ip)=" || echo "  (SOCKS5 不通时此项为空)"
    echo

    if [[ \${ok} -eq 1 ]]; then
      echo -e "\${_G}╔══════════════════════════════════════════════╗\${_N}"
      echo -e "\${_G}║  ✓  Google Gemini 送中成功！全部检测通过     ║\${_N}"
      echo -e "\${_G}╚══════════════════════════════════════════════╝\${_N}"
    else
      echo -e "\033[0;31m[✗] 存在异常，请根据上方提示逐层排查\033[0m"
      echo -e "    详细日志: warp debug"
    fi ;;
  debug)
    echo "=== warp-cli status ===" ; warp-cli status 2>&1 || true
    echo; echo "=== warp-tproxy service ===" ; systemctl status warp-tproxy --no-pager -l 2>&1 | head -25 || true
    echo; echo "=== 端口监听 ===" ; ss -tlnp 2>/dev/null | grep -E ":\${WARP_PROXY_PORT}|:\${TPROXY_PORT}" || echo "无相关端口"
    echo; echo "=== iptables nat OUTPUT ===" ; iptables -t nat -L OUTPUT -v --line-numbers 2>/dev/null | head -10 || true
    echo; echo "=== ipset ===" ; ipset list warp_google4 2>/dev/null | head -6 || echo "不存在"
    echo; echo "=== ENV 文件 ===" ; cat "\${ENV_FILE}" 2>/dev/null || echo "无"
    echo; echo "=== 最近日志 ===" ; journalctl -u warp-tproxy -n 20 --no-pager 2>/dev/null || true ;;
  ip)
    echo "直连 IP:"; curl -4 -s --max-time 8 ip.sb || echo "获取失败"
    echo; echo "WARP IP:"; curl -s --max-time 8 -x "socks5h://127.0.0.1:\${WARP_PROXY_PORT}" ip.sb || echo "获取失败"
    echo ;;
  update)
    /usr/local/bin/warp-google update
    /usr/local/bin/warp-google restart ;;
  upgrade)
    echo "[warp] 升级中..."
    local_tmp="\$(mktemp)"; sum_tmp="\$(mktemp)"
    trap "rm -f '\${local_tmp}' '\${sum_tmp}'" EXIT
    curl -fsSL "\${REPO_RAW_URL}"    -o "\${local_tmp}" || { echo "[warp] 下载失败" >&2; exit 1; }
    curl -fsSL "\${REPO_SHA256_URL}" -o "\${sum_tmp}"   || { echo "[warp] 校验文件下载失败" >&2; exit 1; }
    _verify_checksum "\${local_tmp}" "\${sum_tmp}" || exit 1
    bash -n "\${local_tmp}" || { echo "[warp] 语法检查失败" >&2; exit 1; }
    chmod +x "\${local_tmp}"; bash "\${local_tmp}" --install
    echo "[warp] 升级完成" ;;
  uninstall)
    # 强制从终端读取，避免 stdin 是管道时静默跳过
    read -r -p "确定要卸载 WARP？[y/N]: " confirm </dev/tty
    [[ "\${confirm}" =~ ^[Yy]\$ ]] || { echo "已取消"; exit 0; }
    echo "正在卸载..."
    /usr/local/bin/warp-google stop 2>/dev/null || true
    warp-cli disconnect 2>/dev/null || true
    for svc in warp-keepalive.timer warp-keepalive.service warp-google.service \
                warp-tproxy.service warp-svc.service redsocks.service; do
      systemctl disable --now "\${svc}" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/warp-keepalive.timer   \
          /etc/systemd/system/warp-keepalive.service  \
          /etc/systemd/system/warp-google.service     \
          /etc/systemd/system/warp-tproxy.service     \
          /etc/systemd/system/redsocks.service
    systemctl daemon-reload 2>/dev/null || true
    rm -f /usr/local/bin/warp-google /usr/local/bin/warp-keepalive \
          /usr/local/bin/ipt2socks   /usr/local/bin/warp-tproxy-py \
          /etc/redsocks.conf
    rm -rf /etc/warp-google
    iptables -t nat    -D OUTPUT -j WARP_GOOGLE      2>/dev/null || true
    iptables -t nat    -F WARP_GOOGLE                 2>/dev/null || true
    iptables -t nat    -X WARP_GOOGLE                 2>/dev/null || true
    iptables -t filter -D OUTPUT -j WARP_GOOGLE_QUIC 2>/dev/null || true
    iptables -t filter -F WARP_GOOGLE_QUIC            2>/dev/null || true
    iptables -t filter -X WARP_GOOGLE_QUIC            2>/dev/null || true
    ipset destroy warp_google4 2>/dev/null || true
    sed -i "/\${GAI_MARK}/,+1d" /etc/gai.conf 2>/dev/null || true
    if [[ -f "\${DNS_MODE_FILE}" ]]; then
      _dns_mode="\$(cat "\${DNS_MODE_FILE}" 2>/dev/null || echo skip)"
      case "\${_dns_mode}" in
        resolved) rm -f "\${RESOLVED_DROPIN_FILE}"; systemctl restart systemd-resolved 2>/dev/null || true ;;
        file)
          chattr -i /etc/resolv.conf 2>/dev/null || true
          [[ -f /etc/resolv.conf.warp-backup ]] && mv /etc/resolv.conf.warp-backup /etc/resolv.conf 2>/dev/null || true
          _was_imm="\$(cat "\${CACHE_DIR}/resolv_was_immutable" 2>/dev/null || echo 0)"
          [[ "\${_was_imm}" == "1" ]] && { chattr +i /etc/resolv.conf 2>/dev/null || true; echo "已恢复 resolv.conf 锁定"; }
          rm -f "\${CACHE_DIR}/resolv_was_immutable" ;;
        skip) ;;
      esac
      rm -f "\${DNS_MODE_FILE}"
    fi
    if [[ -f /etc/os-release ]]; then
      source /etc/os-release
      case "\${ID:-}" in
        ubuntu|debian)
          apt-get remove -y cloudflare-warp 2>/dev/null || true
          rm -f /etc/apt/sources.list.d/cloudflare-client.list
          rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
          apt-get update -y >/dev/null 2>&1 || true ;;
        centos|rhel|rocky|almalinux|fedora)
          if command -v dnf >/dev/null 2>&1; then dnf remove -y cloudflare-warp 2>/dev/null || true
          else yum remove -y cloudflare-warp 2>/dev/null || true; fi
          rm -f /etc/yum.repos.d/cloudflare-warp.repo ;;
      esac
    fi
    rm -f /usr/local/bin/warp
    echo "卸载完成" ;;
  *)
    echo -e "\${_W}WARP 管理工具 v\${SCRIPT_VERSION}\${_N}  \${_C}(Google Gemini 送中)\${_N}"
    echo
    echo "用法: warp <命令>"
    echo
    echo "  \${_G}status\${_N}    查看状态"
    echo "  \${_G}start\${_N}     启动"
    echo "  \${_G}stop\${_N}      停止"
    echo "  \${_G}restart\${_N}   重启"
    echo "  \${_G}test\${_N}      逐层诊断（8层，含端到端）"
    echo "  \${_G}debug\${_N}     原始诊断信息（日志/端口/规则）"
    echo "  \${_G}ip\${_N}        查看直连 IP 与 WARP IP"
    echo "  \${_G}update\${_N}    更新 Google IP 段"
    echo "  \${_G}upgrade\${_N}   升级脚本（含 SHA256 校验）"
    echo "  \${_G}uninstall\${_N} 完整卸载" ;;
esac
WARPCLIEOF

  chmod +x /usr/local/bin/warp
  success "warp 管理命令已创建"
}

# ---------------------------------------------------------------------------
# Keepalive（source ENV_FILE，不写死端口）
# ---------------------------------------------------------------------------
write_keepalive() {
  info "创建 keepalive (每 10 分钟)..."

  cat > /usr/local/bin/warp-keepalive <<KEEPEOF
#!/usr/bin/env bash
set -euo pipefail
ENV_FILE="/etc/warp-google/env"
[[ -f "\${ENV_FILE}" ]] && source "\${ENV_FILE}" || true
WARP_PROXY_PORT="\${WARP_PROXY_PORT:-40000}"
LOCK_FILE="${WARP_KEEPALIVE_LOCK}"
LOG_TAG="warp-keepalive"

exec 9>"\${LOCK_FILE}"; flock -n 9 || exit 0

if ! curl -s --max-time 10 -x "socks5h://127.0.0.1:\${WARP_PROXY_PORT}" \
   -o /dev/null https://www.google.com; then
  logger -t "\${LOG_TAG}" "WARP proxy unreachable, reconnecting..."
  warp-cli disconnect 2>/dev/null || true; sleep 2
  warp-cli connect   2>/dev/null || true; sleep 3
fi

if ! curl -s --max-time 10 -o /dev/null https://www.google.com; then
  logger -t "\${LOG_TAG}" "transparent proxy down, restarting warp-tproxy..."
  systemctl restart warp-tproxy >/dev/null 2>&1 \
    && logger -t "\${LOG_TAG}" "restarted ok" \
    || logger -t "\${LOG_TAG}" "restart failed"
fi
KEEPEOF
  chmod +x /usr/local/bin/warp-keepalive

  cat > /etc/systemd/system/warp-keepalive.service <<'SVC'
[Unit]
Description=WARP keepalive check
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-keepalive
SVC

  cat > /etc/systemd/system/warp-keepalive.timer <<'TIMER'
[Unit]
Description=Run WARP keepalive every 10 minutes
[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
Persistent=true
[Install]
WantedBy=timers.target
TIMER

  systemctl daemon-reload
  systemctl enable --now warp-keepalive.timer >/dev/null 2>&1 || true
  success "keepalive 已配置"
}

write_systemd_service() {
  cat > /etc/systemd/system/warp-google.service <<'EOF_SVC'
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
EOF_SVC
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
  install_tproxy_backend   # 在 configure_warp 之前，service 需要先创建
  write_warp_google
  write_warp_cli
  write_keepalive
  write_systemd_service
  configure_warp           # 决定最终端口并写入 ENV_FILE
  # 用最终端口重启 tproxy（ENV_FILE 已更新）
  systemctl restart warp-tproxy >/dev/null 2>&1 || true

  /usr/local/bin/warp-google update || warn "Google IP 更新失败，使用静态列表"
  /usr/local/bin/warp-google start  || true

  echo
  success "安装完成"
  echo -e "\n管理命令: ${GREEN}warp {status|start|stop|restart|test|debug|ip|update|upgrade|uninstall}${NC}\n"

  info "安装后逐层诊断..."
  sleep 2
  warp test
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
    2)
      if [[ -x /usr/local/bin/warp ]]; then
        /usr/local/bin/warp uninstall
      else
        warn "WARP 未安装，无需卸载"
      fi ;;
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
