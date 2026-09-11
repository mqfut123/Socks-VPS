# Socks-VPS 错误记录

## v1.3.1 连接与生命周期修复

发生与修复日期：2026-09-05。源代码修复提交：[fce6a75](https://github.com/mqfut123/Socks-VPS/commit/fce6a75241352709f9c00cfc2e6580d0c8ca1f05)。

| 现象与影响 | 复现或原因 | 处理与当次验证 |
|---|---|---|
| 一侧 TCP RST 后另一侧连接滞留 | relay 忽略 `io.Copy` 错误并继续等待 | 实际复制错误关闭双方，正常 EOF 保留半关闭；本机真实 TCP 与定向回归通过。 |
| 首个公网 A 地址不响应时后续地址无机会 | 所有 numeric-IP 拨号共享截止时间，首地址消耗预算 | 在既有循环分配剩余时间，保留总期限；可控 dialer 覆盖首超时、后成功与父取消。 |
| 认证自检失败仍显示正常 | Bash 条件调用抑制 errexit，后续检查覆盖结果 | 两个配置入口显式传递 self-check 失败，Shell 函数级回归通过。 |
| nft 查询失败被当作表已撤销 | 对查询退出码直接取反 | 复用既有 `capture_existing_table`，仅确认 absent 才成功；nft 故障模拟通过。 |

发布与验证层次见 [timeline](../docs/timeline.md)；剩余实机验收统一见 [todo](../todo.md)。新增问题记录版本、现象、复现与影响、证据、判断、处理和验证，不在错误正文另维护任务状态。
