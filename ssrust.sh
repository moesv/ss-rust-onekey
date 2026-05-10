#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  ssrust+ — Shadowsocks-Rust + Shadow-TLS 一键管理脚本
#  Supports: Debian / Ubuntu / CentOS / RHEL / Rocky / Alma
# ============================================================

SCRIPT_VERSION="v2.0.0"
SCRIPT_URL="https://raw.githubusercontent.com/moesv/ssrust/main/ssrust.sh"

# ---------- 默认参数（可用环境变量覆盖） ----------
SS_PORT="${SS_PORT:-}"
SS_METHOD="${SS_METHOD:-aes-128-gcm}"
SS_NODE_NAME="${SS_NODE_NAME:-ssrust}"

# ---------- 路径 ----------
SS_DIR="/etc/shadowsocks-rust"
SS_CONF="$SS_DIR/config.json"
SS_VER_FILE="$SS_DIR/ver.txt"
SS_BIN="/usr/local/bin/ssserver"
SS_SVC="/etc/systemd/system/shadowsocks-rust.service"
SS_INFO="/root/ss-rust-info.txt"

STLS_DIR="/etc/shadow-tls"
STLS_ENV="$STLS_DIR/env"
STLS_VER_FILE="$STLS_DIR/ver.txt"
STLS_BIN="/usr/local/bin/shadow-tls"
STLS_SVC="/etc/systemd/system/shadow-tls.service"

SYSCTL_DROPIN="/etc/sysctl.d/99-ss-rust.conf"
WORK_DIR="/opt/ss-rust"

SS_REPO="shadowsocks/shadowsocks-rust"
STLS_REPO="ihciah/shadow-tls"
SS_BACKUP_VER="v1.14.1"
SS_BACKUP_BASE="https://raw.githubusercontent.com/xOS/Others/master/shadowsocks-rust"

# ---------- 输出 helper ----------
if [[ -t 1 ]]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'; C_D=$'\033[2m'; C_N=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_N=""
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$C_B" "$C_N" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_N" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_R" "$C_N" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- 前置 ----------
require_root() {
  [[ $EUID -eq 0 ]] || die "请用 root 运行"
}

OS=""
detect_os() {
  [[ -r /etc/os-release ]] || die "无法识别系统（缺少 /etc/os-release）"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) OS=debian ;;
    *centos*|*rhel*|*rocky*|*almalinux*|*fedora*) OS=rhel ;;
    *) die "仅支持 Debian/Ubuntu 或 CentOS/RHEL（当前: ${PRETTY_NAME:-未知}）" ;;
  esac
}

pkg_install() {
  case "$OS" in
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null
      apt-get install -y --no-install-recommends "$@"
      ;;
    rhel)
      if command -v dnf >/dev/null 2>&1; then dnf install -y "$@"
      else yum install -y "$@"
      fi
      ;;
  esac
}

install_deps() {
  info "安装依赖"
  if [[ "$OS" == debian ]]; then
    pkg_install curl wget tar xz-utils jq ca-certificates openssl iproute2 qrencode coreutils
  else
    pkg_install curl wget tar xz jq ca-certificates openssl iproute qrencode coreutils
  fi
}

# ---------- 架构映射 ----------
map_arch_ss() {
  case "$(uname -m)" in
    x86_64)        printf 'x86_64-unknown-linux-gnu' ;;
    aarch64|arm64) printf 'aarch64-unknown-linux-gnu' ;;
    armv7l|armv7)  printf 'armv7-unknown-linux-gnueabihf' ;;
    i686|i386)     printf 'i686-unknown-linux-musl' ;;
    *) die "ss-rust 不支持的架构: $(uname -m)" ;;
  esac
}

map_arch_stls() {
  case "$(uname -m)" in
    x86_64)        printf 'x86_64-unknown-linux-musl' ;;
    aarch64|arm64) printf 'aarch64-unknown-linux-musl' ;;
    armv7l|armv7)  printf 'armv7-unknown-linux-musleabihf' ;;
    *) die "shadow-tls 不支持的架构: $(uname -m)" ;;
  esac
}

# ---------- 网络 ----------
http_dl() {
  local url="$1" dst="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-delay 2 --max-time 60 -o "$dst" "$url"
  else
    wget -q --tries=3 --timeout=60 -O "$dst" "$url"
  fi
}

# 通过 GitHub 重定向取最新 tag（避开 API 限流）
latest_release_tag() {
  local repo="$1" loc
  loc="$(curl -sIL --max-time 15 "https://github.com/$repo/releases/latest" \
        | awk 'BEGIN{IGNORECASE=1} /^location:/ {print $2}' | tr -d '\r' | tail -1)"
  [[ -n "$loc" ]] || return 1
  printf '%s' "${loc##*/tag/}"
}

verify_sha256() {
  local file="$1" expected="$2" actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ -n "$expected" && "$actual" == "$expected" ]]
}

# ---------- 通用 helper ----------
backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -a "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)"
}

port_in_use() {
  local p="$1"
  ss -Hlntu "sport = :$p" 2>/dev/null | grep -q .
}

