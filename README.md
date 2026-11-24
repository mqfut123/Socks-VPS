# Socks-VPS

[程序入口](cmd/) · [实现代码](internal/)

```bash
bash <(curl -fsSL https://github.com/mqfut123/Socks-VPS/releases/latest/download/install.sh)
```

在自己的 Linux VPS 上运行 SOCKS5 代理，为不同设备、应用或使用者分配连接，并通过中文菜单管理。

## 为什么选择 Socks-VPS

- **安装只需选择端口和大陆访问方式。** 用户名和密码自动生成，安装结束显示完整连接信息，可以直接用于配置客户端。
- **支持自动化全新安装。** 免交互入口接收端口、凭据和访问选项，以 JSON 返回结果，并提供固定的退出码。
- **直接导入 Xray 客户端。** 每组 SOCKS 会生成可被支持该格式的 Xray 客户端识别的 `socks://` 分享链接，安装、列表和状态页面都可以直接复制。
- **一台 VPS 管理多组连接。** 每组 SOCKS 都有独立端口、用户名和密码，便于按设备或用途分配；全部配置由同一个进程运行。
- **按端口控制大陆来源。** 启用阻断后，命中大陆 IPv4 地址库的连接会在 TCP 握手完成前被丢弃；不同端口可以分别选择是否阻断。
- **默认丢弃异常的 TCP 连接请求。** 所有 SOCKS 端口都会丢弃携带 IPv4 选项的 TCP 连接请求，用于缓解 Linux 内核漏洞 CVE-2026-98432；正常客户端不使用 IPv4 选项，连接不受影响。
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
导入链接：socks://...

• 打开管理菜单：sudo socks-vpsctl
```

公网 IPv4 查询失败时，请在客户端填写 VPS 的公网 IPv4 地址。

在云平台安全组和主机防火墙中放行所选 TCP 端口，然后在支持 SOCKS5 用户名/密码认证的客户端中填入服务器 IPv4、端口、用户名和密码。

在 v2rayN、v2rayNG 等支持 `socks://` 分享链接的客户端中，复制链接后选择从剪贴板导入即可。

以后需要查看或修改设置，运行：

```bash
sudo socks-vpsctl
```

### 免交互全新安装

从 v1.4.0 起，发布版引导脚本支持 `--non-interactive`。在 root 会话中下载引导脚本，然后把参数原样传给 `bash install.sh`。下面指定端口和用户名，从密码文件读取密码，允许大陆来源，并允许安装缺少的系统依赖：

```bash
umask 077
curl -fsSL https://github.com/mqfut123/Socks-VPS/releases/latest/download/install.sh -o install.sh
bash install.sh --non-interactive \
  --port 45123 \
  --username client \
  --password-stdin \
  --allow-cn=true \
  --install-deps \
  < /root/socks-password > install-result.json
```

`/root/socks-password` 由调用方预先准备。密码只从 stdin（标准输入）读取至 EOF，接受一个末尾 LF 换行；内容必须为 1–255 字节 UTF-8，不含 NUL、CR 或内嵌 LF。不支持密码命令行参数。

| 参数 | 默认值与行为 |
|---|---|
| `--non-interactive` | 必须放在第一个参数，只做全新安装 |
| `--port auto` 或 `--port PORT` | 默认 `auto`；具体端口范围为 1024–65535 |
| `--username USERNAME` | 省略时生成 20 位安全随机值；指定值须为 1–255 字节 UTF-8 |
| `--password-stdin` | 省略时生成 20 位安全随机密码，仅通过结果中的 `generated_password` 返回 |
| `--allow-cn=true\|false` | 默认 `false`，即开启大陆来源阻断 |
| `--install-deps` | 默认不安装依赖；显式指定后允许通过 APT、DNF 或 YUM 安装缺少的 `ss`、`nft` 所属软件包。`nft` 为必需依赖，缺少且未指定本参数时返回 `69` |
| `--help` | 查看安装帮助，也可运行包内的 `bash scripts/install.sh --help` |

用户名和密码可以各自指定或省略。指定端口发生占用时返回 `78`，不换端口；自动模式先执行真实 IPv4 bind 检查，在服务启动时遇到 bind 竞争最多重选一次，再次竞争失败返回 `78`。

此入口必须以 root 运行，不调用交互式 sudo。检测到已安装实例、任何不完整安装路径或专用账号冲突时返回 `73`，不安装依赖、不修改现有配置或服务。免交互安装复用原有安装事务、回滚和健康检查。进度与诊断写入 stderr（标准错误）；成功时 stdout（标准输出）只包含一个 JSON 对象，失败时返回非零退出码，不输出成功 JSON。

成功结果示例（调用方提供密码）：

```json
{"config":"socks-1","port":45123,"username":"client","block_cn":false,"public_ipv4":"203.0.113.10","share_link":null,"version":"1.4.0","generated_password":null}
```

