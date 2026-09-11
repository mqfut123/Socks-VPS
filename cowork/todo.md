# Socks-VPS 待办

| 编号 | 事项 | 状态 | 执行角色 | 下一步与完成依据 |
|---|---|---|---|---|
| SOCKS-ACCEPT-01 | v1.3.1 Linux 实际验收 | 待授权测试环境 | 维护者与运维 | 核对 APT / DNF、amd64 / arm64、systemd、端口、真实 nftables 与计数、CN `n → y → n`、真实流量及同机共存；按 [实现偏好](docs/implementation-preferences.md) 记录实际环境与结果。历史版本结论不替代本版本验收。 |
| SOCKS-TEST-01 | 可复用测试与发布工具的共享交接 | 待独立审阅 | 项目维护者 | 审查现有测试和发布脚本的依赖、敏感信息及精确公开文件清单，再决定可共享范围；本次只公开已审阅的协作 Markdown。 |

## 已完成

- 2026-09-05：v1.3.1 四项修复、本地 Go/Shell 回归、正式发布和五项公开资产回读完成；依据 `fce6a75`、`7ec1d3d` 及 [时间线](docs/timeline.md)。
- 2026-09-11：建立统一 AGENTS / cowork，迁入现行实现偏好与冻结初版基线，精确 publication allowlist 加入已审阅协作文件。