pick_free_port() {
  local p tries=0
  while (( tries < 200 )); do
    p=$((30000 + RANDOM % 35536))
    port_in_use "$p" || { printf '%s' "$p"; return 0; }
    tries=$((tries + 1))
  done
  return 1
}

validate_port() {
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 ))
}

validate_ss_port() {
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]{5}$ ]] && (( p >= 30000 && p <= 65535 ))
}

resolve_ss_port() {
  if [[ -n "$SS_PORT" ]]; then
    validate_ss_port "$SS_PORT" || { err "端口非法: $SS_PORT（必须 30000-65535）"; return 1; }
    port_in_use "$SS_PORT" && { err "端口已被占用: $SS_PORT"; return 1; }
  else
    SS_PORT="$(pick_free_port)" || { err "未找到可用端口"; return 1; }
  fi
}

# ---------- 密码 / 加密 ----------
cipher_keylen_2022() {
  case "$1" in
    2022-blake3-aes-128-gcm)        echo 16 ;;
    2022-blake3-aes-256-gcm)        echo 32 ;;
    2022-blake3-chacha20-poly1305)  echo 32 ;;
    *) echo 0 ;;
  esac
}

is_2022_cipher() {
  [[ "$1" == 2022-blake3-* ]]
}

validate_cipher() {
  case "$1" in
    aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305) return 0 ;;
    2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) return 0 ;;
    *) return 1 ;;
  esac
}

gen_password_classic() {
  # 32 位十六进制，避免 shell/JSON/URL 特殊字符
  openssl rand -hex 16
}

gen_password() {
  local m="${1:-$SS_METHOD}" n
  if is_2022_cipher "$m"; then
    n="$(cipher_keylen_2022 "$m")"
    [[ "$n" -gt 0 ]] || die "未知 2022 加密方式: $m"
    openssl rand -base64 "$n" | tr -d '\n'
  else
    gen_password_classic
  fi
}

# ---------- IP ----------
get_server_ip() {
  local ip
  ip="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -6 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "$ip"
}

# ---------- URL / ss:// ----------
url_safe_b64() { base64 -w0 | tr '+/' '-_' | tr -d '='; }

build_ss_url() {
  local method="$1" password="$2" server="$3" port="$4" name="$5"
  local b64
  b64="$(printf '%s' "${method}:${password}@${server}:${port}" | url_safe_b64)"
  printf 'ss://%s#%s' "$b64" "$name"
}

# ---------- 写入信息文件 ----------
write_info() {
  local server="$1" method="$2" password="$3" port="$4"
  local ss_url surge_line
  ss_url="$(build_ss_url "$method" "$password" "$server" "$port" "$SS_NODE_NAME")"
  surge_line="${SS_NODE_NAME} = ss, ${server}, ${port}, encrypt-method=${method}, password=\"${password}\", udp-relay=true"

  umask 077
  cat > "$SS_INFO" <<EOF
server=${server}
port=${port}
method=${method}
password=${password}
ss_url=${ss_url}
surge=${surge_line}
EOF
  chmod 600 "$SS_INFO"

  echo
  ok "完成"
  printf '  server:   %s\n  port:     %s\n  method:   %s\n  password: %s\n  ss_url:   %s\n  surge:    %s\n  info:     %s\n\n' \
    "$server" "$port" "$method" "$password" "$ss_url" "$surge_line" "$SS_INFO"
}

show_qr() {
  if ! command -v qrencode >/dev/null 2>&1; then
    warn "未安装 qrencode，跳过二维码"
    return 0
  fi
  [[ -f "$SS_INFO" ]] || { warn "未找到配置"; return 0; }
  local url
  url="$(grep '^ss_url=' "$SS_INFO" | cut -d= -f2-)"
  [[ -n "$url" ]] || return 0
  say "二维码（ss://）："
  qrencode -t ANSIUTF8 -m 2 "$url"
}

# ---------- ss-rust 下载/安装 ----------
SS_DOWNLOADED_TAG=""

download_ssserver() {
  # download_ssserver tag → 写入 $WORK_DIR/ssserver；成功后 SS_DOWNLOADED_TAG=tag
  local tag="$1" arch pkg url sha_url tmp
  arch="$(map_arch_ss)"
  pkg="shadowsocks-${tag}.${arch}.tar.xz"
  url="https://github.com/$SS_REPO/releases/download/${tag}/${pkg}"
  sha_url="${url}.sha256"

  tmp="$(mktemp -d)"
  info "下载 ${pkg}"
  if ! http_dl "$url" "$tmp/ss.tar.xz"; then
    rm -rf "$tmp"
    return 1
  fi

  if http_dl "$sha_url" "$tmp/ss.sha256" 2>/dev/null; then
    local expected
    expected="$(awk '{print $1}' "$tmp/ss.sha256")"
    if ! verify_sha256 "$tmp/ss.tar.xz" "$expected"; then
      err "ss-rust sha256 校验失败 (expected=$expected)"
      rm -rf "$tmp"
      return 1
    fi
    ok "sha256 校验通过"
  else
    warn "未找到 sha256 校验文件，跳过校验"
  fi

  tar -xf "$tmp/ss.tar.xz" -C "$tmp"
  [[ -f "$tmp/ssserver" ]] || { err "解压后未找到 ssserver"; rm -rf "$tmp"; return 1; }
  mkdir -p "$WORK_DIR"
  install -m 755 "$tmp/ssserver" "$WORK_DIR/ssserver"
  rm -rf "$tmp"
  SS_DOWNLOADED_TAG="$tag"
}

