#!/usr/bin/env bash
set -euo pipefail

# ===== 可改参数 =====
# 默认自动随机 5 位端口（10000-65535），也可手动传 SS_PORT
SS_PORT="${SS_PORT:-}"
SS_METHOD="${SS_METHOD:-aes-128-gcm}"
# 配置查看是否默认脱敏（1=脱敏，0=明文）
MASK_CONFIG_DEFAULT="${MASK_CONFIG_DEFAULT:-1}"
# ===================

SCRIPT_VERSION="v1.4.0"

CONFIG_PATH="/etc/shadowsocks-rust/config.json"
SERVICE_PATH="/etc/systemd/system/shadowsocks-rust.service"
INFO_PATH="/root/ss-rust-info.txt"

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

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]{5}$ ]] || return 1
  (( p >= 10000 && p <= 65535 )) || return 1
  return 0
}

resolve_port() {
  if [[ -n "$SS_PORT" ]]; then
    if ! validate_port "$SS_PORT"; then
      echo "端口格式错误：$SS_PORT（必须是 10000-65535 的 5 位端口）"
      exit 1
    fi
    if port_in_use "$SS_PORT"; then
      echo "端口已被占用: $SS_PORT，请换一个端口"
      exit 1
    fi
  else
    SS_PORT="$(pick_free_port)" || { echo "未找到可用 5 位端口"; exit 1; }
  fi
}

gen_password() {
  openssl rand -base64 36 | tr -d '\n' | cut -c1-32
}

get_server_ip() {
  local ip
  ip="$(curl -4 -s ifconfig.me || true)"
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I | awk '{print $1}' || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(curl -6 -s ifconfig.me || true)"
  fi
  echo "$ip"
}

write_info() {
  local server_ip="$1" method="$2" password="$3" port="$4"
  local ss_base64 ss_url
  ss_base64="$(printf '%s' "${method}:${password}@${server_ip}:${port}" | base64 -w0)"
  ss_url="ss://${ss_base64}"

  cat > "$INFO_PATH" <<EOF
server=${server_ip}
port=${port}
method=${method}
password=${password}
ss_url=${ss_url}
EOF
  chmod 600 "$INFO_PATH"

  echo
  echo "✅ 完成"
  echo "server:   ${server_ip}"
  echo "port:     ${port}"
  echo "method:   ${method}"
  echo "password: ${password}"
  echo "ss_url:   ${ss_url}"
  echo "info:     ${INFO_PATH}"
  echo
}

install_deps() {
  echo "[1/8] 安装依赖..."
  apt update -y
  apt install -y curl wget tar xz-utils jq ca-certificates ufw openssl
}

install_binary() {
  echo "[2/8] 下载 shadowsocks-rust..."
  local arch tag pkg url
  arch="$(uname -m)"
  case "$arch" in
    x86_64) arch="x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) arch="aarch64-unknown-linux-gnu" ;;
    *) echo "不支持架构: $arch"; exit 1 ;;
  esac

  tag="$(curl -fsSL --retry 3 --retry-delay 2 https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | jq -r .tag_name)"
  pkg="shadowsocks-v${tag#v}.${arch}.tar.xz"
  url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${tag}/${pkg}"

  mkdir -p /opt/ss-rust
  cd /opt/ss-rust
  wget -q --tries=3 -O ss.tar.xz "$url"
  tar -xf ss.tar.xz
  install -m 755 ssserver /usr/local/bin/ssserver
}

write_config() {
  local port="$1" method="$2" password="$3"
  echo "[3/8] 写入 ss 配置（备份旧配置）..."
  mkdir -p /etc/shadowsocks-rust
  if [[ -f "$CONFIG_PATH" ]]; then
    cp -a "$CONFIG_PATH" "${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  cat > "$CONFIG_PATH" <<EOF
{
  "server": "0.0.0.0",
  "server_port": ${port},
  "password": "${password}",
  "method": "${method}",
  "mode": "tcp_and_udp"
}
EOF
  chmod 600 "$CONFIG_PATH"
}

write_service() {
  echo "[4/8] 创建/更新 systemd 服务..."
  cat > "$SERVICE_PATH" <<'EOF'
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
}

ensure_bbr() {
  echo "[BBR] 检查并启用..."
  local current_cc
  current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  if [[ "$current_cc" == "bbr" ]]; then
    echo "检测到系统已启用 BBR，跳过重复写入 /etc/sysctl.conf"
  else
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
    echo "已写入并应用 BBR 参数"
  fi
}

show_bbr_status() {
  echo "当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  echo "当前队列调度: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
}

enable_bbr_only() {
  ensure_bbr
  show_bbr_status
}

open_firewall() {
  local port="$1"
  echo "[6/8] 放行防火墙..."
  ufw allow "${port}/tcp" || true
  ufw allow "${port}/udp" || true
}

