# Socks-VPS

```bash
bash <(curl -fsSL https://github.com/mqfut123/Socks-VPS/releases/latest/download/install.sh)
```

在自己的 Linux VPS 上运行 SOCKS5 代理，为不同设备、应用或使用者分配连接，并通过中文菜单管理。

## 为什么选择 Socks-VPS

- **安装只需选择端口和大陆访问方式。** 用户名和密码自动生成，安装结束显示完整连接信息，可以直接用于配置客户端。
- **一台 VPS 管理多组连接。** 每组 SOCKS 都有独立端口、用户名和密码，便于按设备或用途分配；全部配置由同一个进程运行。
- **按端口控制大陆来源。** 启用阻断后，命中大陆 IPv4 地址库的连接会在 TCP 握手完成前被丢弃；不同端口可以分别选择是否阻断。
- **日常维护从中文菜单完成。** 查看连接信息、新增或删除 SOCKS、修改账号和访问设置，都有对应入口，后续调整不需要手工编辑配置文件。
- **重启和更新后继续使用原有设置。** 服务开机自启，异常退出由 systemd 自动重启；更新保留所有端口、凭据和大陆阻断选项，客户端无需重新配置。

## 安装与连接

安装配置只问两件事：

```text
TCP 端口 [回车 = 随机选择 1024-65535]：
是否阻止中国大陆 IPv4 TCP 访问？[Y/n]：
```

系统依赖齐全时，连续两次回车即可选择未占用端口并开启大陆来源阻断。用户名和密码各为 20 位安全随机值。需要自行指定端口时，在第一项输入端口号；需要允许大陆来源时，在第二项输入 `n`。

安装完成后会显示连接信息，例如：

```text
✓ Socks-VPS 已就绪
服务器 IPv4：203.0.113.10
端口：45826
用户名：2mX7rQ9vK4cN8pL5tH3s
密码：qP9kD2wR7xM4bV8nC5zT
配置名称：socks-1
中国大陆来源阻断：开启

• 打开管理菜单：sudo socks-vpsctl
```

公网 IPv4 查询失败时，请在客户端填写 VPS 的公网 IPv4 地址。

在云平台安全组和主机防火墙中放行所选 TCP 端口，然后在支持 SOCKS5 用户名/密码认证的客户端中填入服务器 IPv4、端口、用户名和密码。

以后需要查看或修改设置，运行：

```bash
sudo socks-vpsctl
```

## 支持环境

- 使用 systemd 的 Linux VPS
- `amd64` 或 `arm64` 架构
- IPv4 网络
- `curl`、`tar` 和 `sha256sum`

安装器按当前操作检查 `ss`、`nft` 等依赖。缺少依赖时，会先列出需要安装的软件包；回车确认后通过 APT、DNF 或 YUM 安装，输入 `n` 或 `N` 取消。全新安装选择允许大陆来源时，不要求安装 nftables。

协议范围为 SOCKS5 用户名/密码认证和 TCP `CONNECT`，监听与代理目标均使用 IPv4，目标仅限公网地址，拒绝本机及 IANA 特殊用途地址。不支持 IPv6、UDP、`BIND`，也不额外封装加密隧道。

手动指定的端口若已被占用，安装器会显示占用者并停止；自动模式会选择未占用端口，在服务启动时遇到端口竞争会重新选择一次。

## 管理

```bash
# 查看服务和全部配置
sudo socks-vpsctl status
sudo socks-vpsctl list

# 新增一个 SOCKS
sudo socks-vpsctl add

# 修改连接设置
sudo socks-vpsctl credentials

# 永久删除一个配置
sudo socks-vpsctl remove

# 更新到最新版本
sudo socks-vpsctl update

# 清理旧版本、历史备份与临时残留
sudo socks-vpsctl cleanup

# 永久卸载
sudo socks-vpsctl uninstall
```

`status` 检查服务、监听、认证和所需防火墙状态；`status` 和 `list` 都会逐项显示每组 SOCKS 的名称、端口、用户名、密码和大陆来源设置。

### 新增、修改和删除

`add` 按安装时的两项选择创建一组新的 SOCKS 连接。

`credentials` 进入“修改连接设置”。选定 SOCKS 后，可以分别选择修改大陆来源阻断、用户名和密码，也可以一次修改多项：

- 每项默认不修改，没有选择任何设置时不写配置、不重启服务。
- 选择修改用户名或密码后，输入新值即可指定；留空则重新生成对应凭据。
- 选择修改大陆来源阻断后，回车或输入 `y` 开启，输入 `n` 关闭。

修改或删除时，只有一组 SOCKS 会直接选中；有多组时按 `1、2、3…` 输入序号选择。也可以直接指定配置名称：

```bash
sudo socks-vpsctl credentials socks-1
sudo socks-vpsctl remove socks-2
```

`remove` 会永久删除选中的配置。最后一组 SOCKS 需要通过 `uninstall` 完整卸载。

### 重装、清理和卸载

菜单中的重装会在确认后永久替换全部现有 SOCKS 配置，创建一组新连接。

`cleanup` 对应菜单中的“清理日志”，清理旧版本、历史备份和临时残留；当前配置和服务继续保留。

`uninstall` 会停止服务，并永久移除全部 SOCKS 配置、程序版本、管理命令、systemd unit、Socks-VPS 防火墙规则、运行目录、历史备份以及专用用户和组。

### 启动、停止和重启

服务也可以使用标准 systemd 命令管理：

```bash
sudo systemctl restart socks-vps.service
sudo systemctl stop socks-vps.service
sudo systemctl start socks-vps.service
```

## 大陆来源地址库

大陆来源阻断采用 IPdeny CN IPv4 网段，地址库随发布包统一交付。新版地址库通过 Socks-VPS 版本更新获取。

## 配置与资源

- SOCKS 配置：`/etc/socks-vps/instances/*.json`
- 管理命令：`/usr/local/bin/socks-vpsctl`
- 程序入口：`/usr/local/bin/socks-vps`
- 当前版本：`/usr/local/lib/socks-vps/current`
- 服务：`socks-vps.service`
- 防火墙生命周期：`socks-vps-firewall.service`
- nftables：`table ip socks_vps`

## License

Socks-VPS 以 [MIT License](LICENSE) 发布。第三方许可和 IPdeny 数据来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 项目协作

项目资料：[背景](cowork/background.md)、[规则](cowork/rules.md)、[待办](cowork/todo.md)和[文档索引](cowork/docs/README.md)。