download_ssserver_backup() {
  warn "回退到备份源 ${SS_BACKUP_VER}（无 sha256 校验）"
  local arch pkg url tmp
  arch="$(map_arch_ss)"
  pkg="shadowsocks-${SS_BACKUP_VER}.${arch}.tar.xz"
  url="${SS_BACKUP_BASE}/${SS_BACKUP_VER}/${pkg}"
  tmp="$(mktemp -d)"
  if ! http_dl "$url" "$tmp/ss.tar.xz"; then
    rm -rf "$tmp"
    return 1
  fi
  tar -xf "$tmp/ss.tar.xz" -C "$tmp"
  [[ -f "$tmp/ssserver" ]] || { err "备份源未找到 ssserver"; rm -rf "$tmp"; return 1; }
  mkdir -p "$WORK_DIR"
  install -m 755 "$tmp/ssserver" "$WORK_DIR/ssserver"
  rm -rf "$tmp"
  SS_DOWNLOADED_TAG="$SS_BACKUP_VER"
}

install_ssserver() {
  info "获取 ss-rust 最新版本"
  local tag=""
  if tag="$(latest_release_tag "$SS_REPO" 2>/dev/null)" && [[ -n "$tag" ]]; then
    if ! download_ssserver "$tag"; then
      warn "主源下载失败，尝试备份源"
      download_ssserver_backup || die "ss-rust 安装失败"
    fi
  else
    warn "无法解析 GitHub 最新版本"
    download_ssserver_backup || die "ss-rust 安装失败"
  fi
  install -m 755 "$WORK_DIR/ssserver" "$SS_BIN"
  "$SS_BIN" -V >/dev/null 2>&1 || die "ssserver 自检失败"
  mkdir -p "$SS_DIR"
  echo "$SS_DOWNLOADED_TAG" > "$SS_VER_FILE"
  ok "ss-rust 版本: $SS_DOWNLOADED_TAG"
}

write_ss_config() {
  local port="$1" method="$2" password="$3"
  info "写入 ss-rust 配置"
  mkdir -p "$SS_DIR"
  backup_file "$SS_CONF"
  umask 077
  cat > "$SS_CONF" <<EOF
{
  "server": "::",
  "server_port": ${port},
  "password": "${password}",
  "method": "${method}",
  "mode": "tcp_and_udp",
  "fast_open": true,
  "no_delay": true,
  "ipv6_first": false,
  "nameserver": "1.1.1.1,8.8.8.8"
}
EOF
  chmod 600 "$SS_CONF"
}

write_ss_service() {
  info "写入 systemd 单元"
  cat > "$SS_SVC" <<EOF
[Unit]
Description=Shadowsocks Rust Server
Documentation=https://github.com/shadowsocks/shadowsocks-rust
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SS_BIN} -c ${SS_CONF}
Restart=on-failure
RestartSec=3s
LimitNOFILE=51200
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=${SS_CONF}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now shadowsocks-rust
}

ss_health() {
  if ! systemctl is-active --quiet shadowsocks-rust; then
    err "ss-rust 启动失败，最近日志："
    journalctl -u shadowsocks-rust -n 30 --no-pager || true
    return 1
  fi
  ok "ss-rust 已运行"
}

require_ss_installed() {
  [[ -f "$SS_CONF" ]] || { err "ss-rust 未安装"; return 1; }
}

do_install_ss() {
  detect_os
  install_deps
  validate_cipher "$SS_METHOD" || die "不支持的加密方式: $SS_METHOD"
  resolve_ss_port || return 1
  local pw server
  pw="$(gen_password "$SS_METHOD")"
  install_ssserver
  write_ss_config "$SS_PORT" "$SS_METHOD" "$pw"
  write_ss_service
  open_firewall_ports "$SS_PORT"
  ss_health || return 1
  server="$(get_server_ip)"
  [[ -n "$server" ]] || warn "未能自动获取公网 IP"
  write_info "${server:-<server-ip>}" "$SS_METHOD" "$pw" "$SS_PORT"
  show_qr
}

update_ssserver() {
  require_ss_installed || return 1
  detect_os
  local current="" latest
  [[ -f "$SS_VER_FILE" ]] && current="$(cat "$SS_VER_FILE")"
  latest="$(latest_release_tag "$SS_REPO" 2>/dev/null)" || { err "无法解析最新版本"; return 1; }
  if [[ "$current" == "$latest" ]]; then
    ok "ss-rust 已是最新 ($latest)"
    return 0
  fi
  info "升级 ss-rust: ${current:-未知} → $latest"
  if ! download_ssserver "$latest"; then
    err "升级失败"
    return 1
  fi
  install -m 755 "$WORK_DIR/ssserver" "$SS_BIN"
  echo "$SS_DOWNLOADED_TAG" > "$SS_VER_FILE"
  systemctl restart shadowsocks-rust
  ss_health
}

