import Foundation
import AgentRuntime
import AIKit

typealias TurnContextSnapshot = TurnContextSnapshotDTO
typealias TurnState = StoredAgentTurn.State

/// 一次工具调用的完整记录:调用本身和它的结果。
///
/// 聊天气泡和详情面板都认这层 app 自己的结构;真正回放给模型的 transcript 存在
/// `ChatMessage.storedTurn` 里,会话文件里没有任何 AIKit 类型。
struct ToolCallRecord: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let name: String
    let input: String
    var output: String?
    var report: HealthReport?
    /// 这一轮挑中的动作(`suggest_exercises`)。卡片照着它渲染。
    ///
    /// 存 id 不存整条:库跟着 app 走,旧会话里的 id 万一被删了,那张卡不出现就是了——
    /// 而存下整份步骤会让每条会话都带上一份动作库的副本。
    var exerciseIDs: [String]?
    /// `ask_user` 这一轮摆出去的那个问题。卡片照着它渲染。
    var askQuestion: AskUserQuestion?
    /// 他在那张卡上按了什么。**工具跑完时是 nil,他点了才写进来**——所以它和上面那几个
    /// 不一样,不来自 `metadata`,而是 app 这一侧后来补上去的(见 `ChatViewModel.answerAsk`)。
    ///
    /// 跟着会话落盘:不存的话,三天前答过的问题重开会话时会变回一张还能点的卡。
    var askAnswer: AskUserAnswer?
    var isError: Bool
    /// 发起这次调用的那一刻,正文已经写到第几个字。
    ///
    /// 气泡按它把一轮摊回**发生顺序**(见 `ChatMessage.turnSegments`)。模型这一轮实际是
    /// 交错的——说一句、查一次、再说一句——而 `text` 是一个一直往后接的字符串、`toolCalls`
    /// 是一个数组,两边各存各的,交错关系除了这一个数字没有别的地方记着。
    /// (`storedTurn.exactTranscript` 里有,但那份是给模型回放的,而且要等整轮结束才落下来。)
    ///
    /// 可空:这个字段是后加的,之前存下来的会话里没有——那些会话退回"chip 全排在正文前面"
    /// 的老排法,不去猜一个位置。猜错的表现是一段话被切在莫名其妙的地方。
    var textOffset: Int?
    /// 同上,思考写到第几个字。
    ///
    /// 思考和正文是两条独立的流,同一轮里各长各的,所以要各记一个。少了这一个,一条回复里
    /// 那四五轮思考会全被拼进顶上那**一颗** chip——而它们之间连个分隔都没有,上一轮的
    /// 「I'll do them one at a time.」和下一轮的「Sleep data: 3 nights recorded」直接粘成
    /// 一个病句。屏幕上还看不出哪一轮想过、哪一轮没想。
    var reasoningOffset: Int?

    init(
        id: String,
        name: String,
        input: String,
        output: String? = nil,
        report: HealthReport? = nil,
        exerciseIDs: [String]? = nil,
        askQuestion: AskUserQuestion? = nil,
        askAnswer: AskUserAnswer? = nil,
        isError: Bool = false,
        textOffset: Int? = nil,
        reasoningOffset: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.output = output
        self.report = report
        self.exerciseIDs = exerciseIDs
        self.askQuestion = askQuestion
        self.askAnswer = askAnswer
        self.isError = isError
        self.textOffset = textOffset
        self.reasoningOffset = reasoningOffset
    }

    /// 三种 metadata 并存在同一个字段上是安全的:必填键不一样,互相解不出来
    /// (`HealthReport` 要 `title`,`ExerciseSelection` 要 `moveIDs`,`AskUserQuestion`
    /// 要 `question` + `options`)。加第四种时先确认这一条还成立。
    var metadataValue: RuntimeJSONValue? {
        if let report { return HealthReport.encodeForToolMetadata(report) }
        if let exerciseIDs {
            return ExerciseSelection.encodeForToolMetadata(.init(moveIDs: exerciseIDs))
        }
        if let askQuestion { return AskUserQuestion.encodeForToolMetadata(askQuestion) }
        return nil
    }

    /// 同 `ChatMessage.rendersIdentically`。`report` 只比行数:它和 `output` 是
    /// `finishToolCall` 里一次写进去的,`output` 变了这条自然就不等了,而逐小时序列
    /// 逐点比一遍是这里唯一真正贵的操作。
    func rendersIdentically(to other: ToolCallRecord) -> Bool {
        id == other.id
            && name == other.name
            && isError == other.isError
            && output == other.output
            && report?.rows.count == other.report?.rows.count
            && exerciseIDs == other.exerciseIDs
            && askQuestion == other.askQuestion
            // 他点完那张卡,卡上的勾和底下那行字都要跟着变。漏掉这一项,表现就是点了没反应。
            && askAnswer == other.askAnswer
            // 它决定这颗 chip 插在正文的哪儿。写进去之后就不会再变,但漏掉这一项的话,
            // 那次改变永远刷不出来。
            && textOffset == other.textOffset
            && reasoningOffset == other.reasoningOffset
    }
}

