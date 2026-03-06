#!/usr/bin/env bash
set -euo pipefail

# ===== 可改参数 =====
# 端口：默认自动随机 5 位（10000-65535），且避开已占用端口
# 也可手动传 SS_PORT 覆盖（若被占用会报错退出）
SS_PORT="${SS_PORT:-}"
SS_METHOD="${SS_METHOD:-aes-128-gcm}"
# ===================

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行"
  exit 1
fi

port_in_use() {
  local p="$1"
  ss -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)$p$"
}

pick_free_port() {
  local p tries=0
  while (( tries < 200 )); do
    p=$((10000 + RANDOM % 55536))
    if ! port_in_use "$p"; then
      echo "$p"
      return 0
    fi
    tries=$((tries + 1))
  done
  return 1
}

if [[ -n "$SS_PORT" ]]; then
  if port_in_use "$SS_PORT"; then
    echo "端口已被占用: $SS_PORT，请换一个端口"
    exit 1
  fi
else
  SS_PORT="$(pick_free_port)" || { echo "未找到可用 5 位端口"; exit 1; }
fi

gen_password() {
  # avoid pipefail SIGPIPE issue from tr|head
  openssl rand -base64 36 | tr -d '\n' | cut -c1-32
}

SS_PASSWORD="$(gen_password)"

echo "[1/7] 安装依赖..."
apt update -y
apt install -y curl wget tar jq ca-certificates ufw

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) SS_ARCH="x86_64-unknown-linux-gnu" ;;
  aarch64|arm64) SS_ARCH="aarch64-unknown-linux-gnu" ;;
  *)
    echo "不支持架构: $ARCH"
    exit 1
    ;;
esac

echo "[2/7] 下载 shadowsocks-rust..."
TAG="$(curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | jq -r .tag_name)"
PKG="shadowsocks-v${TAG#v}.${SS_ARCH}.tar.xz"
URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${TAG}/${PKG}"

mkdir -p /opt/ss-rust
cd /opt/ss-rust
wget -qO ss.tar.xz "$URL"
tar -xf ss.tar.xz
install -m 755 ssserver /usr/local/bin/ssserver

echo "[3/7] 写入 ss 配置..."
mkdir -p /etc/shadowsocks-rust
cat > /etc/shadowsocks-rust/config.json <<EOF
{
  "server": "0.0.0.0",
  "server_port": ${SS_PORT},
  "password": "${SS_PASSWORD}",
  "method": "${SS_METHOD}",
  "mode": "tcp_and_udp"
}
EOF
chmod 600 /etc/shadowsocks-rust/config.json

echo "[4/7] 创建 systemd 服务..."
cat > /etc/systemd/system/shadowsocks-rust.service <<'EOF'
[Unit]
Description=Shadowsocks Rust Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks-rust/config.json
Restart=always
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now shadowsocks-rust

echo "[5/7] 写入 sysctl（含 BBR）..."
cat > /etc/sysctl.conf <<'EOF'
fs.file-max = 6815744
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_abort_on_overflow = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_timestamps = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv4.conf.all.route_localnet = 1
EOF

sysctl -p

echo "[6/7] 放行防火墙..."
ufw allow "${SS_PORT}/tcp" || true
ufw allow "${SS_PORT}/udp" || true

echo "[7/7] 输出连接信息..."
SERVER_IP="$(curl -s ifconfig.me || hostname -I | awk '{print $1}')"

cat > /root/ss-rust-info.txt <<EOF
server=${SERVER_IP}
port=${SS_PORT}
method=${SS_METHOD}
password=${SS_PASSWORD}
EOF
chmod 600 /root/ss-rust-info.txt

echo
echo "✅ 完成"
echo "server:   ${SERVER_IP}"
echo "port:     ${SS_PORT}"
echo "method:   ${SS_METHOD}"
echo "password: ${SS_PASSWORD}"
echo "info:     /root/ss-rust-info.txt"
echo
echo "BBR 检查：sysctl net.ipv4.tcp_congestion_control"
echo "服务检查：systemctl status shadowsocks-rust --no-pager"