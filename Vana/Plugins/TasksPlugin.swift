import Foundation
import AgentRuntime

/// 提醒、目标、现在几点、派后台任务。核心插件,任何 Vana 都带着。
///
/// - 写的那几个声明 `.writeLocal`:不留痕浮层和后台那几轮都不挂——不该在用户不在场时替他设提醒。
/// - `start_task` 另带 `.needsUser`:它只放一张确认卡、要用户点了才跑。后台路因此挂不上它,
///   后台助手不能再派后台助手。
/// - 进行中的目标(≤5 条,一行一个)**常驻 system 段**易变区——以前「目标」是一条专属的会话线;
///   现在只有一条对话,模型随时知道他在推进什么,目标一变只打掉尾巴。
struct TasksPlugin: AgentPlugin {
    let id = "tasks"
    let env: TasksEnvironment

    func tools(context: PluginContext) -> [PluginTool] {
        var tools = PluginTool.from(TasksTools.registry(env)) { name in
            TasksTools.readTools.contains(name) ? [.read] : [.writeLocal]
        }
        if env.jobs != nil {
            tools += PluginTool.from(SubagentTools.startTaskRegistry(env)) { _ in [.writeLocal, .needsUser] }
        }
        return tools
    }

    func promptBlocks(context: PluginContext, mountedTools: Set<String>) -> [PromptBlock] {
        var blocks: [PromptBlock] = []
        if mountedTools.contains(TasksTools.createReminderToolName) {
            blocks.append(PromptBlock(
                order: PromptOrder.guideTasks,
                text: "用户要你在某个时间提醒他做某件事时，先用 \(TasksTools.getTimeToolName) 知道现在几点，"
                    + "把「明晚 8 点」这类说法换算成具体时间，再用 \(TasksTools.createReminderToolName) 设好，并照实告诉他设在了什么时候。"
                    + "提醒到点只会发一条通知，不会再调用你。"
                    + "用户说想长期坚持某件事（备半马、学吉他、把作息调回来）时，可以问他要不要记成一个目标（\(TasksTools.createGoalToolName)）；"
                    + "目标有进展或改了计划时用 \(TasksTools.updateGoalToolName) 记下。"
                    + "已经不做的提醒或目标，用 \(TasksTools.updateTaskToolName) 完成或取消。"
            ))
        } else if mountedTools.contains(TasksTools.getTimeToolName) {
            blocks.append(PromptBlock(
                order: PromptOrder.guideTasks,
                text: "要知道现在几点（不只是今天几号）时调用 \(TasksTools.getTimeToolName)。"
            ))
        }
        if mountedTools.contains(SubagentTools.startToolName) {
            let web = mountedTools.contains(WebSearchTools.searchToolName)
                ? "它能上网搜索；"
                : "它现在不能上网（没配搜索），只能用记忆和过往的对话；"
            blocks.append(PromptBlock(
                order: PromptOrder.guideJobs,
                text: "遇到**独立的、要花几分钟**的事（比较几个方案、整理一个主题的资料、查一批信息），"
                    + "可以用 \(SubagentTools.startToolName) 派给后台助手，\(web)它看不到这段对话，所以 brief 要写得自足。"
                    + "它会先给用户一张确认卡，他点了才跑，做完结果会出现在对话里。"
                    + "一句话能答的、需要来回商量的、涉及他此刻感受的事，直接在对话里做，不要派。"
            ))
        }
        let goals = env.activeGoals.filter { $0.kind == .goal && $0.isActive }.prefix(TasksTools.maxActiveGoals)
        if !goals.isEmpty {
            let lines = goals.map { goal in
                var line = "- \(goal.handle) \(goal.title)"
                if !goal.why.isEmpty { line += "（\(goal.why)）" }
                line += " · \(goal.planProgress)"
                if let note = goal.notes.last { line += " · 最近进展：\(note.text.prefix(40))" }
                return line
            }.joined(separator: "\n")
            blocks.append(PromptBlock(order: PromptOrder.goals, text: "他正在推进的目标（不是每次都要提起，相关时再结合）：\n\(lines)"))
        }
        return blocks
    }
}
