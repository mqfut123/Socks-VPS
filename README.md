# Socks-VPS

一个命令，把 Linux VPS 变成轻量、独立、可管理的 IPv4 SOCKS5 出口。

```bash
bash <(curl -fsSL https://github.com/mqfut123/Socks-VPS/releases/latest/download/install.sh)
```

安装只问两件事：

```text
TCP port [Enter = random 1024-65535]:
Block mainland China IPv4 TCP access? [Y/n]:
```

连续两次回车，Socks-VPS 会选择一个未占用端口，默认阻断中国大陆来源，并生成 20 位安全用户名和密码。完成后直接显示连接信息：

```text
Socks-VPS is ready.

  Server IP  203.0.113.10
  Port       45826
  Username   2mX7rQ9vK4cN8pL5tH3s
  Password   qP9kD2wR7xM4bV8nC5zT
  Config     socks-1
  CN block   enabled
```

## 一个进程，多个 SOCKS

每个 SOCKS 使用独立配置文件，所有配置由同一个轻量进程统一运行。增加节点不会复制一套服务和防火墙。

```bash
sudo socks-vpsctl list
sudo socks-vpsctl add
sudo socks-vpsctl credentials socks-1
sudo socks-vpsctl remove socks-2
```

`add` 同样只问端口和大陆阻断选项，并自动生成新凭据。`credentials` 可以自行输入新用户名和密码，任一字段直接回车则重新生成 20 位安全值。

## 为什么用 Socks-VPS

| | Socks-VPS |
|---|---|
| 运行方式 | 单个 Go 二进制、单个 systemd 服务 |
| 多配置 | 一个进程监听多个独立 SOCKS 配置 |
| 协议 | SOCKS5 用户名/密码认证、TCP `CONNECT` |
| 网络边界 | 仅监听和连接 IPv4 |
| 默认凭据 | 安全随机用户名和密码，各 20 字符 |
| 大陆阻断 | 可选，默认开启，在 TCP 握手前由 nftables 丢弃 |
| 生命周期 | 开机自启，异常退出由 systemd 自动重启 |
| 资源所有权 | 只管理 Socks-VPS 自有配置、服务和 nftables 表 |

它只接受公网 IPv4 目标。IPv6、UDP、BIND、私网、回环、本机地址、链路本地地址、云元数据和 IANA 特殊用途地址会被拒绝。

## 管理

```bash
# 查看服务和全部配置
sudo socks-vpsctl status
sudo socks-vpsctl list

# 新增一个 SOCKS
sudo socks-vpsctl add

# 修改凭据
sudo socks-vpsctl credentials socks-1

# 删除一个配置
sudo socks-vpsctl remove socks-2

# 更新到最新版本
sudo socks-vpsctl update

# 可恢复卸载
sudo socks-vpsctl uninstall
```

不带参数运行 `sudo socks-vpsctl` 也可以使用交互菜单。最后一个 SOCKS 配置不会被单独删除，需要时请使用 `uninstall`。

服务仍可用标准 systemd 命令管理：

```bash
sudo systemctl restart socks-vps.service
sudo systemctl stop socks-vps.service
sudo systemctl start socks-vps.service
```

更新会保留所有端口、凭据和大陆阻断选项。配置变更、更新和卸载前会在 `/var/backups/socks-vps/` 留下可恢复快照。

## 大陆来源阻断

默认规则使用随版本打包的 IPdeny CN IPv4 网段，只对启用阻断的 SOCKS TCP 端口执行 `drop`。未命中的流量继续经过主机原有 nftables、firewalld、UFW 和云防火墙规则。

项目使用独立的 `table ip socks_vps`，不添加全局 `accept`，不修改默认策略，也不会接管 WARP VPS Manager 的服务、端口、网卡、路由或 `table inet warp_vps`。同名 nftables 表只有带项目所有权标记时才会被替换或删除。

如果全部配置都关闭大陆阻断，Socks-VPS 不要求安装 nftables，也不会操作外部同名表。

## 支持环境

- 使用 systemd 的 Linux
- `amd64` 或 `arm64`
- IPv4 网络
- `curl`、`tar` 和 SHA-256 工具

缺少运行依赖时，安装器支持 APT、DNF 和 YUM，并且只安装实际缺少的包。手动指定的端口若已被占用，安装会显示占用者并停止；自动模式只跳过占用端口，不会因普通系统识别结果提前中止。

## 配置与资源

- SOCKS 配置：`/etc/socks-vps/instances/*.json`
- 管理命令：`/usr/local/bin/socks-vpsctl`
- 程序入口：`/usr/local/bin/socks-vps`
- 当前版本：`/usr/local/lib/socks-vps/current`
- 服务：`socks-vps.service`
- 防火墙生命周期：`socks-vps-firewall.service`
- nftables：`table ip socks_vps`
- 可恢复备份：`/var/backups/socks-vps/`

Socks-VPS 使用标准 SOCKS5 用户名/密码认证，不额外封装加密隧道。

## License

Socks-VPS 以 [MIT License](LICENSE) 发布。第三方许可和 IPdeny 数据来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