| JSON 字段 | 类型与含义 |
|---|---|
| `config` | string；新配置名，固定为 `socks-1` |
| `port` | number；健康检查通过的实际监听端口，包含自动重选后的结果 |
| `username` | string；实际用户名 |
| `block_cn` | boolean；`true` 表示开启大陆来源阻断 |
| `public_ipv4` | string 或 null；经导入链接生成校验的公网 IPv4，查询或校验失败时为 null |
| `share_link` | string 或 null；`socks://` 导入链接；无法生成时为 null。提供密码时也为 null，避免输出其可逆编码；链接仍保存到受保护的实例 `.url` 文件 |
| `version` | string；安装版本号 |
| `generated_password` | string 或 null；只有自动生成密码时返回该密码，调用方提供密码时为 null |

省略 `--password-stdin` 时，JSON 会包含生成密码；公网地址可用且链接可生成时，也会包含导入链接。自动化调用方应保存该结果供连接使用。

| 退出码 | 免交互安装结果 |
|---|---|
| `0` | 安装与健康检查成功 |
| `64` | 参数、端口范围、用户名或 stdin 密码无效 |
| `65` | 引导运行环境不支持、下载失败、安装包缺失、平台不匹配或完整性校验失败 |
| `69` | 缺少依赖且未允许安装，或依赖安装/可用性检查失败 |
| `70` | 其他安装、回滚或结果读取/输出失败 |
| `71` | 服务启动或健康检查失败，执行原有事务回滚 |
| `73` | 已安装、不完整安装、安装路径或专用账号冲突 |
| `77` | 非 root 运行 |
| `78` | 指定端口被占用，或服务 bind 竞争且不能继续重选 |

这些字段和退出码只适用于 `--non-interactive`；原有交互安装及管理子命令保留原行为和输出。

## 支持环境

- 使用 systemd 的 Linux VPS
- `amd64` 或 `arm64` 架构
- IPv4 网络
- `curl`、`tar` 和 `sha256sum`

安装器按当前操作检查 `ss`、`nft` 等依赖。缺少依赖时，会先列出需要安装的软件包；回车确认后通过 APT、DNF 或 YUM 安装，输入 `n` 或 `N` 取消。从 v1.5.0 起，每组 SOCKS 都由 Socks-VPS 自有的 nftables 表保护，因此无论是否允许大陆来源都需要 `nft`。

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

# 重新生成公网地址变化后的导入链接
sudo socks-vpsctl link [CONFIG]

# 永久删除一个配置
sudo socks-vpsctl remove

# 更新到最新版本
sudo socks-vpsctl update

# 清理旧版本、历史备份与临时残留
sudo socks-vpsctl cleanup

# 永久卸载
sudo socks-vpsctl uninstall
```

`status` 检查服务、监听、认证和所需防火墙状态；`status` 和 `list` 都会逐项显示每组 SOCKS 的名称、端口、用户名、密码、大陆来源设置和导入链接。

首次生成链接时，安装器通过 IPv4 查询服务取得公网 IPv4，并把完整链接保存为对应实例的 `.url` 文件。已有链接不会在 `list`、`status` 或后续结果页重复查询公网 IP。修改凭据时用原公网 IPv4 更新链接；公网 IPv4 变化后，运行 `sudo socks-vpsctl link [CONFIG]` 主动重新生成。首次查询失败时显示未生成；主动刷新失败时保留原链接并提示原因。

### 新增、修改和删除

`add` 按安装时的两项选择创建一组新的 SOCKS 连接。

`credentials` 进入“修改连接设置”。选定 SOCKS 后，可以分别选择修改大陆来源阻断、用户名和密码，也可以一次修改多项：

- 每项默认不修改，没有选择任何设置时不写配置、不重启服务。
- 选择修改用户名或密码后，输入新值即可指定；留空则重新生成对应凭据。
- 选择修改大陆来源阻断后，回车或输入 `y` 开启，输入 `n` 关闭。

修改或删除时，只有一组 SOCKS 会直接选中；有多组时按 `1、2、3…` 输入序号选择。也可以直接指定配置名称：

```bash
sudo socks-vpsctl credentials socks-1
sudo socks-vpsctl link socks-1
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

## 防火墙规则

Socks-VPS 只维护 `table ip socks_vps`，不改动主机其他防火墙配置。表内两条规则按顺序生效：

1. 丢弃携带 IPv4 选项（IP 头长度大于 20 字节）且目标为任一 SOCKS 端口的 TCP 报文。这是 Linux 内核 CVE-2026-98432 的缓解措施，所有端口始终启用；正常客户端不使用 IPv4 选项，不受影响。
2. 丢弃来源命中大陆 IPv4 地址库、目标为已启用阻断端口的 TCP 报文。仅对选择阻断大陆来源的端口生效。

更新到 v1.5.0 后，已安装的实例在服务重启时自动获得第 1 条规则，无需修改配置。

## 配置与资源

- SOCKS 配置：`/etc/socks-vps/instances/*.json`
- SOCKS 导入链接缓存：`/etc/socks-vps/instances/*.url`
- 管理命令：`/usr/local/bin/socks-vpsctl`
- 程序入口：`/usr/local/bin/socks-vps`
- 当前版本：`/usr/local/lib/socks-vps/current`
- 服务：`socks-vps.service`
- 防火墙生命周期：`socks-vps-firewall.service`
- nftables：`table ip socks_vps`

## License

Socks-VPS 以 [MIT License](LICENSE) 发布。第三方许可和 IPdeny 数据来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
