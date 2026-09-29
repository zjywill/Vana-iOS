import Foundation
import AgentRuntime

/// 引擎在一轮回复中吐出的事件:文本增量,或一次工具调用的开始与结束,以及整轮结束。
///
/// 开始和结束分开发:工具跑起来先让界面有反应,结果回来再补上——合成一个事件的话,
/// 慢查询期间界面上什么都不会动。
typealias AgentEvent = AgentTurnEvent

enum AgentError: LocalizedError {
    case needsAPIKey
    case needsModelSelection
    case cloudService(String)
    case incompleteResponse
    case contextWindowExceeded

    var errorDescription: String? {
        switch self {
        // 说清楚**下一步做什么**,不是只报一句缺什么:这两句出现的时候,用户手上除了
        // 一颗解不掉它的「重试」什么都没有(气泡底下那颗按钮这时候换成「去设置」)。
        case .needsAPIKey: "还没配置云端 API key。到设置里填一把，再选 provider 和模型，就能开始问了。"
        case .needsModelSelection: "还没选好云端模型。到设置里的「模型」那一行选一个，就能开始问了。"
        case .cloudService(let message): "云端服务返回错误：\(message)"
        case .incompleteResponse: "模型回复没有正常结束，请重试"
        case .contextWindowExceeded: "这一次要带的内容太多，超出了模型的上下文上限。把这条消息或附件缩短一点再试一次。"
        }
    }

    /// runtime 的错误是英文、中立的(它不知道自己在给谁跑);中文文案属于这一层。
    ///
    /// 取消不翻译——上层要靠 `CancellationError` 区分"用户按了停止"和"真出错了"。
    static func wrapping(_ error: any Error) -> any Error {
        switch error {
        case let agentError as AgentError:
            return agentError
        case is CancellationError:
            return error
        case let loopError as AgentLoopError:
            switch loopError {
            case .service(let message): return AgentError.cloudService(message)
            case .contentFilter: return AgentError.cloudService("模型因安全策略拒绝了这次请求")
            case .incompleteResponse: return AgentError.incompleteResponse
            case .contextWindowExceeded: return AgentError.contextWindowExceeded
            }
        default:
            return error
        }
    }
}

extension ModelSummarizer {
    /// 中文的总结提示。摘要是发给模型看的,和对话同语言才不会平白多一层翻译损耗。
    ///
    /// 「保留什么、丢什么」写得很具体是有原因的:说得笼统模型就只会写一段客套的概述,
    /// 把真正要留的数字丢掉——那样压缩就等于失忆。
    static func vana(client: any AgentModelClient) -> ModelSummarizer {
        ModelSummarizer(
            client: client,
            instruction: """
                你在压缩一段日常助手的对话，好让它能在更小的上下文窗口里继续。
                只输出两段，各自用标签包起来：

                <visible>一句话给用户看的回顾：到目前为止聊过什么。</visible>
                <replay>给接着聊下去的助手看的要点笔记，严格用这几个小标题：
                \(sections)
                数字原样保留，不要四舍五入。可以丢掉：寒暄、重复的提问、已经被结论概括掉的逐行原始数据。\
                写成笔记，不要写成文章。某个小标题下没内容就写「（无）」。</replay>

                不要编造对话里没有的事实。
                """,
            updateInstruction: """
                你在维护一份日常助手对话的滚动摘要。给你的是上一版摘要，和它之后新发生的对话。
                只输出两段，各自用标签包起来：

                <visible>一句话给用户看的回顾：到目前为止聊过什么。</visible>
                <replay>更新后的要点笔记，严格用这几个小标题：
                \(sections)
                上一版摘要里仍然成立的内容必须全部带过来——原始对话已经不在了，你丢掉的就永久丢了。\
                再把新对话并进去：查完的结论并入「已有结论」，「待跟进」按最新情况改写。\
                数字原样保留，不要四舍五入。写成笔记，不要写成文章。</replay>

                不要编造上一版摘要和新对话里都没有的事实。
                """,
            requestFormat: "下面是要压缩的对话：\n\n%@",
            updateRequestFormat: """
                <previous-summary>
                %1$@
                </previous-summary>

                这版摘要之后新发生的对话：

                %2$@
                """,
            fallbackVisibleFormat: "早先的 %d 条对话已折叠"
        )
    }

