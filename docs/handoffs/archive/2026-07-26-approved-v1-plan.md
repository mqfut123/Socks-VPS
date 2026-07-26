# Socks-VPS v1 实施方案 handoff

日期：2026-07-26
状态：历史回填；方案已经批准，当时尚未开始实现。

## 目标边界

- Linux VPS 公网监听 `0.0.0.0`，全链路仅 IPv4。
- 只接受 SOCKS5 TCP `CONNECT`。
- 只接受 RFC 1929 用户名和密码认证。
- 只连接公网 IPv4 目标。
- IPdeny CN IPv4 aggregated 来源在 TCP 握手前由 nftables drop。
- Go 服务不重复判断 CN 来源。
- 与 WARP VPS Manager 完全独立。

## 计划结构

- `cmd/socks-vps`：程序入口。
- `internal/config`：配置读取和校验。
- `internal/server`：认证、请求处理和双向转发。
- `internal/target`：A 记录解析及公网 IPv4 判断。
- `internal/firewall`：自有 nftables 配置生成和所有权检查。
- `internal/port`：手动冲突检查和自动端口选择。
- `assets/ipdeny`：原始 CN 数据、版权和来源记录。
- `packaging/systemd`、`scripts`、`tests`：服务、生命周期和验收。

## 协议和目标策略

- 锁定 `github.com/go-gost/gosocks5` 版本，只用于 RFC 1928/1929 报文解析。
- 项目自己实现最小 handler，不使用依赖默认转发。
- BIND、UDP ASSOCIATE 和 IPv6 ATYP 返回准确 SOCKS 错误。
- 域名只查询一次 A 记录，检查后直接连接已通过的 IPv4，避免二次解析。
- 出站固定 `tcp4`，并设置握手、认证和目标连接期限。
- 私网、回环、链路本地、云元数据、IANA 特殊用途和 VPS 本机地址全部拒绝。

## 配置和端口

唯一权威配置为 `/etc/socks-vps/config.json`，保存 schema、固定监听地址、
已确定端口、用户名、密码和安装版本。

手动端口使用正式 IPv4/TCP bind 语义检查，冲突时显示进程、PID 和可识别
systemd unit 后停止。自动端口排除已监听和系统保留端口，以最终正式 bind
为权威，只在明确的地址占用错误时换候选。

## 防火墙和生命周期

- 独立使用 `table ip socks_vps` 与 CN IPv4 interval set。
- 规则只匹配当前 SOCKS TCP 端口，不添加全局 accept。
- 完整 nft batch 先做语法检查，再原子提交。
- 防火墙服务先于主服务；防火墙失败时主服务不启动。
- 更新保留端口和凭据；卸载只移动自有资源到可恢复备份。

## 发布和验收

公开入口只下载一个版本化发布包和对应 SHA-256。归档必须包含二进制、
units、IPdeny 数据、许可、安装器和版本信息；安装、启动和更新不访问
IPdeny。

计划要求本地测试、双架构包校验以及 APT/DNF、amd64/arm64、真实来源、
firewalld/UFW、WARP 同机的真实 VPS 验收分别记录，不得互相替代。

当前实现与完成状态只以根目录 `HANDOFF.md` 为准。