# ---------- ss-rust 配置变更 ----------
change_ss_port() {
  require_ss_installed || return 1
  resolve_ss_port || return 1
  local old pw method server
  old="$(jq -r '.server_port' "$SS_CONF")"
  pw="$(jq -r '.password' "$SS_CONF")"
  method="$(jq -r '.method' "$SS_CONF")"
  backup_file "$SS_CONF"
  local tmp; tmp="$(mktemp)"
  jq --argjson p "$SS_PORT" '.server_port=$p' "$SS_CONF" > "$tmp"
  install -m 600 "$tmp" "$SS_CONF"; rm -f "$tmp"
  open_firewall_ports "$SS_PORT"
  close_firewall_ports "$old"
  systemctl restart shadowsocks-rust
  ss_health || return 1
  server="$(get_server_ip)"
  write_info "${server:-<server-ip>}" "$method" "$pw" "$SS_PORT"
  ok "端口: ${old} → ${SS_PORT}"
}

change_ss_password() {
  require_ss_installed || return 1
  local method port pw server
  method="$(jq -r '.method' "$SS_CONF")"
  port="$(jq -r '.server_port' "$SS_CONF")"
  pw="$(gen_password "$method")"
  backup_file "$SS_CONF"
  local tmp; tmp="$(mktemp)"
  jq --arg pw "$pw" '.password=$pw' "$SS_CONF" > "$tmp"
  install -m 600 "$tmp" "$SS_CONF"; rm -f "$tmp"
  systemctl restart shadowsocks-rust
  ss_health || return 1
  server="$(get_server_ip)"
  write_info "${server:-<server-ip>}" "$method" "$pw" "$port"
  ok "密码已重置"
}

change_ss_cipher() {
  require_ss_installed || return 1
  cat <<EOF
可选加密方式:
  1) aes-128-gcm                    (经典 AEAD)
  2) aes-256-gcm                    (经典 AEAD)
  3) chacha20-ietf-poly1305         (经典 AEAD)
  4) 2022-blake3-aes-128-gcm        (推荐)
  5) 2022-blake3-aes-256-gcm
  6) 2022-blake3-chacha20-poly1305
EOF
  read -rp "选择 [1-6]: " c
  local method
  case "${c:-}" in
    1) method=aes-128-gcm ;;
    2) method=aes-256-gcm ;;
    3) method=chacha20-ietf-poly1305 ;;
    4) method=2022-blake3-aes-128-gcm ;;
    5) method=2022-blake3-aes-256-gcm ;;
    6) method=2022-blake3-chacha20-poly1305 ;;
    *) warn "已取消"; return 0 ;;
  esac
  local port pw server
  port="$(jq -r '.server_port' "$SS_CONF")"
  pw="$(gen_password "$method")"
  backup_file "$SS_CONF"
  local tmp; tmp="$(mktemp)"
  jq --arg m "$method" --arg pw "$pw" '.method=$m | .password=$pw' "$SS_CONF" > "$tmp"
  install -m 600 "$tmp" "$SS_CONF"; rm -f "$tmp"
  systemctl restart shadowsocks-rust
  ss_health || return 1
  server="$(get_server_ip)"
  write_info "${server:-<server-ip>}" "$method" "$pw" "$port"
  ok "加密方式 → $method（密码已重置）"
}

# ---------- 防火墙（UFW / firewalld） ----------
open_firewall_ports() {
  local p="$1"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${p}/tcp" >/dev/null 2>&1 || true
    ufw allow "${p}/udp" >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${p}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

close_firewall_ports() {
  local p="$1"
  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true
    ufw delete allow "${p}/udp" >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="${p}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --remove-port="${p}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

# ---------- BBR + TFO ----------
ensure_bbr_tfo() {
  info "写入 BBR + TFO sysctl drop-in"
  cat > "$SYSCTL_DROPIN" <<'EOF'
# Managed by ssrust+
fs.file-max = 6815744
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 4096
net.ipv4.tcp_tw_reuse = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_timestamps = 1
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF
  sysctl --system >/dev/null
  ok "已写入 $SYSCTL_DROPIN"
}

show_bbr_status() {
  printf 'tcp_congestion_control: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo ?)"
  printf 'default_qdisc:          %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo ?)"
  printf 'tcp_fastopen:           %s\n' "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo ?)"
}

bbr_menu() {
  cat <<EOF

BBR + TFO 管理:
1) 查看状态
2) 启用（写入 /etc/sysctl.d/）
0) 返回
EOF
  read -rp "选择: " c
  case "${c:-}" in
    1) show_bbr_status ;;
    2) ensure_bbr_tfo; show_bbr_status ;;
    0|"") return ;;
    *) warn "无效" ;;
  esac
}

