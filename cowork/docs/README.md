# Socks-VPS 文档索引

| 主题 | 入口 |
|---|---|
| 安装、产品能力、公开命令 | [根 README](../../README.md) |
| 项目范围与当前阶段 | [background](../background.md) |
| 项目规则 | [rules](../rules.md) |
| 系统适配、安装体验、资源所有权、生命周期、验收 | [implementation-preferences](implementation-preferences.md) |
| 2026-07-26 冻结的初版目标 | [initial-baseline](initial-baseline.md)，用于理解历史决定，不回写后续产品变化 |
| IPdeny 数据与版权 | [SOURCE.json](../../assets/ipdeny/SOURCE.json)、[Copyrights](../../assets/ipdeny/Copyrights.txt)、[THIRD_PARTY_NOTICES](../../THIRD_PARTY_NOTICES.md) |
| 待办、历史与经验 | [todo](../todo.md)、[timeline](timeline.md)、[pitfalls](pitfalls.md)、[error](../error/README.md) |

公开源码与文档范围由精确文件清单审阅。新增测试或交付资料先按 [SOCKS-TEST-01](../todo.md) 完成可共享性核对。

## 发布边界

项目为 SOCKS 服务，不提供网站或仓库静态文件服务。版本包使用固定成员清单，仅包含程序、安装脚本、systemd、规则、许可和面向使用者的 README；AGENTS 与 cowork 不进入安装包。协作 Markdown 在 Git 仓库中阅读。
