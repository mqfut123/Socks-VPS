# Socks-VPS 时间线

| 日期 | 事件与证据 |
|---|---|
| 2026-07-26 | 冻结 IPv4 SOCKS5 / TCP CONNECT 与包内 IPdeny 的 [初版基线](initial-baseline.md)；后续不回写此历史文档。 |
| 2026-08-03 | `a1cdb85` 对应 [v1.3.0](https://github.com/mqfut123/Socks-VPS/releases/tag/v1.3.0)，收紧生命周期所需依赖的检查范围。 |
| 2026-09-05 | `fce6a75` 修复 TCP RST 滞留、多地址拨号预算、自检失败传播、nft 查询失败判断；`7ec1d3d` 更新 README，并发布 [v1.3.1](https://github.com/mqfut123/Socks-VPS/releases/tag/v1.3.1)。 |
| 2026-09-11 | 原项目规则迁入 rules，通用实现偏好与冻结基线迁入 cowork/docs；统一根 AGENTS 和协作结构，公开源树精确清单仅加入已审阅文档。 |

## v1.3.1 验证范围（2026-09-05 交接）

当次记录：macOS arm64 / Go 1.26.3 的六包、89 个顶层测试及 race 通过；八组 Shell 回归通过。TCP RST 使用本机真实连接复现，正常 EOF 后 73 KiB 响应完整转发；多地址使用可控 dialer，Shell 状态与 nft 故障使用函数级模拟。完整 ShellCheck 仍有既有告警，未放松规则。

两个 Linux 架构正式包完成成员、摘要、锁定依赖、精确二进制重建、README 和 bootstrap 一致性核对；GitHub 五项正式资产回下载与本地一致，当时的 Latest 与 main/tag 回读通过。

当次没有 Linux VPS 写入验收；后续实际验收在 [SOCKS-ACCEPT-01](../todo.md) 记录。这些是当次交付事实，不表示本次协作迁移重新运行了发布或流量测试。
