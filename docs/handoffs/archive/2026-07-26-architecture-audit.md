# Socks-VPS 架构与参考审计 handoff

日期：2026-07-26
状态：历史回填；本阶段只完成审计和方案收敛，没有实现、Git 仓库或发布。

## 当时目标

研究 CNipblocker 与 233boy/Xray，形成一个公开的一键 SOCKS5 项目。项目
需要低资源占用、systemd 自启动、中国大陆来源阻断，并与 WARP VPS Manager
完全共存。

## 关键纠正

最初方案错误地把“参考 233boy 生命周期”扩大成采用 Xray-core。用户明确
要求这是独立内核，因此最终边界改为：

- 不引入 Xray 二进制、配置、运行时或协议实现。
- 233boy/Xray 只参考 systemd 自启动、失败重启和管理交互。
- CNipblocker 只参考“来源 CIDR 集合 + 指定监听端口阻断”概念。
- 不复制上游的全局 iptables/ipset 状态、远程脚本执行或不完整卸载路径。

## 已确定产品方向

- 首版只提供 IPv4 和 TCP `CONNECT`。
- 使用 SOCKS5 用户名/密码认证。
- IPv6、UDP、BIND 和额外协议不进入首版。
- 中国大陆来源规则使用 IPdeny CN IPv4 aggregated 数据。
- 规则由项目维护并随仓库和版本包交付，VPS 不单独访问 IPdeny。
- 手动端口冲突时报告占用者并停止；自动端口只选择未占用候选。
- 所有 Socks-VPS 服务、配置、端口和防火墙对象必须独立于 WARP。

## 上游审计结论

CNipblocker 当时实现依赖全局 ipset/iptables、包管理器覆盖有限、更新只增
不删、存在非 HTTPS fallback 且没有完整许可证，因此不能直接复制。

233boy/Xray 提供了成熟的服务生命周期参考，但其远程脚本、弱下载校验、
root 服务、多协议复杂度和 Xray 核心均不符合本项目边界。

## 未完成

- 没有创建 Go 源码、安装器、测试或发布包。
- 没有初始化 Git 或创建远端。
- 没有 Linux systemd、nftables、真实流量或资源占用证据。

后续实施方案取代了本阶段的初始路径。当前状态只以根目录 `HANDOFF.md`
为准。
