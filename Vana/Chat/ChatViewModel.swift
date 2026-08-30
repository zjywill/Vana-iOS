import SwiftUI
import AgentRuntime

@MainActor
@Observable
final class ChatViewModel {
    private(set) var session = ChatSession()
    var summaries: [SessionSummary] = []
    /// 用户自己开的几件长期的事,最近动过的在前。
    var goals: [GoalSummary] = []
    var input = ""
    var isReplying = false
    /// 正在写的那条回复。事件的收件人,也是气泡判断「我是不是正在流」的依据。
    ///
    /// 不能再用 `messages.last`:用户可以在回复期间接着发消息,那几条排在正在写的这条
    /// **后面**——照旧取最后一条的话,模型吐出来的字会一个个落进用户刚打的那句话里。
    private(set) var replyingMessageID: UUID?
    var isLoadingConversation = true
    var engineGuidance: String?
    /// 他按了发送,但还没配 key。
    ///
    /// **是一次请求,不是一种状态**——界面接住它、把设置页推到他面前,然后立刻置回 false。
    /// 做成常驻状态的话,从设置页退回来那一刻它还是 true,设置页会当场再推一次。
    var needsCloudSetup = false
    /// 他按了发送,但还没同意过把数据发给当前这家 provider(`ProviderConsent`)。
    ///
    /// 存的是 provider id,界面拿它弹那个点名确认的 alert。和 `needsCloudSetup` 一样是
    /// 一次请求不是一种状态:同意或取消都当场清掉。打的字留在输入框里,同意之后再发。
    private(set) var pendingProviderConsent: String?
    /// 正在退避重试时给用户看的一句话。
    ///
    /// 退避期间界面上什么都不动的话,等十几秒和卡死是一模一样的观感——而这时候 app 其实
    /// 知道发生了什么。
    private(set) var retryNotice: String?
    /// 先给按时段挑的默认问题,AI 生成的回来了再替换。
    var suggestions = SuggestedQuestions.defaults()
    /// 首屏那句话:打开 app 先说发生了什么,不是先问他一个问题。
    ///
    /// 和 `suggestions` 同一套两级:本地那句立刻出,模型润色好了原地换掉。`nil` 只出现在
    /// 处境还没判定完的那几十毫秒里——之后它永远有内容,连"没读到值得留意的波动"都是一种
    /// 回答("要不要在意"的答案是"不用")。
    private(set) var quickSummary: String?
    /// 本地判定出来的处境。首屏那张卡点开之后,详情页要按项列出「现在是多少」——那句话是
    /// 从这里写出来的,而用户想知道的下一件事永远是"这话是根据什么说的"。
    ///
    /// 家人成员那条路上永远是 nil:`HealthSituation` 读的是机主的 HealthKit,整个不跑。
    private(set) var situation: HealthSituation?
    /// 那段话正在写。详情页那颗刷新按钮靠它转圈,也靠它挡住连按。
    private(set) var isWritingSummary = false
    /// 接着刚才那段回答问的几条追问。
    ///
    /// 空着不是错误状态,是常态的一半:还没答完、生成失败、没配 key 都是空的,那时候
    /// `ComposerBar` 用固定那几条顶上。所以这里不需要"正在生成"这种状态——多一个状态就多
    /// 一个转圈,而它转的那两秒里用户什么都不缺。
    private(set) var followUps: [String] = []
    /// 输入框上方那排还没发出去的照片。
    ///
    /// 排在这儿而不是直接变成气泡:识别要花几百毫秒,而识别错一个小数点在健康场景里不是
    /// 「有点脏数据」——他得先看见发出去的是什么,才谈得上核对。
    private(set) var draftAttachments: [DraftAttachment] = []
    /// 还有图在读或者在认。这时候发送要等一下:发出去的是空文本的话,模型只能说"没看到"。
    var isRecognizingAttachments: Bool {
        draftAttachments.contains { $0.isRecognizing || $0.isLoading }
    }
    /// 一句话最多带几张照片。
    static let maxAttachments = 6
    var canAttachMore: Bool { draftAttachments.count < Self.maxAttachments }

    /// 正在跑的识别,按附件编号存着,删掉那张就取消它。
    private var recognitionTasks: [UUID: Task<Void, Never>] = [:]

    private var currentReplyTask: Task<Void, Never>?
    /// 首屏那段话的生成。按刷新时先取消在飞的那次:两条流往同一个字段上写,后到的那片
    /// 会把先到的整段顶掉,屏幕上表现为文字来回跳。
    private var summaryTask: Task<Void, Never>?
    /// 思考的增量攒一小会儿再落盘。
    ///
    /// 思考模型一秒能吐几十个 delta,而每一次落进 `session.messages` 都是一次
    /// `@Observable` 失效:整列气泡重新判等,思考面板开着的话那一整段文字还要重新排一遍。
    /// 攒到 `reasoningFlushInterval` 再一次性落,观感是一样的(一秒十二次已经比眼睛快),
    /// 重排的次数少一个数量级。
    ///
    /// 正文不走这条:它一进来就要撤掉重试提示,而且 provider 给正文的 chunk 本来就不碎——
    /// 碎的是思考。
    private var pendingReasoning = ""
    private var reasoningFlushTask: Task<Void, Never>?
    private static let reasoningFlushInterval = Duration.milliseconds(80)
    private var hasRequestedSuggestions = false
    /// 没选话题时该显示的那几条,取消话题选择时用它复位。
    private var situationSuggestions = SuggestedQuestions.defaults()

    /// 这条会话开始时的记忆快照,**会话之内不换**。
    ///
    /// 引擎每轮现造,靠它拿到同一份 system 段:中途换记忆既打掉 prompt 缓存,也让模型对
    /// 用户的认知在一条对话里跳变。抽取写在会话结束、快照读在会话开始,正好配套——这条
    /// 会话学到的东西,下一条会话生效。
    private(set) var memory: MemorySnapshot = .empty
    /// 这条会话开始时的用药与补剂表,同样**会话之内不换**。理由和 `memory` 一样。
    private(set) var medications: MedicationSnapshot = .empty
    /// 这条会话围绕清单里的哪一条(`SessionThread.medication`)。
    private(set) var focusMedication: MedicationItem?
    /// 当前这条会话已经发过请求了。发过之后就不再换快照,哪怕后台刚抽完新记忆。
    private var didStartReplyInSession = false
    /// 抽取排成一队。两个抽取同时读同一份记忆再各写各的,会写出两条一样的。
    private var harvestTail: Task<Void, Never>?
    /// 挂在 loop 生命周期上的那几个旁观者(眼下只有追问 chip)。
    ///
    /// **一条会话一个**,换会话时整个丢掉:hook 记着"上一句问了什么",那是这条会话的事。
    /// 第一次真的要发请求时才建——没聊过的会话不该为它多做任何事。
    private var hooks: AgentHookDispatcher?

    /// 每轮现造引擎。测试注入一个脚本化的假引擎,就能在不碰 Keychain 和网络的前提下
    /// 走完整条 loop。
    typealias EngineFactory = @MainActor @Sendable (ChatTopic?) throws -> any AgentEngine

    private let engineFactory: EngineFactory?
    private let memoryStore: MemoryStore
    private let sessionStore: SessionStore
    private let medicationStore: MedicationStore
    /// 这个 view model 服务的是哪位成员。
    ///
    /// **一个 view model 一位成员,不给它换人的方法**。切成员在 `ChatView` 那边是整个换掉
    /// 这个对象(`.id(tenant.id)`),不是给它发一条「现在换成妈妈」的消息:回复可能正在飞、
    /// hook 记着上一句、四个 store 的缓存全是上一个人的东西,而漏掉其中任何一样都是把上一位
    /// 的内容端到下一位名下。换掉整个对象,这几件一次性全没了。
    private let tenant: Tenant
    /// 这位成员有没有 Apple 健康数据。**只有机主有**(见 `Tenant.Kind`)。
    var hasHealthData: Bool { tenant.isOwner }
    var currentTenant: Tenant { tenant }

    /// 导航栏副标题。成员名字和隐私状态挤在同一行。
    ///
    /// **机主不标注**。「我以为在自己这儿、其实在妈妈那儿」是这个功能最糟的失灵,而反过来那次
    /// 不会出事——所以只给家人挂一直在视线里的名字,单人用户那一屏一个字都没变。给每个人都
    /// 标上的话,那行字在 99% 的时间里说的是一件恒成立的事,人几天就不看它了,而它恰恰是要
    /// 在剩下 1% 里被看见的。
    var navigationSubtitle: String {
        var parts: [String] = []
        if !tenant.isOwner { parts.append(tenant.displayName) }
        if session.isPrivate { parts.append(String(localized: "隐私对话 · 不保存")) }
        return parts.joined(separator: " · ")
    }

    var messages: [ChatMessage] { session.messages }

