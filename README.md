# ssrust+

一键安装 / 管理 **Shadowsocks-Rust + Shadow-TLS**（Debian / Ubuntu / CentOS / RHEL）。

## 功能

- **Shadowsocks-Rust**：自动安装最新版（GitHub redirect 获取 tag，避开 API 限流），sha256 校验，主源失败自动回退到备份源
- **AEAD-2022 加密**：支持 `2022-blake3-aes-128-gcm`、`2022-blake3-aes-256-gcm`、`2022-blake3-chacha20-poly1305`，按规则生成 base64 密钥
- **Shadow-TLS v3**：可在 ss-rust 前架设 Shadow-TLS，菜单中可改端口 / SNI / strict / wildcard / fastopen / 后端
- **BBR + TFO**：通过 `/etc/sysctl.d/99-ss-rust.conf` drop-in，不覆盖用户原有 sysctl 配置
- **systemd 加固**：`NoNewPrivileges` / `ProtectSystem=strict` / `ProtectHome` / `PrivateTmp`
- **防火墙**：自动适配 ufw / firewalld，改端口 / 卸载时回收旧端口规则
- **ss:// + 二维码**：SIP002 URL-safe base64，附 `#节点名`，终端打印 ANSI 二维码方便扫码
- **Surge 节点行**：含 SS 直连与 SS + Shadow-TLS 组合
- **二进制自动升级**：菜单一键检测并更新 ss-rust / shadow-tls
- **脚本自更新**：菜单 → `self-update`

## 系统支持

Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux（root 权限，systemd）

架构：`x86_64` / `aarch64` / `armv7` / `i686`

## 使用

```bash
chmod +x ssrust.sh
./ssrust.sh           # 交互菜单
./ssrust.sh install   # 直接安装
```

## 子命令

```bash
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
bash ssrust.sh bbr-status               # 查看 BBR / TFO 状态
bash ssrust.sh self-update              # 自更新脚本
bash ssrust.sh uninstall                # 卸载（含 stls）

bash ssrust.sh stls install             # 安装 Shadow-TLS
bash ssrust.sh stls update              # 升级 Shadow-TLS
bash ssrust.sh stls view                # 查看 STLS 配置
bash ssrust.sh stls uninstall           # 卸载 Shadow-TLS
```

## 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `SS_PORT` | 随机 5 位（30000-65535） | 服务端口，可手动指定 |
| `SS_METHOD` | `aes-128-gcm` | 见 `change-cipher` 列表 |
| `SS_NODE_NAME` | `ssrust` | ss:// 与 Surge 节点名 |

示例：

```bash
SS_PORT=34567 SS_METHOD=2022-blake3-aes-128-gcm SS_NODE_NAME=hk-01 \
  bash ssrust.sh install
```

## 文件位置

| 路径 | 说明 |
|------|------|
| `/usr/local/bin/ssserver` | ss-rust 二进制 |
| `/etc/shadowsocks-rust/config.json` | ss 配置 |
| `/etc/shadowsocks-rust/ver.txt` | 当前 ss-rust 版本 |
| `/etc/systemd/system/shadowsocks-rust.service` | systemd 单元 |
| `/usr/local/bin/shadow-tls` | shadow-tls 二进制 |
| `/etc/shadow-tls/env` | shadow-tls 参数（KV） |
| `/etc/shadow-tls/ver.txt` | shadow-tls 版本 |
| `/etc/systemd/system/shadow-tls.service` | systemd 单元 |
| `/etc/sysctl.d/99-ss-rust.conf` | BBR + TFO drop-in |
| `/root/ss-rust-info.txt` | 连接信息（ss:// / Surge） |

## v2.0.0 相对原版的改进

- 替换为 redirect 方式取 latest tag，不再受 GitHub API 60/h 限流影响
- ss-rust 下载使用 `.sha256` 校验；shadow-tls 上游未发布校验文件，已显式 warn
- 用 URL-safe base64 生成 `ss://`（兼容 SIP002 严格客户端）
- BBR 配置写入 `/etc/sysctl.d/`，不再覆盖 `/etc/sysctl.conf`
- AEAD-2022 密码按 cipher key 长度生成（16 / 32 字节 base64）
- systemd 单元加固（capabilities + protect 系列）
- 防火墙改端口 / 卸载时自动撤销旧端口规则
- 多发行版支持：Debian/Ubuntu (apt) + CentOS/RHEL (dnf/yum)
- 菜单层级精简到 12 项；服务控制 / Shadow-TLS / BBR 各自子菜单