health_check() {
  echo "[7/8] 服务健康检查..."
  if ! systemctl is-active --quiet shadowsocks-rust; then
    echo "服务启动失败，请查看日志：journalctl -u shadowsocks-rust -n 100 --no-pager"
    exit 1
  fi
}

do_install() {
  resolve_port
  local password server_ip
  password="$(gen_password)"

  install_deps
  install_binary
  write_config "$SS_PORT" "$SS_METHOD" "$password"
  write_service
  # BBR 改为交互菜单手动启用，不在安装流程自动执行
  open_firewall "$SS_PORT"
  health_check

  echo "[8/8] 输出连接信息..."
  server_ip="$(get_server_ip)"
  write_info "$server_ip" "$SS_METHOD" "$password" "$SS_PORT"

  echo "服务检查：systemctl status shadowsocks-rust --no-pager"
  echo "日志查看：journalctl -u shadowsocks-rust -f"
  echo "如需启用 BBR：进入菜单选 9"
}

change_port() {
  if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "未找到配置文件：$CONFIG_PATH，请先执行安装"
    exit 1
  fi

  resolve_port
  local old_port password method server_ip
  old_port="$(jq -r '.server_port' "$CONFIG_PATH")"
  password="$(jq -r '.password' "$CONFIG_PATH")"
  method="$(jq -r '.method' "$CONFIG_PATH")"

  cp -a "$CONFIG_PATH" "${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
  jq --argjson p "$SS_PORT" '.server_port=$p' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp"
  mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
  chmod 600 "$CONFIG_PATH"

  # 放行新端口（旧端口规则不强删，避免误删）
  open_firewall "$SS_PORT"

  systemctl restart shadowsocks-rust
  health_check

  server_ip="$(get_server_ip)"
  write_info "$server_ip" "$method" "$password" "$SS_PORT"
  echo "端口已变更：${old_port} -> ${SS_PORT}"
}

delete_config() {
  echo "将删除 Shadowsocks Rust 配置并停止服务，继续？[y/N]"
  read -r ans
  if [[ "${ans:-N}" != "y" && "${ans:-N}" != "Y" ]]; then
    echo "已取消"
    exit 0
  fi

  systemctl disable --now shadowsocks-rust 2>/dev/null || true
  rm -f "$SERVICE_PATH"
  systemctl daemon-reload

  [[ -f "$CONFIG_PATH" ]] && rm -f "$CONFIG_PATH"
  [[ -f "$INFO_PATH" ]] && rm -f "$INFO_PATH"

  echo "✅ 已删除配置并停止服务"
}

change_password() {
  if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "未找到配置文件：$CONFIG_PATH，请先执行安装"
    exit 1
  fi
  local new_password method port server_ip
  new_password="$(gen_password)"
  method="$(jq -r '.method' "$CONFIG_PATH")"
  port="$(jq -r '.server_port' "$CONFIG_PATH")"

  cp -a "$CONFIG_PATH" "${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
  jq --arg pw "$new_password" '.password=$pw' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp"
  mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
  chmod 600 "$CONFIG_PATH"

  systemctl restart shadowsocks-rust
  health_check

  server_ip="$(get_server_ip)"
  write_info "$server_ip" "$method" "$new_password" "$port"
  echo "密码已重置（随机生成）"
}

restart_service() {
  systemctl restart shadowsocks-rust
  health_check
  echo "✅ 服务已重启"
}

stop_service() {
  systemctl stop shadowsocks-rust
  echo "✅ 服务已停止"
}

show_logs() {
  journalctl -u shadowsocks-rust -n 100 --no-pager
}