    /// 还有话排着没进上下文。
    ///
    /// 回复期间由 loop 在下一个工具轮边界取走;停止回复之后队列**不会**自动清空——用户
    /// 打的字不该被替他扔掉,发送按钮会一直亮着等他决定。
    var hasQueuedInput: Bool { session.messages.contains { $0.isQueued } }

    /// - Parameters:
    ///   - loadsPersistedSession: 关掉就不读盘、不写盘,`isLoadingConversation` 直接是
    ///     false。测试用。
    ///   - memoryStore: 测试必须传自己的。app 侧的测试跑在 app host 里,
    ///     `MemoryStore.shared` 就是模拟器上那份真的 `memory.json`。
    ///   - sessionStore: 同上。`loadsPersistedSession: false` 只挡住了**写**,而延续线要
    ///     去读盘找上一段——读到用户真实的会话,测试就会把它拽进来当成自己的。
    ///   - medicationStore: 同上。`MedicationStore.shared` 是模拟器上那份真的
    ///     `medications.json`,测试写它等于把用户录的药删了。
    init(
        engineFactory: EngineFactory? = nil,
        loadsPersistedSession: Bool = true,
        tenant: Tenant = TenantScope.current,
        memoryStore: MemoryStore = .shared,
        sessionStore: SessionStore = .shared,
        medicationStore: MedicationStore = .shared
    ) {
        self.engineFactory = engineFactory
        self.tenant = tenant
        self.memoryStore = memoryStore
        self.sessionStore = sessionStore
        self.medicationStore = medicationStore
        refreshEngineAvailability()
        guard loadsPersistedSession else {
            session = ChatSession(isPrivate: true)
            isLoadingConversation = false
            return
        }
        Task {
            await loadInitialSession()
        }
    }