extension ToolCallRecord {
    /// 这次调用在气泡上出不出胶囊。
    ///
    /// `ask_user` 成功的那次不出:它的结果就是下面那张卡,而一颗写着「问了你一个问题」的
    /// chip 顶在一个问题上面是纯噪声。参数不合法的那次照出——那时候卡画不出来,不留一点
    /// 痕迹的话屏幕上就是模型莫名其妙地卡了一下。
    ///
    /// 不出胶囊的那条**也不在正文里切一刀**(见 `ChatMessage.turnSegments`):屏幕上没有
    /// 任何东西落在那个位置,切开只会让一段话在莫名其妙的地方断开。
    var showsChip: Bool { askQuestion == nil }
}

/// 一条回复摊回发生顺序之后的一段。
enum TurnSegment: Identifiable {
    case reasoning(String, index: Int)
    case text(String, index: Int)
    case tool(ToolCallRecord)

    /// 流式期间最后一段文本一直在长,所以按**序号**发 id,不按内容——按内容的话每来一个字
    /// 都是一条新身份,SwiftUI 会把那段整个拆掉重建。
    var id: String {
        switch self {
        case .reasoning(_, let index): "reasoning-\(index)"
        case .text(_, let index): "text-\(index)"
        case .tool(let call): call.id
        }
    }
}

struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    /// **用户打的字**,不含照片识别出来的那几段。
    ///
    /// 发给模型的是 `modelText`(它把附件的文本接在后面)。分开存不是重复:标题、召回索引
    /// (`SessionIndexEntry.userText`)、记忆抽取要的都是他自己说的那句话——把几千字的化验单
    /// 掺进去,会话列表上的标题会变成一行血常规,常驻内存的那份索引也跟着胖一个数量级。
    var text: String
    /// 随这句话拍进来的照片。识别出来的文字在每一条里,图片在 `AttachmentStore`。
    var attachments: [ChatAttachment]
    /// `text` 是 app 写给用户的占位("已停止回复"/"无法回复：…"),不是模型说的话。
    ///
    /// 有这个标记,runtime 判断该不该回放时就不用去比对某句中文——那句话属于 app。
    var textIsPlaceholder: Bool
    /// 模型这一轮的思考,几段拼在一起。没有思考(或者模型不吐思考)时是空串。
    ///
    /// 存盘:重开一条老会话时思考还在,和刚聊完时看到的是同一屏。它和
    /// `storedTurn.exactTranscript` 里的 `.reasoning` 是同一段话的两种形态——那份带
    /// provider metadata,要原样发回给模型;这份是纯文本,只给人看。
    var reasoning: String
    var toolCalls: [ToolCallRecord]
    var storedTurn: StoredAgentTurn
    var errorDescription: String?
    /// 这条是用户在上一条回复还在跑的时候补发的,还没进过任何一次请求。
    ///
    /// 打出去的字必须马上看得见,所以气泡立刻就在;但模型还没看见它。两种状态一定要分得开
    /// ——猜错的那个方向恰好是最糟的(以为说了,其实没说)。什么时候翻面由
    /// `AgentPendingInputProvider` 说了算:被取走的那一刻就是它进上下文的那一刻。
    var isQueued: Bool
    /// 这条消息是什么时候产生的。
    ///
    /// 可空:这个字段是后加的,之前存下来的会话里没有——与其编一个时间,不如在菜单里
    /// 不显示。
    var createdAt: Date?

    /// 这条气泡里的字是不是**模型真的写的**。
    ///
    /// 「以上由 AI 生成」那句标注挂在第一条这样的消息下面。报错和占位那两种气泡也是
    /// assistant,但它们是 app 自己写的——在它们下面标一句「AI 生成」,是拿一句诚实的话去说
    /// 一件不实的事,而这句标注的全部作用就是它可信。
    var isModelWritten: Bool {
        role == .assistant && !textIsPlaceholder && errorDescription == nil && !text.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case attachments
        case textIsPlaceholder
        case reasoning
        case toolCalls
        case storedTurn
        case errorDescription
        case isQueued
        case createdAt

        // 旧会话格式:transcript 曾经直接落的是 AIKit 的 Message。
        case replayMessages
        case finishReason
        case usage
        case context
        case turnState
    }

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        attachments: [ChatAttachment] = [],
        textIsPlaceholder: Bool = false,
        reasoning: String = "",
        toolCalls: [ToolCallRecord] = [],
        storedTurn: StoredAgentTurn = .init(),
        errorDescription: String? = nil,
        isQueued: Bool = false,
        createdAt: Date? = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.textIsPlaceholder = textIsPlaceholder
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.storedTurn = storedTurn
        self.errorDescription = errorDescription
        self.isQueued = isQueued
        self.createdAt = createdAt
    }

    init(_ dto: AgentChatMessageDTO) {
        id = dto.id
        role = Role(dto.role)
        text = dto.text
        // DTO 那份的 `text` 已经是拼好的模型文本(`modelText`),再挂一次附件就会把识别出来的
        // 那几段写两遍。附件本来也只有 app 这一侧认得。
        attachments = []
        textIsPlaceholder = dto.textIsPlaceholder
        reasoning = dto.reasoning
        toolCalls = dto.toolCalls.map(ToolCallRecord.init)
        storedTurn = dto.storedTurn
        errorDescription = dto.errorDescription
        // 排队是 app 这一侧的事:runtime 那边只认「取走了没有」,取走之前它压根不知道
        // 有这条消息。从 DTO 转回来的一律是已经发出去的。
        isQueued = false
        createdAt = dto.createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        attachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        textIsPlaceholder = try container.decodeIfPresent(Bool.self, forKey: .textIsPlaceholder) ?? false
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        toolCalls = try container.decodeIfPresent([ToolCallRecord].self, forKey: .toolCalls) ?? []
        errorDescription = try container.decodeIfPresent(String.self, forKey: .errorDescription)
        // 停止回复时队列里剩下的那几条会**带着排队状态存下来**——用户打的字不能替他扔掉。
        // 重开这条会话,它们还排在那儿,按一下发送就出去。
        isQueued = try container.decodeIfPresent(Bool.self, forKey: .isQueued) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)

        // 要问 `contains`,不能用 `try? decodeIfPresent`:键不存在时后者是"成功地解出了 nil",
        // 一样会走进这个分支,底下的旧格式就永远读不到了。
        if container.contains(.storedTurn) {
            self.storedTurn = (try? container.decode(StoredAgentTurn.self, forKey: .storedTurn)) ?? .init()
            return
        }

        // 旧格式:把 AIKit 的消息翻成 app 自己的 transcript,之后就再也不碰 AIKit 类型了。
        let replayMessages = ((try? container.decodeIfPresent([AIKit.Message].self, forKey: .replayMessages)) ?? [])
            .map(\.agentTranscriptMessage)
        let finishReason = (try? container.decodeIfPresent(FinishReason.self, forKey: .finishReason)) ?? nil
        let usage = (try? container.decodeIfPresent(Usage.self, forKey: .usage)) ?? nil
        let context = (try? container.decodeIfPresent(TurnContextSnapshot.self, forKey: .context)) ?? nil
        let turnState = (try? container.decodeIfPresent(TurnState.self, forKey: .turnState)) ?? nil

        self.storedTurn = .init(
            exactTranscript: .init(messages: replayMessages),
            finishReason: finishReason?.agentFinishReason,
            usage: usage?.agentUsage,
            state: turnState,
            context: context
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        if !attachments.isEmpty {
            try container.encode(attachments, forKey: .attachments)
        }
        try container.encode(textIsPlaceholder, forKey: .textIsPlaceholder)
        if !reasoning.isEmpty {
            try container.encode(reasoning, forKey: .reasoning)
        }
        try container.encode(toolCalls, forKey: .toolCalls)
        try container.encode(normalizedStoredTurn, forKey: .storedTurn)
        try container.encodeIfPresent(errorDescription, forKey: .errorDescription)
        if isQueued {
            try container.encode(isQueued, forKey: .isQueued)
        }
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

extension ChatMessage {
    var turnState: TurnState? {
        get { storedTurn.state }
        set { storedTurn.state = newValue }
    }

    var finishReason: AgentFinishReason? { storedTurn.finishReason }
    var usage: AgentUsage? { storedTurn.usage }
    var context: TurnContextSnapshot? { storedTurn.context }

    /// 这条消息的结尾处折叠掉了它上面的一整段。
    ///
    /// 只认跨多条的 artifact:单条那种是发请求时按预算临时决定的,下一轮可能就不压了,
    /// 不该在界面上留痕。整段摘要是实打实存下来的,回不去了,得让用户看见。
    var foldedSpan: CompactionArtifact? {
        guard let compaction = storedTurn.compaction,
              compaction.sourceMessageIDs.count > 1 else {
            return nil
        }
        return compaction
    }

    /// 这一轮按**发生顺序**摊平:说了一段、查了一次、又说了一段。
    ///
    /// 气泡原来是写死的三段——思考 chip、**所有**工具 chip、**整段**正文——而模型这一轮实际
    /// 是交错的。两处代价:
    ///
    /// - **跳动**。每发起一次调用,一颗 chip 插进正文**上方**,底下已经写好的十几行整个往下
    ///   挪一次;工具返回时 chip 里的转圈换成「N 行 ›」,再挪一次。三次查询就是六次位移,
    ///   而滚动是贴着底的,眼里就是整段字在原地弹。
    /// - **因果反了**。模型写完「现在查这三项：」才去查,而那三颗 chip 在这句话**上面**;
    ///   查完之后的结论又直接接在同一段末尾,和查询前的话粘成一整段。
    ///
    /// 按顺序摊开之后,新东西永远追加在**末尾**,上面的一个像素都不动。
    ///
    /// 没有 `textOffset` 的那几条(旧会话)排在最前面,退回老排法:位置是真的不知道,
    /// 而猜错的表现是一段话被切在莫名其妙的地方。
    var turnSegments: [TurnSegment] {
        let chips = toolCalls.filter(\.showsChip)
        var segments: [TurnSegment] = []

        var text = Splitter(source: self.text, kind: TurnSegment.text)
        var think = Splitter(source: reasoning, kind: TurnSegment.reasoning)

        // 旧会话里这两样都没有位置,退回原来的排法:思考一颗 chip 打头,工具 chip 跟在
        // 后面,正文最后。**思考在前**——它原来就是气泡里的第一样东西。
        let anchored = chips.contains { $0.reasoningOffset != nil }
        if !anchored {
            think.appendRest(to: &segments)
        }
        segments += chips.filter { $0.textOffset == nil }.map(TurnSegment.tool)

        for call in chips where call.textOffset != nil {
            // 思考排在这一轮的正文**前面**:模型先想、再说,最后才发起这次调用。
            if anchored, let offset = call.reasoningOffset {
                think.append(upTo: offset, to: &segments)
            }
            text.append(upTo: call.textOffset ?? 0, to: &segments)
            segments.append(.tool(call))
        }

        // 收尾:最后一次调用之后的那一轮。它也是唯一可能还在写的那一轮。
        if anchored {
            think.appendRest(to: &segments)
        }
        text.appendRest(to: &segments)
        return segments
    }

    /// 按字符位置把一条累积的流切成几段。思考和正文各走一份——它们是两条独立的流。
    private struct Splitter {
        let source: String
        let kind: (String, Int) -> TurnSegment

        private var cursor: String.Index
        private var placed = 0
        private var index = 0

        init(source: String, kind: @escaping (String, Int) -> TurnSegment) {
            self.source = source
            self.kind = kind
            cursor = source.startIndex
        }

        mutating func append(upTo offset: Int, to segments: inout [TurnSegment]) {
            // 撤字(重试前那次 `.textRolledBack` / `.reasoningRolledBack`)之后 offset 会指到
            // 末尾之外;夹住之后还要单调不减,否则一份被改过的会话文件能把正文切成乱序。
            let clamped = min(max(offset, placed), source.count)
            placed = clamped
            emit(through: source.index(source.startIndex, offsetBy: clamped), to: &segments)
        }

        mutating func appendRest(to segments: inout [TurnSegment]) {
            emit(through: source.endIndex, to: &segments)
        }

        /// 切点落在换行后面时这一段会以空行开头,那会在 chip 底下多撑出一截空白。
        /// 只裁换行——前导空格在 markdown 里是有意义的(缩进代码块)。
        private mutating func emit(through end: String.Index, to segments: inout [TurnSegment]) {
            guard cursor < end else { return }
            let chunk = String(source[cursor..<end]).trimmingCharacters(in: .newlines)
            cursor = end
            guard !chunk.isEmpty else { return }
            segments.append(kind(chunk, index))
            index += 1
        }
    }

    /// 有一次调用还没回来。
    ///
    /// 摊平之后它就是最后一段,自己带着转圈排在整条回复的最底下——底部那个"还在进行"的
    /// 指示器这时候不用再出一个(见 `MessageBubble.showsTrailingIndicator`)。
    var hasRunningToolCall: Bool {
        toolCalls.contains { $0.output == nil }
    }

    /// 这条气泡上有没有东西给用户看。
    ///
    /// 用来判断一条被插话劈开的回复,前半段值不值得留下来——只吐了思考也算,那颗 chip
    /// 是点得开的。
    var hasVisibleTurnContent: Bool {
        !text.isEmpty || !reasoning.isEmpty || !toolCalls.isEmpty
    }

    /// 模型收到的那一份:用户打的字 + 每张照片识别出来的文本。
    ///
    /// 和气泡上显示的是**同一个来源**(`ChatAttachment.modelText` 那一支),两边各拼一遍
    /// 迟早对不上——同 `HealthReport` 的 `modelText` / 面板那套。
    var modelText: String {
        ChatAttachment.modelText(typed: text, attachments: attachments)
    }

    /// 这条消息有东西可发。
    ///
    /// 只拍了一张化验单、一个字没打也算——那时候 `text` 是空的,而他确实说了点什么。
    var hasContentToSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// 这一轮是被单轮查询次数上限截住的。
    ///
    /// 不是失败:已经查到的东西都在,只是模型还想接着查。用户需要知道这件事——不然它
    /// 看起来就是说到一半自己停了。
    var stoppedAtToolRoundLimit: Bool {
        storedTurn.finishReason?.raw == AgentLoop.toolRoundLimitReason
    }

    /// 这两条画在屏幕上会不会有区别。
    ///
    /// 给气泡判等用(`MessageBubble.==`),不是给业务逻辑用。合成的 `==` 会把 `storedTurn`
    /// 一起深比较——整份工具原文加每份 `HealthReport` 的逐小时序列,而这些界面上一个字都
    /// 不显示。流式一秒几十帧,每帧比一遍是这一屏最贵的一次白干。
    ///
    /// 加字段时记得跟上:这里漏一个,界面上就是那个字段改了不刷新。
    func rendersIdentically(to other: ChatMessage) -> Bool {
        id == other.id
            && text == other.text
            && attachments == other.attachments
            && reasoning == other.reasoning
            && errorDescription == other.errorDescription
            && createdAt == other.createdAt
            && isQueued == other.isQueued
            && stoppedAtToolRoundLimit == other.stoppedAtToolRoundLimit
            && toolCalls.count == other.toolCalls.count
            && zip(toolCalls, other.toolCalls).allSatisfy { $0.rendersIdentically(to: $1) }
    }

    /// 真的要发出去的那几张原图。
    ///
    /// 只有 OCR 一个字都没认出来、用户又自己点了「让 Vana 看这张图」的那几张在这儿
    /// (`ChatAttachment.sendsImage`),而且**顺序必须和 `modelText` 里那几句「随附的第 N 张图」
    /// 一致**——`carriesImage` 是两边共同的判据,别在其中一边另写一套条件。
    ///
    /// 图还没从盘上读回来时这里是空的,那时候 `modelText` 也不会说「原图在下面」:两句话
    /// 同源,不会出现「说了有图、其实没发」。
    var modelFiles: [AgentTranscript.FilePart] {
        attachments.compactMap { attachment in
            guard attachment.carriesImage, let payload = attachment.imagePayload else { return nil }
            return AgentTranscript.FilePart(mediaType: "image/jpeg", data: .base64(payload))
        }
    }

    /// 交给 runtime 的形态。落盘和回放走的是同一份,不会出现"存的和发的不一样"。
    var agentDTO: AgentChatMessageDTO {
        var dto = rawDTO
        dto.storedTurn = normalizedStoredTurn
        return dto
    }

    /// 不带归一化的原样转换。给 compactor 用——归一化本身要读它,不能反过来依赖归一化。
    private var rawDTO: AgentChatMessageDTO {
        AgentChatMessageDTO(
            id: id,
            role: AgentChatMessageDTO.Role(role),
            // 交给 runtime 的是拼好的那一份:照片识别出来的文字要跟着这句话一起进上下文,
            // 而 runtime 那边不认识附件(会话文件里也不该出现只有界面看得懂的类型)。
            text: modelText,
            files: modelFiles,
            textIsPlaceholder: textIsPlaceholder,
            reasoning: reasoning,
            toolCalls: toolCalls.map(\.dto),
            storedTurn: storedTurn,
            errorDescription: errorDescription,
            createdAt: createdAt
        )
    }

    /// 回合一结束就把 compaction artifact 算出来存下,而不是每次要用时现推。
    ///
    /// 现推的问题是它只能拿到当时还剩下的东西;artifact 要在信息最全的时候生成。
    private var normalizedStoredTurn: StoredAgentTurn {
        guard role == .assistant, storedTurn.compaction == nil, storedTurn.state != nil else {
            return storedTurn
        }
        var normalized = storedTurn
        normalized.compaction = TranscriptCompactor.healthChat.artifact(for: rawDTO)
        return normalized
    }
}

/// 事件怎么改状态只写在 runtime 的 `AgentTurnSink.apply` 里;这里只提供存储。
extension ChatMessage: AgentTurnSink {
    mutating func appendText(_ delta: String) {
        if textIsPlaceholder {
            text = ""
            textIsPlaceholder = false
        }
        text += delta
    }

    mutating func appendReasoning(_ delta: String) {
        reasoning += delta
    }

    mutating func startToolCall(_ record: ToolCallRecordDTO) {
        var call = ToolCallRecord(record)
        // 这两句就是整个交错顺序的全部来源:发起调用的这一刻,正文和思考各写到哪儿了。
        // 只写一次,之后再也不动——它记的是"当时",不是"现在"。
        call.textOffset = text.count
        call.reasoningOffset = reasoning.count
        toolCalls.append(call)
    }

    mutating func finishToolCall(id: String, output: AgentToolOutput, isError: Bool) {
        guard let index = toolCalls.firstIndex(where: { $0.id == id }) else { return }
        toolCalls[index].output = output.text
        toolCalls[index].report = HealthReport.decode(fromToolMetadata: output.metadata)
        toolCalls[index].exerciseIDs = ExerciseSelection
            .decode(fromToolMetadata: output.metadata)?.moveIDs
        toolCalls[index].askQuestion = AskUserQuestion.decode(fromToolMetadata: output.metadata)
        toolCalls[index].isError = isError
    }

    mutating func completeTurn(
        transcript: AgentTranscript,
        finishReason: AgentFinishReason?,
        usage: AgentUsage?,
        context: TurnContextSnapshotDTO?
    ) {
        storedTurn.exactTranscript = transcript
        storedTurn.finishReason = finishReason
        storedTurn.usage = usage
        storedTurn.context = context
        storedTurn.state = .completed
    }

    mutating func rollBackText(_ characterCount: Int) {
        guard characterCount > 0, !textIsPlaceholder else { return }
        text.removeLast(min(characterCount, text.count))
    }

    mutating func rollBackReasoning(_ characterCount: Int) {
        guard characterCount > 0 else { return }
        reasoning.removeLast(min(characterCount, reasoning.count))
    }

    mutating func acceptPendingInput(_ inputs: [AgentPendingInput]) {
        storedTurn.inlinedMessageIDs.append(contentsOf: inputs.map(\.id))
    }

    // 这两句是 app 写给用户的话,要跟着界面语言走(错误描述那半句早就本地化了,漏的只有
    // 前缀——英文界面上「无法回复： The API key was rejected…」正是 2026-08-30 逮到的样子)。
    // 回放判断靠 `textIsPlaceholder` 标记,不比对字面,所以本地化是安全的。
    mutating func markStopped() {
        if text.isEmpty {
            text = String(localized: "已停止回复")
            textIsPlaceholder = true
        }
        storedTurn.state = .stopped
    }

    mutating func markFailed(_ description: String) {
        if text.isEmpty {
            text = String(localized: "无法回复：\(description)")
            textIsPlaceholder = true
        }
        storedTurn.state = .failed
        errorDescription = description
    }
}

private extension ToolCallRecord {
    init(_ dto: ToolCallRecordDTO) {
        id = dto.id
        name = dto.name
        input = dto.input
        output = dto.output?.text
        report = dto.output.flatMap { HealthReport.decode(fromToolMetadata: $0.metadata) }
        exerciseIDs = dto.output
            .flatMap { ExerciseSelection.decode(fromToolMetadata: $0.metadata)?.moveIDs }
        askQuestion = dto.output.flatMap { AskUserQuestion.decode(fromToolMetadata: $0.metadata) }
        // 他点了什么只有 app 这一侧知道:runtime 那边从头到尾没见过这个字段。
        askAnswer = nil
        isError = dto.isError
    }

    var dto: ToolCallRecordDTO {
        ToolCallRecordDTO(
            id: id,
            name: name,
            input: input,
            output: output.map {
                AgentToolOutput(
                    kind: report == nil ? .text : .table,
                    text: $0,
                    metadata: metadataValue
                )
            },
            isError: isError
        )
    }
}

private extension ChatMessage.Role {
    init(_ role: AgentChatMessageDTO.Role) {
        switch role {
        case .user: self = .user
        case .assistant: self = .assistant
        }
    }
}

private extension AgentChatMessageDTO.Role {
    init(_ role: ChatMessage.Role) {
        switch role {
        case .user: self = .user
        case .assistant: self = .assistant
        }
    }
}
