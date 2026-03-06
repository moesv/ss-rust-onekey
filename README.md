# ss-rust-onekey

一键安装 **Shadowsocks Rust + BBR**（Debian/Ubuntu，root）。

## 功能

- 自动安装 shadowsocks-rust（最新 release）
- 默认协议：`aes-128-gcm`
- 密码自动随机生成（32 位）
- 自动写入并启用 `systemd` 服务
- 自动写入 `sysctl`（含 BBR 参数）并 `sysctl -p`
- 自动放行 TCP/UDP 端口（UFW）
- 安装后输出连接信息并保存到 `/root/ss-rust-info.txt`

## 使用

```bash
chmod +x install-ss-rust-bbr.sh
./install-ss-rust-bbr.sh
```

## 可选环境变量

- `SS_PORT`（默认 `8388`）
- `SS_METHOD`（默认 `aes-128-gcm`）

示例：

```bash
SS_PORT=443 SS_METHOD=aes-128-gcm ./install-ss-rust-bbr.sh
```

## 安装后检查

```bash
systemctl status shadowsocks-rust --no-pager
sysctl net.ipv4.tcp_congestion_control
cat /root/ss-rust-info.txt
```

## 卸载（手动）

```bash
systemctl disable --now shadowsocks-rust
rm -f /etc/systemd/system/shadowsocks-rust.service
systemctl daemon-reload
rm -f /usr/local/bin/ssserver
rm -rf /etc/shadowsocks-rust /opt/ss-rust
```
