# Socks-VPS 项目背景

Socks-VPS 在 Linux VPS 上提供需要用户名/密码的 IPv4 SOCKS5 TCP `CONNECT` 服务，支持多组独立端口与凭据、逐端口大陆来源设置和中文管理。

- 仓库：[mqfut123/Socks-VPS](https://github.com/mqfut123/Socks-VPS)，公开仓库，项目位于根目录。
- 迁移读取基线：`7ec1d3d`（2026-09-05）。
- 最近已记录发布：[v1.3.1](https://github.com/mqfut123/Socks-VPS/releases/tag/v1.3.1)；该次公开发布与资产回验已完成，版本验收范围见 [timeline](docs/timeline.md)。
- Outline：未上线，暂无需阅读和更新。

## 实现与交付

| 路径 | 职责 |
|---|---|
| `cmd/socks-vps/`、`internal/` | Go 服务、配置、来源规则、端口、目标过滤与转发 |
| `scripts/bootstrap.sh`、`scripts/install.sh` | 版本包入口、交互与生命周期 |
| `scripts/firewall.sh` | Socks-VPS 自有 nftables 规则 |
| `packaging/systemd/` | 服务单元 |
| `assets/ipdeny/` | 随版本交付的 CN 数据、来源摘要和版权 |

服务只连接批准的公网 IPv4 目标，域名使用 A 查询；不提供 UDP、IPv6 或匿名访问。IPdeny 数据由维护者更新并随项目版本发布，VPS 生命周期只读取包内数据。公开命令与当前产品行为以 [根 README](../README.md) 和源码为准。

Socks-VPS 与 WARP VPS Manager 独立维护，可能同机运行；资源所有权与共存要求见 [rules](rules.md) 及 [实现偏好](docs/implementation-preferences.md)。

历史初版基线已冻结，不能代表后续多配置、可选大陆阻断或永久卸载的现行行为；通过 [文档索引](docs/README.md) 区分当前规则与历史决定。当前验收事项统一见 [todo](todo.md)。
