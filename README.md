# Socks-VPS

一个命令，把 Linux VPS 变成轻量、独立、可管理的 IPv4 SOCKS5 出口。

```bash
bash <(curl -fsSL https://github.com/mqfut123/Socks-VPS/releases/latest/download/install.sh)
```

| | Socks-VPS |
|---|---|
| 运行方式 | 单个 Go 二进制，一个主服务和一个防火墙生命周期 unit |
| 多配置 | 一个进程监听多个独立 SOCKS 配置 |
| 协议 | SOCKS5 用户名/密码认证、TCP `CONNECT` |
| 网络边界 | 仅监听和连接 IPv4 |
| 默认凭据 | 安全随机用户名和密码，各 20 字符 |
| 大陆阻断 | 可选，默认开启，在 TCP 握手前由 nftables 丢弃 |
| 资源所有权 | 只管理 Socks-VPS 自有配置、服务和 nftables 表 |

安装只问两件事：

```text
TCP 端口 [回车 = 随机选择 1024-65535]：
是否阻止中国大陆 IPv4 TCP 访问？[Y/n]：
```

连续两次回车，Socks-VPS 会选择一个未占用端口，默认阻断中国大陆来源，并生成 20 位安全用户名和密码。环境检查、安装包校验和服务自检会显示为简短的彩色状态；用于管道或 systemd 日志时自动改为普通文本，不输出颜色控制符。

完成后直接显示连接信息：

```text
✓ Socks-VPS 已就绪
服务器 IPv4：203.0.113.10
端口：45826
用户名：2mX7rQ9vK4cN8pL5tH3s
密码：qP9kD2wR7xM4bV8nC5zT
配置名称：socks-1
中国大陆来源：已拦截
```

公网 IPv4 查询失败时，服务器地址会显示“请填写 VPS 公网 IPv4”，不会把 NAT 私网地址当作连接地址。

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

- 独立 Go 核心，不依赖 Xray。
- 开机自启，异常退出由 systemd 自动重启。
- 只接受公网 IPv4 目标；拒绝 IPv6、UDP、BIND、私网、回环、本机地址、链路本地地址、云元数据和 IANA 特殊用途地址。
- 手动端口冲突时显示占用者并停止；自动端口只在真实 bind 竞争时重新选择一次。
- 更新、配置变更和重装失败时，只在同一次操作内恢复原状态并清理临时文件，不创建持久备份或恢复入口。

## 管理

```bash
# 查看服务和全部配置
sudo socks-vpsctl status
sudo socks-vpsctl list

# 新增一个 SOCKS
sudo socks-vpsctl add

# 修改凭据
sudo socks-vpsctl credentials socks-1

# 永久删除一个配置
sudo socks-vpsctl remove socks-2

# 更新到最新版本
sudo socks-vpsctl update

# 永久卸载
sudo socks-vpsctl uninstall
```

不带参数运行 `sudo socks-vpsctl` 会进入中文交互菜单。`status` 会一起检查配置、systemd、监听归属、认证和所需防火墙状态；`list` 按配置逐项显示名称、端口和大陆来源设置。

成功执行 `remove` 后，对应配置会永久删除。最后一个 SOCKS 配置不能单独删除，需要时使用 `uninstall`。菜单中的重装会先明确提示，然后永久替换全部现有 SOCKS 配置。

服务仍可用标准 systemd 命令管理：

```bash
sudo systemctl restart socks-vps.service
sudo systemctl stop socks-vps.service
sudo systemctl start socks-vps.service
```

更新会保留所有端口、凭据和大陆阻断选项。操作未完成时，脚本只在当前进程内恢复本次操作前的状态；成功后不保留快照、备份目录或 `restore` 命令。

永久卸载会先确认安装资源确实属于 Socks-VPS，再停止服务并移除全部配置、版本、命令、systemd unit、自有 nftables 表、运行目录、历史备份以及专用用户和组。

## 大陆来源阻断

默认规则使用随版本打包的 IPdeny CN IPv4 网段，只对启用阻断的 SOCKS TCP 端口执行 `drop`。未命中的流量继续经过主机原有 nftables、firewalld、UFW 和云防火墙规则。

项目使用独立的 `table ip socks_vps`，不添加全局 `accept`，不修改默认策略，也不会接管 WARP VPS Manager 的服务、端口、网卡、路由或 `table inet warp_vps`。同名 nftables 表只有带项目所有权标记时才会被替换或删除。

如果全部配置都关闭大陆阻断，Socks-VPS 不要求安装 nftables，也不会操作外部同名表。

## 支持环境

- 使用 systemd 的 Linux
- `amd64` 或 `arm64`
- IPv4 网络
- `curl`、`tar` 和 `sha256sum`

缺少运行依赖时，安装器支持 APT、DNF 和 YUM，并且只安装实际缺少的包。手动指定的端口若已被占用，安装会显示占用者并停止；自动模式只跳过占用端口，不会因普通系统识别结果提前中止。

## 配置与资源

- SOCKS 配置：`/etc/socks-vps/instances/*.json`
- 管理命令：`/usr/local/bin/socks-vpsctl`
- 程序入口：`/usr/local/bin/socks-vps`
- 当前版本：`/usr/local/lib/socks-vps/current`
- 服务：`socks-vps.service`
- 防火墙生命周期：`socks-vps-firewall.service`
- nftables：`table ip socks_vps`

Socks-VPS 使用标准 SOCKS5 用户名/密码认证，不额外封装加密隧道。

## License

Socks-VPS 以 [MIT License](LICENSE) 发布。第三方许可和 IPdeny 数据来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
