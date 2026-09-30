import SwiftUI
import AgentRuntime

/// 那条永远的对话。
///
/// 没有「会话」这个用户能管理的东西了:打开就接着上次,一条时间线。内存里持有的是线程**末尾**
/// 的一段(`messages`,滑到顶再往前翻),盘上是追加式的 `ThreadStore`。
///
/// 三件事在这里接线,都是「每一轮请求带多少历史」这个问题的一部分:
/// - **窗口**(`ThreadWindow`):请求里只带窗口内的原文。窗口只在涨到高水位时一次砍到低水位,
///   两次淘汰之间请求前缀是纯追加,prompt 缓存稳定。窗口之外的历史不丢——记忆管长期事实,
///   档案按需检索(`search_sessions`)。
/// - **持久化**:只写变了的,排成一条队,和后台追加的主动消息不抢。
/// - **收割**:记忆抽取按水位线做,和窗口解耦(`MemoryHarvester`)。
///
/// `isEphemeral` 是「不留痕」浮层:内存里聊,不读盘不写盘、不抽记忆,关了就没。
///
/// `sideChat` 是一条侧聊:同一个类型接另一条线程(`SideChatStore`),插话、窗口、重试、hook
/// 全部原样。主对话专属的那几样(「今天」、首屏那段话和建议、check-in)在侧聊里不出。
@MainActor
@Observable
final class ChatViewModel {
    /// 线程末尾那一段,按位置排好。
    private(set) var messages: [ChatMessage] = []
    /// 不留痕:这一段不留任何本机痕迹。不落盘、不进线程、不写记忆、不进兴趣统计。
    ///
    /// 承诺的边界只到本机为止——问题照样要发给用户配置的云端模型才能回答,这一点界面上
    /// 明说(`ChatView.privacyNote`)。
    let isEphemeral: Bool
    /// 这是哪条侧聊。主对话和不留痕都是 nil。名字会被他改、会拿第一句话起,所以是 var。
    private(set) var sideChat: SideChat?
    var isSideChat: Bool { sideChat != nil }
    /// 那条永远的对话本身。「今天」、首屏、check-in、清理全部历史都只在这里。
    var isMainThread: Bool { !isEphemeral && sideChat == nil }
    var input = ""
    var isReplying = false
    /// 正在写的那条回复。事件的收件人,也是气泡判断「我是不是正在流」的依据。
    ///
    /// 不能再用 `messages.last`:用户可以在回复期间接着发消息,那几条排在正在写的这条
    /// **后面**——照旧取最后一条的话,模型吐出来的字会一个个落进用户刚打的那句话里。
    private(set) var replyingMessageID: UUID?
    var isLoadingConversation = true
    /// 盘上还有更早的。滑到顶就再往前翻一页。
    private(set) var hasOlderHistory = false
    /// 每往前翻一页加一。界面据此把滚动位置补上,不然新塞进顶部的内容会把正看的那条顶下去。
    private(set) var olderPageToken = 0
    /// 刚翻出来那一页之前,原来的第一条。界面滚回它。
    private(set) var olderPageAnchor: UUID?
    var engineGuidance: String?
    /// 他按了发送,但还没配 key。
    ///
    /// **是一次请求,不是一种状态**——界面接住它、把设置页推到他面前,然后立刻置回 false。
    var needsCloudSetup = false
    /// 他按了发送,但还没同意过把数据发给当前这家 provider(`ProviderConsent`)。
    ///
    /// 存的是 provider id,界面拿它弹那个点名确认的 alert。同意或取消都当场清掉。
    /// 打的字留在输入框里,同意之后再发。
    private(set) var pendingProviderConsent: String?
    /// 正在退避重试时给用户看的一句话。退避期间界面上什么都不动的话,等十几秒和卡死是一模
    /// 一样的观感——而这时候 app 其实知道发生了什么。
    private(set) var retryNotice: String?
    /// 首屏那句话:打开 app 先说发生了什么,不是先问他一个问题。
    ///
    /// 「今天」页「现在」那一行说的也是它,所以一变就跟着重拼一次——模型写的那段是在本地那句
    /// 之后才到的,不跟的话那一行永远停在本地那句上。流式期间每个字都会走到这儿,`refreshTodaySoon`
    /// 自己去抖。
    private(set) var quickSummary: String? {
        didSet { if quickSummary != oldValue { refreshTodaySoon() } }
    }
    /// 本地判定出来的处境。首屏那张卡点开之后,详情页要按项列出「现在是多少」。
    ///
    /// 家人成员那条路上永远是 nil:`HealthSituation` 读的是机主的 HealthKit,整个不跑。
    private(set) var situation: HealthSituation?
    /// 那段话正在写。详情页那颗刷新按钮靠它转圈,也靠它挡住连按。
    private(set) var isWritingSummary = false
    /// 接着刚才那段回答问的几条追问。空着不是错误状态,是常态的一半。
    private(set) var followUps: [String] = []
    /// 「今天」页上的那几行。本机数据拼的,零模型调用;只在主对话上有(侧聊、不留痕里没有那颗按钮)。
    private(set) var todayCards: [TodayCard] = []
    /// 顶栏「今天」上的角标:需要他看一眼的有几件。
    var attentionCount: Int { TodaySummary.attention(todayCards) }
    /// 健康插件那一格建议:本地按处境挑的,模型写好了原地换掉。
    private var healthSuggestions: [SuggestedQuestion] = []
    /// 输入框上方那排还没发出去的照片。
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
    /// 首屏那段话的生成。按刷新时先取消在飞的那次。
    private var summaryTask: Task<Void, Never>?
    /// 思考的增量攒一小会儿再落盘(一秒十二次已经比眼睛快),重排的次数少一个数量级。
    private var pendingReasoning = ""
    private var reasoningFlushTask: Task<Void, Never>?
    private static let reasoningFlushInterval = Duration.milliseconds(80)
    private var hasRequestedSuggestions = false

    /// 这一轮用的记忆快照。**每轮现读**:没有会话边界了,而记忆不变时渲染出来的那一块逐字
    /// 相同,prompt 缓存不受影响;变了只打掉易变区那一截尾巴。
    private(set) var memory: MemorySnapshot = .empty
    /// 用药与补剂表,同上。
    private(set) var medications: MedicationSnapshot = .empty
    /// 「问问这个药」带进来的一次性上下文:下一轮回复里带着它,回复完就撤。
    ///
    /// 以前这会切进一条专属的「用药线」会话;现在只有一条对话,所以只是一个焦点。
    private(set) var focusMedication: MedicationItem?
    /// 挂在 loop 生命周期上的那几个旁观者(眼下只有追问 chip)。第一次真的要发请求时才建。
    private var hooks: AgentHookDispatcher?

    // MARK: 线程

