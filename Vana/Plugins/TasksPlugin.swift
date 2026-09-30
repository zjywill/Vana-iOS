import Foundation
import AgentRuntime

/// 提醒、目标、现在几点。核心插件,任何 Vana 都带着。
///
/// - 写的那几个声明 `.writeLocal`:不留痕浮层和后台那几轮都不挂——不该在用户不在场时替他设提醒。
/// - 以前还有 `start_task`(派后台任务),2026-09-30 连同子 agent 撤掉了:独立的活由用户自己开侧聊。
/// - 进行中的目标(≤5 条,一行一个)**常驻 system 段**易变区——以前「目标」是一条专属的会话线;
///   现在只有一条对话,模型随时知道他在推进什么,目标一变只打掉尾巴。
struct TasksPlugin: AgentPlugin {
    let id = "tasks"
    let env: TasksEnvironment

    func tools(context: PluginContext) -> [PluginTool] {
        PluginTool.from(TasksTools.registry(env)) { name in
            TasksTools.readTools.contains(name) ? [.read] : [.writeLocal]
        }
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