# ---------- Shadow-TLS ----------
STLS_DOWNLOADED_TAG=""

download_shadow_tls() {
  local tag="$1" arch bin url tmp
  arch="$(map_arch_stls)"
  bin="shadow-tls-${arch}"
  url="https://github.com/$STLS_REPO/releases/download/${tag}/${bin}"
  tmp="$(mktemp -d)"
  info "下载 ${bin}"
  if ! http_dl "$url" "$tmp/shadow-tls"; then
    rm -rf "$tmp"
    return 1
  fi
  warn "shadow-tls 未提供 sha256 校验文件，跳过校验"
  mkdir -p "$WORK_DIR"
  install -m 755 "$tmp/shadow-tls" "$WORK_DIR/shadow-tls"
  rm -rf "$tmp"
  STLS_DOWNLOADED_TAG="$tag"
}

read_stls_env_var() {
  [[ -f "$STLS_ENV" ]] || return 1
  grep "^$1=" "$STLS_ENV" | cut -d= -f2-
}

rewrite_stls_env() {
  umask 077
  cat > "$STLS_ENV" <<EOF
STLS_LISTEN_PORT=${STLS_LISTEN_PORT}
STLS_TLS_SNI=${STLS_TLS_SNI}
STLS_PASSWORD=${STLS_PASSWORD}
STLS_STRICT=${STLS_STRICT}
STLS_WILDCARD=${STLS_WILDCARD}
STLS_FASTOPEN=${STLS_FASTOPEN}
STLS_BACKEND=${STLS_BACKEND}
EOF
  chmod 600 "$STLS_ENV"
}

write_shadow_tls_service() {
  # shellcheck disable=SC1091
  . "$STLS_ENV"

  local global=("--v3")
  [[ "${STLS_FASTOPEN:-0}" == 1 ]] && global+=("--fastopen")

  local sub=("server")
  [[ "${STLS_STRICT:-0}" == 1 ]] && sub+=("--strict")
  [[ "${STLS_WILDCARD:-0}" == 1 ]] && sub+=("--wildcard-sni=authed")
  sub+=(
    "--listen" "[::]:${STLS_LISTEN_PORT}"
    "--server" "${STLS_BACKEND}"
    "--tls" "${STLS_TLS_SNI}"
    "--password" "${STLS_PASSWORD}"
  )

  cat > "$STLS_SVC" <<EOF
[Unit]
Description=Shadow-TLS Server
Documentation=https://github.com/ihciah/shadow-tls
After=network-online.target shadowsocks-rust.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${STLS_BIN} ${global[*]} ${sub[*]}
Restart=on-failure
RestartSec=3s
LimitNOFILE=51200
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now shadow-tls
}

stls_health() {
  if ! systemctl is-active --quiet shadow-tls; then
    err "shadow-tls 启动失败，最近日志："
    journalctl -u shadow-tls -n 30 --no-pager || true
    return 1
  fi
  ok "shadow-tls 已运行"
}

install_shadow_tls() {
  detect_os
  install_deps
  require_ss_installed || die "请先安装 ss-rust"

  info "获取 shadow-tls 最新版本"
  local tag
  tag="$(latest_release_tag "$STLS_REPO" 2>/dev/null)" || die "无法解析 shadow-tls 版本"
  [[ -n "$tag" ]] || die "shadow-tls 版本为空"
  download_shadow_tls "$tag" || die "shadow-tls 下载失败"
  install -m 755 "$WORK_DIR/shadow-tls" "$STLS_BIN"
  mkdir -p "$STLS_DIR"
  echo "$STLS_DOWNLOADED_TAG" > "$STLS_VER_FILE"

  local ss_port
  ss_port="$(jq -r '.server_port' "$SS_CONF")"
  if [[ ! -f "$STLS_ENV" ]]; then
    STLS_LISTEN_PORT=443
    STLS_TLS_SNI="gateway.icloud.com:443"
    STLS_PASSWORD="$(gen_password_classic)"
    STLS_STRICT=1
    STLS_WILDCARD=1
    STLS_FASTOPEN=1
    STLS_BACKEND="127.0.0.1:${ss_port}"
    rewrite_stls_env
  fi
  write_shadow_tls_service
  open_firewall_ports "$(read_stls_env_var STLS_LISTEN_PORT)"
  stls_health || true
  view_shadow_tls
}

update_shadow_tls() {
  [[ -f "$STLS_BIN" ]] || { err "shadow-tls 未安装"; return 1; }
  detect_os
  local cur="" latest
  [[ -f "$STLS_VER_FILE" ]] && cur="$(cat "$STLS_VER_FILE")"
  latest="$(latest_release_tag "$STLS_REPO" 2>/dev/null)" || { err "无法解析最新版本"; return 1; }
  if [[ "$cur" == "$latest" ]]; then
    ok "shadow-tls 已是最新 ($latest)"
    return 0
  fi
  info "升级 shadow-tls: ${cur:-未知} → $latest"
  download_shadow_tls "$latest" || { err "升级失败"; return 1; }
  install -m 755 "$WORK_DIR/shadow-tls" "$STLS_BIN"
  echo "$STLS_DOWNLOADED_TAG" > "$STLS_VER_FILE"
  systemctl restart shadow-tls
  stls_health
}