mask_value() {
  local v="$1"
  local n=${#v}
  if (( n <= 8 )); then
    echo "****"
  else
    echo "${v:0:4}****${v:n-4:4}"
  fi
}

show_config() {
  local mode="${1:-auto}"
  local mask="$MASK_CONFIG_DEFAULT"
  [[ "$mode" == "plain" ]] && mask=0
  [[ "$mode" == "mask" ]] && mask=1

  if [[ -f "$INFO_PATH" ]]; then
    local server port method password ss_url
    server="$(grep '^server=' "$INFO_PATH" | cut -d= -f2-)"
    port="$(grep '^port=' "$INFO_PATH" | cut -d= -f2-)"
    method="$(grep '^method=' "$INFO_PATH" | cut -d= -f2-)"
    password="$(grep '^password=' "$INFO_PATH" | cut -d= -f2-)"
    ss_url="$(grep '^ss_url=' "$INFO_PATH" | cut -d= -f2-)"

    echo "当前配置："
    echo "server=${server}"
    echo "port=${port}"
    echo "method=${method}"
    if [[ "$mask" == "1" ]]; then
      echo "password=$(mask_value "$password")"
      echo "ss_url=$(mask_value "$ss_url")"
      echo "(当前为脱敏显示，命令行用: bash ssrust.sh show-config-plain 查看明文)"
    else
      echo "password=${password}"
      echo "ss_url=${ss_url}"
    fi
  elif [[ -f "$CONFIG_PATH" ]]; then
    echo "当前配置（原始）："
    if [[ "$mask" == "1" ]]; then
      jq '.password="****"' "$CONFIG_PATH"
    else
      cat "$CONFIG_PATH"
    fi
  else
    echo "未找到配置文件"
  fi
}

status_check() {
  local port
  port="$(jq -r '.server_port' "$CONFIG_PATH" 2>/dev/null || echo 0)"
  systemctl status shadowsocks-rust --no-pager || true
  echo "---"
  ss -lntup | grep -E "ssserver|:${port}\\b" || true
  [[ -f "$INFO_PATH" ]] && { echo "---"; cat "$INFO_PATH"; }
}

network_test() {
  local port
  if [[ -f "$CONFIG_PATH" ]]; then
    port="$(jq -r '.server_port' "$CONFIG_PATH")"
    echo "本机端口测试:"
    ss -lntup | grep -E ":${port}\b|ssserver" || true
  else
    echo "未找到配置文件，无法测试端口"
  fi
}

config_manage_menu() {
  while true; do
    cat <<EOF

转发配置管理:
1. 更改端口（随机5位）
2. 更改端口（手动输入）
3. 重置密码（随机）
0. 返回上级
EOF
    read -rp "请输入选项 [0-3]: " c
    case "$c" in
      1) SS_PORT=""; change_port ;;
      2) read -rp "输入新端口(10000-65535): " p; SS_PORT="$p"; change_port ;;
      3) change_password ;;
      0) break ;;
      *) echo "无效选项" ;;
    esac
  done
}

interactive_menu() {
  while true; do
    cat <<EOF

============= SSRust 控制台 ${SCRIPT_VERSION} =============
 1) 安装
 2) 查看配置
 3) 修改端口
 4) 重置密码
 5) BBR管理
 6) 服务状态
 7) 重启服务
 8) 停止服务
 9) 查看日志
10) 连通性测试
11) 卸载
 0) 退出
==================================================
EOF
    read -rp "输入编号 [0-11]: " n
    case "$n" in
      1) do_install ;;
      2) show_config ;;
      3)
        read -rp "输入新端口(10000-65535，回车则随机): " p
        SS_PORT="$p"
        change_port
        ;;
      4) change_password ;;
      5)
        echo "\nBBR 管理:"
        echo "1) 查看 BBR 状态"
        echo "2) 启用 BBR"
        read -rp "选择 [1-2]: " b
        case "$b" in
          1) show_bbr_status ;;
          2) enable_bbr_only ;;
          *) echo "无效选项" ;;
        esac
        ;;
      6) status_check ;;
      7) restart_service ;;
      8) stop_service ;;
      9) show_logs ;;
      10) network_test ;;
      11) delete_config ;;
      0) echo "已退出"; exit 0 ;;
      *) echo "编号无效，请重试" ;;
    esac
  done
}

usage() {
  cat <<EOF
用法:
  bash ssrust.sh                      # 交互菜单
  bash ssrust.sh install              # 安装/重装
  bash ssrust.sh change-port          # 改端口（随机5位）
  SS_PORT=23456 bash ssrust.sh change-port   # 改为指定端口
  bash ssrust.sh change-password      # 重置随机密码
  bash ssrust.sh restart              # 重启服务
  bash ssrust.sh stop                 # 停止服务
  bash ssrust.sh logs                 # 查看日志
  bash ssrust.sh status               # 查看状态
  bash ssrust.sh test                 # 简单网络测试
  bash ssrust.sh bbr                  # 仅启用/检查 BBR
  bash ssrust.sh show-config          # 查看当前配置（默认脱敏）
  bash ssrust.sh show-config-plain    # 查看当前配置（明文）
  bash ssrust.sh delete-config        # 删除配置并停服务
EOF
}

ACTION="${1:-menu}"
case "$ACTION" in
  menu) interactive_menu ;;
  install) do_install ;;
  change-port) change_port ;;
  change-password) change_password ;;
  restart) restart_service ;;
  stop) stop_service ;;
  logs) show_logs ;;
  status) status_check ;;
  test) network_test ;;
  bbr) enable_bbr_only ;;
  show-config) show_config mask ;;
  show-config-plain) show_config plain ;;
  delete-config) delete_config ;;
  -h|--help|help) usage ;;
  *)
    echo "未知参数: $ACTION"
    usage
    exit 1
    ;;
esac