    private let thread: ThreadStore
    /// 这位成员的侧聊名单。主对话拿它做三件事:「⋯ › 侧聊」那一页、收割时连侧聊一起收、
    /// 清理历史时连侧聊一起清。
    let sides: SideChatStore
    /// 已经离开过这条侧聊了。关掉、删除、换成员,几条路都会走到 `leaveSideChat`。
    private var didLeaveSideChat = false
    /// 这位成员的主对话线程。侧聊里「带回主对话」往它末尾追加;主对话里就是 `thread` 本身。
    private let mainThread: ThreadStore
    /// 这一轮回复收尾时通知一声。只有 `SideChatHost` 用:侧聊关掉时回复还在写,写完要亮未读点。
    var onReplyFinished: (() -> Void)?
    /// 这一次打开期间带回过主对话的那几条。只记在内存里:它的用处是让他按完看得见结果、
    /// 别连按两次,不是一份要存下来的账——主对话里那一条本身才是记录。
    private(set) var broughtBackIds: Set<UUID> = []
    /// 这一份要不要落盘。不留痕的不落;测试关掉读盘时也不写——不然写的就是模拟器上那条真的线程。
    private let persists: Bool
    /// 界面这一份已经同步给盘的 id。只删这里面有、列表里没了的——后台追加、界面还没读到的
    /// 不会被误删。
    private var syncedIds: Set<UUID> = []
    /// 已经同步过、之后又改过的。
    private var dirtyIds: Set<UUID> = []
    private var persistTail: Task<Void, Never>?
    private var oldestSegment = Int.max
    private var isLoadingOlder = false
    /// 窗口第一条消息的 id。窗口只在淘汰时前移。
    private var windowStartId: UUID?
    /// 回复期间有后台消息落进线程了,等这一轮结束再并进来。
    private var hasPendingBackgroundMessages = false
    private var backgroundObserver: (any NSObjectProtocol)?
    private var tasksObserver: (any NSObjectProtocol)?
    private var idleHarvestTask: Task<Void, Never>?

    /// 每轮现造引擎。测试注入一个脚本化的假引擎,就能在不碰 Keychain 和网络的前提下
    /// 走完整条 loop。
    typealias EngineFactory = @MainActor @Sendable () throws -> any AgentEngine

    private let engineFactory: EngineFactory?
    private let memoryStore: MemoryStore
    private let medicationStore: MedicationStore
    let taskStore: TaskStore
    let noteStore: NoteStore
    /// 任务页、详情页、对话里那张确认卡读的那一份。
    let taskBoard: TaskBoard
    /// 这个 view model 服务的是哪位成员。**一个 view model 一位成员,不给它换人的方法**。
    /// 切成员在 `ChatView` 那边是整个换掉这个对象(`.id(tenant.id)`)。
    private let tenant: Tenant
    /// 这位成员有没有 Apple 健康数据。**只有机主有**(见 `Tenant.Kind`)。
    var hasHealthData: Bool { tenant.isOwner && EngineSettings.healthEnabled }
    var currentTenant: Tenant { tenant }

    /// 导航栏副标题。成员名字和不留痕状态挤在同一行。**机主不标注**。
    var navigationSubtitle: String {
        var parts: [String] = []
        if !tenant.isOwner { parts.append(tenant.displayName) }
        if isEphemeral { parts.append(String(localized: "不留痕 · 关掉就没了")) }
        // 一直认得出是侧聊:标题栏写的是它的名字,这一行说它是什么。
        if isSideChat { parts.append(String(localized: "侧聊")) }
        return parts.joined(separator: " · ")
    }

    /// 还有话排着没进上下文。停止回复之后队列**不会**自动清空——用户打的字不该被替他扔掉。
    var hasQueuedInput: Bool { messages.contains { $0.isQueued } }

    /// 线程是真的空的(全新安装、刚清空过)。欢迎卡只在这时候出现。
    var isThreadEmpty: Bool { messages.isEmpty && !hasOlderHistory }

    /// 首屏那三条:核心先占位,健康分一格。某个插件正处在具体上下文里(聊某样药、替家人问)时
    /// 只给它的。完全本地拼,一次模型调用都不发。
    var suggestions: [SuggestedQuestion] {
        PluginRegistry.suggestions(SuggestionContext(
            isEnabled: EngineSettings.isPluginEnabled,
            tenant: tenant,
            focusMedication: focusMedication,
            medications: medications,
            healthQuestions: healthSuggestions
        ))
    }

    /// 欢迎语里「我能帮你……」那一段:哪些插件开着就提哪些。
    var welcomeBody: String { PluginRegistry.welcomeBody(isEnabled: EngineSettings.isPluginEnabled) }

