# Socks-VPS 项目初版原始基线

- 基线日期：2026-07-26
- 基线范围：项目首个生产可用版本
- 文档性质：冻结已确认的初版目标、方案和验收边界，不随后续实现变更回写

当前使用方式和验证状态以项目根目录的
[`README.md`](../../README.md) 为准。后续版本不得通过修改本文件重写初版决策。

## 1. 目标

在使用 systemd 的 Linux VPS 上交付一个独立的 SOCKS5 服务：

- 公网监听仅使用 IPv4。
- 只支持用户名/密码认证和 TCP `CONNECT`。
- 代理出口只连接公网 IPv4 目标。
- 中国大陆 IPv4 来源在 TCP 握手完成前被丢弃。
- IPdeny 规则与程序放在同一个仓库、同一个版本包中统一下载。
- Socks-VPS 自行维护依赖版本和规则更新，不在用户 VPS 上单独获取 IPdeny。
- 可与 WARP VPS Manager 安装在同一台机器，双方资源和生命周期互不接管。

## 2. 已确认的初版选择

| 决策项 | 初版选择 |
|---|---|
| 默认端口选项 | 选项 1：自动选择未占用的 TCP 端口 |
| 手动端口 | 保留用户指定值；已占用时停止，不自动换端口 |
| IP 协议 | 只提供 IPv4 |
| SOCKS 能力 | SOCKS5、RFC 1929 用户名/密码、TCP `CONNECT` |
| IPdeny 方案 | 方案 A：IPv4 aggregated country zone |
| 国家 | `CN`，中国大陆 |
| 规则文件 | `cn-aggregated.zone` |
| 规则交付 | 纳入仓库并随发布包统一交付 |
| 规则维护 | 维护者更新、校验、审查并随新版本发布 |
| 来源拒绝位置 | nftables 输入链，在 TCP 握手前 `drop` |
| 现有防火墙 | 继续生效；项目不添加全局 `accept` |

## 3. 协议与目标边界

服务监听 `tcp4` 的 `0.0.0.0:<port>`，不创建 IPv6 监听。

客户端必须使用 SOCKS5 用户名/密码认证。服务只接受 TCP `CONNECT`，
拒绝无认证、UDP `ASSOCIATE`、`BIND`、IPv6 地址和其他地址类型。

目标地址只允许公网 IPv4：

- IPv4 字面量必须通过公网目标检查。
- 域名只查询 `A` 记录，不查询或使用 `AAAA`。
- 私网、本机、回环、链路本地、云元数据和 IANA 特殊用途地址不得连接。
- 目标不符合边界时返回对应 SOCKS 错误，不回落到 VPS 原生直连。

初版不提供 IPv6、UDP、匿名访问、多用户、流量加密或 SOCKS 协议自动降级。

## 4. 端口选择

### 4.1 自动模式

自动模式是安装器默认的选项 1，候选范围为 `1024–65535/TCP`。

选择流程：

1. 从随机候选位置开始遍历整个范围。
2. 读取 Linux `ip_local_reserved_ports`，跳过系统保留端口。
3. 对每个候选执行与正式服务一致的 `tcp4 0.0.0.0:<port>` 真实绑定检查。
4. `EADDRINUSE` 表示已占用，继续检查下一个候选。
5. 其他绑定错误立即停止，不把权限、地址或系统错误当成端口冲突。
6. 特权安装阶段再次检查候选；如果端口在此期间被占用，自动模式重新选择。
7. Go 服务的实际监听仍是最终绑定结果；启动时发生冲突必须报告失败。

自动模式不得返回检查时已经占用或被系统保留的端口。

### 4.2 手动模式

手动模式接受用户明确指定的 `1024–65535/TCP` 端口。安装器不得替换该值。
如果端口已被占用，安装停止并使用 `ss` 显示可读取的监听进程或 systemd
服务信息。

端口选择、用户名和密码在请求 root 权限或修改系统前完成。

## 5. IPdeny 数据交付与维护

初版只使用 IPdeny 的 `CN` IPv4 aggregated 数据：

```text
https://www.ipdeny.com/ipblocks/data/aggregated/cn-aggregated.zone
```

