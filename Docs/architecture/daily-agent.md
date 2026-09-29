# 日常 agent：iOS 落地记录

方案和决策记录在 Android 那边（`../Vana-Android/docs/architecture/daily-agent-plan.md`），对账清单是
`../Vana-Android/docs/architecture/ios-parity.md`。这里只记 iOS 这一侧**怎么落的**，以及和清单有出入的地方。
设计理由写在 `CLAUDE.md` 对应的几节里，这份不重复。

## 对账（`ios-parity.md` 的「必须一致」）

| 条目 | iOS 落在哪 | 状态 |
|---|---|---|
| 一条对话，旧存储不迁移、首次清掉 | `Vana/Thread/ThreadStore`、`LegacySessions` | ✓ |
| 窗口：35% 预算、12k–32k、砍到 40%、轮边界、固定开销先扣、超限留两轮重试 | `AgentRuntime/WindowPolicy`、`ThreadWindow`、`ChatViewModel.advanceWindow` / `runTurnShrinkingOnOverflow` | ✓ |
| 聊天路径不主动摘要 | `AIKitEngine`（`summarizer: nil`） | ✓ |
| 召回只在有原文滑出窗口时挂、只搜用户说的话 | `HistoryRecallTools`、`RecallPlugin` | ✓ |
| 主动消息折进下一条用户消息、≥6 小时时间标记 | `HistoryMarkers` | ✓ |
| 记忆按水位线收割、和窗口解耦 | `MemoryHarvester` | ✓ |
| 「不留痕」是浮层 | `ChatViewModel(isEphemeral:)`，`ChatView` 里的 `fullScreenCover` | ✓ |
| 核心不认识领域、健康关掉无健康词 | `CoreInstructions`、`HealthInstructions`、`AssemblyContractTests` | ✓ |
| 工具声明副作用，按 `PluginContext` 统一过滤 | `AgentRuntime/AgentPlugin`（`ToolEffect`、`PluginHost`） | ✓ |
| system 段按会不会变分区、精确时间走 `get_current_time` | `PromptOrder`、`TasksTools` | ✓ |
| 记忆 v2 种类、固定中文标签、episode 规则 | `MemoryItem`（`MemoryKind`）、`MemoryStore` | ✓ |
| 提醒不调模型、挂钟时间、补响标「错过」 | `ReminderRules`、`ReminderScheduler` | ✓ |
| 「今天」零模型调用、插件贡献卡片 | `Vana/Today`、`VanaPlugin.todayCards` | ✓ |
| 目标 ≤5、常驻易变区、手动和工具同一批上限 | `TaskStore`、`TaskActions`、`TasksPlugin` | ✓ |
| 后台任务：确认卡、只读、隔离、提议、预算、一次一件、同意闸 | `Vana/Tasks/Subagent.swift`、`SubagentScheduler.swift` | ✓ |
| `fetch_url` 的地址规矩 | `Vana/Search/WebFetch.swift`（`FetchURLPolicy`、`DirectWebFetch`） | ✓ |
| 笔记：按需、无删除工具、`memoryExclusions` | `Vana/Notes`、`NotesPlugin` | ✓ |
| 每条出设备的路过同意闸 | `CloudAccess`（前台）/ `CloudAccess.backgroundSettings()`（后台） | ✓ |
| 隐私说明中英两份 + 告知屏 | `Vana/Legal`，`ComplianceTests` | ✓ |

## 和 Android 不一样的地方

- **健康插件多一样 Apple 健康**（`HealthDataPlugin`，只有机主有）。Android 那边的「测量卡片」iOS 没有——
  iOS 的数字从 HealthKit 来。
- **提醒**用 `UNCalendarNotificationTrigger`，系统保证时刻，所以没有「可能晚几分钟」那句。
- **后台任务的存活**：跑的时候申请 `beginBackgroundTask`，被系统收走的那件下次回到前台接着排。
  **没有上 `BGProcessingTask`**：和 Android 那边一样，先看真有没有人总在任务跑到一半时切走 app。
- **读网页的内网防护**：URLSession 没有可替换的 DNS 钩子，所以连接之前自己 `getaddrinfo` 一遍，
  每一跳重定向都重新解析（自动跳转在 delegate 里关掉）。解析和连接之间换了地址（DNS rebinding）这一种
  挡不住——Android 的 `Dns` 钩子能挡，这里有意接受：只读、只收文字、不带任何凭据。
- **首屏那段话**（`HealthStatusView`）挪进了「今天」条，是健康插件贡献的第一张卡。
- **用药焦点**不再另开一条线，是下一轮的一次性焦点（`ChatViewModel.openMedication`）。
- **Siri**（`AskVanaIntent`）落进那条线程，回答正在写时当成插话排队。

## 升级时会发生什么

旧版本的会话文件（`sessions/`）和它们的照片在第一次启动新版本时**整个删掉，不迁移**（`LegacySessions`）。
记忆、用药表、成员名单不动。这是和 Android 同一个决定：迁移要把几百条会话的工具轨迹重新排进一条线里，
而那份历史对新的窗口和召回几乎没有用处。