    /// 「保留什么、丢什么」写得很具体是有原因的:说得笼统模型就只会写一段客套的概述,
    /// 把真正要留的数字丢掉——那样压缩就等于失忆。固定小标题是同一件事的更硬的写法。
    private static let sections = """
        ## 用户目标
        ## 用户的情况与偏好（用户说过的限制、习惯、在意的事）
        ## 已有结论（连同支撑它的具体数字）
        ## 查询轨迹（调用过哪个工具、参数是什么、返回了什么）
        ## 待跟进（用户接下来大概要问什么）
        """
}

extension ContextPolicy {
    /// 工具返回的多是聚合值和摘要,一次调用几百字就到头了。留 6000 字符是
    /// 给「查一整年」这种问法的余量,同时挡住任何一次调用把整个窗口吃掉。
    ///
    /// 截断提示跟对话同语言——它是发给模型看的。
    static let vana = ContextPolicy(
        toolOutputTruncationNotice: "…（结果过长已截断：省略 %d 字，原文共 %d 字。需要更细可以缩小时间范围再查一次）"
    )
}

/// 模型在发工具调用时被输出上限截断,顶替执行结果的那句话。
///
/// 参数可能只写了一半,照着执行等于拿错的日期去查——查出来的数字看着很正常,但是错的。
/// 不执行,原样告诉模型让它重发一次。
let truncatedToolCallNotice = """
    这次调用没有执行：上一条回复达到了输出长度上限，参数可能不完整。请用完整的参数重新调用一次。
    """

extension TranscriptCompactor {
    /// 折叠提示是要发给模型看的,所以跟对话同语言。
    static let vana = TranscriptCompactor(
        maxCharactersPerToolCall: 180,
        maxToolCallsInDigest: 6,
        digestHeaderFormat: "[这一轮折叠了 %d 次工具调用，只保留要点]",
        truncationSuffix: "…（已截断）",
        overflowFormat: "（另有 %d 次查询未列出）"
    )
}

/// 对话引擎统一接口。UI 层只认这个协议和 AgentEvent,不感知引擎差异。
/// 当前唯一实现是 AIKitEngine(端上 FoundationModels 引擎暂时移除,见 PLAN.md M3)。
protocol AgentEngine: Sendable {
    var name: String { get }

    /// 这个引擎背后的模型看得了图吗。
    ///
    /// 问引擎而不是问 `EngineSettings`:决定要不要带上原图的那一步,必须和**真正要跑这一轮
    /// 的那个模型**对上。设置里写的是下一次新建引擎会用哪个模型,而这一轮手上的可能是别的
    /// (注入的、后台派生的)。两者一旦分叉,带出去的图就会发给一个收不了图的 endpoint,
    /// 那是一个 400,而这条对话从此发不出去。
    var supportsVision: Bool { get }

    /// 发送一轮对话,流式返回事件。工具调用在引擎内部完成。
    ///
    /// - Parameter pendingInput: 用户在这一轮跑的过程中补的话从哪儿取。给 nil 就是
    ///   「这一轮只有开头那一句」——后台派生的那几轮(没有用户在场)走的正是这条。
    func reply(
        to history: [ChatMessage],
        pendingInput: AgentPendingInputProvider?
    ) -> AsyncThrowingStream<AgentEvent, Error>

    /// 每一轮请求都要带、但不在消息列表里的那部分(system 段、工具定义)大概占多少 token。
    /// 窗口从预算里先扣掉它(`ThreadWindow.evict`)。
    func requestOverheadTokens() -> Int
}

extension AgentEngine {
    func reply(to history: [ChatMessage]) -> AsyncThrowingStream<AgentEvent, Error> {
        reply(to: history, pendingInput: nil)
    }

    /// 默认按**看不了**算。多带一张图给一个收不了图的模型是一个 400;少带一张,用户最多
    /// 接着用文字描述,而那本来就是这个 app 一直以来的样子。
    var supportsVision: Bool { false }

    func requestOverheadTokens() -> Int { 0 }
}