    /// 发一句话。**正在回复时照发不误**。
    ///
    /// 等上一句答完才能开口,是这个 app 里最不像跟人说话的一处:模型跑六轮工具要十几秒,
    /// 而人在这十几秒里想起来的那句「顺便也看看心率」根本没地方说。所以这里不再拦——
    /// 打出去的字立刻变成气泡,由 loop 在下一个工具轮边界接进上下文。
    ///
    /// 空文本也是有意义的一次调用:队列里还剩着东西时(停止回复之后),它就是「把排着的
    /// 那几句发出去」。
    func send(_ suggestedQuestion: String? = nil) {
        guard !isLoadingConversation else { return }

        // 没配 key 就别把这句话发出去。
        //
        // 发出去的结果是 provider 回一个 401,而那句报错既不是他的错,也没告诉他下一步该做
        // 什么——**2026-08-16 那次审核走的正是这条路**(Guideline 2.1(a))。原来只有
        // `sendWhenReady`(Siri 那条)挡了,手动发送这条是敞开的;而欢迎卡上那句引导排在
        // 免责声明底下、灰色小字、不可点,审核员翻都不会翻到。
        //
        // 这里**现查一次钥匙串**而不是信 `engineGuidance`:那个值只在 `onAppear` 和 init
        // 时刷新,而"刚在设置里填完 key 回来"恰好是最需要它准的那一刻。
        refreshEngineAvailability()
        guard engineGuidance == nil else {
            // 打的字留在输入框里。点 chip 进来的那句也放进去——他配完 key 回来按一下就
            // 发得出去,不用重想一遍刚才要问什么。
            if let suggestedQuestion { input = suggestedQuestion }
            needsCloudSetup = true
            return
        }

        // 第一次要发给这家 provider:先点名征一次同意(Guideline 5.1.2(i),2026-08-29 被判
        // 的正是「发送之前没问过、也没点过名」)。字留在输入框里,他在 alert 上按「同意并
        // 发送」会再回到这里,那时候这道闸已经开了。换 provider 会再问,同一家只问一次。
        //
        // 注入了假引擎就是在测试里,那条路上没有任何东西真的出设备,不拦。
        if engineFactory == nil {
            let provider = EngineSettings.selection.provider
            guard ProviderConsent.granted(provider) else {
                if let suggestedQuestion { input = suggestedQuestion }
                pendingProviderConsent = provider
                return
            }
        }

        let text = (suggestedQuestion ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        // 排在输入框上方的照片跟着下一句话一起走,不管这句话是打出来的还是点 chip 点出来的:
        // 规矩只有一条才记得住。
        let attachments = takeDraftAttachments()
        if !text.isEmpty || !attachments.isEmpty {
            input = ""
            session.messages.append(ChatMessage(
                role: .user,
                text: text,
                attachments: attachments,
                isQueued: true
            ))
        }
        // 正在回复:这一句排进队列就完了,不再开一轮。取走它的是 `takeQueuedInput`。
        guard !isReplying, hasQueuedInput else { return }
        startReply()
    }

    /// 他在点名确认的 alert 上按了「同意并发送」。记下来,然后把刚才那句发出去——
    /// 字还在输入框里,`send()` 会再走一遍,这次闸是开的。
    func confirmProviderConsent() {
        guard let provider = pendingProviderConsent else { return }
        ProviderConsent.record(provider)
        pendingProviderConsent = nil
        send()
    }

    /// 按了「取消」:什么都不发,字留在输入框里。不记录任何东西——下次按发送会再问。
    func declineProviderConsent() {
        pendingProviderConsent = nil
    }

    /// 收回一条还没进上下文的消息,文字放回输入框。
    ///
    /// 只有排队中的能收回:已经发出去的那一句模型已经看过了,从列表里抹掉它只会让屏幕上
    /// 的对话和模型记得的对话对不上。
    func withdrawQueued(_ messageID: UUID) {
        guard let index = index(of: messageID), session.messages[index].isQueued else { return }
        let message = session.messages[index]
        session.messages.remove(at: index)
        input = input.isEmpty ? message.text : "\(message.text)\n\(input)"
        // 照片也一起退回到输入框上方。只把字还回来的话,那几张图就凭空没了,而他收回这条
        // 多半正是因为发现某一页拍糊了。
        for attachment in message.attachments {
            if let documentName = attachment.documentName {
                draftAttachments.append(DraftAttachment(
                    id: attachment.id,
                    documentName: documentName,
                    text: attachment.text,
                    droppedLines: attachment.droppedLines,
                    failure: nil
                ))
                continue
            }
            guard let image = AttachmentImageCache.shared.cached(attachment.id) else { continue }
            var draft = DraftAttachment(id: attachment.id, preview: image)
            draft.text = attachment.text
            draft.droppedLines = attachment.droppedLines
            draft.isRecognizing = false
            // 「要发原图」也跟着退回来。丢掉的话他收回这条改两个字再发,那张图就悄悄不发了,
            // 而屏幕上没有一个字说过它被关掉。
            draft.sendsImage = attachment.sendsImage
            draftAttachments.append(draft)
        }
    }

    /// 他在某张 `ask_user` 卡上点完了。
    ///
    /// **走的就是 `send`**,和他自己打这几个字发出去没有任何区别——排队、劈开、存盘、会话
    /// 标题、召回索引、记忆抽取因此一条都不用改。这张卡省掉的是"想怎么描述"那一步,
    /// 不是另开一条消息通道。
    ///
    /// 先落 `askAnswer` 再发:那一下就是卡片从"能点"翻成"答过了"的时刻,而发出去的消息
    /// 在同一帧里出现在它下面。反过来的话,中间那一瞬卡还是能点的,连点两下就是两条一样的
    /// 消息。
    func answerAsk(messageID: UUID, callID: String, answer: AskUserAnswer) {
        guard !answer.isEmpty,
              let index = index(of: messageID),
              let callIndex = session.messages[index].toolCalls.firstIndex(where: { $0.id == callID }),
              session.messages[index].toolCalls[callIndex].askAnswer == nil
        else { return }

        session.messages[index].toolCalls[callIndex].askAnswer = answer
        send(answer.messageText)
    }

    // MARK: - 照片

    /// 他刚选完,先把格子摆上。返回的这几个编号就是屏幕上那几个转圈的位子。
    ///
    /// 拍的、选的、从「文件」里挑的都走这儿进来,而「摆格子」和「把东西读进来」是分开的两步
    /// ——读要几秒钟,摆是当场的。见 `AttachmentIntake`。
    @discardableResult
    func reserveAttachments(_ count: Int) -> [UUID] {
        // 一句话最多带这么多件。每件能带四千字,六件已经是一次请求里最大的一块了——
        // 而 `ContextPolicy` 那四档降级只管工具输出,拦不住用户消息。
        let room = Self.maxAttachments - draftAttachments.count
        guard count > 0, room > 0 else { return [] }
        let ids = (0..<min(count, room)).map { _ in UUID() }
        draftAttachments.append(contentsOf: ids.map(DraftAttachment.init(loading:)))
        return ids
    }

    /// 某一格的东西到齐了。
    ///
    /// 填进来的是**一组**:一份 PDF 渲染出好几页,第一页顶掉那个格子,剩下的紧跟着插在它
    /// 后面——追加到整排末尾的话,同时选两份文件时第一份的第二页会排到第二份后面去。
    ///
    /// 格子已经不在了(他等不及,按了那颗叉;或者这句话已经发出去了)就整组扔掉:那正是
    /// 他的意思,而这条也顺带挡住了「发送之后才落地的那一份」。
    ///
    /// 照片要识别,文件已经是文字了(`AttachmentImporter` 那边直接取的原文)——两条路在这里
    /// 合流,后面的排队、核对、发送、存盘就只有一套。
    func fill(_ id: UUID, with items: [PreparedAttachment]) {
        guard let index = draftAttachments.firstIndex(where: { $0.id == id }) else { return }
        guard let first = items.first else {
            draftAttachments.remove(at: index)
            return
        }

        draftAttachments[index] = draft(id: id, from: first)
        if case .photo(_, let original) = first { recognize(original, for: id) }

        var insertion = index + 1
        for extra in items.dropFirst() {
            guard draftAttachments.count < Self.maxAttachments else { break }
            let extraID = UUID()
            draftAttachments.insert(draft(id: extraID, from: extra), at: insertion)
            insertion += 1
            if case .photo(_, let original) = extra { recognize(original, for: extraID) }
        }
    }

    /// 这一件根本读不出来。
    ///
    /// 格子必须停下来说句话:一直转下去和真的卡死在屏幕上是一模一样的,而且 `isRecognizing`
    /// 还压着发送键——他会连这句话都发不出去。
    func failAttachment(_ id: UUID, message: String) {
        guard let index = draftAttachments.firstIndex(where: { $0.id == id }) else { return }
        draftAttachments[index].isLoading = false
        draftAttachments[index].isRecognizing = false
        draftAttachments[index].failure = message
    }

    private func draft(id: UUID, from item: PreparedAttachment) -> DraftAttachment {
        switch item {
        case .photo(let preview, _):
            // 气泡和输入框上方那一排都从这里取图。落盘要等到真的发出去(隐私会话则永远不落)。
            AttachmentImageCache.shared.set(preview, for: id)
            var draft = DraftAttachment(id: id, preview: preview)
            // 「每张都发原图」那档在这儿就翻过去,不等识别结果:那一档的判据里根本没有
            // 「认没认出字」。模型看不了图时不翻——`loadImagePayloads` 那边最后还会兜一道,
            // 但让屏幕上先摆一个不会发生的承诺没有道理。
            draft.sendsImage = modelSupportsVision && photoImagePolicy.sendsImageByDefault
            return draft
        case .document(let name, let text, let droppedLines, let failure):
            return DraftAttachment(
                id: id,
                documentName: name,
                text: text,
                droppedLines: droppedLines,
                failure: failure
            )
        }
    }

    /// 用户改过的那一份就是发出去的那一份。
    func updateAttachmentText(_ id: UUID, to text: String) {
        guard let index = draftAttachments.firstIndex(where: { $0.id == id }) else { return }
        draftAttachments[index].text = text
        // 他自己删掉几行之后,「后面 N 行没识别进来」那句话就不再是这段文字的实情了。
        draftAttachments[index].droppedLines = 0
    }

    func removeAttachment(_ id: UUID) {
        recognitionTasks.removeValue(forKey: id)?.cancel()
        draftAttachments.removeAll { $0.id == id }
    }

    private func recognize(_ image: UIImage, for id: UUID) {
        recognitionTasks[id] = Task {
            let result = try? await TextRecognizer.recognize(image)
            guard !Task.isCancelled,
                  let index = draftAttachments.firstIndex(where: { $0.id == id })
            else { return }
            draftAttachments[index].isRecognizing = false
            recognitionTasks[id] = nil
            guard let result else {
                draftAttachments[index].failure = TextRecognizer.Failure.unreadableImage.localizedDescription
                return
            }
            draftAttachments[index].text = result.text
            draftAttachments[index].droppedLines = result.droppedLines
        }
    }

    /// 取走这一排,变成消息上的附件。**返回即消费**,同 `takeQueuedInput`。
    private func takeDraftAttachments() -> [ChatAttachment] {
        guard !draftAttachments.isEmpty else { return [] }
        let drafts = draftAttachments
        draftAttachments = []
        recognitionTasks.values.forEach { $0.cancel() }
        recognitionTasks = [:]

        // 隐私会话不落盘,图片跟着不落——那条会话的全部意义就是不留本机痕迹。屏幕上照常
        // 看得见:内存里那份还在,关掉就没了。
        let persists = !session.isPrivate
        // JPEG 只压一次:落盘那份和发给模型那份是同一批字节,压两遍是白花几十毫秒,
        // 而这一下发生在他刚按下发送键的时候。
        let encoded = drafts.reduce(into: [UUID: Data]()) { data, draft in
            guard let preview = draft.preview else { return }
            // 没人要的那几张不压:多数照片认出了字,压出来的这份除了写盘没有第二个用处。
            guard persists || draft.sendsImage else { return }
            data[draft.id] = AttachmentImage.jpegData(from: preview)
        }
        if persists {
            persistImages(encoded)
        }
        return drafts.map { draft in
            ChatAttachment(
                id: draft.id,
                text: draft.text,
                droppedLines: draft.droppedLines,
                // 文件没有图可存,那一栏永远是 nil——气泡靠 `documentName` 认出该画文档卡。
                imageFileName: persists && !draft.isDocument
                    ? ChatAttachment.fileName(for: draft.id)
                    : nil,
                documentName: draft.documentName,
                sendsImage: draft.sendsImage,
                // 隐私会话里这就是那张图**唯一**的一份:盘上不会有,重开 app 之后也补不回来
                // ——而那条会话本来就不会被重开。
                imagePayload: draft.sendsImage
                    ? encoded[draft.id]?.base64EncodedString()
                    : nil
            )
        }
    }

    /// 写盘和这句话的发送互不相干:写失败最多是重开会话时少一张缩略图,而真正要紧的那段
    /// 识别文本存在消息里,一个字都不会丢。所以它不该挡住提问。
    private func persistImages(_ encoded: [UUID: Data]) {
        for (id, data) in encoded {
            Task {
                do {
                    try await AttachmentStore.shared.store(data, id: id)
                } catch {
                    print("保存照片失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 发请求之前对一遍要发的那几张图。
    ///
    /// 两件事,而且必须在同一个地方做——`carriesImage` 认的是 `imagePayload` 在不在,
    /// 正文里那句「随附的第 N 张图」和真的发出去的 file part 都从它来。在别处单独关掉其中
    /// 一边,就会出现「说了有图、其实没发」。
    ///
    /// **一、冷启动之后补回来。** `imagePayload` 故意不进会话文件(那是几十上百 KB 的
    /// base64,会把 `SessionIndexEntry` 那套增量索引的收益整个吃掉),所以每次重开都是空的。
    /// 补的时机是**发请求之前**,不是打开会话的时候:多数会话里一张图都没有,为一件多半不会
    /// 发生的事在打开时读盘,是让每一次切会话都多等一下。
    /// 补不回来(图被删了、写盘当时就失败了)不报错,只是这一轮退回纯文字。
    ///
    /// **二、模型换成看不了图的就把图摘掉。** 他可以在聊到一半时换模型,而这几张图是跟着
    /// 历史每一轮重发的——原样发过去是一个 400,而这条对话从此发不出去。摘掉之后正文自动
    /// 退回那句「看不了图像本身」,那正是这个模型此刻的实情。
    private func loadImagePayloads(supportsVision: Bool) async {
        // 一张说好要发的图都没有(绝大多数会话)就整段不跑:下面那两层循环要走遍全部历史,
        // 而这里跑在用户已经在等回复的时候。
        guard session.messages.contains(where: { $0.attachments.contains(where: \.sendsImage) })
        else { return }
        for index in session.messages.indices {
            for attachmentIndex in session.messages[index].attachments.indices {
                let attachment = session.messages[index].attachments[attachmentIndex]
                guard attachment.sendsImage else { continue }
                guard supportsVision else {
                    session.messages[index].attachments[attachmentIndex].imagePayload = nil
                    continue
                }
                guard attachment.imagePayload == nil,
                      let name = attachment.imageFileName,
                      let data = await AttachmentStore.shared.data(named: name)
                else { continue }
                session.messages[index].attachments[attachmentIndex].imagePayload =
                    data.base64EncodedString()
            }
        }
    }

    // MARK: - 直接发图

    /// 界面上要不要出那行「让 Vana 直接看图」。
    ///
    /// 查的是设置(`EngineSettings.modelSupportsVision`),不是 `resolveEngine()`:这个属性
    /// 跑在界面刷新的路径上,而 `resolveEngine` 每问一次就现造一个引擎。真正决定带不带图的
    /// 那一步在 `runTurn` 里问**这一轮手上的那个引擎**——两处在线上问的是同一个 provider
    /// 和同一个 model,而带出去的图必须和真的要跑这一轮的那个对上。
    var modelSupportsVision: Bool { EngineSettings.modelSupportsVision }

    /// 照片原图默认发不发。**只是默认**,每一张在核对面板里都还能单独翻。
    var photoImagePolicy: PhotoImagePolicy { EngineSettings.photoImagePolicy }

    /// 他设过一档会发原图的默认,可这个模型看不了图——那一档在这条会话里静静地不生效。
    ///
    /// 只在**真的对不上**时才有话说:设的就是「只发文字」的人不需要听这一句,而这一屏上
    /// 每多一句用不上的话,真正要紧的那句就少被读到一次。
    ///
    /// 这条路是从「在能看图的模型上设了每张都发,然后换了个模型」来的。设置存的是这台设备的
    /// 偏好,不跟着模型走——所以它一直在,只是不生效,而不生效这件事必须说出口。
    var visionUnavailableNote: String? {
        guard !modelSupportsVision, photoImagePolicy != .textOnly else { return nil }
        return String(localized: "你设的是「\(photoImagePolicy.name)」，但当前模型看不了图——这一档暂时不生效。")
    }

    /// 输入框上方那一行要说哪几张。
    ///
    /// 按当前那档默认挑(`PhotoImagePolicy.offers`),而不是死认「没认出字的」:
    /// `.always` 那档说的是「这几张原图会发出去 · 撤销」,`.textOnly` 那档一个字都不说
    /// (要发的自己去核对面板里开)。模型看不了图时同样一句话都不说——那等于摆一个按不动
    /// 的按钮。
    var imageSendCandidates: [DraftAttachment] {
        let policy = photoImagePolicy
        let candidates = draftAttachments.filter { $0.suggestsImage(under: policy) }
        guard !candidates.isEmpty, modelSupportsVision else { return [] }
        return candidates
    }

    /// 这一排里已经说好要发原图的有几张。
    var sendingImageCount: Int { draftAttachments.count { $0.sendsImage } }

    /// 整排一起翻。
    ///
    /// 一次拍三张菜、三张都没有字,让他一张一张点三下是把一个决定拆成三份同样的劳动;
    /// 真要单独控制某一张的,核对面板里那颗开关还在原位。
    ///
    /// 只翻**那一行提到的那几张**:`.askWhenNoText` 那档下面按一下「好」,不该顺手把这一排
    /// 里那张化验单也翻过去——他答应的是屏幕上写着的那句话。
    func setSendsImage(_ sends: Bool) {
        let policy = photoImagePolicy
        for index in draftAttachments.indices
        where draftAttachments[index].suggestsImage(under: policy) {
            draftAttachments[index].sendsImage = sends
        }
    }

    /// 单独一张。核对面板里那颗开关走这条。
    ///
    /// 这里认的是 `canSendImage` 不是 `suggestsImage`:那颗开关对**任何**一张读得出来的
    /// 照片都开着,认出字的也一样。默认那档不主动问它们,不等于他不许自己开——那正是
    /// 「认不出字才发」写死之后固化掉的那一格。
    func setSendsImage(_ sends: Bool, for id: UUID) {
        guard let index = draftAttachments.firstIndex(where: { $0.id == id }),
              draftAttachments[index].canSendImage
        else { return }
        draftAttachments[index].sendsImage = sends
    }

    func stopReply() {
        currentReplyTask?.cancel()
    }

    /// 重新回答某一条回复。
    ///
    /// 中间那条也能重答——从它开始后面整段都丢掉,再重新生成。不做"保留旧版本、左右
    /// 切换"那套:想留着旧的走分支就行,那本来就是分支的意思。
    func retry(_ messageID: UUID) {
        guard canRetry(messageID), let index = index(of: messageID) else { return }

        session.messages.removeSubrange(index...)
        startReply()
    }

    func canRetry(_ messageID: UUID) -> Bool {
        guard !isReplying, !isLoadingConversation, let index = index(of: messageID) else {
            return false
        }
        return session.messages[index].role == .assistant
            && session.messages[..<index].contains { $0.role == .user }
    }

    /// 从某条回复分叉出一条新会话:到这条为止的内容照搬过去,原会话原样留在列表里。
    ///
    /// 想试另一个问法又不想毁掉现在这条,走这里;愿意毁掉的走 retry。
    func branch(from messageID: UUID) {
        guard !isReplying, !isLoadingConversation, let index = index(of: messageID) else { return }

        let history = Array(session.messages[...index])
        session = ChatSession(
            messages: history,
            topicId: session.topicId,
            // 分叉出来的**不**继承延续线:两条会话都认领同一条线的话,下次 check-in 接哪条
            // 就成了看谁最后更新的,而用户完全看不出规则。分叉是"另开一支",本来就该断开。
            threadId: nil,
            // 隐私会话分叉出来的还是隐私的——说好不存就不能因为换了条会话就存了。
            isPrivate: session.isPrivate,
            // 水位跟着搬过来:这段对话原会话已经抽过了,分叉不该让它再被抽一遍。
            memoryHarvestedMessageCount: min(session.memoryHarvestedMessageCount, history.count)
        )
        Task {
            await saveSession()
        }
    }

    private func index(of messageID: UUID) -> Int? {
        session.messages.firstIndex { $0.id == messageID }
    }

    // MARK: - 会话

    /// 开一条新会话。当前这条已经存过盘,不会丢。
    func startNewSession(isPrivate: Bool = false) {
        guard !isReplying else { return }
        replaceSession(with: ChatSession(isPrivate: isPrivate), harvestingPrevious: true)
        suggestions = situationSuggestions
        Task { await refreshSummaries() }
    }

    /// 会话还空着时可以随时切换隐私与否;开聊之后就定了,不然"说好不存"会被推翻。
    func setPrivate(_ isPrivate: Bool) {
        guard messages.isEmpty, !isReplying else { return }
        session.isPrivate = isPrivate
    }

    /// 从 check-in 通知或者 Siri 进来:开一条带话题的新会话,把开场问题填进输入框。
    ///
    /// 默认不自动发送——通知是邀请不是命令,让用户看一眼再决定问不问。Siri 那条置了
    /// `autoSend`:问题已经说出口了,再要求按一次发送很没道理。
    func open(_ checkIn: CheckInLaunch) {
        guard !isReplying else { return }

        if let question = checkIn.question {
            input = question
        }
        // 说好回头看的事,这就在看了。留着它只会在接下来几天的早上重复同一句。
        if let followUpId = checkIn.followUpId {
            Task {
                _ = try? await memoryStore.delete(id: followUpId)
                refreshMemory()
            }
        }
        // 用药那边的回访同理,但**只清掉约定,不删那条记录**——那样东西他还在吃,要走的只是
        // 「回头问一句」这个约定。从详情页那颗按钮进来的不走这条路,那不是在兑现约定。
        if case .medication(let id) = checkIn.thread {
            Task {
                _ = try? await medicationStore.clearFollowUp(id: id)
                refreshMedications()
            }
        }

        // 找线程要读盘,这几十毫秒里 `sendWhenReady` 会被 `isLoadingConversation` 挡着等,
        // 正好——Siri 冷启动那条路本来就在等它。
        isLoadingConversation = true
        Task {
            var continued: ChatSession?
            if let thread = checkIn.thread {
                continued = await sessionStore.openThread(thread)
            }
            replaceSession(
                with: continued ?? ChatSession(
                    // 延续线不带话题。一条攒了四天 check-in 的会话,今天问活动量、明天问睡眠;
                    // 话题写死在 system 段里,聊到第三天就和正在问的事对不上了,而中途改它
                    // 又会让模型对这次对话的认知跳变。重点由那句开场问题自己带。
                    topicId: checkIn.thread == nil ? checkIn.topicId : nil,
                    threadId: checkIn.thread?.id
                ),
                harvestingPrevious: true
            )
            isLoadingConversation = false

            if let topic = session.topic {
                suggestions = topic.questions.map { SuggestedQuestion(icon: topic.icon, text: $0) }
            }
            if let question = checkIn.question, checkIn.autoSend {
                sendWhenReady(question)
            }
            await refreshSummaries()
        }
    }

    // MARK: - 目标线

    /// 开一条新的目标线。
    ///
    /// 这条会话空着,所以**还不会落盘**(空会话不落盘那条规矩没有例外)。用户问出第一句它才
    /// 真正存在——比在列表里先摆一条什么都没有的「减脂计划」诚实。
    func startGoal(named name: String) {
        guard !isReplying else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        replaceSession(
            with: ChatSession(threadId: SessionThread.goal(UUID()).id, threadTitle: trimmed),
            harvestingPrevious: true
        )
        suggestions = situationSuggestions
        Task { await refreshSummaries() }
    }

    /// 回到某条目标线:接得上就接着上一段聊,接不上就在同一条线上另起一段。
    ///
    /// 「另起一段」不是丢历史——上一段一条不少地留在列表和 `search_sessions` 里,模型问一句
    /// 就能翻回去。换来的是这条线不会长成一份永不结束的日志。
    func openGoal(_ goal: GoalSummary) {
        guard !isReplying, let thread = goal.thread else { return }

        isLoadingConversation = true
        Task {
            let continued = await sessionStore.openThread(thread)
            replaceSession(
                with: continued ?? ChatSession(threadId: thread.id, threadTitle: goal.title),
                harvestingPrevious: true
            )
            isLoadingConversation = false
            await refreshSummaries()
        }
    }

    func renameGoal(_ goal: GoalSummary, to name: String) {
        guard !isReplying, let thread = goal.thread else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != goal.title else { return }

        Task {
            try? await sessionStore.renameThread(thread, to: trimmed)
            // 改的可能正是当前这条。盘上改了、手里这份没改,标题栏就会一直显示旧名字。
            if session.threadId == thread.id {
                session.threadTitle = trimmed
            }
            await refreshSummaries()
        }
    }

    /// 整条删掉,包括它已经分出去的每一段。
    ///
    /// 用户是把它当成一件事在管的,删的时候也该是一件事——只删最新那段,剩下两段会以
    /// 「减脂计划 · 7月2日起」的样子留在列表里,看着像没删干净。
    func deleteGoal(_ goal: GoalSummary) {
        guard !isReplying, let thread = goal.thread else { return }
        Task {
            let isCurrent = session.threadId == thread.id
            try? await sessionStore.deleteThread(thread)
            if isCurrent {
                // 不抽记忆:用户刚把这条线删了,再从里面记下点什么是反着来的。
                let next = (try? await sessionStore.mostRecent()) ?? ChatSession()
                replaceSession(with: next, harvestingPrevious: false)
            }
            await refreshSummaries()
        }
    }

    // MARK: - 用药线

    /// 从用药详情页那颗「问问 Vana」进来。接得上就接着上一段,接不上就在同一条线上另起一段。
    ///
    /// 和 `openGoal` 同一套。**不预填问题**:预填一句「这个有什么副作用」会把对话推向一个他
    /// 可能没想问的方向,而那三条开场建议本来就按状态分好了(`MedicationItem.openingQuestions`)。
    func openMedication(_ item: MedicationItem) {
        guard !isReplying else { return }
        let thread = SessionThread.medication(item.id)

        isLoadingConversation = true
        Task {
            let continued = await sessionStore.openThread(thread)
            replaceSession(
                // 名字存在每一段的 `threadTitle` 上,同目标线:改了名字要改到每一段,
                // 但换来的是这条线的名字和内容永远在同一个文件里。
                with: continued ?? ChatSession(threadId: thread.id, threadTitle: item.name),
                harvestingPrevious: true
            )
            // 快照那条路是异步的,而这一条的 focus 我们此刻就拿在手上——不在这儿设的话,
            // 空会话的头几百毫秒里 system 段还没有它。
            focusMedication = item
            suggestions = item.openingQuestions.map {
                SuggestedQuestion(icon: item.status.icon, text: $0)
            }
            isLoadingConversation = false
            await refreshSummaries()
        }
    }

    /// 等会话载入完再发。
    ///
    /// Siri 冷启动 app 时,这一句多半赶在会话还没载入完的时候到,而 `send` 会被
    /// `isLoadingConversation` 挡掉——问题就这么无声无息地没了。宁可多等几十毫秒。
    /// 等超过一秒就放弃自动发送,把它留在输入框里:那时候多半是别的地方出了问题,
    /// 让用户自己按一下,总好过一直转圈。
    private func sendWhenReady(_ question: String) {
        // 没配 key 就别自动发了:发出去只会立刻收到一条报错,还占掉一条会话。
        guard engineGuidance == nil else { return }

        Task {
            let deadline = Date().addingTimeInterval(1)
            while isLoadingConversation, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !isLoadingConversation, input == question else { return }
            send(question)
        }
    }

    func openSession(id: UUID) {
        guard !isReplying, id != session.id else { return }
        Task {
            if let opened = try? await sessionStore.load(id: id) {
                replaceSession(with: opened, harvestingPrevious: true)
            }
            await refreshSummaries()
        }
    }

    func deleteSession(id: UUID) {
        guard !isReplying else { return }
        Task {
            try? await sessionStore.delete(id: id)
            // 删掉的正是当前这条,就换上剩下里最近的一条,没有就开新的。
            if id == session.id {
                // 不抽记忆:用户刚把这段对话删了,再从里面记下点什么是反着来的。
                let next = (try? await sessionStore.mostRecent()) ?? ChatSession()
                replaceSession(with: next, harvestingPrevious: false)
            }
            await refreshSummaries()
        }
    }

    func clearConversation() {
        guard !isReplying else { return }
        let id = session.id
        replaceSession(with: ChatSession(), harvestingPrevious: false)
        Task {
            try? await sessionStore.delete(id: id)
            await refreshSummaries()
        }
    }

    /// 选话题。只在会话还空着时能改——聊到一半换话题,前面的上下文就对不上了。
    ///
    /// 选完直接换成这个话题的默认问题:话题已经把范围说清楚了,不值得再花一次模型调用。
    func selectTopic(_ topic: ChatTopic?) {
        guard messages.isEmpty, !isReplying else { return }
        session.topicId = topic?.id
        suggestions = topic.map { chosen in
            chosen.questions.map { SuggestedQuestion(icon: chosen.icon, text: $0) }
        } ?? situationSuggestions
    }

    /// 每次启动只生成一次:模型那步是一次真实调用,不该每回到首屏就花一遍钱。
    ///
    /// 分两级:先本地判定处境(纯 HealthKit 查询,没配 key 也有),再交给模型润色成人话。
    /// 一次判定喂两个消费者——首屏那句话和下面那三条问题说的必须是同一件事,各判定一遍
    /// 迟早会在同一屏上说出两种结论。
    func refreshSuggestionsIfNeeded() {
        guard !hasRequestedSuggestions, !isLoadingConversation, messages.isEmpty else { return }
        hasRequestedSuggestions = true

        summaryTask = Task {
            // 家人成员这条路上 `HealthSituation` 整个不跑。它读的是 HealthKit,而那份数据
            // 属于机主——跑一遍拿回来的「昨晚只睡了 6.2 小时」说的是机主,却会印在妈妈的
            // 首屏上。这是 `HealthStore` 五个调用方里最容易漏掉的一个:它藏在"首屏建议"
            // 后面,看着和健康数据没关系。
            guard hasHealthData else {
                situationSuggestions = TenantOpening.questions(for: tenant, medications: medications)
                quickSummary = TenantOpening.quickSummary(for: tenant, medications: medications)
                if session.topicId == nil {
                    suggestions = situationSuggestions
                }
                return
            }
            let situation = await HealthSituation.detect(
                interests: await sessionStore.interests()
            )
            guard messages.isEmpty else { return }
            self.situation = situation
            situationSuggestions = situation.questions
            quickSummary = situation.quickSummary
            if session.topicId == nil {
                suggestions = situationSuggestions
            }

            // 同意之前一次模型调用都不发。这条跑在**启动时**、带着健康结论——正是
            // 「发送之前没问过」最实打实的一条路。本地那句和那三条本地问题已经摆上了。
            guard let settings = try? cloudSettings(),
                  ProviderConsent.granted(settings.provider) else { return }
            let suggester = QuestionSuggester(
                providerId: settings.provider,
                model: settings.model,
                situation: situation
            )
            // 并发发出去。串起来的话用户要等两次往返,而这两件事互不相干——一边失败了
            // 另一边照常换掉,各自的兜底也各自还在。
            async let generated = suggester.suggestions()
            async let written: Void = writeQuickSummary(for: situation, settings: settings)

            await written
            // 回来得太晚就别抢了——用户已经开聊或者已经自己选了话题。
            if let questions = try? await generated, messages.isEmpty {
                situationSuggestions = questions
                if session.topicId == nil {
                    suggestions = questions
                }
            }
        }
    }

    /// 重新读一遍数据、重新写一遍那段话。详情页上那颗刷新按钮。
    ///
    /// 生成这件事本来一次启动只跑一次(那是省钱的默认),但**用户对写出来的那段不满意**是
    /// 一种没有出口的处境:数据是对的,话没说到点上,而他能做的只有关掉 app 再打开。给一颗
    /// 按钮就够了——这是他自己按的,不是每回到首屏就自动花一次钱。
    ///
    /// 顺带重查一遍处境:按这颗按钮的另一半理由是"我刚同步完手表",那时候要换的是数据本身。
    func regenerateQuickSummary() {
        guard hasHealthData, !isWritingSummary else { return }

        summaryTask?.cancel()
        isWritingSummary = true
        summaryTask = Task {
            let situation = await HealthSituation.detect(
                interests: await sessionStore.interests()
            )
            guard !Task.isCancelled else {
                isWritingSummary = false
                return
            }
            self.situation = situation
            // 本地那句先换上。模型那段还没开始写,而数据可能已经变了——这几秒里让详情页
            // 里的读数和句子对不上,比多等一会儿更糟。
            quickSummary = situation.quickSummary
            // 没配 key 时这颗按钮也不是白按的:重读一遍数据本身就是它的另一半用处
            // (「我刚同步完手表」),那一半不需要模型。
            guard let settings = try? cloudSettings(),
                  ProviderConsent.granted(settings.provider) else {
                isWritingSummary = false
                return
            }
            await writeQuickSummary(for: situation, settings: settings, alreadyWriting: true)
        }
    }

    /// 流式写那段话。每一片回来就往 `quickSummary` 上换一次,详情页里看到的就是它在写。
    ///
    /// 收尾才做校验:写超了、写跑题了整段作废,退回本地那句。作废这条路是静默的,所以
    /// `QuickSummaryWriter` 那边留了一处 DEBUG 日志打模型原文。
    private func writeQuickSummary(
        for situation: HealthSituation,
        settings: (provider: String, model: String),
        alreadyWriting: Bool = false
    ) async {
        guard situation.hasSummaryFacts else {
            if alreadyWriting { isWritingSummary = false }
            return
        }
        if !alreadyWriting { isWritingSummary = true }
        defer { isWritingSummary = false }

        let writer = QuickSummaryWriter(
            providerId: settings.provider,
            model: settings.model,
            situation: situation
        )
        var latest = ""
        do {
            for try await text in writer.stream() {
                // 用户已经开聊了就撒手:首屏那张卡这会儿根本不在屏幕上,而他正在等的是
                // 另一条流。
                guard !Task.isCancelled, messages.isEmpty else { return }
                latest = text
                quickSummary = QuickSummaryWriter.partial(text)
            }
        } catch {
            quickSummary = situation.quickSummary
            return
        }
        guard !Task.isCancelled, messages.isEmpty else { return }
        if let written = QuickSummaryWriter.parse(latest) {
            quickSummary = written
        } else {
            #if DEBUG
            // 作废这条路是静默的:界面上只表现为"本地那句一直没换掉"。写长了、带了壳、
            // 分成三行写,原因只有原文说得清。
            print("[首屏那段话] 这次没能用，模型原样输出：\n\(latest)")
            #endif
            quickSummary = situation.quickSummary
        }
    }

    // MARK: - 记忆

    /// 换会话:走的那条该抽的记忆在这里抽,新的那条配一份最新的快照。
    private func replaceSession(with next: ChatSession, harvestingPrevious: Bool) {
        let previous = session
        // 接着的正是当前这条(用户已经在这条延续线里了)。不能当成"换会话"处理:那会拿它
        // 自己去抽一次记忆,还会把盘上那份盖掉刚打的字。
        guard next.id != previous.id else { return }
        session = next
        didStartReplyInSession = false
        // hook 记着的是上一条会话问到哪儿了,跟着会话一起丢。还在飞的那次生成由交付那一步
        // 的会话号挡住。
        hooks = nil
        followUps = []
        // 还没发出去的那几张图跟着走的那条会话一起丢:它们是那一刻的东西,跟到新会话里
        // 只会在他问一件别的事时莫名其妙地被一起发出去。
        recognitionTasks.values.forEach { $0.cancel() }
        recognitionTasks = [:]
        draftAttachments = []
        if harvestingPrevious {
            harvestMemory(from: previous)
        }
        refreshMemory()
        refreshMedications()
    }

    /// app 退到后台。多数会话是聊完就切走的,不在这儿抽,那段对话可能几天都轮不到抽一次。
    func harvestCurrentSessionMemory() {
        guard !isReplying else { return }
        harvestMemory(from: session)
    }

    /// 按住说话时提示给识别器的那份词表。
    ///
    /// 从**这条会话的快照**拼(`medications` / `memory`),不去读盘:词表和 system 段里那两块
    /// 是同一份材料,而按住说话的那一刻用户已经开口了,不是做磁盘 IO 的时候。两个开关也因此
    /// 自动生效——关掉记忆或用药表时那两份快照本来就是空的。
    var voiceVocabulary: [String] {
        VoiceVocabulary.terms(medications: medications, memory: memory)
    }

    private func refreshMemory() {
        guard EngineSettings.memoryEnabled else {
            memory = .empty
            return
        }
        let targetId = session.id
        Task {
            let snapshot = await memoryStore.snapshot()
            // 回来得太晚:人已经换到别的会话,或者已经在这条里问出第一句了。
            guard session.id == targetId, !didStartReplyInSession else { return }
            memory = snapshot
        }
    }

    /// 用药表的快照跟着会话换。
    ///
    /// **关掉开关只是不给模型看**,不清空盘上那份——列表页照常能看能改。这和 `memory` 的
    /// 处理一致,区别只在开关是另一个(见 `EngineSettings.medicationsEnabled`)。
    private func refreshMedications() {
        guard EngineSettings.medicationsEnabled else {
            medications = .empty
            focusMedication = nil
            return
        }
        let targetId = session.id
        // 会话属于哪一条药,由 threadId 说了算——名字会被改,id 不会。
        let focusId: UUID? = if case .medication(let id) = session.thread { id } else { nil }
        Task {
            let snapshot = await medicationStore.snapshot()
            let focus = focusId.flatMap { id in snapshot.items.first { $0.id == id } }
            // 回来得太晚:人已经换到别的会话,或者已经在这条里问出第一句了。
            guard session.id == targetId, !didStartReplyInSession else { return }
            medications = snapshot
            focusMedication = focus
        }
    }

    /// 后台抽一次记忆。全程失败即放弃——记忆学不到东西是小事,让用户这一步卡住是大事。
    private func harvestMemory(from harvested: ChatSession) {
        guard EngineSettings.memoryEnabled, MemoryHarvest.shouldHarvest(harvested) else { return }
        // 注入了假引擎就是在测试里,别真去调模型。没同意过发给这家的也不抽——能走到这儿
        // 说明对话发生过,同意几乎必然在;这一句兜的是「聊完之后换了 provider」那条缝。
        guard engineFactory == nil,
              let settings = try? cloudSettings(),
              ProviderConsent.granted(settings.provider) else { return }

        let previous = harvestTail
        let messageCount = harvested.messages.count
        harvestTail = Task {
            await previous?.value
            // 和后台派生的那一轮抢同一个位子。抢不到就这次不抽——`memoryHarvestedMessageCount`
            // 没往前走,下次切会话/退后台照样会抽到这一段,一个字都不会漏。
            await BackgroundModelWork.shared.run {
                await harvest(harvested, messageCount: messageCount, settings: settings)
            }
        }
    }

    private func harvest(
        _ harvested: ChatSession,
        messageCount: Int,
        settings: (provider: String, model: String)
    ) async {
        // 用此刻盘上的记忆,不是这条会话开始时那份快照——中间可能已经抽过别的会话了,
        // 拿旧的会把同一件事再记一遍。
        let snapshot = await memoryStore.snapshot()
        let extractor = MemoryExtractor(
            providerId: settings.provider,
            model: settings.model,
            snapshot: snapshot
        )
        guard let operations = try? await extractor.operations(from: harvested) else { return }
        _ = try? await memoryStore.apply(operations, sessionId: harvested.id)
        try? await sessionStore.markMemoryHarvested(
            id: harvested.id,
            messageCount: messageCount
        )
        refreshMemory()
    }

    /// 没配 key 时那句引导。**一处定义**:发送被挡下、欢迎卡上那条横幅、首屏那段话底下的
    /// 小字说的都是它。三处各写一句的话,它们会慢慢漂成三种说法,而用户会以为是三件事。
    static let cloudSetupGuidance = String(localized: "还没配置云端模型。到设置里填一把 API key，再选 provider 和模型，就能开始问了。")

    /// key 填好了、模型没选上时那句。和上面那句分开:两句话要他做的事不一样,而
    /// 「到设置里填一把 API key」对一个已经填好 key 的人是一句读不懂的话。
    static let modelSetupGuidance = String(localized: "还没选好云端模型。到设置里的「模型」那一行选一个，就能开始问了。")

    /// key 存在但没通过验证时那句。**一处定义**:气泡上要认出这一类失败(重试解不掉,
    /// 该去的是设置页),靠的就是和这句对上。
    static let authFailureGuidance = String(
        localized: "API key 没通过验证。请到「设置 › 云端模型」确认 key 填对了、没有过期，并且和选中的 provider 对得上。"
    )

    func refreshEngineAvailability() {
        engineGuidance = currentSetupGuidance
    }

    /// 现在这台设备配齐了没有,配不齐差的是哪一样。**纯计算,不写任何状态**——
    /// 报错气泡在 `body` 里要问它一次,而在 `body` 里改 `@Observable` 就是一次无限刷新。
    ///
    /// 问的是**「现在答不答得出来」**,不是「钥匙串里有没有东西」——注入了引擎的那条路
    /// (测试、预览)根本不走 `cloudSettings()`,拿 key 的有无去挡它,挡掉的是一个明明
    /// 跑得起来的引擎。判据必须和 `resolveEngine()` 里那个分支一致:那边抛得出两种错
    /// (没 key、没模型),这边就得挡得住两种。
    ///
    /// **模型这一条是后补的。** 只问 key 的话,模型那一格空着的人照样发得出去,换来的是
    /// 一个「需要先在设置里选择云端模型」的错误气泡加一颗按几次都一样的「重试」——
    /// 2026-08-19 那次审核看到的正是这一屏。
    private var currentSetupGuidance: String? {
        guard engineFactory == nil else { return nil }
        guard (try? cloudKeyAvailable()) ?? false else { return Self.cloudSetupGuidance }
        return EngineSettings.selection.model.isEmpty ? Self.modelSetupGuidance : nil
    }

    /// 一条报错气泡底下该给他哪颗按钮。
    ///
    /// 「重试」只对**这一次没成功**有意义。key 没填、模型没选、key 没通过验证这几种,
    /// 重试一百次都是同一句话,而屏幕上没有一个字告诉他该去哪儿——审核员就是这么按了两次
    /// 重试然后把这个 build 拒掉的。
    func recovery(for messageID: UUID) -> ErrorRecovery? {
        guard canRetry(messageID), let index = index(of: messageID) else { return nil }
        guard let failure = session.messages[index].errorDescription else { return nil }
        // 现在就配不齐:重试发出去的还是同一句话。**现算一次**而不是记在消息上,
        // 这样他配完回来那颗按钮自己就变回「重试」。
        if currentSetupGuidance != nil { return .openSetup }
        return failure == Self.authFailureGuidance ? .openSetup : .retry
    }

    // MARK: - 回复

    private func startReply() {
        isReplying = true
        didStartReplyInSession = true
        retryNotice = nil
        // 定位是异步的,这一次多半来不及赶上下面这轮请求——赶上的是下一句。发一句话就顺手
        // 定一次(内部按 `LocationProvider.refreshInterval` 节流,没授权直接返回),
        // 是为了让「他换了个城市」这件事在他开口的时候就已经在路上了。
        LocationProvider.shared.refresh()
        // 那几条接的是上一段回答,新的一段就要开始写了。留着比空着糟:它们和固定那几条
        // 长得一模一样,而点下去问的是三句话之前的事。
        followUps = []

        currentReplyTask = Task {
            // 一次「回复」可能跨好几轮。队列里的话赶在最后一次请求之后才到时,loop 已经没有
            // 边界可以接它了——那几句在这儿接着跑一轮,不用用户再按一次发送。停止之后不续跑:
            // 他按停止的意思就是别再发了,队列原样留着等他自己决定。
            while !Task.isCancelled {
                dequeueAll()
                beginAssistantMessage()
                await runTurn()
                guard !Task.isCancelled, hasQueuedInput else { break }
            }
            isReplying = false
            replyingMessageID = nil
            retryNotice = nil
            currentReplyTask = nil
            await saveSession()
        }
    }

    /// 在列表末尾起一条空回复,并把它定为接下来所有事件的收件人。
    @discardableResult
    private func beginAssistantMessage(inlining inlined: [UUID] = []) -> UUID {
        let message = ChatMessage(
            role: .assistant,
            text: "",
            storedTurn: .init(inlinedMessageIDs: inlined)
        )
        session.messages.append(message)
        replyingMessageID = message.id
        return message.id
    }

    /// 插话被接进上下文的那一刻:把这一轮的回复**从这里劈开**,后半段另起一条,排在插话下面。
    ///
    /// 不劈开的话,答这句话的正是它上面那条还在写的回复——用户看到的是「我问了,它没理我」,
    /// 而实际上模型早就答了。这是这套东西最容易被误读成坏掉的一处:消息列表是线性的,
    /// 而一条跨过插话的回复在时间上是压着它的,没有哪个位置是对的。劈开之后每一段都落在
    /// 它该在的位置上。
    ///
    /// 前半段一个字没说、也没查东西时直接扔掉:那只是一个空气泡。
    private func splitReplyAroundInterjection() {
        guard let previousID = replyingMessageID, let index = replyingIndex() else { return }

        var inlined: [UUID] = []
        if session.messages[index].hasVisibleTurnContent {
            // 前半段和后半段在 runtime 眼里是**同一轮**:整轮的 transcript 到最后会一次性
            // 落在后半段上,里面已经含了前半段说过的话。回放时要跳过前半段那条气泡。
            inlined.append(previousID)
        } else {
            session.messages.remove(at: index)
        }
        beginAssistantMessage(inlining: inlined)
    }

    /// 排队中的那几条这就要作为普通历史发出去了,不再是「还没进上下文」。
    private func dequeueAll() {
        for index in session.messages.indices where session.messages[index].isQueued {
            session.messages[index].isQueued = false
        }
    }

    private func runTurn() async {
        do {
            let engine = try resolveEngine()
            // 说好要发的那几张原图,冷启动之后只剩一个文件名。补在这儿——**拿到引擎之后、
            // 发请求之前**:能不能带图是这一轮手上这个引擎的属性,而它每轮现造。
            await loadImagePayloads(supportsVision: engine.supportsVision)
            let stream = engine.reply(to: session.messages, pendingInput: pendingInputProvider())
            for try await event in stream {
                apply(event)
            }
            // AsyncThrowingStream 的消费者被取消时,`for try await` 是**正常**结束的,
            // 不抛 CancellationError。只靠 catch 抓不到"用户按了停止",那条回复会既没
            // 文本也没状态地存下去。
            if Task.isCancelled {
                markStopped()
            }
        } catch is CancellationError {
            markStopped()
        } catch {
            if Task.isCancelled {
                markStopped()
            } else {
                markFailed(error)
            }
        }
    }

    /// loop 每个工具轮边界来问一次。**返回即消费**——拿到的这几句它马上就会发出去,
    /// 所以队列标记必须在同一步清掉,否则下一个边界会把同一句再发一遍。
    private func pendingInputProvider() -> AgentPendingInputProvider {
        { [weak self] in
            await MainActor.run { self?.takeQueuedInput() ?? [] }
        }
    }

    private func takeQueuedInput() -> [AgentPendingInput] {
        var taken: [AgentPendingInput] = []
        for index in session.messages.indices where session.messages[index].isQueued {
            session.messages[index].isQueued = false
            taken.append(AgentPendingInput(
                id: session.messages[index].id,
                // 插话也可能带着一张刚拍的图。发的是拼好的那一份,和它当成普通历史发出去时
                // 一模一样(`ChatMessage.modelText`)。
                text: session.messages[index].modelText
            ))
        }
        return taken
    }

    /// 事件落到正在写的那条回复上。语义在 `AgentTurnSink.apply` 里,这里只负责找到收件人
    /// ——每个 delta 都把整条会话翻一遍 DTO 太贵了。
    private func apply(_ event: AgentEvent) {
        if case .reasoningDelta(let delta) = event {
            bufferReasoning(delta)
            return
        }
        // 别的事件一律先把攒着的思考落下去。撤字尤其要紧:`reasoningRolledBack` 报的字数
        // 里含着还在缓冲区里的那几个,先落再撤才对得上。
        flushReasoning()

        switch event {
        // 例外:整段摘要挂在早先某条上。存下来,下轮就不用再叫一次模型重算。
        case .historyCompacted(let messageID, let artifact):
            guard let index = session.messages.firstIndex(where: { $0.id == messageID }) else { return }
            session.messages[index].storedTurn.compaction = artifact
            return
        case .retryScheduled(let notice):
            retryNotice = String(localized: "连接不稳定，正在重试（\(notice.attempt)/\(notice.maxAttempts)）")
        case .textDelta:
            // 重试成功了,模型开口了。
            retryNotice = nil
        case .pendingInputAccepted:
            // 先劈开,再让事件落到后半段上——记「这一轮内联了哪几条」的正是后半段。
            splitReplyAroundInterjection()
        default:
            break
        }
        guard let index = replyingIndex() else { return }
        session.messages[index].apply(event)
    }

    private func bufferReasoning(_ delta: String) {
        pendingReasoning += delta
        guard reasoningFlushTask == nil else { return }
        reasoningFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reasoningFlushInterval)
            guard let self, !Task.isCancelled else { return }
            flushReasoning()
        }
    }

    private func flushReasoning() {
        reasoningFlushTask?.cancel()
        reasoningFlushTask = nil
        guard !pendingReasoning.isEmpty else { return }
        let delta = pendingReasoning
        pendingReasoning = ""
        guard let index = replyingIndex() else { return }
        session.messages[index].apply(.reasoningDelta(delta))
    }

    /// 从后往前找:收件人几乎总是最后一条,只有用户中途插话时才往前挪那么一两格。
    private func replyingIndex() -> Int? {
        guard let replyingMessageID else { return nil }
        return session.messages.lastIndex { $0.id == replyingMessageID }
    }

    /// 这两条走的是流结束之后的路,没有事件替它们把缓冲区落下去——按停止的那一刻思考已经
    /// 想了半段,丢掉它等于用户看到的比实际发生的少。
    private func markStopped() {
        flushReasoning()
        guard let index = replyingIndex() else { return }
        session.messages[index].markStopped()
    }

    private func markFailed(_ error: any Error) {
        flushReasoning()
        guard let index = replyingIndex() else { return }
        session.messages[index].markFailed(Self.userFacingFailure(error))
    }

    /// provider 的原文不能直接上屏。
    ///
    /// 它是写给开发者看的——「Error code: 401 - {'error': {'message': 'Incorrect API key
    /// provided'}}」。用户从这句话里得不到任何他能做的事,而这恰好是他最需要知道下一步该干
    /// 什么的时刻。**2026-08-16 那次 App Store 拒的就是这个**:审核员没配 key、提了个问题,
    /// 屏幕上回他一个 401(Guideline 2.1(a) - App Completeness)。
    ///
    /// 分类交给 `ModelFailure.kind`,这里只把每一类翻成一句「你现在能做什么」。分不出来的
    /// 那一类**照旧给原文**:说不出所以然的时候,一句编出来的通用错误比原文更没用,而原文
    /// 至少还是排查的线索。
    static func userFacingFailure(_ error: any Error) -> String {
        let raw = error.localizedDescription
        switch ModelFailure.kind(of: raw) {
        case .authentication:
            return authFailureGuidance
        case .quota:
            return String(localized: "这把 key 的额度用完了，或者账户欠着费。到 provider 那边确认额度之后再试一次。")
        case .contextOverflow:
            return String(localized: "这条对话太长了，装不下。开一条新对话再问一次，刚才查到的数据都还在。")
        case .transient:
            return String(localized: "网络或者模型服务暂时不通，重试几次都没成功。过一会儿再试一次。")
        case .other:
            return raw
        }
    }

    // MARK: - 引擎

    private func resolveEngine() throws -> any AgentEngine {
        if let engineFactory {
            // 注入假引擎的那条路不挂 hook:hook 的行为由 `FollowUpChipTests` 直接对着
            // `AgentLoop` 验,不必穿过这个状态机。
            return try engineFactory(session.topic)
        }
        let settings = try cloudSettings()
        return AIKitEngine(
            providerId: settings.provider,
            model: settings.model,
            topic: session.topic,
            // 家人成员在这儿多一块 system 段(「这不是用户本人,而且你读不到他的健康数据」),
            // 而健康工具在下面一个都不挂。两处必须一起变:只挡工具不说话,模型会为了有话说
            // 而猜一个数字;只说话不挡工具,它会去查,查回来的是机主的数字。
            tenant: tenant,
            goal: session.thread?.isGoal == true ? session.threadTitle : nil,
            // 隐私会话照样**读**记忆:承诺的是不往盘上写,不是失忆。真要把已经知道的也关掉,
            // 用户恰恰是在想问点私密事的时候拿到一个不认识他的助手,那这个开关只会没人用。
            memory: memory,
            // 用药表同理:隐私会话照样**读**——「他不能吃什么」这一条在想问点私密事的时候
            // 尤其不能关掉。承诺的是不留痕迹,不是不管他死活。
            medications: medications,
            focusMedication: focusMedication,
            // **每轮现取**,不像上面几份绑在会话上:人会走动,而这块东西存在的理由正是
            // 「他此刻在哪」。没授权就是 `.unknown`,那一段 system 段不发。
            //
            // 隐私会话照样带。它不往盘上写任何东西(承诺的是不留本机痕迹),而问题终究要发给
            // 云端模型才有人回答——同记忆、同用药表。
            location: LocationProvider.shared.snapshot,
            // 写的那一头堵死:`remember` 在这条会话里根本不挂出去。
            capabilityRegistry: .healthChat(
                // 这台设备的 HealthKit 只有机主一个人的数据。给家人挂上健康工具,模型会去查,
                // 而查回来的是**机主的**数字——它会一本正经地拿爸爸的静息心率解释妈妈的化验单,
                // 并且不报错。
                includesHealthTools: tenant.isOwner,
                allowsMemoryWrites: !session.isPrivate,
                // 他自己提起过去,才有「过去」可翻。没提就连工具都不挂——留着的话模型每轮都要
                // 判一次要不要翻,而健康对话句句连着上一句,那个判断天然偏向"要"。
                allowsRecall: SessionRecallTrigger.unlocksRecall(in: session.messages),
                allowsMedicationWrites: !session.isPrivate,
                memoryStore: memoryStore,
                sessionStore: sessionStore,
                medicationStore: medicationStore,
                currentSessionId: session.id
            ),
            hooks: followUpHooks(settings)
        )
    }

    /// 追问 chip 的宿主。第一次要发请求时才建,之后这条会话一直用它。
    private func followUpHooks(_ settings: (provider: String, model: String)) -> AgentHookDispatcher {
        if let hooks { return hooks }

        let suggester = FollowUpSuggester(providerId: settings.provider, model: settings.model)
        // 交付时校验会话号。宿主跟着会话丢了,但上一条会话还在飞的那次生成仍然握着自己的
        // hook——它回来得晚一点,就会把三条属于上一段对话的追问摆到这一条下面。
        let sessionId = session.id
        let hook = FollowUpSuggestionHook(
            generate: { context in
                // 失败即放弃。追问 chip 没生成出来,用户手上还有固定那几条和输入框。
                (try? await suggester.suggestions(for: context)) ?? []
            },
            deliver: { [weak self] suggestions in
                guard let self, session.id == sessionId, !isReplying else { return }
                followUps = suggestions
            }
        )
        let dispatcher = AgentHookDispatcher([hook])
        hooks = dispatcher
        return dispatcher
    }

    /// 云端调用要齐的三样:key、provider、model。缺一样就别发请求。
    private func cloudSettings() throws -> (provider: String, model: String) {
        guard try cloudKeyAvailable() else {
            throw AgentError.needsAPIKey
        }

        // 和设置页显示的那两行**同一个来源**(`EngineSettings.selection`)。各读各的那一版
        // 让审核员看着一屏配好的设置收到「你还没选模型」,见 `seedDefaultsIfNeeded`。
        //
        // 模型是在设置里选的,选空了仍然不拿默认模型顶上——那多半属于另一个 provider。
        let selection = EngineSettings.selection
        guard !selection.model.isEmpty else {
            throw AgentError.needsModelSelection
        }

        return selection
    }

    private func cloudKeyAvailable() throws -> Bool {
        let key = try KeychainStore.get(account: KeychainStore.apiKeyAccount) ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func nonEmptySetting(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    // MARK: - 存取

    /// 冷启动落在新对话上,不接着上次那条。
    ///
    /// 打开 app 的时候人多半是想问一件新的事。续上几天前那句「那第三天呢」,既要先读完
    /// 才知道自己在哪儿,想问新的还得再点一次「新对话」。上一条一条没丢,在会话列表里
    /// 一点就回得去。
    ///
    /// 代价是被系统回收之后再进来,不会自动回到刚才那条——换来的是每次进来都可预测。
    private func loadInitialSession() async {
        defer { isLoadingConversation = false }
        if EngineSettings.memoryEnabled {
            memory = await memoryStore.snapshot()
        }
        if EngineSettings.medicationsEnabled {
            medications = await medicationStore.snapshot()
        }
        await refreshSummaries()
    }

    private func saveSession() async {
        // 空会话不落盘,否则每次点「新对话」都在列表里留一条空壳。
        // 隐私会话永远不落盘——这是它唯一的意义。会话文件是所有本机痕迹的源头:不落盘,
        // 会话列表、兴趣统计(`InterestProfile.build(from:)` 只数存下来的会话)就一并没有它。
        guard !session.isEmpty, !session.isPrivate else { return }
        session.updatedAt = Date()
        do {
            try await sessionStore.save(session)
        } catch {
            print("保存会话失败：\(error.localizedDescription)")
        }
        await refreshSummaries()
    }

    private func refreshSummaries() async {
        summaries = await sessionStore.summaries()
        // 同一次索引扫描的两个读者,一起刷。分两次去问 actor,列表和目标区就可能有一瞬
        // 对不上——刚删掉的那条线还在上面挂着。
        goals = await sessionStore.goals()
    }
}

/// 一条报错气泡底下那颗按钮做什么。
///
/// 定在文件层不定在 `ChatViewModel` 里面:气泡的 `==` 是 `nonisolated` 的,而嵌在一个
/// `@MainActor` 类型里的枚举在那儿要多绕一圈。
enum ErrorRecovery {
    case retry
    case openSetup
}