set_stls_param() {
  local key="$1" val="$2"
  [[ -f "$STLS_ENV" ]] || { err "shadow-tls 未安装"; return 1; }
  # shellcheck disable=SC1091
  . "$STLS_ENV"
  case "$key" in
    STLS_LISTEN_PORT) STLS_LISTEN_PORT="$val" ;;
    STLS_TLS_SNI)     STLS_TLS_SNI="$val" ;;
    STLS_PASSWORD)    STLS_PASSWORD="$val" ;;
    STLS_STRICT)      STLS_STRICT="$val" ;;
    STLS_WILDCARD)    STLS_WILDCARD="$val" ;;
    STLS_FASTOPEN)    STLS_FASTOPEN="$val" ;;
    STLS_BACKEND)     STLS_BACKEND="$val" ;;
    *) err "未知 key: $key"; return 1 ;;
  esac
  backup_file "$STLS_ENV"
  rewrite_stls_env
  write_shadow_tls_service
  systemctl restart shadow-tls
  stls_health || true
}

view_shadow_tls() {
  [[ -f "$STLS_ENV" ]] || { warn "shadow-tls 未安装"; return 1; }
  say "${C_D}Shadow-TLS 配置：${C_N}"
  cat "$STLS_ENV"
  local listen pw sni server backend ss_method ss_pw
  listen="$(read_stls_env_var STLS_LISTEN_PORT)"
  pw="$(read_stls_env_var STLS_PASSWORD)"
  sni="$(read_stls_env_var STLS_TLS_SNI)"
  backend="$(read_stls_env_var STLS_BACKEND)"
  if [[ -f "$SS_CONF" ]]; then
    ss_method="$(jq -r '.method' "$SS_CONF")"
    ss_pw="$(jq -r '.password' "$SS_CONF")"
    server="$(get_server_ip)"
    say ""
    say "${C_D}客户端示例（Surge）：${C_N}"
    printf '%s-stls = ss, %s, %s, encrypt-method=%s, password="%s", udp-relay=true, shadow-tls-password="%s", shadow-tls-sni=%s, shadow-tls-version=3\n' \
      "$SS_NODE_NAME" "${server:-<server-ip>}" "$listen" "$ss_method" "$ss_pw" "$pw" "${sni%%:*}"
    say ""
    say "${C_D}后端：${C_N} $backend"
  fi
}

uninstall_shadow_tls() {
  read -rp "确认卸载 shadow-tls？[y/N] " a
  [[ "${a:-N}" =~ ^[yY]$ ]] || { say "取消"; return 0; }
  systemctl disable --now shadow-tls 2>/dev/null || true
  rm -f "$STLS_SVC" "$STLS_BIN"
  systemctl daemon-reload
  if [[ -f "$STLS_ENV" ]]; then
    local p; p="$(read_stls_env_var STLS_LISTEN_PORT)"
    [[ -n "$p" ]] && close_firewall_ports "$p"
  fi
  rm -rf "$STLS_DIR"
  ok "shadow-tls 已卸载"
}

stls_menu() {
  while true; do
    cat <<EOF

============ Shadow-TLS 管理 ============
 1) 安装 / 重装
 2) 查看配置
 3) 修改监听端口
 4) 修改 SNI（伪装站点 host:port）
 5) 重置密码
 6) 切换 strict / wildcard / fastopen
 7) 修改后端 (host:port)
 8) 升级二进制
 9) 状态 / 日志
10) 卸载
 0) 返回
==========================================
EOF
    read -rp "选择 [0-10]: " c
    case "${c:-}" in
      1) install_shadow_tls || warn "未完成" ;;
      2) view_shadow_tls || true ;;
      3)
        read -rp "新监听端口 (1-65535): " p
        if validate_port "$p"; then
          local old; old="$(read_stls_env_var STLS_LISTEN_PORT || true)"
          set_stls_param STLS_LISTEN_PORT "$p"
          [[ -n "$old" && "$old" != "$p" ]] && close_firewall_ports "$old"
          open_firewall_ports "$p"
        else
          warn "端口非法"
        fi
        ;;
      4) read -rp "新 SNI (如 gateway.icloud.com:443): " s; set_stls_param STLS_TLS_SNI "$s" ;;
      5) set_stls_param STLS_PASSWORD "$(gen_password_classic)"
         ok "新 STLS 密码: $(read_stls_env_var STLS_PASSWORD)"
         ;;
      6)
        say "1) strict  2) wildcard  3) fastopen"
        read -rp "切换哪一项: " t
        local v
        case "${t:-}" in
          1) v="$(read_stls_env_var STLS_STRICT)"
             set_stls_param STLS_STRICT "$([[ "$v" == 1 ]] && echo 0 || echo 1)" ;;
          2) v="$(read_stls_env_var STLS_WILDCARD)"
             set_stls_param STLS_WILDCARD "$([[ "$v" == 1 ]] && echo 0 || echo 1)" ;;
          3) v="$(read_stls_env_var STLS_FASTOPEN)"
             set_stls_param STLS_FASTOPEN "$([[ "$v" == 1 ]] && echo 0 || echo 1)" ;;
          *) warn "无效" ;;
        esac
        ;;
      7) read -rp "新后端 host:port (默认 127.0.0.1:ss_port): " b; set_stls_param STLS_BACKEND "$b" ;;
      8) update_shadow_tls || true ;;
      9) systemctl status shadow-tls --no-pager || true
         say "---"
         journalctl -u shadow-tls -n 30 --no-pager || true
         ;;
      10) uninstall_shadow_tls ;;
      0) return ;;
      *) warn "无效" ;;
    esac
  done
}

