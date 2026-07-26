# Socks-VPS handoff 时间线

这里是三层 handoff 的历史层，也是维护规则的唯一权威：

1. [`../../HANDOFF.md`](../../HANDOFF.md)：当前活跃 handoff，只保留一份。
2. 本文件：按时间倒序记录历史节点和简短改动总结。
3. [`archive/`](archive/)：保存每一份已经结束的完整 handoff。

换代时先把旧的活跃 handoff 完整归档，再重写活跃 handoff，最后在本时间线
顶部增加一条记录。归档文件不跟随当前状态追改；若发现历史描述有误，在
当前活跃 handoff 和时间线说明修正。

## 时间线

### 2026-07-26 · v1.0.4 · 当前

采用 MIT License，并让源码、发布包和安装后的版本目录都携带项目
`LICENSE`。建立当前活跃 handoff、历史时间线和完整归档三层结构；原测试
VPS 的 SSH 主机密钥变化，因此本版本只完成本地发布包验收，未继续远端写入。

- 当前交接：[`../../HANDOFF.md`](../../HANDOFF.md)

### 2026-07-26 · v1.0.3

修复 Ubuntu 22.04 nft JSON 缺少 table 注释导致的所有权误判；协调原生
nftables reload/restart/stop，规则重建失败时停止 SOCKS 监听。完成
Ubuntu 22.04 amd64、UFW、故障注入和资源占用实测。

- 完整归档：[`archive/2026-07-26-v1.0.3.md`](archive/2026-07-26-v1.0.3.md)

### 2026-07-26 · v1.0.2

发布包移除 macOS 扩展属性、ACL 和 file flags，避免 Linux 解包出现宿主
元数据警告；代理运行行为不变。

- 完整归档：[`archive/2026-07-26-v1.0.2.md`](archive/2026-07-26-v1.0.2.md)

### 2026-07-26 · v1.0.1

关闭 Go VCS stamping，使发布构建不依赖工作目录是否已经初始化 Git，
继续保持锁定源码重建一致性；代理运行行为不变。

- 完整归档：[`archive/2026-07-26-v1.0.1.md`](archive/2026-07-26-v1.0.1.md)

### 2026-07-26 · v1.0.0

首次公开发布 IPv4-only、TCP `CONNECT`、RFC 1929 认证、IPdeny CN 集合、
独立 nftables 表和可恢复生命周期。

- 完整归档：[`archive/2026-07-26-v1.0.0.md`](archive/2026-07-26-v1.0.0.md)

### 2026-07-26 · v1.0.0 发布候选

从空项目完成 Go 服务、安装/更新/卸载、发布包和本地测试；当时真实 VPS、
公开 HTTPS 发布和项目许可证仍未完成。

- 完整归档：[`archive/2026-07-26-v1.0.0-release-candidate.md`](archive/2026-07-26-v1.0.0-release-candidate.md)

### 2026-07-26 · 实施方案定稿

确定公网 IPv4、TCP `CONNECT`、RFC 1929、IPdeny CN bundled data、
项目自有 nftables、自动/手动端口规则和 WARP 完全隔离的实施边界。

- 完整归档：[`archive/2026-07-26-approved-v1-plan.md`](archive/2026-07-26-approved-v1-plan.md)
- 冻结基线：[`../initial-baseline.md`](../initial-baseline.md)

### 2026-07-26 · 架构与参考审计

纠正最初采用 Xray-core 的方向，确认 Socks-VPS 必须是独立内核；CNipblocker
和 233boy/Xray 只作为来源阻断与生命周期参考。

- 完整归档：[`archive/2026-07-26-architecture-audit.md`](archive/2026-07-26-architecture-audit.md)

## 历史来源

前三份规划与候选交接根据当时任务记录回填；v1.0.0–v1.0.3 根据 Git tag、
commit、GitHub Release 和测试记录回填。它们在本结构建立前并不是仓库内
已有文件，归档中均保留这一事实。
