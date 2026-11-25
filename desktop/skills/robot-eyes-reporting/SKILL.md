---
name: robot-eyes-reporting
description: Report AI task lifecycle states to the local Robot Eyes desktop MCP. Use once Robot Eyes reporting has been enabled for this AI client.
---

# Robot Eyes 状态上报

使用 `robot-eyes` MCP 的 `set_eye_state`。每次传入 `state` 和 `session`。在首次上报前为任务选择一个 1 到 64 个字符的稳定 ID。同一任务在恢复、等待和结束时沿用原 ID，并行任务各用独立 ID。

| 时机 | state |
| --- | --- |
| 开始执行或从等待中恢复 | `THINKING` |
| 必须等用户确认或补充信息才能继续 | `QUESTION` |
| 完成任务，在发出最终答复前 | `DONE` |
| 因失败退出任务 | `ERROR` |
| 用户取消任务 | `STOPPED` |
| 主动清除该任务的显示 | `IDLE` |

运行或等待超过 15 分钟时，在下一次可用的执行机会续报当前状态。结束状态会保留约 30 秒，让它自然过期。客户端若提供可调用 MCP 的失败或取消钩子，可由钩子发送对应的结束状态，沿用任务的 `session`。取消已中断执行时，无法依靠对话指令补发。

MCP 暂时不可用时继续原任务，在下一次正常状态切换时再尝试。首次成功上报后，状态变化由工具调用完成，无需在答复中重复。
