# Socks-VPS 实现与交付索引

核心协议与资源边界见[根AGENTS](../AGENTS.md)。

| 工作 | 资料 |
|---|---|
| 系统适配、依赖、交互和生命周期 | [实现偏好](docs/implementation-preferences.md) |
| 当前安装与公开命令 | [README](../README.md) |
| 初版目标与后续变动 | [冻结基线](docs/initial-baseline.md)、[时间线](docs/timeline.md)及其历史交接索引 |
| 当前验证缺口与源码共享 | [todo](todo.md) |

Linux验收覆盖systemd、端口、路由、防火墙、真实流量与同机共存，不能由本地Shell、mock或单元测试替代。文案先说明使用结果和最短入口；安装/状态提示、选择和失败诊断按实现偏好的对应合同维护。

本机仍保留未公开的构建/发布门禁与测试源码，路径不迁入cowork；是否共享由SOCKS-TEST-01跟踪。公共资料不依赖这些文件作为可点击入口。完整文档与维护约定见[索引](docs/README.md)。
