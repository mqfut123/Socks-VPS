# Socks-VPS 当前活跃 handoff

更新时间：2026-07-26

本文件是当前状态的唯一交接入口。历史时间线和完整归档位于
[`docs/handoffs/README.md`](docs/handoffs/README.md)。

## 当前版本

- 仓库：`https://github.com/mqfut123/Socks-VPS`
- 当前发布：`v1.0.4`
- 项目许可：MIT，项目许可正文位于 `LICENSE`
- 发布包：Linux `amd64`、Linux `arm64`
- IPdeny：CN IPv4 aggregated 数据随仓库和同一版本发布包交付

`v1.0.4` 只改变许可与交接文档，并让发布包和安装后的版本目录携带项目
`LICENSE`；SOCKS 协议、防火墙和生命周期行为保持 `v1.0.3` 的契约。
两个架构的 v1.0.4 归档已通过本地完整发布门禁；未在原测试 VPS 上执行
v1.0.3 → v1.0.4 更新，因为连接前发现其 SSH 主机密钥已经变化。

## 当前产品边界

- 独立 Go 服务，不使用 Xray 运行时。
- 监听 `tcp4` 和 `0.0.0.0:<port>`。
- 只支持 SOCKS5、RFC 1929 用户名/密码认证和 TCP `CONNECT`。
- 域名只解析 A 记录，出站只使用 `tcp4`。
- 拒绝 IPv6、UDP、BIND、私网、本机、链路本地、云元数据和其他
  IPv4 特殊用途目标。
- CN 来源由 `table ip socks_vps` 在 TCP 握手前丢弃；Go 服务不重复判断
  CN 来源。
- 未命中的数据包继续经过主机已有 nftables、UFW、firewalld 和云防火墙，
  项目不添加全局 accept。
- WARP VPS Manager 的服务、网卡、路由、配置和 `table inet warp_vps`
  始终是外部资源。

## 权威状态与资源

- 配置：`/etc/socks-vps/config.json`
- 当前版本链接：`/usr/local/lib/socks-vps/current`
- 版本目录：`/usr/local/lib/socks-vps/releases/<version>`
- 程序入口：`/usr/local/bin/socks-vps`
- 服务：`socks-vps.service`、`socks-vps-firewall.service`
- 防火墙：`table ip socks_vps`
- 所有权标记：`cn_ipv4` set 注释 `Socks-VPS managed CN IPv4 set`
- 可恢复备份：`/var/backups/socks-vps/<timestamp>-<action>`

端口和凭据只以 `/etc/socks-vps/config.json` 为权威。手动端口冲突时显示
占用者并停止；自动端口跳过已占用候选，最终以服务真实 bind 结果为准。

## 已完成验证

本地门禁已覆盖：

- Go 单元测试、race、vet、gofmt 和模块锁校验。
- Bash 语法和生命周期、账户、监听归属、恢复、发布契约测试。
- amd64、arm64 发布包成员 allowlist、逐文件哈希、源码清单、ELF 架构和
  锁定源码重建字节一致性。

Ubuntu 22.04 `amd64` KVM VPS 对 v1.0.3 已覆盖：

- 自动端口安装、认证、TCP `CONNECT`、公网 IPv4 出口及协议拒绝边界。
- 模拟 CN 来源 SYN drop 与非 CN 来源进入认证。
- UFW enable/reload/deny/恢复，不绕过现有主机防火墙。
- 原生 nftables reload/restart/stop、规则重建失败停服及开机启动。
- 主进程异常退出、端口抢占、错误配置、更新、卸载、恢复和重启。
- 三轮各 256 条 TCP 隧道和 256 条慢握手；峰值 RSS 约 10.7 MiB，
  cgroup 内存约 13.2 MiB，未观察到持续增长。

## 当前操作边界

- 原生 `nftables.service` 正在运行时，reload/restart 会重建 Socks-VPS
  自有表；重建失败会停止主服务。
- 原生 `nftables.service` 尚未运行、但 Socks-VPS 已运行时，如需启用原生
  服务，应执行 `systemctl restart nftables.service`，不要单独 start。
- 原生 nftables reload 到自有表重新提交之间存在短暂窗口。消除该窗口需要
  接管外部 unit 或增加额外状态机制，当前设计不扩张到该范围。
- 凭据、测试机地址和 SSH 信息不得写入 Git、handoff、日志或发布包。
- 原测试 VPS 的 SSH 主机密钥已变化；在所有者从独立可信渠道确认新指纹前，
  不接受新密钥，也不继续远端写入。

## 尚未完成的独立验收

- DNF/YUM 系统。
- arm64 真机运行。
- 真实 CN/GFW 来源。
- active firewalld。
- 与 WARP VPS Manager 同机安装、更新、重启和卸载。

这些项目完成前，不用本地测试、模拟来源或 Ubuntu 结果替代。

## 后续最短路径

1. 先读 `AGENTS.md`、`reference/README.md`、`docs/initial-baseline.md`、
   本文件及历史时间线。
2. 只处理上述未验收环境或新的明确需求。
3. 保持 IPdeny 数据随版本包交付，VPS 安装与运行不直接访问 IPdeny。
4. 修改发布输入后重新构建两个架构并运行 `scripts/check-release.sh`。
5. 真实系统结论必须保存对应 systemd、nftables、监听与流量证据。

## handoff 换代

创建下一份活跃 handoff 前，先把本文件完整复制到
`docs/handoffs/archive/<date>-<version>.md`，再重写本文件，并在历史时间线
顶部新增一条简短摘要。归档只记录当时事实，不作为当前状态来源。