仓库保存四个权威文件：

- `assets/ipdeny/cn-aggregated.zone`
- `assets/ipdeny/Copyrights.txt`
- `assets/ipdeny/MD5SUM.upstream`
- `assets/ipdeny/SOURCE.json`

程序、安装器、防火墙脚本、规则数据和版权文件进入同一个版本包。VPS
安装、更新、启动和恢复只读取包内文件，不访问 IPdeny，也不单独下载规则。

项目维护者负责依赖更新：

1. 使用 `scripts/update-ipdeny.sh` 获取 CN zone、版权文件和上游 MD5。
2. 每个上游工件只请求一次，并按 IPdeny 使用限制串行请求。
3. 校验 HTTPS、非空文件、CIDR 格式、IPv4-only、上游 MD5 和本地 SHA-256。
4. 记录来源地址、获取时间、上游修改时间、摘要和行数。
5. 生成完整 nftables 规则并执行可用的语法检查。
6. 人工确认后替换仓库内四个权威文件。
7. 运行项目测试、审查差异并随新的 Socks-VPS 版本发布。

初版不在 VPS 上定时更新规则，也不建立第二个规则来源。

## 6. 来源防火墙

### 6.1 采用防火墙的原因

Go 服务拒绝连接时，TCP 三次握手已经由内核完成。TCP 扫描方可以确认端口
开放；主动探测方还可能通过 SOCKS 方法协商或认证响应识别服务。因此，
应用层拒绝不能实现“CN 来源在探测阶段看不到开放服务”。

nftables 在输入链丢弃匹配来源的 TCP 报文。命中规则的 CN IPv4 来源收不到
`SYN-ACK`，无法完成 TCP 握手，连接表现为超时，流量不会到达 Go 服务。

IPdeny CN 表示其当前归类到中国大陆的 IPv4 地址集合，不是 GFW 探测节点
名单。初版保证命中该集合的来源在 TCP 握手前被丢弃；不声称覆盖来源不在
该集合内的探测节点。

### 6.2 规则边界

项目创建独立的 `table ip socks_vps`：

```nft
table ip socks_vps {
    set cn_ipv4 {
        type ipv4_addr
        flags interval
    }

    chain input {
        type filter hook input priority -10
        ip saddr @cn_ipv4 tcp dport <SOCKS_PORT> counter drop
    }
}
```

完整集合元素由发布包内的 `cn-aggregated.zone` 生成。规则只匹配当前 SOCKS
TCP 端口和 CN IPv4 来源。

项目不添加全局 `accept`，不改变主机默认策略，不绕过 nftables、firewalld、
UFW 或云防火墙。未命中 CN set 的流量继续由主机现有规则处理。

### 6.3 所有权与失败行为

`cn_ipv4` set 使用固定注释作为所有权标记：

- table 不存在时创建。
- 标记匹配时允许以单个 nftables transaction 完整替换。
- 同名 table 存在但标记不匹配时视为外部资源，安装或更新停止。
- 卸载只删除已确认由 Socks-VPS 拥有的 table。

主服务必须依赖防火墙服务并在规则加载成功后启动。规则首次加载失败时，
Go 服务不得监听；运行中规则重建失败时停止主服务。主服务停止或意外退出
时撤销项目自有规则，避免留下与实际监听状态不一致的项目规则。

## 7. 安装与生命周期

公开入口只提供一条版本化 Bash 安装命令。安装包必须先完成成员和摘要校验，
再进入交互流程。

首次安装顺序：

1. 校验发布包、系统、架构和 systemd。
2. 收集端口、用户名和密码。
3. 展示将创建的 Socks-VPS 自有资源并请求确认。
4. 获取 root 权限。
5. 只读检查监听端口、现有防火墙、路由和 WARP VPS Manager 共存状态。
6. 安装缺少的 nftables、`ss` 和证书系统依赖。
7. 检查路径、账户、端口和 nftables table 冲突。
8. 写入完整版本目录、配置和两个 systemd units。
9. 先启动来源防火墙，再启动并验证 Go 服务。
10. 只有服务、端口、配置和自有规则全部符合目标状态时报告成功。

