# ss-rust-onekey

一键安装 **Shadowsocks Rust + BBR**（Debian/Ubuntu，root）。

## 功能

- 自动安装 shadowsocks-rust（最新 release）
- 默认协议：`aes-128-gcm`
- 密码自动随机生成（32 位）
- 默认随机 5 位端口（避开已占用端口）
- 自动写入并启用 `systemd` 服务
- 自动写入 `sysctl`（含 BBR 参数）
- 若系统已启用 BBR，则跳过重复写入
- 自动放行 TCP/UDP 端口（UFW）
- 安装后输出连接信息 + `ss://` 链接并保存到 `/root/ss-rust-info.txt`

## 使用

```bash
chmod +x ssrust.sh
./ssrust.sh
```

## 可选环境变量

- `SS_PORT`（默认自动随机 5 位端口，且避开已占用端口）
- `SS_METHOD`（默认 `aes-128-gcm`）

示例：

```bash
SS_PORT=443 SS_METHOD=aes-128-gcm ./ssrust.sh
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


## 新增操作选项

```bash
# 安装/重装（默认）
bash ssrust.sh

# 改端口（自动随机5位端口）
bash ssrust.sh change-port

# 改为指定端口
SS_PORT=23456 bash ssrust.sh change-port

# 删除配置并停服务
bash ssrust.sh delete-config
```


## 交互菜单

```bash
bash ssrust.sh
```

可用选项：安装/更新、转发配置管理（改端口/重置密码）、重启/停止服务、查看日志、状态检测、删除配置。
