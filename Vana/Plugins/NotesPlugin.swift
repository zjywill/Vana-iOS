import Foundation
import AgentRuntime

/// 笔记与清单:用户自己要留着的内容(购物单、想法、草稿)。按需读写,**不常驻上下文**;
/// 它自己存着这些,所以让记忆抽取器让路(购物单不是「关于他的事」)。
struct NotesAgentPlugin: AgentPlugin {
    let id = "notes"
    let store: NoteStore

    var memoryExclusions: [String] { ["购物单、待办清单、草稿这类他要留着的内容（有笔记存着）"] }

    func tools(context: PluginContext) -> [PluginTool] {
        PluginTool.from(NotesTools.registry(store: store)) { name in
            NotesTools.readTools.contains(name) ? [.read] : [.writeLocal]
        }
    }

    func promptBlocks(context: PluginContext, mountedTools: Set<String>) -> [PromptBlock] {
        guard mountedTools.contains(NotesTools.list) else { return [] }
        let writes = mountedTools.contains(NotesTools.save)
            ? "用户要你记下购物单、行李单、想法、草稿时，用 \(NotesTools.save) 存成笔记或清单；"
                + "要往里加东西、勾掉、改写，用 \(NotesTools.update)。"
            : ""
        return [PromptBlock(
            order: PromptOrder.guideNotes,
            text: "用户有自己的笔记和清单，不在你的上下文里，需要时才读：他提到「我记的那个清单」「上次写的草稿」，"
                + "先用 \(NotesTools.list) 找、再用 \(NotesTools.read) 读，不要凭印象说里面写了什么。\(writes)"
                + "笔记是他的内容，记忆是关于他这个人的事实（偏好、家人、习惯），两者不要混：购物单不是记忆。"
        )]
    }
}

struct NotesVanaPlugin: VanaPlugin {
    var manifest: PluginManifest {
        PluginManifest(
            id: PluginIds.notes,
            name: String(localized: "笔记与清单"),
            summary: String(localized: "购物单、想法、草稿，让 Vana 按需读写"),
            icon: "note.text",
            defaultEnabled: true
        )
    }

    var surfaces: [PluginSurface] {
        [PluginSurface(
            id: PluginSurface.notes,
            title: String(localized: "笔记与清单"),
            subtitle: String(localized: "自己记，或者让 Vana 帮你记"),
            icon: "note.text"
        )]
    }

    var welcomeBlurb: String? { String(localized: "记购物清单和想法") }

    func agentPlugins(_ env: PluginEnvironment, route: PluginRoute) -> [any AgentPlugin] {
        // 只前台挂:后台那几轮没有理由读他的清单。
        guard route == .foreground, let store = env.notes else { return [] }
        return [NotesAgentPlugin(store: store)]
    }
}