# ---------- 查看 / 状态 ----------
show_config() {
  if [[ -f "$SS_INFO" ]]; then
    say "${C_D}ss-rust info:${C_N}"
    cat "$SS_INFO"
  elif [[ -f "$SS_CONF" ]]; then
    say "${C_D}ss-rust config:${C_N}"
    cat "$SS_CONF"
  else
    warn "ss-rust 未安装"
  fi
  if [[ -f "$STLS_ENV" ]]; then
    say "---"
    say "${C_D}shadow-tls env:${C_N}"
    cat "$STLS_ENV"
  fi
}

show_combined() {
  show_config
  [[ -f "$SS_INFO" ]] && { say "---"; show_qr; }
}

show_surge() {
  if [[ -f "$SS_INFO" ]]; then
    grep '^surge=' "$SS_INFO" | cut -d= -f2-
  else
    warn "未找到配置"
    return 1
  fi
}

service_menu() {
  while true; do
    cat <<EOF

============ 服务管理 ============
1) 状态 (ss + stls)
2) 重启 ss-rust
3) 停止 ss-rust
4) 重启 shadow-tls
5) 停止 shadow-tls
6) ss-rust 日志
7) shadow-tls 日志
0) 返回
==================================
EOF
    read -rp "选择: " c
    case "${c:-}" in
      1) systemctl status shadowsocks-rust --no-pager || true
         if [[ -f "$STLS_SVC" ]]; then say "---"; systemctl status shadow-tls --no-pager || true; fi
         ;;
      2) systemctl restart shadowsocks-rust && ss_health ;;
      3) systemctl stop shadowsocks-rust && ok "ss-rust 已停止" ;;
      4) [[ -f "$STLS_SVC" ]] && { systemctl restart shadow-tls && stls_health; } || warn "shadow-tls 未安装" ;;
      5) [[ -f "$STLS_SVC" ]] && { systemctl stop shadow-tls && ok "shadow-tls 已停止"; } || warn "shadow-tls 未安装" ;;
      6) journalctl -u shadowsocks-rust -n 100 --no-pager ;;
      7) journalctl -u shadow-tls -n 100 --no-pager ;;
      0) return ;;
      *) warn "无效" ;;
    esac
  done
}

# ---------- 自更新脚本 ----------
self_update() {
  info "拉取最新脚本: $SCRIPT_URL"
  local tmp; tmp="$(mktemp)"
  if ! http_dl "$SCRIPT_URL" "$tmp"; then
    err "下载失败"
    rm -f "$tmp"
    return 1
  fi
  if ! bash -n "$tmp"; then
    err "新脚本语法检查失败，已放弃"
    rm -f "$tmp"
    return 1
  fi
  local self
  self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  backup_file "$self"
  install -m 755 "$tmp" "$self"
  rm -f "$tmp"
  ok "脚本已更新，请重新运行：bash $self"
}

# ---------- 卸载 ----------
uninstall_all() {
  read -rp "将卸载 ss-rust 与 shadow-tls 及其配置，继续？[y/N] " a
  [[ "${a:-N}" =~ ^[yY]$ ]] || { say "已取消"; return 0; }

  if [[ -f "$STLS_SVC" ]] || systemctl list-unit-files 2>/dev/null | grep -q '^shadow-tls\.service'; then
    systemctl disable --now shadow-tls 2>/dev/null || true
    if [[ -f "$STLS_ENV" ]]; then
      local p; p="$(read_stls_env_var STLS_LISTEN_PORT || true)"
      [[ -n "$p" ]] && close_firewall_ports "$p"
    fi
    rm -f "$STLS_SVC" "$STLS_BIN"
    rm -rf "$STLS_DIR"
  fi

  if [[ -f "$SS_SVC" ]] || systemctl list-unit-files 2>/dev/null | grep -q '^shadowsocks-rust\.service'; then
    systemctl disable --now shadowsocks-rust 2>/dev/null || true
    if [[ -f "$SS_CONF" ]]; then
      local p; p="$(jq -r '.server_port // empty' "$SS_CONF" 2>/dev/null || true)"
      [[ -n "$p" ]] && close_firewall_ports "$p"
    fi
    rm -f "$SS_SVC" "$SS_BIN" "$SS_INFO"
    rm -rf "$SS_DIR" "$WORK_DIR"
  fi
  systemctl daemon-reload
  ok "卸载完成"
}