再次运行入口提供状态、更新、重装和可恢复卸载：

- 更新保留端口和凭据，替换完整版本。
- 重装重新收集端口和凭据。
- 更新与重装前保存配置、units、完整程序和规则数据。
- 卸载先停止主服务和防火墙，确认监听与自有 table 已撤销，再把自有文件
  移入带时间戳的备份。
- 恢复只使用备份内保存的版本和规则，不从外部重新获取。

## 8. 与 WARP VPS Manager 共存

Socks-VPS 使用独立资源：

- systemd：`socks-vps.service`、`socks-vps-firewall.service`
- nftables：`table ip socks_vps`
- 配置：`/etc/socks-vps`
- 程序：`/usr/local/lib/socks-vps`
- 入口：`/usr/local/bin/socks-vps`
- 备份：`/var/backups/socks-vps`

WARP VPS Manager 的服务、端口、网卡、路由、`table inet warp_vps`、配置和
状态全部视为外部资源。Socks-VPS 只能只读识别冲突，不得停止、替换、删除
或借用这些资源。

## 9. 实施顺序

1. 定义 IPv4-only 配置、目标过滤和错误契约。
2. 实现真实 IPv4 绑定检查、自动端口选择和冲突报告。
3. 实现 SOCKS5 用户名/密码认证、TCP `CONNECT` 和连接生命周期。
4. 将 IPdeny CN aggregated 数据、来源记录和维护脚本纳入仓库。
5. 实现 nftables 完整规则生成、所有权判断、应用和撤销。
6. 建立防火墙与主服务的 systemd 启停和失败传播关系。
7. 实现安装、更新、重装、可恢复卸载和恢复。
8. 构建 `amd64`、`arm64` 版本包并校验包内程序、规则、文档和摘要一致。
9. 完成本地自动化检查和真实 Linux VPS 验收。

## 10. 验收基线

### 10.1 自动化检查

- 自动端口跳过系统保留端口和真实占用端口。
- 自动候选在特权阶段被占用后重新选择。
- 手动端口冲突停止安装且不改变端口。
- 服务只建立 IPv4 监听，只处理已认证的 TCP `CONNECT`。
- IPv6、UDP、`BIND` 和非公网 IPv4 目标被拒绝。
- CN zone 只包含规范 IPv4 CIDR，并与来源摘要一致。
- nftables 规则只作用于 CN 来源和当前 SOCKS 端口。
- 外部同名 nftables table 不被修改或删除。
- 发布包包含程序、安装器、units、四个 IPdeny 文件、许可和完整摘要。
- 运行时安装与服务路径不访问 `ipdeny.com`。

### 10.2 真实 VPS 验收

- APT 与 DNF/YUM 系统。
- `amd64` 与 `arm64`。
- 首次安装、重复运行、重启、更新、重装、卸载和恢复。
- SOCKS 认证成功与失败、TCP 隧道、上游不可达和 DNS `A` 记录。
- 自动端口、手动端口冲突和服务启动时端口竞争。
- CN set 命中来源无法完成 TCP 握手，未命中来源可到达 SOCKS 认证。
- nftables reload/restart、UFW、firewalld 和云防火墙共存。
- 与 WARP VPS Manager 同机运行时双方服务、端口、网卡、规则和生命周期
  互不影响。
- 真实 CN/GFW 来源验证必须与本地 network namespace 规则模拟分开记录。

## 11. 初版完成条件

以下条件全部满足后，初版可以发布：

- 自动端口不会选择检查时已占用或被系统保留的端口。
- 手动端口保持用户输入，冲突时给出可执行的占用信息。
- 对外能力严格限制为 IPv4 SOCKS5 TCP `CONNECT`。
- 命中 IPdeny CN IPv4 set 的来源在 TCP 握手前被丢弃。
- IPdeny 数据只由维护者更新，并与程序通过同一个版本包交付。
- 防火墙不可用时主服务不对外监听。
- 安装、更新、重装、卸载和恢复只管理 Socks-VPS 自有资源。
- 发布包检查和与风险匹配的真实 VPS 验收通过。
