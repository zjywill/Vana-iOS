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
| 后台任务：确认卡、只读、隔离、提议、预算、一次一件、同意闸 | 2026-09-30 撤掉(方案 §16.7) | — |
| `fetch_url` 的地址规矩 | `Vana/Search/WebFetch.swift`（`FetchURLPolicy`、`DirectWebFetch`） | ✓ |
| 笔记：按需、无删除工具、`memoryExclusions` | `Vana/Notes`、`NotesPlugin` | ✓ |
| 每条出设备的路过同意闸 | `CloudAccess`（前台）/ `CloudAccess.backgroundSettings()`（后台） | ✓ |
| 隐私说明中英两份 + 告知屏 | `Vana/Legal`，`ComplianceTests` | ✓ |

## 侧聊(方案 §16,iOS 先行)

| 期 | 状态 |
|---|---|
| S1 存储、列表、空白侧聊、各自窗口、说明块、收割与清理覆盖侧聊、离开即停 | ✓ 2026-09-30(`Vana/Thread/SideChatStore`、`Vana/Chat/SideChatListView`、`ChatViewModel(sideChat:)`) |
| S2 「在侧聊里接着聊」、「带回主对话」、离开后接着写完 + 未读点 | ✓ 2026-09-30(`SideChatQuote`、`SideChatHost`、`ChatMessage.Provenance`) |
| S3 跨线程召回、主对话里的侧聊名单块 | ✓ 2026-09-30(`HistoryRecallTools.Source`、`RecallReach`、`ChatViewModel.recallSetup`) |
| S4 撤掉子 agent + 告知对齐 | ✓ 2026-09-30(目标的「每周回顾」换成「在侧聊里聊这个目标」) |

S2 和方案不一样的两处:入口在回复底下那颗「⋯」里,和「删除这一问一答」在一起(方案写的是长按;回复气泡本来就
没有长按菜单,操作都收在那颗「⋯」里);搬过去的正文
最长 3000 字(它要进另一条线的窗口)。

S1 落地时和方案不一样的一处:侧聊的名字上限分了两档(自动起名 20 字、他自己打的 40 字符),见 `CLAUDE.md`「侧聊」一节。
隐私说明中英两份里「只有一条持续的对话」改成了「一条主对话加上你自己开的侧聊」,生效日期改为 2026-09-30。

## 和 Android 不一样的地方

- **健康插件多一样 Apple 健康**（`HealthDataPlugin`，只有机主有）。Android 那边的「测量卡片」iOS 没有——
  iOS 的数字从 HealthKit 来。
- **提醒**用 `UNCalendarNotificationTrigger`，系统保证时刻，所以没有「可能晚几分钟」那句。
- ~~**后台任务的存活**~~：后台任务 2026-09-30 撤掉了（方案 §16.7）。侧聊关掉时回复照样写完，app 切到后台
  之后和主对话一样，靠系统给的那几十秒。
- **读网页的内网防护**：URLSession 没有可替换的 DNS 钩子，所以连接之前自己 `getaddrinfo` 一遍，
  每一跳重定向都重新解析（自动跳转在 delegate 里关掉）。解析和连接之间换了地址（DNS rebinding）这一种
  挡不住——Android 的 `Dns` 钩子能挡，这里有意接受：只读、只收文字、不带任何凭据。
- **首屏那段话**（`HealthStatusView`）挪进了「今天」，是健康插件贡献的第一行。
- **「今天」从对话那一列里拿出来了**（2026-09-30，iOS 先行）：和任务页合成单独一页 `TodayView`，入口是顶栏
  那颗带角标的按钮（不上 tab bar）。方案里写的「首页是聊天 + 今天卡片」在 iOS 这一侧不再成立，理由见
  `CLAUDE.md`「提醒、目标、「今天」」。
- **用药焦点**不再另开一条线，是下一轮的一次性焦点（`ChatViewModel.openMedication`）。
- **Siri**（`AskVanaIntent`）落进那条线程，回答正在写时当成插话排队。

## 升级时会发生什么

旧版本的会话文件（`sessions/`）和它们的照片在第一次启动新版本时**整个删掉，不迁移**（`LegacySessions`）。
记忆、用药表、成员名单不动。这是和 Android 同一个决定：迁移要把几百条会话的工具轨迹重新排进一条线里，
而那份历史对新的窗口和召回几乎没有用处。
