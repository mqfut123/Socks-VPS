# Socks-VPS

```bash
bash <(curl -fsSL https://github.com/mqfut123/Socks-VPS/releases/download/v1.0.2/install-v1.0.2.sh)
```

| | Socks-VPS | 通用 SOCKS 安装脚本 |
|---|---|---|
| 协议边界 | SOCKS5、TCP `CONNECT`、全链路 IPv4 | 通常同时开启多种协议 |
| 中国大陆来源 | 在 TCP 握手前由独立 nftables 表丢弃 | 常在应用层拒绝或不限制 |
| 规则交付 | CN aggregated 数据随同一版本包交付 | 可能在 VPS 上另行下载 |
| 共存 | 只管理 `socks-vps` 自有资源 | 取决于脚本 |

Socks-VPS 是运行在 Linux VPS 上的标准 SOCKS5 服务。它监听
`0.0.0.0`，只接受 RFC 1929 用户名/密码认证和 TCP `CONNECT`，只连接
公网 IPv4 目标。IPv6、UDP、私网、本机地址、链路本地地址、云元数据和
IANA 特殊用途 IPv4 目标会被拒绝。

## 支持环境

- 使用 systemd 的 Linux。
- APT、DNF 或 YUM 软件包管理器。
- `amd64` 和 `arm64`。
- nftables。
- 可用的 IPv4 DNS 服务器；域名目标只查询 `A` 记录。

安装器在收齐端口、用户名和密码后才请求 root 权限并修改系统。自动端口
只从当前可绑定的 `1024–65535/TCP` 中选择；用户指定的端口若已占用，
安装停止并显示占用进程，不会修改端口或停止现有服务。

## 管理

再次运行公开安装命令会进入状态、更新、重装和卸载菜单。安装后也可直接
运行同一管理入口：

```bash
/usr/local/lib/socks-vps/current/scripts/install.sh
```

只读状态：

```bash
/usr/local/lib/socks-vps/current/scripts/install.sh --status
```

服务管理：

```bash
sudo systemctl start socks-vps.service
sudo systemctl stop socks-vps.service
sudo systemctl restart socks-vps.service
```

主服务依赖 `socks-vps-firewall.service`。启动、停止或重启主服务时，
项目自有防火墙随之处理；主进程意外退出时防火墙也会撤销，直接停止防火墙
则会停止主服务。安装器的更新、重装、恢复和卸载会依次显式停止主服务与
防火墙服务，并确认两个 unit 均不活动且自有 nftables 表已撤销后再改文件。

## 认证

配置只支持一个用户名和密码，保存在
`/etc/socks-vps/config.json`，权限为 `0640 root:socks-vps`。凭据不进入
命令行、systemd unit 或日志。RFC 1929 用户名/密码认证本身不加密传输。

## CN 来源规则

`table ip socks_vps` 只对当前 SOCKS TCP 端口执行：

- 来源命中 IPdeny `CN` IPv4 aggregated 集合：`drop`。
- 未命中：继续经过主机已有的 nftables、firewalld、UFW 和云防火墙规则。

项目不添加全局 `accept`，不修改默认策略，也不修改
`table inet warp_vps` 或任何 WARP VPS Manager 服务、端口、网卡、路由、
配置和状态。IPdeny 数据只覆盖其当前 CN 地址分配集合，不是 GFW 探测节点
名单。

仓库中的四个权威上游文件为：

- `assets/ipdeny/cn-aggregated.zone`
- `assets/ipdeny/Copyrights.txt`
- `assets/ipdeny/MD5SUM.upstream`
- `assets/ipdeny/SOURCE.json`

VPS 安装、更新和启动只读取发布包内的数据，不访问 IPdeny。维护者使用
`scripts/update-ipdeny.sh` 单次下载并验证新数据，审查四个文件后随新版本
发布。维护脚本串行执行，每项工件只请求一次，并在相邻请求间等待 1 秒，
符合 IPdeny 每 IP 每日不超过 5000 次下载、并发不超过 5 个连接、请求间隔
0.5–1 秒的 [Fair Usage Limits](https://www.ipdeny.com/usagelimits.php)。
IPdeny 的转载条件保存在 `Copyrights.txt`。

## 文件与所有权

- 配置：`/etc/socks-vps/config.json`
- 当前版本：`/usr/local/lib/socks-vps/current`
- 版本目录：`/usr/local/lib/socks-vps/releases/<version>`
- 程序入口：`/usr/local/bin/socks-vps`
- systemd：`socks-vps.service`、`socks-vps-firewall.service`
- nftables：`table ip socks_vps`
- 可恢复备份：`/var/backups/socks-vps/<timestamp>-<action>`

更新保留当前端口和认证配置，并同步配置内的安装版本。更新前会保存配置、
units、完整程序与规则数据；失败时打印备份目录内可独立执行的恢复命令：

```bash
sudo /var/backups/socks-vps/<backup>/restore.sh --restore /var/backups/socks-vps/<backup>
```

卸载先停止流量和自有防火墙，确认端口释放，再把配置、程序和 units 移入
带时间戳的备份目录。共享系统包和其他项目资源不受影响；专用系统账户会
锁定并保留，以便使用卸载结果打印的同一条 `restore.sh --restore` 命令
恢复。恢复入口支持从部分移动状态继续，不覆盖同名目标。

## 构建与发布

本地构建包：

```bash
./scripts/build-release.sh 1.0.2
```

此模式会构建 `linux/amd64` 和 `linux/arm64` 版本，但公开发布校验保持
阻塞。公开发布构建：

```bash
./scripts/build-release.sh 1.0.2 https://github.com/mqfut123/Socks-VPS
```

GitHub Release `v<VERSION>` 必须包含：

- `install-v<VERSION>.sh`
- `socks-vps-v<VERSION>-linux-amd64.tar.gz`
- `socks-vps-v<VERSION>-linux-amd64.tar.gz.sha256`
- `socks-vps-v<VERSION>-linux-arm64.tar.gz`
- `socks-vps-v<VERSION>-linux-arm64.tar.gz.sha256`

构建使用全新的版本化 `dist/staging/<version>-<target>`，对应路径已存在
时停止，不覆盖历史构建。每个归档包含程序、安装器、两个 units、四个
IPdeny 文件、第三方许可、
`MANIFEST.sha256` 和版本/架构信息；包校验检查成员 allowlist、逐文件哈希、
源码与包内文档、脚本、units、许可及 IPdeny 字节一致性、ELF 架构，
并以锁定依赖和当前源码重建二进制进行字节比对。未配置真实 HTTPS 项目
地址时，公开发布校验保持阻塞。

Socks-VPS 本身的项目许可证尚未指定。发布包只附带 go-gost/gosocks5 的
MIT 许可和 IPdeny 的上游版权文件。

## 验证状态

本地发布门禁要求 Go 测试、shell 语法、systemd 静态契约、发布包成员与
字节校验全部通过。生产支持结论还需要在真实 VPS 上完成：

- APT 与 DNF/YUM 各一套。
- `amd64` 与 `arm64`。
- CN 与非 CN 控制来源。
- systemd、nftables、firewalld/UFW 重载和开机启动。
- 主进程意外退出或 bind 失败时，自有防火墙表随之撤销；直接停止任一
  Socks-VPS unit 时另一 unit 按依赖关系停止。
- 与 WARP VPS Manager 同机安装、更新、重启和卸载。

未完成的真实 VPS 项目不会用本地测试结果代替。