# ---------- 主菜单 ----------
main_menu() {
  while true; do
    local ss_v="未安装" stls_v="未安装"
    [[ -f "$SS_VER_FILE" ]] && ss_v="$(cat "$SS_VER_FILE")"
    [[ -f "$STLS_VER_FILE" ]] && stls_v="$(cat "$STLS_VER_FILE")"
    cat <<EOF

============== SSRust+ ${SCRIPT_VERSION} ==============
  ss-rust:    ${ss_v}
  shadow-tls: ${stls_v}
------------------------------------------------------
 1) 安装 / 重装 ss-rust
 2) 查看配置 / ss:// / 二维码
 3) 修改端口
 4) 重置密码
 5) 更改加密方式
 6) 服务管理（状态/重启/停止/日志）
 7) Shadow-TLS 管理
 8) BBR + TFO 管理
 9) 升级 ss-rust 二进制
10) Surge 节点行
11) 自更新脚本
12) 卸载（全部）
 0) 退出
======================================================
EOF
    read -rp "输入 [0-12]: " n
    case "${n:-}" in
      1) do_install_ss || warn "未完成" ;;
      2) show_combined ;;
      3) read -rp "新端口（30000-65535，回车随机）: " p; SS_PORT="$p"; change_ss_port || true ;;
      4) change_ss_password || true ;;
      5) change_ss_cipher || true ;;
      6) service_menu ;;
      7) stls_menu ;;
      8) bbr_menu ;;
      9) update_ssserver || true ;;
      10) show_surge || true ;;
      11) self_update || true ;;
      12) uninstall_all ;;
      0) say "已退出"; exit 0 ;;
      *) warn "无效" ;;
    esac
  done
}

# ---------- CLI ----------
usage() {
  cat <<EOF
SSRust+ ${SCRIPT_VERSION}

用法:
  bash ssrust.sh                          # 交互菜单
  bash ssrust.sh install                  # 安装 ss-rust
  bash ssrust.sh update                   # 升级 ss-rust 二进制
  bash ssrust.sh change-port              # 改端口（SS_PORT 指定或随机）
  bash ssrust.sh change-password          # 重置 ss 密码
  bash ssrust.sh change-cipher            # 切换加密方式（交互）
  bash ssrust.sh status|restart|stop|logs # 服务控制
  bash ssrust.sh show-config              # 查看配置
  bash ssrust.sh surge-line               # 输出 Surge 节点行
  bash ssrust.sh qr                       # 打印 ss:// 二维码
  bash ssrust.sh bbr                      # 启用 BBR + TFO
  bash ssrust.sh bbr-status               # 查看 BBR/TFO 状态
  bash ssrust.sh self-update              # 自更新脚本
  bash ssrust.sh uninstall                # 卸载（含 stls）
  bash ssrust.sh version                  # 显示版本

  bash ssrust.sh stls install             # 安装 Shadow-TLS
  bash ssrust.sh stls update              # 升级 Shadow-TLS
  bash ssrust.sh stls view                # 查看 STLS 配置
  bash ssrust.sh stls uninstall           # 卸载 Shadow-TLS

环境变量:
  SS_PORT       端口（30000-65535）
  SS_METHOD     加密方式（aes-128-gcm / 2022-blake3-aes-128-gcm 等）
  SS_NODE_NAME  ss:// 与 Surge 节点名（默认 ssrust）
EOF
}

ACTION="${1:-menu}"
shift || true
case "$ACTION" in
  version|-v|--version) say "ssrust+ ${SCRIPT_VERSION}"; exit 0 ;;
  -h|--help|help)       usage; exit 0 ;;
esac

require_root
case "$ACTION" in
  menu)            main_menu ;;
  install)         do_install_ss ;;
  update)          update_ssserver ;;
  change-port)     change_ss_port ;;
  change-password) change_ss_password ;;
  change-cipher)   change_ss_cipher ;;
  status)          systemctl status shadowsocks-rust --no-pager ;;
  restart)         systemctl restart shadowsocks-rust && ss_health ;;
  stop)            systemctl stop shadowsocks-rust && ok "已停止" ;;
  logs)            journalctl -u shadowsocks-rust -n 100 --no-pager ;;
  show-config)     show_config ;;
  surge-line)      show_surge ;;
  qr)              show_qr ;;
  bbr)             ensure_bbr_tfo; show_bbr_status ;;
  bbr-status)      show_bbr_status ;;
  self-update)     self_update ;;
  uninstall)       uninstall_all ;;
  stls)
    sub="${1:-view}"; shift || true
    case "$sub" in
      install)   install_shadow_tls ;;
      update)    update_shadow_tls ;;
      view)      view_shadow_tls ;;
      uninstall) uninstall_shadow_tls ;;
      *) err "stls 子命令: install|update|view|uninstall"; exit 1 ;;
    esac
    ;;
  *) err "未知参数: $ACTION"; usage; exit 1 ;;
esac