    /// - Parameters:
    ///   - loadsPersistedThread: 关掉就不读盘,`isLoadingConversation` 直接是 false。测试用。
    ///   - memoryStore / medicationStore / thread: 测试必须传自己的。app 侧的测试跑在 app host
    ///     里,`.shared` 就是模拟器上那份真的数据。
    ///   - sides: 不给就用 `thread` 旁边那份(`SideChatStore.beside`),和线程永远是同一位成员的。
    ///   - sideChat: 给了就是那条侧聊,线程由 `sides` 给(同一条永远是同一个实例),`thread` 不用。
    init(
        engineFactory: EngineFactory? = nil,
        loadsPersistedThread: Bool = true,
        isEphemeral: Bool = false,
        sideChat: SideChat? = nil,
        tenant: Tenant = TenantScope.current,
        memoryStore: MemoryStore = .shared,
        medicationStore: MedicationStore = .shared,
        thread: ThreadStore = TenantScope.currentStores.thread,
        sides: SideChatStore? = nil,
        tasks: TaskStore = TenantScope.currentStores.tasks,
        notes: NoteStore = TenantScope.currentStores.notes
    ) {
        self.engineFactory = engineFactory
        self.isEphemeral = isEphemeral
        self.sideChat = isEphemeral ? nil : sideChat
        self.tenant = tenant
        self.memoryStore = memoryStore
        self.medicationStore = medicationStore
        let sides = sides ?? SideChatStore.beside(thread)
        self.sides = sides
        mainThread = thread
        self.thread = if let sideChat, !isEphemeral { sides.thread(for: sideChat.id) } else { thread }
        self.taskStore = tasks
        self.noteStore = notes
        taskBoard = TaskBoard(store: tasks, tenantId: tenant.id)
        persists = loadsPersistedThread && !isEphemeral
        refreshEngineAvailability()
        guard loadsPersistedThread, !isEphemeral else {
            isLoadingConversation = false
            Task { await refreshSnapshots() }
            return
        }
        // 后台来的主动消息(check-in、提醒、任务结果):等这一轮回复结束再并进列表。
        let directory = thread.directory
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: .vanaThreadDidAppend,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard (note.object as? URL) == directory else { return }
            MainActor.assumeIsolated { self?.backgroundMessageArrived() }
        }
        let tasksFile = tasks.fileURL
        tasksObserver = NotificationCenter.default.addObserver(
            forName: .vanaTasksDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard (note.object as? URL) == tasksFile else { return }
            MainActor.assumeIsolated { self?.refreshTodaySoon() }
        }
        Task {
            await loadInitialHistory()
            await refreshToday()
        }
    }

    isolated deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let tasksObserver { NotificationCenter.default.removeObserver(tasksObserver) }
    }

    // MARK: - 今天

    private var todayTask: Task<Void, Never>?

    private func refreshTodaySoon() {
        guard persists, isMainThread else { return }
        todayTask?.cancel()
        todayTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await refreshToday()
        }
    }

    /// 「今天」页那几行。**零模型调用**:本机的任务、到期的待跟进、用药回访、那句处境。
    func refreshToday() async {
        guard persists, isMainThread else { return }
        let now = Date()
        let dueFollowUps = EngineSettings.memoryEnabled ? await memoryStore.snapshot(now: now).due(at: now) : []
        let context = TodayContext(
            now: now,
            tasks: await taskStore.all(),
            dueFollowUps: dueFollowUps,
            medications: medications,
            healthSummary: hasHealthData && situation != nil ? quickSummary : nil
        )
        todayCards = PluginRegistry.todayCards(context)
    }

    // MARK: - 线程:读、持久化、往前翻

    /// 冷启动直接落在末尾,接着上次。窗口起点在更早的段里时往前读到能盖住它为止,
    /// 不然「窗口」比读进来的还长。
    private func loadInitialHistory() async {
        defer { isLoadingConversation = false }
        await refreshSnapshots()
        var page = await thread.loadTail()
        let windowPos = await thread.meta().windowStartPos
        var loaded = page.messages
        if let windowPos {
            while page.hasOlder, let first = loaded.first,
                  (await thread.position(of: first.id) ?? .greatestFiniteMagnitude) > windowPos {
                page = await thread.loadOlder(beforeSegment: page.oldestSegment)
                loaded = await thread.sortedByPosition(page.messages + loaded)
            }
            var start: UUID?
            for message in loaded {
                if let pos = await thread.position(of: message.id), pos >= windowPos {
                    start = message.id
                    break
                }
            }
            windowStartId = start ?? loaded.first?.id
        } else {
            windowStartId = loaded.first?.id
        }
        oldestSegment = page.oldestSegment
        hasOlderHistory = page.hasOlder
        syncedIds = Set(loaded.map(\.id))
        // 读盘期间他要是已经发了话(极少),别把它盖掉。
        messages = loaded + messages
    }

    /// 滑到顶了,再往前读一页。
    func loadOlder() {
        guard persists, !isLoadingOlder, hasOlderHistory else { return }
        isLoadingOlder = true
        Task {
            defer { isLoadingOlder = false }
            let page = await thread.loadOlder(beforeSegment: oldestSegment)
            oldestSegment = page.oldestSegment
            hasOlderHistory = page.hasOlder
            let fresh = page.messages.filter { !syncedIds.contains($0.id) }
            guard !fresh.isEmpty else { return }
            olderPageAnchor = messages.first?.id
            syncedIds.formUnion(fresh.map(\.id))
            messages = await thread.sortedByPosition(fresh + messages)
            olderPageToken += 1
        }
    }

    private func backgroundMessageArrived() {
        guard !isReplying else {
            hasPendingBackgroundMessages = true
            return
        }
        Task { await mergeBackgroundMessages() }
    }

    /// 后台追加的新消息并进来。回答还在写的时候不动——等这一轮结束(沿用「插话在轮边界接入」)。
    private func mergeBackgroundMessages() async {
        guard persists, !isReplying else { return }
        hasPendingBackgroundMessages = false
        let lastPos: Double? = if let last = messages.last { await thread.position(of: last.id) } else { nil }
        let fresh = await thread.messages(after: lastPos).map(\.message).filter { !syncedIds.contains($0.id) }
        guard !fresh.isEmpty, !isReplying else { return }
        syncedIds.formUnion(fresh.map(\.id))
        messages += fresh
    }

    /// 请求落盘。多次请求排成一条队,顺序不会乱。
    private func persist() {
        guard persists else { return }
        let previous = persistTail
        persistTail = Task {
            await previous?.value
            await persistNow()
        }
    }

    private func persistNow() async {
        // 还在写的助手消息如果还是个空壳,先不落盘——崩了留下一个空气泡比什么都没有更糟。
        let inFlight = isReplying ? replyingMessageID : nil
        let snapshot = messages.filter { message in
            !(message.id == inFlight && !message.hasVisibleTurnContent && !syncedIds.contains(message.id))
        }
        var dirty = dirtyIds
        if let replyingMessageID { dirty.insert(replyingMessageID) }
        dirtyIds.removeAll()
        syncedIds = await thread.sync(snapshot, dirty: dirty, known: syncedIds)
    }

    /// 等排着的写盘都落下去。测试和切到后台时用。
    func flushPersistence() async {
        await persistTail?.value
    }

    /// 删掉这一条(连同它引用的、别处没在用的照片)。
    func deleteMessage(_ id: UUID) {
        guard !isReplying else { return }
        messages.removeAll { $0.id == id }
        if windowStartId == id { windowStartId = messages.first?.id }
        persist()
    }

    /// 删掉一条回答和它对应的那句提问。
    func deleteExchange(_ assistantId: UUID) {
        guard !isReplying, let index = index(of: assistantId) else { return }
        var doomed: Set<UUID> = [assistantId]
        if let userIndex = messages[..<index].lastIndex(where: { $0.role == .user }) {
            doomed.insert(messages[userIndex].id)
        }
        messages.removeAll { doomed.contains($0.id) }
        if let windowStartId, doomed.contains(windowStartId) { self.windowStartId = messages.first?.id }
        persist()
    }

    /// 清空整条对话。设置 › 对话历史用。主对话这一份连侧聊一起清——「清空全部对话」里的
    /// 「全部」就是这个意思。
    func clearHistory() async {
        guard !isReplying else { return }
        stopReply()
        await persistTail?.value
        if persists { await thread.deleteAll() }
        if persists, isMainThread { await sides.deleteAll() }
        messages = []
        syncedIds = []
        dirtyIds = []
        windowStartId = nil
        oldestSegment = .max
        hasOlderHistory = false
        focusMedication = nil
        followUps = []
        hooks = nil
        draftAttachments = []
    }

    /// 清掉 `days` 天前的。设置 › 对话历史用。返回删了多少条。
    @discardableResult
    func clearHistory(olderThanDays days: Int) async -> Int {
        guard !isReplying, persists else { return 0 }
        await persistTail?.value
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var removed = await thread.deleteOlderThan(cutoff)
        if isMainThread { removed += await sides.deleteOlderThan(cutoff) }
        // 重新读一遍末尾:删掉的可能正是手里这一段的开头。
        messages = []
        syncedIds = []
        await loadInitialHistory()
        return removed
    }

    /// 对话历史在盘上占多少。主对话这一份把侧聊也算进去,和清理的范围对得上。
    func historySizeBytes() async -> Int {
        guard persists else { return 0 }
        let own = await thread.sizeBytes()
        return isMainThread ? own + (await sides.sizeBytes()) : own
    }

    // MARK: - 发送

    /// 发一句话。**正在回复时照发不误**:打出去的字立刻变成气泡,由 loop 在下一个工具轮边界
    /// 接进上下文。
    ///
    /// 空文本也是有意义的一次调用:队列里还剩着东西时(停止回复之后),它就是「把排着的
    /// 那几句发出去」。
    func send(_ suggestedQuestion: String? = nil) {
        guard !isLoadingConversation else { return }

        // 没配 key 就别把这句话发出去——发出去的结果是一个 401,而那句报错既不是他的错,也没告诉
        // 他下一步该做什么(2026-08-16 那次审核走的正是这条路)。**现查一次钥匙串**:「刚在设置里
        // 填完 key 回来」恰好是最需要它准的那一刻。
        refreshEngineAvailability()
        guard engineGuidance == nil else {
            if let suggestedQuestion { input = suggestedQuestion }
            needsCloudSetup = true
            return
        }

        // 第一次要发给这家 provider:先点名征一次同意(Guideline 5.1.2(i))。注入了假引擎就是在
        // 测试里,那条路上没有任何东西真的出设备,不拦。
        if engineFactory == nil {
            let provider = EngineSettings.selection.provider
            guard ProviderConsent.granted(provider) else {
                if let suggestedQuestion { input = suggestedQuestion }
                pendingProviderConsent = provider
                return
            }
        }

        let text = (suggestedQuestion ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        // 排在输入框上方的照片跟着下一句话一起走,不管这句话是打出来的还是点 chip 点出来的。
        let attachments = takeDraftAttachments()
        if !text.isEmpty || !attachments.isEmpty {
            input = ""
            messages.append(ChatMessage(
                role: .user,
                text: text,
                attachments: attachments,
                isQueued: true
            ))
            persist()
            noteSideChatActivity(text)
        }
        // 正在回复:这一句排进队列就完了,不再开一轮。取走它的是 `takeQueuedInput`。
        guard !isReplying, hasQueuedInput else { return }
        startReply()
    }

    /// 侧聊里说了一句话:名单按最近说过话排;还没起名的拿这句起名。
    ///
    /// 名字要在**这一轮请求发出去之前**定下来:侧聊说明块里带着它,先发一版没名字的、下一轮
    /// 再换,等于白白打掉一次 prompt 缓存。所以这里当场改内存里那一份,盘上那份由名单自己按
    /// 同一条规则改(`SideChatStore.noteActivity`)。
    private func noteSideChatActivity(_ text: String) {
        guard persists, var chat = sideChat else { return }
        chat.lastActiveAt = Date()
        if chat.autoTitled, let title = SideChatTitle.make(from: text) {
            chat.title = title
            chat.autoTitled = false
        }
        sideChat = chat
        let sides = sides
        Task { await sides.noteActivity(chat.id, text: text, now: chat.lastActiveAt) }
    }

    /// 他在侧聊里改了名字。
    func renameSideChat(to title: String) {
        guard var chat = sideChat else { return }
        chat.title = SideChatTitle.clean(title)
        chat.autoTitled = false
        sideChat = chat
        let sides = sides
        Task { await sides.rename(chat.id, to: title) }
    }

    /// 离开这条侧聊(关掉它、或者要删它)。**正在写的回复停下**——等于按了停止,已经写出来的
    /// 留着;回来时接上同一个对象、让它接着写完是下一步的事。离开时顺手收割一次:里面刚说的
    /// 那几句,主对话那边的收割要等到下一次切后台才轮得到。
    ///
    /// - Parameter harvesting: 要删这条侧聊时传 false——删完之后再去读它,`ThreadStore` 会把
    ///   刚删掉的目录重新建出来。
    ///
    /// 标记是**当场**做的,等回复停下、写盘落地的那一段放在返回的 task 里:几条路(关掉按钮、
    /// 删除、被通知顶掉)会前后脚走到这儿,只有第一条算数。
    @discardableResult
    func leaveSideChat(harvesting: Bool = true) -> Task<Void, Never>? {
        guard isSideChat, !didLeaveSideChat else { return nil }
        didLeaveSideChat = true
        let reply = currentReplyTask
        stopReply()
        return Task {
            await reply?.value
            idleHarvestTask?.cancel()
            await persistTail?.value
            if harvesting { harvestMemoryInBackground() }
        }
    }

    // MARK: - 主对话和侧聊之间搬一段话

    /// 这条回复在「⋯」里能往哪条线上搬。按消息本身判,不去列表里找下标:气泡每次重画都要问一遍。
    func sideChatMove(for message: ChatMessage) -> SideChatMove {
        if isSideChat, broughtBackIds.contains(message.id) { return .broughtBack }
        guard persists, !isReplying, SideChatQuote.canQuote(message) else { return .none }
        if isMainThread { return .continueInSideChat }
        return isSideChat ? .bringBack : .none
    }

    /// 这条回复能不能「在侧聊里接着聊」:主对话里、模型真的写完了的回答。
    func canContinueInSideChat(_ messageID: UUID) -> Bool {
        guard isMainThread, persists, !isReplying, let index = index(of: messageID) else { return false }
        return SideChatQuote.canQuote(messages[index])
    }

    /// 拿主对话里这一问一答开一条新侧聊。名字取那句提问(他随后能改),开头是那段回答的原文。
    /// 返回那条侧聊,界面接着把它打开。
    func continueInSideChat(from messageID: UUID) async -> SideChat? {
        guard canContinueInSideChat(messageID), let index = index(of: messageID) else { return nil }
        let answer = messages[index]
        let question = messages[..<index].last { $0.role == .user && !$0.isQueued }
        let seed = SideChatQuote.seed(question: question, answer: answer)
        let chat = await sides.create(title: question.flatMap { SideChatTitle.make(from: $0.text) } ?? "")
        await sides.thread(for: chat.id).appendAtEnd(seed)
        return chat
    }

    /// 某个目标的那条侧聊:同名的已经有了就接着用,没有就开一条。以前的「每周回顾」由后台每七天
    /// 自动跑一次,子 agent 撤掉之后改成他想聊的时候自己开——每次都新开一条的话,列表里很快就是
    /// 一串同名的侧聊。
    func sideChat(forGoal goal: TaskItem) async -> SideChat {
        let title = SideChatTitle.clean(goal.title)
        if let existing = await sides.all().first(where: { $0.title == title }) { return existing }
        return await sides.create(title: title)
    }

    /// 目标那条侧聊里替他起的头。放进输入框,他看一眼再发。
    static func goalReviewPrompt(_ goal: TaskItem) -> String {
        String(localized: "回顾一下「\(goal.title)」最近的进展，接下来该做什么？")
    }

    /// 这条回复能不能「带回主对话」:侧聊里、模型真的写完了的回答,这一次还没带回去过。
    func canBringBack(_ messageID: UUID) -> Bool {
        guard isSideChat, persists, !broughtBackIds.contains(messageID), let index = index(of: messageID) else { return false }
        return SideChatQuote.canQuote(messages[index])
    }

    /// 把侧聊里这一段原样追加到主对话末尾。主对话那边照后台来的主动消息那样,在轮边界并进去。
    func bringBackToMain(_ messageID: UUID) {
        guard canBringBack(messageID), let chat = sideChat, let index = index(of: messageID) else { return }
        broughtBackIds.insert(messageID)
        let note = SideChatQuote.broughtBack(messages[index], from: chat.displayTitle)
        let main = mainThread
        Task { await main.appendAtEnd(note) }
    }

    /// 他在点名确认的 alert 上按了「同意并发送」。
    func confirmProviderConsent() {
        guard let provider = pendingProviderConsent else { return }
        ProviderConsent.record(provider)
        pendingProviderConsent = nil
        send()
    }

    /// 按了「取消」:什么都不发,字留在输入框里。
    func declineProviderConsent() {
        pendingProviderConsent = nil
    }

    /// 收回一条还没进上下文的消息,文字放回输入框。
    ///
    /// 只有排队中的能收回:已经发出去的那一句模型已经看过了,从列表里抹掉它只会让屏幕上
    /// 的对话和模型记得的对话对不上。
    func withdrawQueued(_ messageID: UUID) {
        guard let index = index(of: messageID), messages[index].isQueued else { return }
        let message = messages[index]
        messages.remove(at: index)
        persist()
        input = input.isEmpty ? message.text : "\(message.text)\n\(input)"
        // 照片也一起退回到输入框上方。只把字还回来的话,那几张图就凭空没了。
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
            draft.sendsImage = attachment.sendsImage
            draftAttachments.append(draft)
        }
    }

    /// 他在某张 `ask_user` 卡上点完了。**走的就是 `send`**,和他自己打这几个字发出去没有任何区别。
    ///
    /// 先落 `askAnswer` 再发:那一下就是卡片从"能点"翻成"答过了"的时刻。
    func answerAsk(messageID: UUID, callID: String, answer: AskUserAnswer) {
        guard !answer.isEmpty,
              let index = index(of: messageID),
              let callIndex = messages[index].toolCalls.firstIndex(where: { $0.id == callID }),
              messages[index].toolCalls[callIndex].askAnswer == nil
        else { return }

        messages[index].toolCalls[callIndex].askAnswer = answer
        dirtyIds.insert(messageID)
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

        // 不留痕的那条对话不落盘,图片跟着不落——它的全部意义就是不留本机痕迹。屏幕上照常
        // 看得见:内存里那份还在,关掉就没了。
        // 不写线程的那几条路(不留痕、测试)也不写图:测试里那就是模拟器上真的附件目录。
        let persists = self.persists
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
        guard messages.contains(where: { $0.attachments.contains(where: \.sendsImage) })
        else { return }
        for index in messages.indices {
            for attachmentIndex in messages[index].attachments.indices {
                let attachment = messages[index].attachments[attachmentIndex]
                guard attachment.sendsImage else { continue }
                guard supportsVision else {
                    messages[index].attachments[attachmentIndex].imagePayload = nil
                    continue
                }
                guard attachment.imagePayload == nil,
                      let name = attachment.imageFileName,
                      let data = await AttachmentStore.shared.data(named: name)
                else { continue }
                messages[index].attachments[attachmentIndex].imagePayload =
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

    /// 重新回答某一条回复。中间那条也能重答——从它开始后面整段都丢掉,再重新生成。
    func retry(_ messageID: UUID) {
        guard canRetry(messageID), let index = index(of: messageID) else { return }
        let removed = messages[index...].map(\.id)
        messages.removeSubrange(index...)
        if let windowStartId, removed.contains(windowStartId) { self.windowStartId = messages.first?.id }
        startReply()
    }

    func canRetry(_ messageID: UUID) -> Bool {
        guard !isReplying, !isLoadingConversation, let index = index(of: messageID) else {
            return false
        }
        return messages[index].role == .assistant
            && !messages[index].isProactive
            && messages[..<index].contains { $0.role == .user }
    }

    private func index(of messageID: UUID) -> Int? {
        messages.lastIndex { $0.id == messageID }
    }

    // MARK: - 从别处进来

    /// 从用药详情页那颗「问问 Vana」进来:把它挂成**下一轮回复**的一次性上下文。
    ///
    /// **不预填问题**:预填一句「这个有什么副作用」会把对话推向一个他可能没想问的方向,而那三条
    /// 开场建议本来就按状态分好了(`MedicationItem.openingQuestions`)。
    func openMedication(_ item: MedicationItem) {
        guard EngineSettings.isPluginEnabled(PluginIds.healthMedications) else { return }
        focusMedication = item
        refreshEngineAvailability()
    }

    func clearFocus() {
        focusMedication = nil
    }

    /// 从 check-in 通知或者 Siri 进来。
    ///
    /// 通知是**邀请**:Vana 在线程里开个场(一条主动消息,不调模型),开场问题填进输入框,
    /// 让他看一眼再决定问不问。Siri 置了 `autoSend`:问题已经说出口了,该直接发——回答正在
    /// 写的时候它会被当成插话排队,**不会**砍掉进行中的那条回复。
    func open(_ launch: CheckInLaunch) {
        // 说好回头看的事,这就在看了。留着它只会在接下来几天的早上重复同一句。
        if let followUpId = launch.followUpId {
            Task {
                _ = try? await memoryStore.delete(id: followUpId)
                await refreshSnapshots()
            }
        }
        // 用药那边的回访同理,但**只清掉约定,不删那条记录**——那样东西他还在吃。
        if let medicationId = launch.medicationId {
            Task {
                _ = try? await medicationStore.clearFollowUp(id: medicationId)
                await refreshSnapshots()
            }
        }
        if let opener = launch.opener?.trimmingCharacters(in: .whitespacesAndNewlines), !opener.isEmpty, !isEphemeral {
            messages.append(ChatMessage(role: .assistant, text: opener, origin: .checkIn))
            persist()
        }
        guard let question = launch.question else { return }
        if launch.autoSend {
            sendWhenReady(question)
        } else if input.isEmpty {
            input = question
        }
    }

    /// 等线程载入完再发。Siri 冷启动 app 时,这一句多半赶在还没载入完的时候到,而 `send` 会被
    /// `isLoadingConversation` 挡掉——问题就这么无声无息地没了。等超过一秒就放弃自动发送,
    /// 把它留在输入框里。
    private func sendWhenReady(_ question: String) {
        guard engineGuidance == nil else {
            input = question
            return
        }
        Task {
            let deadline = Date().addingTimeInterval(1)
            while isLoadingConversation, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !isLoadingConversation else {
                input = question
                return
            }
            send(question)
        }
    }

    // MARK: - 首屏

    /// 每次启动只判定一次处境:本地那句和那三条问题是零成本的,首屏和「今天」共用。
    ///
    /// **模型那步只在线程真的空着时跑**(全新安装、刚清空):以前每次冷启动都落在新对话上,
    /// 那一段话每次都要写;一条永远的对话里首屏就是上次聊到的地方,为一张没人看的卡每次启动
    /// 都花一次钱不值。想要模型写的那段,详情页那颗刷新按钮还在。
    func refreshSuggestionsIfNeeded() {
        guard !hasRequestedSuggestions, !isLoadingConversation else { return }
        hasRequestedSuggestions = true
        // 首屏那段话和建议是主对话的首屏。侧聊的空白页只说一句它是什么。
        guard !isSideChat else { return }

        summaryTask = Task {
            // 家人成员这条路上 `HealthSituation` 整个不跑。它读的是 HealthKit,而那份数据
            // 属于机主——这是 `HealthStore` 几个调用方里最容易漏掉的一个。
            guard hasHealthData else {
                if !tenant.isOwner {
                    quickSummary = TenantOpening.quickSummary(for: tenant, medications: medications)
                }
                return
            }
            let situation = await HealthSituation.detect(interests: await thread.interests())
            self.situation = situation
            healthSuggestions = situation.questions
            quickSummary = situation.quickSummary
            await refreshToday()

            guard isThreadEmpty,
                  let settings = try? cloudSettings(),
                  ProviderConsent.granted(settings.provider) else { return }
            let suggester = QuestionSuggester(
                providerId: settings.provider,
                model: settings.model,
                situation: situation
            )
            // 并发发出去。两件事互不相干——一边失败了另一边照常换掉。
            async let generated = suggester.suggestions()
            async let written: Void = writeQuickSummary(for: situation, settings: settings)

            await written
            if let questions = try? await generated, isThreadEmpty {
                healthSuggestions = questions
            }
        }
    }

    /// 重新读一遍数据、重新写一遍那段话。详情页上那颗刷新按钮。
    ///
    /// **用户对写出来的那段不满意**是一种没有出口的处境:数据是对的,话没说到点上。给一颗
    /// 按钮就够了——这是他自己按的,不是每回到首屏就自动花一次钱。顺带重查一遍处境:按这颗
    /// 按钮的另一半理由是"我刚同步完手表",那一半不需要模型。
    func regenerateQuickSummary() {
        guard hasHealthData, !isWritingSummary else { return }

        summaryTask?.cancel()
        isWritingSummary = true
        summaryTask = Task {
            let situation = await HealthSituation.detect(interests: await thread.interests())
            guard !Task.isCancelled else {
                isWritingSummary = false
                return
            }
            self.situation = situation
            quickSummary = situation.quickSummary
            guard let settings = try? cloudSettings(),
                  ProviderConsent.granted(settings.provider) else {
                isWritingSummary = false
                return
            }
            await writeQuickSummary(for: situation, settings: settings, alreadyWriting: true)
        }
    }

    /// 流式写那段话。收尾才做校验:写超了、写跑题了整段作废,退回本地那句。
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
                guard !Task.isCancelled else { return }
                latest = text
                quickSummary = QuickSummaryWriter.partial(text)
            }
        } catch {
            quickSummary = situation.quickSummary
            return
        }
        guard !Task.isCancelled else { return }
        if let written = QuickSummaryWriter.parse(latest) {
            quickSummary = written
        } else {
            #if DEBUG
            // 作废这条路是静默的:界面上只表现为"本地那句一直没换掉"。
            print("[首屏那段话] 这次没能用，模型原样输出：\n\(latest)")
            #endif
            quickSummary = situation.quickSummary
        }
    }

    // MARK: - 记忆与快照

    /// 这一轮用的记忆和用药表。**关掉开关只是不给模型看**,不清空盘上那份。
    private func refreshSnapshots() async {
        memory = EngineSettings.memoryEnabled ? await memoryStore.snapshot() : .empty
        medications = EngineSettings.isPluginEnabled(PluginIds.health) && EngineSettings.medicationsEnabled
            ? await medicationStore.snapshot()
            : .empty
    }

    /// app 退到后台:趁这时候把水位线之后攒下的抽一遍。
    ///
    /// 主对话这一份连侧聊一起收:记忆只有一份,侧聊里说的和主对话里说的一样该记。水位线各记
    /// 各的,所以不会重复看。侧聊那一份只收自己(它是刚被说过话的那一条)。
    func harvestMemoryInBackground() {
        guard persists, engineFactory == nil else { return }
        Task {
            await persistTail?.value
            var threads = [thread]
            if isMainThread { threads += await sides.allThreads() }
            await MemoryHarvester.runIfDue(threads: threads, memory: memoryStore, environment: harvestEnvironment())
        }
    }

    /// 一轮回复结束、他安静了半小时:抽一次记忆。切到后台那个触发点在 `ChatView` 里。
    private func scheduleIdleHarvest() {
        guard persists, engineFactory == nil else { return }
        idleHarvestTask?.cancel()
        idleHarvestTask = Task {
            try? await Task.sleep(for: Self.idleHarvestDelay)
            guard !Task.isCancelled else { return }
            harvestMemoryInBackground()
        }
    }

    private static let idleHarvestDelay = Duration.seconds(30 * 60)

    /// 抽取器只需要知道哪些插件开着、各自声明了哪些别记进记忆的话题,不会真的去调工具。
    private func harvestEnvironment() -> PluginEnvironment {
        PluginEnvironment(
            tenant: tenant,
            memoryStore: memoryStore,
            includesHealthData: true,
            medicationStore: medicationStore
        )
    }

    /// 按住说话时提示给识别器的那份词表。和 system 段里那两块是同一份材料。
    var voiceVocabulary: [String] {
        VoiceVocabulary.terms(medications: medications, memory: memory)
    }

    /// 没配 key 时那句引导。**一处定义**:发送被挡下、欢迎卡上那条横幅、首屏那段话底下的
    /// 小字说的都是它。三处各写一句的话,它们会慢慢漂成三种说法,而用户会以为是三件事。
    nonisolated static let cloudSetupGuidance = String(localized: "还没配置云端模型。到设置里填一把 API key，再选 provider 和模型，就能开始问了。")

    /// key 填好了、模型没选上时那句。和上面那句分开:两句话要他做的事不一样,而
    /// 「到设置里填一把 API key」对一个已经填好 key 的人是一句读不懂的话。
    nonisolated static let modelSetupGuidance = String(localized: "还没选好云端模型。到设置里的「模型」那一行选一个，就能开始问了。")

    /// key 存在但没通过验证时那句。**一处定义**:气泡上要认出这一类失败(重试解不掉,
    /// 该去的是设置页),靠的就是和这句对上。
    nonisolated static let authFailureGuidance = String(
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
        guard let failure = messages[index].errorDescription else { return nil }
        // 现在就配不齐:重试发出去的还是同一句话。**现算一次**而不是记在消息上,
        // 这样他配完回来那颗按钮自己就变回「重试」。
        if currentSetupGuidance != nil { return .openSetup }
        return failure == Self.authFailureGuidance ? .openSetup : .retry
    }

    // MARK: - 回复

    private func startReply() {
        isReplying = true
        retryNotice = nil
        idleHarvestTask?.cancel()
        // 定位是异步的,这一次多半来不及赶上下面这轮请求——赶上的是下一句。
        LocationProvider.shared.refresh()
        // 那几条接的是上一段回答,新的一段就要开始写了。
        followUps = []

        currentReplyTask = Task {
            // 一次「回复」可能跨好几轮。队列里的话赶在最后一次请求之后才到时,loop 已经没有
            // 边界可以接它了——那几句在这儿接着跑一轮。停止之后不续跑。
            while !Task.isCancelled {
                dequeueAll()
                beginAssistantMessage()
                await runTurnShrinkingOnOverflow()
                guard !Task.isCancelled, hasQueuedInput else { break }
            }
            isReplying = false
            replyingMessageID = nil
            retryNotice = nil
            currentReplyTask = nil
            // 焦点只管这一轮;回复完就撤。
            focusMedication = nil
            persist()
            if hasPendingBackgroundMessages { await mergeBackgroundMessages() }
            scheduleIdleHarvest()
            await refreshToday()
            onReplyFinished?()
        }
    }

    /// 撞上模型的上下文上限:以前是让用户「开一条新对话」——现在没有新对话可开。改成强制把
    /// 窗口砍到最近两轮,再原样跑一次;砍不动(本来就只剩两轮)才把错误报给用户。
    private func runTurnShrinkingOnOverflow() async {
        do {
            try await runTurn()
        } catch let error where Self.isContextOverflow(error) {
            guard !Task.isCancelled else { return markStopped() }
            guard let index = replyingIndex(), !messages[index].hasVisibleTurnContent,
                  await advanceWindow(force: true, overheadTokens: 0)
            else { return markFailed(error) }
            do {
                try await runTurn()
            } catch {
                finish(with: error)
            }
        } catch {
            finish(with: error)
        }
    }

    private func finish(with error: any Error) {
        if error is CancellationError || Task.isCancelled {
            markStopped()
        } else {
            markFailed(error)
        }
    }

    private static func isContextOverflow(_ error: any Error) -> Bool {
        if case AgentError.contextWindowExceeded = error { return true }
        if case AgentLoopError.contextWindowExceeded = error { return true }
        return false
    }

    private func runTurn() async throws {
        await refreshSnapshots()
        var engine = try await resolveEngine()
        // 请求之前先看窗口该不该滑:固定开销(system 段、工具定义)先从预算里扣掉。滑动之后
        // 「有原文滑出去了」这件事变了,召回该不该挂也跟着变——所以要重新装配一次。
        if await advanceWindow(force: false, overheadTokens: engine.requestOverheadTokens()) {
            engine = try await resolveEngine()
        }
        // 说好要发的那几张原图,冷启动之后只剩一个文件名。补在这儿——**拿到引擎之后、
        // 发请求之前**:能不能带图是这一轮手上这个引擎的属性,而它每轮现造。
        await loadImagePayloads(supportsVision: engine.supportsVision)
        let history = windowMessages().filter { !$0.isQueued }
        let stream = engine.reply(to: history, pendingInput: pendingInputProvider())
        for try await event in stream {
            apply(event)
        }
        // AsyncThrowingStream 的消费者被取消时,`for try await` 是**正常**结束的,
        // 不抛 CancellationError。只靠 catch 抓不到"用户按了停止"。
        if Task.isCancelled { markStopped() }
    }

    /// 在列表末尾起一条空回复,并把它定为接下来所有事件的收件人。
    @discardableResult
    private func beginAssistantMessage(inlining inlined: [UUID] = []) -> UUID {
        let message = ChatMessage(
            role: .assistant,
            text: "",
            storedTurn: .init(inlinedMessageIDs: inlined)
        )
        messages.append(message)
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
        if messages[index].hasVisibleTurnContent {
            dirtyIds.insert(previousID)
            // 前半段和后半段在 runtime 眼里是**同一轮**:整轮的 transcript 到最后会一次性
            // 落在后半段上,里面已经含了前半段说过的话。回放时要跳过前半段那条气泡。
            inlined.append(previousID)
        } else {
            messages.remove(at: index)
        }
        beginAssistantMessage(inlining: inlined)
    }

    /// 排队中的那几条这就要作为普通历史发出去了,不再是「还没进上下文」。
    private func dequeueAll() {
        for index in messages.indices where messages[index].isQueued {
            messages[index].isQueued = false
            dirtyIds.insert(messages[index].id)
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
        for index in messages.indices where messages[index].isQueued {
            messages[index].isQueued = false
            dirtyIds.insert(messages[index].id)
            taken.append(AgentPendingInput(
                id: messages[index].id,
                // 插话也可能带着一张刚拍的图。发的是拼好的那一份,和它当成普通历史发出去时
                // 一模一样(`ChatMessage.modelText`)。
                text: messages[index].modelText
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
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
            messages[index].storedTurn.compaction = artifact
            dirtyIds.insert(messageID)
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
        messages[index].apply(event)
        dirtyIds.insert(messages[index].id)
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
        messages[index].apply(.reasoningDelta(delta))
    }

    /// 从后往前找:收件人几乎总是最后一条,只有用户中途插话时才往前挪那么一两格。
    private func replyingIndex() -> Int? {
        guard let replyingMessageID else { return nil }
        return messages.lastIndex { $0.id == replyingMessageID }
    }

    /// 这两条走的是流结束之后的路,没有事件替它们把缓冲区落下去——按停止的那一刻思考已经
    /// 想了半段,丢掉它等于用户看到的比实际发生的少。
    private func markStopped() {
        flushReasoning()
        guard let index = replyingIndex() else { return }
        messages[index].markStopped()
    }

    private func markFailed(_ error: any Error) {
        flushReasoning()
        guard let index = replyingIndex() else { return }
        messages[index].markFailed(Self.userFacingFailure(error))
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
    nonisolated static func userFacingFailure(_ error: any Error) -> String {
        let raw = error.localizedDescription
        switch ModelFailure.kind(of: raw) {
        case .authentication:
            return authFailureGuidance
        case .quota:
            return String(localized: "这把 key 的额度用完了，或者账户欠着费。到 provider 那边确认额度之后再试一次。")
        case .contextOverflow:
            return String(localized: "这一次要带的内容太多，装不下。把这条消息或附件缩短一点再试一次。")
        case .transient:
            return String(localized: "网络或者模型服务暂时不通，重试几次都没成功。过一会儿再试一次。")
        case .other:
            return raw
        }
    }

    // MARK: - 引擎

    private func resolveEngine() async throws -> any AgentEngine {
        if let engineFactory {
            // 注入假引擎的那条路不挂 hook:hook 的行为由 `FollowUpChipTests` 直接对着
            // `AgentLoop` 验,不必穿过这个状态机。
            return try engineFactory()
        }
        let settings = try cloudSettings()
        let environment = await pluginEnvironment()
        return AIKitEngine(
            providerId: settings.provider,
            model: settings.model,
            environment: environment,
            // 写的那一头由 `PluginContext.isPrivate` 统一堵死:`remember`、用药表的两个写工具
            // 在不留痕的那条对话里根本不挂出去。
            isPrivate: isEphemeral,
            hooks: followUpHooks(settings),
            sideChatTitle: sideChat?.title
        )
    }

    /// 装配要用的全部输入。聊天和抽记忆都从这里取——抽取器要遵守的「哪些话题别记」
    /// 得和聊天时实际挂出去的插件是同一份,不然两边各说各话。
    private func pluginEnvironment() async -> PluginEnvironment {
        // 召回读整条线程的档案;**只有真的有看不见的原文才挂**——没有「看不见的历史」,
        // 就没有可回顾的。不留痕的那条对话不在线程里,也不去翻它。
        let (recall, reach) = await recallSetup()
        return PluginEnvironment(
            tenant: tenant,
            recall: recall,
            recallReach: reach,
            memoryStore: memoryStore,
            // 不留痕照样**读**记忆:承诺的是不往盘上写,不是失忆。
            memory: memory,
            // **每轮现取**:人会走动,而这块东西存在的理由正是「他此刻在哪」。
            location: LocationProvider.shared.snapshot,
            webSearch: .storedKey(),
            webFetch: .direct(),
            exerciseLibrary: .shared,
            // 这台设备的 HealthKit 只有机主一个人的数据。`HealthDataPlugin` 的 `dataScope`
            // 兜着这一条:给家人挂上,查回来的是**机主的**数字。
            includesHealthData: true,
            medicationStore: medicationStore,
            // 用药表同理:不留痕照样**读**——「他不能吃什么」这一条在想问点私密事的时候
            // 尤其不能关掉。
            medications: medications,
            focusMedication: focusMedication,
            // 不留痕的那一层不写任何东西,提醒和目标也不例外——写的那几个本来就会被
            // `isPrivate` 挡掉,整组不带省得连只读的也要解释一遍。
            tasks: isEphemeral ? nil : TasksEnvironment(
                store: taskStore,
                tenantId: tenant.id,
                activeGoals: await taskStore.active().filter { $0.kind == .goal }
            ),
            notes: noteStore
        )
    }

    /// 追问 chip 的宿主。第一次要发请求时才建,之后一直用它。
    private func followUpHooks(_ settings: (provider: String, model: String)) -> AgentHookDispatcher {
        if let hooks { return hooks }

        let suggester = FollowUpSuggester(providerId: settings.provider, model: settings.model)
        let hook = FollowUpSuggestionHook(
            generate: { context in
                // 失败即放弃。追问 chip 没生成出来,用户手上还有固定那几条和输入框。
                (try? await suggester.suggestions(for: context)) ?? []
            },
            deliver: { [weak self] suggestions in
                guard let self, !isReplying else { return }
                followUps = suggestions
            }
        )
        let dispatcher = AgentHookDispatcher([hook])
        hooks = dispatcher
        return dispatcher
    }

    /// 召回够得着哪些线。这条对话自己只翻滑出窗口的那段;别的线(主对话里是全部侧聊,侧聊里是
    /// 主对话和别的侧聊)整条都算看不见——窗口各管各的,互通就靠这一层和记忆。一条都没有就不挂。
    ///
    /// 每轮现算:侧聊刚删掉的话,下一轮就翻不到它(同「删掉的消息必须立刻从档案里消失」)。
    /// 线的名字是给模型看的,固定中文,不跟着界面语言走。
    func recallSetup() async -> (CapabilityRegistry?, RecallReach?) {
        guard persists else { return (nil, nil) }
        let unbounded = Double.greatestFiniteMagnitude
        let own = await hiddenBeforePos()
        var others: [HistoryRecallTools.Source] = []
        var listings: [RecallReach.Listing] = []
        var reachesOtherSideChats = false
        if isSideChat, await mainThread.hasArchiveRows(before: unbounded) {
            others.append(.init(label: "主对话", store: mainThread))
        }
        for chat in await sides.all() where chat.id != sideChat?.id {
            let store = sides.thread(for: chat.id)
            guard await store.hasArchiveRows(before: unbounded) else { continue }
            others.append(.init(label: "侧聊「\(chat.displayTitle)」", store: store))
            reachesOtherSideChats = true
            if isMainThread {
                listings.append(.init(title: chat.displayTitle, lastActiveAt: chat.lastActiveAt))
            }
        }
        var sources = others
        if let own { sources.insert(.init(label: nil, store: thread, hiddenBefore: own), at: 0) }
        guard !sources.isEmpty else { return (nil, nil) }
        guard !others.isEmpty else { return (HistoryRecallTools.registry(sources: sources), nil) }
        let scope = isMainThread
            ? "他开的侧聊"
            : (reachesOtherSideChats ? "主对话和别的侧聊" : "主对话")
        let reach = RecallReach(
            ownHistory: own != nil,
            others: scope,
            sideChats: Array(listings.prefix(RecallReach.maxListed))
        )
        return (HistoryRecallTools.registry(sources: sources), reach)
    }

    // MARK: - 窗口

    /// 窗口起点的位置——它**之前**的才是「滑出去了」的历史。没淘汰过、或者前面什么都没有,
    /// 就没有可翻的。读的是线程里持久化的位置,所以重启之后依然对得上。
    private func hiddenBeforePos() async -> Double? {
        guard persists, let windowStartId, let pos = await thread.position(of: windowStartId) else { return nil }
        return await thread.hasArchiveRows(before: pos) ? pos : nil
    }

    private func windowStartIndex() -> Int {
        windowStartId.flatMap { id in messages.firstIndex { $0.id == id } } ?? 0
    }

    /// 这一轮请求里带的历史:窗口起点往后的全部。窗口之外的原文不发。
    private func windowMessages() -> [ChatMessage] {
        Array(messages.dropFirst(windowStartIndex()))
    }

    /// 窗口滑不滑。涨到高水位才动,一次砍到低水位;`force` 是撞上上下文上限时的救援,
    /// 只留最近两轮。返回窗口起点有没有前移。**淘汰只前移游标**(存进线程 meta),
    /// 消息本身一条不删。
    @discardableResult
    private func advanceWindow(force: Bool, overheadTokens: Int) async -> Bool {
        let start = windowStartIndex()
        let newStart: Int
        if force {
            newStart = ThreadWindow.forceEvict(messages, from: start, keepTurns: Self.forcedKeepTurns)
        } else {
            newStart = ThreadWindow.evict(
                messages,
                from: start,
                policy: .forContext(EngineSettings.contextWindow),
                overheadTokens: overheadTokens
            )
        }
        guard newStart != start, messages.indices.contains(newStart) else { return false }
        let id = messages[newStart].id
        windowStartId = id
        guard persists else { return true }
        // 游标要落在一个盘上有位置的消息上。它多半早就同步过了;没同步过就先等这一次写盘。
        await persistTail?.value
        if await thread.position(of: id) == nil { await persistNow() }
        let pos = await thread.position(of: id)
        await thread.updateMeta { $0.windowStartPos = pos }
        // 有原文要离开窗口了:趁这时候把还没抽过的收割一遍(不等它,也不因此阻塞这一轮)。
        harvestMemoryInBackground()
        return true
    }

    /// 撞上上下文上限时强制留下的最近轮数。
    private static let forcedKeepTurns = 2

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

}

/// 一条回复能往另一条线上搬的那一步。主对话里是「在侧聊里接着聊」,侧聊里是「带回主对话」。
enum SideChatMove: Equatable {
    case none
    case continueInSideChat
    case bringBack
    /// 这一次打开期间已经带回去过了:按完要看得见结果,也别让他连按两次。
    case broughtBack
}

/// 一条报错气泡底下那颗按钮做什么。
///
/// 定在文件层不定在 `ChatViewModel` 里面:气泡的 `==` 是 `nonisolated` 的,而嵌在一个
/// `@MainActor` 类型里的枚举在那儿要多绕一圈。
enum ErrorRecovery {
    case retry
    case openSetup
}
