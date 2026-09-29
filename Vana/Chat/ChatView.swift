import SwiftUI
import AgentRuntime

struct ChatView: View {
    @Binding var openedCheckIn: CheckInLaunch?

    @State private var model: ChatViewModel
    /// 不留痕那一层怎么关。主对话是 nil。
    private let onClose: (() -> Void)?
    /// 用药表以 sheet 呈现:详情页那颗「问问 Vana」要回到聊天界面,而从 push 出来的两层里
    /// 退回根视图没有干净的写法。它本来也是一次离开对话的 detour,模态是对的形状。
    @State private var isShowingMedications = false
    /// 「⋯」菜单里 push 出去的那几页。
    @State private var menuRoute: MenuRoute?
    /// 不留痕的那一层:内存里聊,关掉就没。盖在整个主对话上面,不进线程。
    @State private var isShowingEphemeral = false
    /// 「任务」页。
    @State private var isShowingTasks = false
    /// 从「今天」、确认卡、结果消息点进来的那一条任务。
    @State private var openedTask: UUID?
    @State private var jobs = AppJobControls.shared
    /// 首屏那张卡点开之后的那一页。和用药表一样走 sheet:它是一次离开对话的 detour,
    /// 看完就该回到刚才那一屏。
    @State private var isShowingStatus = false
    /// 输入框的焦点。持有它的是这一层而不是 `ComposerBar`:盖住对话的那几层(抽屉、
    /// 两张 sheet、首次那一屏)全在这儿开合,而它们一个都不会把输入框从视图层级里摘掉。
    @FocusState private var isComposerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// 首次那一屏(`DataUseNoticeSheet`)按过没有。设备级,不跟着成员走(同 provider 和
    /// API key):它说的是这台手机怎么工作。健康授权面板要排在它后面。
    @AppStorage(DataUseNotice.acceptedKey) private var hasAcceptedDataUseNotice = false
    /// 「此刻在不在屏幕上」是另一件事,置位在 `.task` 里(第一帧之后)。
    @State private var isShowingDataUseNotice = false
    /// 按了发送但还没配 key 时,把设置页推出来。
    ///
    /// 用 push 不用 sheet:它和 toolbar 上那颗齿轮通向的是同一页,两条路进去的样子该一样,
    /// 而 push 自带一颗返回按钮——sheet 里那一页没有任何一处写着怎么退出去。
    @State private var isShowingCloudSetup = false
    /// 往回翻远了。输入框上方那颗「回到底部」靠它出现。
    ///
    /// 不记「滚到哪儿了」只记「远不远」:见下面 `onScrollGeometryChange` 那段。
    @State private var isScrolledUp = false
    /// 输入区这一刻有多高。那颗「回到底部」浮在它上面,而它会跟着 chip 那排、附件、
    /// 波形一起长高。
    @State private var composerHeight: CGFloat = 0

    init(
        openedCheckIn: Binding<CheckInLaunch?> = .constant(nil),
        isEphemeral: Bool = false,
        onClose: (() -> Void)? = nil
    ) {
        _openedCheckIn = openedCheckIn
        _model = State(initialValue: ChatViewModel(isEphemeral: isEphemeral))
        self.onClose = onClose
    }

    private enum MenuRoute: Hashable {
        case memory
        case plugins
        case settings
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    // 不是 Lazy。`LazyVStack` 对屏幕外的气泡只有估算高度,第一条滚出屏幕
                    // 被回收的那一刻真实高度换成估算值,整段内容高度变一下,贴着底的偏移
                    // 就跟着跳——"尤其是第一条消息"说的就是这个。
                    // 代价可控:一段会话最多几十条(`SessionThreadPolicy` 攒够 40 条就
                    // 另起一段),全量布局一次远比每帧猜错一次便宜。
                    VStack(spacing: 16) {
                        // 空线程时「今天」排在最前面(那时候最前面就是最后面)。有消息之后它是
                        // 今天那一段的段头,见下面的 `todayStrip`。
                        if model.isThreadEmpty || model.isLoadingConversation {
                            todayStrip
                        }

                        if model.isLoadingConversation {
                            ProgressView("正在载入对话")
                                .padding(.top, 40)
                        } else if model.isThreadEmpty {
                            // 锚点挂在整个首屏上,不是只挂欢迎卡:归位归到欢迎卡顶部的话,
                            // 排在它上面的那段不留痕说明正好被顶出屏幕。
                            VStack(spacing: 16) {
                                if model.isEphemeral {
                                    Self.privacyNote
                                }

                                // 排在欢迎卡**前面**:欢迎卡的开头是这个 app 是什么,
                                // 而回头客要的是"我怎么样"。
                                // 「今天」里已经有那张状况卡时让位:同一句话摆两遍,像是出了两件事。
                                if let summary = model.quickSummary,
                                   !model.todayCards.contains(where: { $0.id == TodayCard.healthStatusId }) {
                                    QuickSummaryCard(
                                        text: summary,
                                        // 家人那边没有处境可展开:那份数据属于机主。
                                        onOpen: model.situation == nil
                                            ? nil
                                            : { isShowingStatus = true }
                                    )
                                }

                                WelcomeCard(
                                    setupGuidance: model.engineGuidance,
                                    blurb: model.welcomeBody,
                                    questions: model.suggestions,
                                    tenant: model.currentTenant,
                                    showsHealthAttribution: model.hasHealthData,
                                    onSelectQuestion: model.send,
                                    onOpenSetup: { isShowingCloudSetup = true }
                                )
                            }
                            // 上面有「今天」时收紧:那一排已经留过顶部的空。
                            .padding(.top, model.isEphemeral || model.todayCards.isEmpty ? 24 : 0)
                            .id(Self.welcomeAnchor)
                        } else {
                            // 滑到顶就往前翻一页。放一行真的看得见的东西而不是只挂 onAppear:
                            // 翻页要读盘,那几十毫秒里他得知道上面还有。
                            if model.hasOlderHistory {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .onAppear { model.loadOlder() }
                            }

                            ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                                // 单线程里消息跨天:按天出一条分隔,不然「昨天说的」和「刚才说的」
                                // 在屏幕上长得一样。
                                if index == todayStartIndex {
                                    // 今天那一段的段头:它自己就写着「今天」,日期分隔让位。
                                    todayStrip
                                } else if let label = dayLabel(at: index) {
                                    DaySeparator(label: label)
                                }

                                MessageBubble(
                                    // 正在写的那条不一定是最后一条了:用户能在回复期间接着
                                    // 发消息,那几条排在它后面。
                                    message: message,
                                    taskBoard: model.taskBoard,
                                    isStreaming: message.id == model.replyingMessageID,
                                    canRetry: model.canRetry(message.id),
                                    canDelete: !model.isReplying && !model.isEphemeral,
                                    // `ask_user` 那张卡只有排在最后、而且没有回复在跑的时候
                                    // 才点得动。
                                    canAnswerAsk: message.id == model.messages.last?.id
                                        && !model.isReplying,
                                    // 只有报错的那几条要问一次,它读钥匙串。
                                    recovery: message.errorDescription == nil
                                        ? nil
                                        : model.recovery(for: message.id),
                                    onRetry: { model.retry(message.id) },
                                    onOpenSetup: { isShowingCloudSetup = true },
                                    onDelete: {
                                        message.role == .assistant && !message.isProactive
                                            ? model.deleteExchange(message.id)
                                            : model.deleteMessage(message.id)
                                    },
                                    onWithdraw: { model.withdrawQueued(message.id) },
                                    onOpenTask: { openedTask = $0 },
                                    onAnswerAsk: { callID, answer in
                                        model.answerAsk(
                                            messageID: message.id,
                                            callID: callID,
                                            answer: answer
                                        )
                                    }
                                )
                                    // 手写判等,见 `MessageBubble.==`。
                                    .equatable()
                                    .id(message.id)

                                // 挂在手里这一段的**第一段回答**下面。每条都挂的话它三句话之后
                                // 就变成背景噪音;之后想再看,「关于」页里一直在。
                                if message.id == firstAssistantMessageID {
                                    Self.generatedNotice(healthRelated: isHealthRelated(at: index))
                                }

                                if let folded = message.foldedSpan {
                                    CompactionDivider(artifact: folded)
                                }
                            }

                            // 今天还一句话都没说:排在最后,就在输入框上面——打开 app 第一眼
                            // 看到的正是它。一开口,它就挪到那句话上面去当段头,位置不变。
                            if todayStartIndex == nil {
                                todayStrip.id(Self.todayAnchor)
                            }

                            // 退避重试期间界面上什么都不动的话,等十几秒和卡死没有区别。
                            if let notice = model.retryNotice {
                                Label(notice, systemImage: "arrow.trianglehead.2.clockwise")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .transition(.opacity)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                // 三个角色分开写,别再合回一句 `.defaultScrollAnchor(.bottom)`——那一句
                // 等于把下面三件事一起交给系统,其中两件正好和贴底打架。
                //
                // 进来时落在哪儿:有消息就是最后一条,空会话贴顶(否则欢迎卡被压到屏幕底部)。
                .defaultScrollAnchor(model.messages.isEmpty ? .top : .bottom, for: .initialOffset)
                // 内容不满一屏时顶部对齐。底部对齐的话第一条消息贴着输入区,回复长出来时
                // 整段往上爬,而贴底又在同时改偏移,两边各推各的——那阵跳动就是这么来的。
                .defaultScrollAnchor(.top, for: .alignment)
                // 内容变高时系统不要动偏移。贴底这件事由下面那个 `onChange` 一家说了算:
                // 两套机制盯着同一段内容,谁都不知道对方已经推过一次了。
                .defaultScrollAnchor(nil, for: .sizeChanges)
                // **不能用 `.interactively`。** 那个模式只认一种手势:手指落在键盘上、往下拖,
                // 键盘跟着手走。而这一屏里输入区是浮在键盘上方的 `safeAreaInset`,那条路基本
                // 够不着——于是滚动消息列表怎么滚键盘都不收,而屏幕上又没有别的地方能收它,
                // 用户是真的被困在那儿(踩过)。
                //
                // `.immediately` 自带阈值,不需要另做一个:UIScrollView 要等 pan 越过它自己的
                // slop 才算"开始滚动",所以点一下、手指抖一下都不会收键盘,真的开始滑才收。
                // 流式期间那些 `scrollTo` 是程序滚动,不算手势,不受影响。
                .scrollDismissesKeyboard(.immediately)
                // 输入区是浮在内容上的玻璃,内容从它下面过。软边让文字在那儿淡出,
                // 不然一行字会被硬生生切成两半。
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .onChange(of: scrollKey) { old, new in
                    // 新气泡出现是一次跳转,该有动画。其余都是内容自己长高,贴着走就行
                    // ——流式一秒几十次,每次再起一个 0.25 秒的动画,十几个叠在一起各自
                    // 朝一个已经过期的目标去,那就是抖动。
                    scroll(with: proxy, animated: new.messageCount != old.messageCount)
                }
                // 往前翻了一页:新塞进顶部的内容会把他正看的那条顶下去,滚回刚才那条的顶上。
                .onChange(of: model.olderPageToken) {
                    guard let anchor = model.olderPageAnchor else { return }
                    proxy.scrollTo(anchor, anchor: .top)
                }
                // 他往回翻了多远。**只问一个布尔**,不是把偏移量搬进 `@State`:
                // 手指一路滑下来,后者是每帧一次界面刷新,而这一屏要重画的是整列非 Lazy
                // 的气泡。这里只在跨过门槛的那一下变一次。
                //
                // 「还剩多少内容在看得见的部分下面」只能这么算,别自己拿 offset 去凑:
                // **`containerSize` 已经是扣掉安全区之后的高度**(实测 874 - 116 - 156 = 602),
                // 而 `visibleRect` 是含安全区的那一份。第一版写成
                // `contentSize + insB - (offset + containerSize)`,等于把底部安全区算了两遍——
                // 贴在底部时它算出 284,门槛才 240,于是那颗按钮**一直亮着**(真机上被逮到)。
                //
                // 这一版贴底时算出来是 11(正文底下那 12 点内边距),往回翻 708 点时是 719,
                // 差值和手指走的距离逐点对得上。
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    ScrollBottomDistance.isScrolledUp(
                        contentHeight: geometry.contentSize.height,
                        visibleMaxY: geometry.visibleRect.maxY,
                        bottomInset: geometry.contentInsets.bottom,
                        threshold: Self.jumpToBottomThreshold
                    )
                } action: { _, isAway in
                    isScrolledUp = isAway
                }
                // 输入区挪进 `ScrollViewReader` 里面:那颗「回到底部」要用 `proxy`,
                // 而贴底这件事从头到尾只有 `scroll(with:animated:)` 一个说了算的地方——
                // 为它另起一套滚动机制,就是这一屏最早那阵抖动的来路。
                .safeAreaInset(edge: .bottom) {
                    ComposerBar(model: model, isFocused: $isComposerFocused)
                        // 那颗按钮要浮在输入区**上面**,而它自己不知道输入区有多高
                        // (chip 那排、附件、波形都会让它长高)。量一次交上去。
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            composerHeight = $0
                        }
                }
                // 浮在对话上,**不进输入区那一列**:做成 `VStack` 里的一行,它每次出现和
                // 消失都会把整段对话顶一下——而它恰好在用户正翻着旧消息的时候出现。
                //
                // 也不做成输入区的 `overlay` 往上偏移:画得出来,但**点不着**——画到父视图
                // 框外的那部分收不到触摸,表现是按钮好端端地摆在那儿,按下去什么都不发生
                // (在 iPad 上试过一次)。挂在这一层,它整个落在自己的框里。
                .overlay(alignment: .bottom) {
                    // 空会话时不出:那一屏本来就没有「底部」可回。
                    if isScrolledUp, !model.messages.isEmpty {
                        jumpToBottomButton { scroll(with: proxy, animated: true) }
                            .padding(.bottom, composerHeight + 8)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .animation(.smooth(duration: 0.2), value: isScrolledUp)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(model.isEphemeral ? "不留痕聊天" : "Vana")
            // 隐私是整条会话的属性,不是刚才点过的一个动作,所以它得一直在视线里。放在
            // 标题下面而不是 chip 排里:那排会随着开聊消失,而这条承诺要一直有效。
            .navigationSubtitle(model.navigationSubtitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
            .sheet(isPresented: $isShowingMedications) {
                MedicationListView(model: model)
            }
            .sheet(isPresented: $isShowingTasks) {
                TasksView(board: model.taskBoard)
            }
            .sheet(item: $openedTask) { id in
                NavigationStack {
                    TaskDetailView(board: model.taskBoard, taskId: id)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { openedTask = nil }
                            }
                        }
                }
            }
            // 后台任务点了「开始」,但还没同意把数据发给这家:同样点名征一次。
            .alert(
                Text("发送给 \(CloudCatalog.providerName(for: jobs.pendingConsent?.providerId ?? ""))？"),
                isPresented: Binding(
                    get: { jobs.pendingConsent != nil },
                    set: { if !$0 { jobs.declineConsent() } }
                )
            ) {
                Button("同意并开始", action: jobs.confirmConsent)
                Button("取消", role: .cancel, action: jobs.declineConsent)
            } message: {
                Text("这件后台任务的说明，连同它需要查的资料和记忆，会发送给第三方模型服务来完成，由对方按它自己的隐私政策处理。")
            }
            .sheet(isPresented: $isShowingStatus) {
                HealthStatusView(
                    summary: model.quickSummary ?? HealthSituation.calmSummary,
                    situation: model.situation,
                    isWriting: model.isWritingSummary,
                    // 没配 key 时刷新只重读数据,不重写那段话——那一页得把这件事说清楚,
                    // 否则那颗按钮按下去像是坏的。
                    canGenerate: model.engineGuidance == nil,
                    onRefresh: model.regenerateQuickSummary
                )
            }
            // 盖上来之前先把键盘收掉。挂在状态上而不是那几颗按钮的动作里:抽屉有四个
            // 出口、两张 sheet 也不止一处能开,漏掉任何一个就是那条路上键盘照旧悬着。
            .onChange(of: isCoveringConversation) { _, covering in
                guard covering else { return }
                isComposerFocused = false
            }
            .onAppear {
                model.refreshEngineAvailability()
            }
            // 他按了发送而 key 还没配:直接把设置页推出来。
            //
            // 只弹一次——`needsCloudSetup` 当场置回 false,否则从设置页退回来的那一帧它还是
            // true,这一页会立刻再推自己一次,表现为返回按钮按不动。
            .onChange(of: model.needsCloudSetup) { _, needsSetup in
                guard needsSetup else { return }
                model.needsCloudSetup = false
                isComposerFocused = false
                isShowingCloudSetup = true
            }
            // 第一次要把数据发给这家 provider:点名征一次同意(Guideline 5.1.2(i))。
            // 「同意并发送」把刚才那句原样发出去;「取消」什么都不发,字留在输入框里。
            .alert(
                Text("发送给 \(pendingConsentProviderName)？"),
                isPresented: Binding(
                    get: { model.pendingProviderConsent != nil },
                    set: { if !$0 { model.declineProviderConsent() } }
                )
            ) {
                Button(action: model.confirmProviderConsent) {
                    Text("同意并发送")
                }
                Button(role: .cancel, action: model.declineProviderConsent) {
                    Text("取消")
                }
            } message: {
                Text("你的问题，连同它需要用到的内容（这条对话的往来、从 Apple「健康」读到的聚合数值、长期记忆和用药表里的条目），会发送给第三方模型服务 \(pendingConsentProviderName) 来生成回答，由对方按它自己的隐私政策处理。这台设备上发给这家服务的请求只问这一次；换用其他服务时会再次询问。")
            }
            .navigationDestination(isPresented: $isShowingCloudSetup) {
                SettingsView(chat: model.isEphemeral ? nil : model)
            }
            .navigationDestination(item: $menuRoute) { route in
                switch route {
                case .memory: MemoryView()
                case .plugins: PluginsView(openMedications: { isShowingMedications = true })
                case .settings: SettingsView(chat: model)
                }
            }
            // 切到后台:趁这时候把水位线之后攒下的抽一遍记忆。
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                model.harvestMemoryInBackground()
            }
            .onChange(of: openedCheckIn) { _, checkIn in
                guard let checkIn else { return }
                model.open(checkIn)
                openedCheckIn = nil
            }
            .task {
                // 本地那句处境和首屏建议:零成本,首屏和「今天」共用。
                model.refreshSuggestionsIfNeeded()
                guard !model.isEphemeral else { return }
                isShowingDataUseNotice = !hasAcceptedDataUseNotice
                await requestHealthAuthorization()
            }
            .onChange(of: model.isLoadingConversation) { _, loading in
                guard !loading else { return }
                model.refreshSuggestionsIfNeeded()
            }
        }
        // 不留痕那一层盖在整个主对话上。它自己一个 view model,关掉就连同内存里那几条一起没了。
        .fullScreenCover(isPresented: $isShowingEphemeral) {
            ChatView(isEphemeral: true, onClose: { isShowingEphemeral = false })
        }
        // 第一次打开时先说清楚数据会去哪儿。它排在 HealthKit 授权面板**前面**——反过来的话,
        // 用户先被问「允许 Vana 读取健康数据吗」,再被告知这些数据会发到哪儿去,而告知的意义
        // 全在于它发生在决定之前。
        //
        // 挂在最外层(和抽屉那个 overlay 同一级),不和里面那两张 sheet 挤在 `NavigationStack`
        // 上:它盖住的是整屏,包括导航栏。
        //
        // 授权那次请求挂在 `onDismiss` 上,不挂在「按过了没有」那个状态的 onChange 上:
        // 后者在他按下按钮的**那一帧**就到,而这一屏此刻正在往下退。系统的授权面板要从
        // 同一条 presentation 链上推上来,撞上一次还在进行的 dismiss,那次 present 就
        // 悄悄地不发生——而 HealthKit 那个 await 也跟着永远不回话(2026-08-25 审核报的
        // 「按了没反应」,根子多半在这里:第一次打开正好是这条路)。`onDismiss` 在退场
        // 动画真的结束之后才到,那时候这条链是空的。
        .fullScreenCover(
            isPresented: $isShowingDataUseNotice,
            onDismiss: { Task { await requestHealthAuthorization() } }
        ) {
            DataUseNoticeSheet {
                hasAcceptedDataUseNotice = true
                isShowingDataUseNotice = false
            }
        }
    }

    /// 点名确认那个 alert 上的名字。目录里查得到就用显示名(DeepSeek),查不到
    /// (自建 endpoint、手填的 id)就原样给 id——名字必须有,哪怕不好看。
    private var pendingConsentProviderName: String {
        model.pendingProviderConsent.map(CloudCatalog.providerName(for:)) ?? ""
    }

    /// 有东西盖住对话了吗。
    ///
    /// 四层都在对话**上面**,而不是把对话换掉:抽屉是 overlay,两张 sheet 和首次那一屏
    /// 底下那一屏都还在。所以输入框仍然是第一响应者,键盘不会自己走——push 出去的设置页
    /// 不在这份名单里,那一下输入框真的离开了层级,系统自己会收。
    private var isCoveringConversation: Bool {
        isShowingMedications || isShowingStatus || isShowingDataUseNotice || isShowingEphemeral
            || isShowingTasks || openedTask != nil
    }

    /// 点了一张「今天」卡片。
    private func perform(_ action: TodayAction) {
        switch action {
        case .openTasks: isShowingTasks = true
        case .openTask(let id): openedTask = id
        case .openMemory: menuRoute = .memory
        case .ask(let prompt): model.send(prompt)
        case .openSurface(let id):
            if id == PluginSurface.medications { isShowingMedications = true } else { menuRoute = .plugins }
        case .openHealthStatus: isShowingStatus = true
        }
    }

    /// 家人成员这儿不请求授权。这台设备的健康数据不属于他,请他去授权一份读不到的数据是一句
    /// 说不通的话——而那张面板一旦被按了「不允许」,机主那边也再弹不出来了。
    private func requestHealthAuthorization() async {
        guard hasAcceptedDataUseNotice, model.hasHealthData else { return }
        do {
            try await HealthStore.shared.requestAuthorizationIfNeeded()
        } catch {
            print("HealthKit 授权请求失败：\(error.localizedDescription)")
        }
    }

    /// 拆出来不是为了整洁:连着 toolbar 一起写在 `body` 里,类型检查器就开始超时。
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if let onClose {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭", action: onClose)
            }
        } else {
            // 「任务」:提醒、目标、后台任务。角标是需要他看一眼的那几件。
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingTasks = true
                } label: {
                    Image(systemName: "checklist")
                }
                .badge(model.attentionCount)
                .accessibilityLabel(model.attentionCount > 0 ? "任务，\(model.attentionCount) 件需要你看" : "任务")
            }

            // 一颗「⋯」收住所有「离开对话去看别的东西」:记忆、插件、不留痕、设置。没有会话列表
            // 了,也就没有左上角那颗抽屉按钮;用药表这类领域入口收进插件页,核心界面不认识它们。
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if EngineSettings.isPluginEnabled(PluginIds.health),
                       EngineSettings.isPluginEnabled(PluginIds.healthMedications) {
                        Button {
                            isShowingMedications = true
                        } label: {
                            Label("用药与补剂", systemImage: "pills")
                        }
                    }
                    Button {
                        menuRoute = .memory
                    } label: {
                        Label("Vana 记住的事", systemImage: "brain")
                    }
                    Button {
                        menuRoute = .plugins
                    } label: {
                        Label("插件", systemImage: "puzzlepiece.extension")
                    }
                    Button {
                        isShowingEphemeral = true
                    } label: {
                        Label("不留痕聊天", systemImage: "eye.slash")
                    }
                    Divider()
                    Button {
                        menuRoute = .settings
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
        }
    }

    /// 这一条前面要不要出一条日期分隔:第一条,或者和上一条不在同一天。
    private func dayLabel(at index: Int) -> String? {
        let messages = model.messages
        guard let date = messages[index].createdAt else { return nil }
        if index > 0, let previous = messages[index - 1].createdAt,
           Calendar.current.isDate(previous, inSameDayAs: date) {
            return nil
        }
        return DaySeparator.label(for: date)
    }

    private static let welcomeAnchor = "welcome"
    private static let todayAnchor = "today"

    /// 「今天」:本机数据拼的那几张卡,横着一排。**是对话这一列里的一项,不悬浮**——浮在顶上的话
    /// 对话从它底下穿过去,两层字叠在一起。位置是今天那一段的段头:今天说过话,就排在今天第一条
    /// 消息上面;还没说过,就排在最后。于是每次打开都在眼前,聊起来它也不跟着动。
    /// 左右各伸出 16 点贴到屏幕边,下一张卡才露得出来。不留痕那一层里不出。
    @ViewBuilder
    private var todayStrip: some View {
        if !model.isEphemeral {
            TodayStrip(cards: model.todayCards, onAction: perform)
                .padding(.horizontal, -16)
        }
    }

    /// 今天第一条消息在手里这一段的哪儿。nil:今天还没说过话(或者今天的还没翻到——不会,
    /// 翻页是往前翻的,最新的永远在手里)。
    private var todayStartIndex: Int? {
        model.messages.firstIndex { $0.createdAt.map(Calendar.current.isDateInToday) ?? false }
    }

    /// 离底多远才算"翻上去了"。半屏太迟(他已经翻过好几条了),几十点太早(流式期间
    /// 手指轻轻一顶就冒出来)。240 点大概是一条长回复的高度:少于这个距离,他自己往下
    /// 一划就到了,那颗按钮反而挡着字。
    private static let jumpToBottomThreshold: CGFloat = 240

    /// 会改变内容高度的一切。贴底的触发信号。
    ///
    /// 不拿 `model.messages` 当信号:那要把整条会话深比较一遍,里面含 `storedTurn`
    /// (整份工具原文和逐小时序列),每帧比一遍纯属白干。
    ///
    /// 但也**不能只看正文长度**。回复写完的那一刻正文不再变,而这一帧里高度还在动:
    /// markdown 解析完把星号吃掉、复制那排按钮冒出来、重试提示消失、"正在回复"三个点
    /// 换成正文。少算一样,最后就差那么一截滚不到位——原来差的正是复制那排的高度。
    private struct ScrollKey: Equatable {
        var messageCount = 0
        var isReplying = false
        var hasRetryNotice = false
        var textLength = 0
        /// 思考**有没有**,不是有多长。
        ///
        /// 那颗 chip 是固定尺寸的,思考从 100 字长到 3000 字它一个像素都不动——按长度算的话,
        /// 思考模型每吐一个 token 都会换来一次 `scrollTo`,而 `scrollTo` 要把整列非 Lazy 的
        /// 气泡重新布一遍。真正改高度的只有「从无到有」那一下:chip 冒出来。
        var hasReasoning = false
        var toolCallCount = 0
        /// 已经出结果的工具数。chip 从转圈换成箭头,那一下也在改高度。
        var settledToolCallCount = 0
        /// 排队中的条数。它变的时候不只是多一个气泡:被取走的那条底下那行「Vana 还没看到」
        /// 会消失,整段跟着矮一截。
        var queuedCount = 0
    }

    private var scrollKey: ScrollKey {
        // 正在长高的是那条回复,不一定是最后一条——用户插话之后它后面还跟着几个气泡。
        let replying = model.replyingMessageID.flatMap { id in
            model.messages.last { $0.id == id }
        } ?? model.messages.last
        return ScrollKey(
            messageCount: model.messages.count,
            isReplying: model.isReplying,
            hasRetryNotice: model.retryNotice != nil,
            textLength: replying?.text.count ?? 0,
            hasReasoning: !(replying?.reasoning.isEmpty ?? true),
            toolCallCount: replying?.toolCalls.count ?? 0,
            settledToolCallCount: replying?.toolCalls.count { $0.output != nil } ?? 0,
            queuedCount: model.messages.count { $0.isQueued }
        )
    }

    /// 这一段回答是模型写的、可能有错。
    ///
    /// 首屏那张欢迎卡底下也有一句免责,但它在发出第一条消息之后就再也不出现了——而用户真正
    /// 需要这句话的时刻,恰恰是他正在读一段关于自己身体的结论的时候。
    private static func generatedNotice(healthRelated: Bool) -> some View {
        Label(
            healthRelated
                ? "以上由 AI 生成，可能有误。不构成诊断或用药建议，关键数值请对照原始记录核对。"
                : "以上由 AI 生成，可能有误，重要信息请自行核对。",
            systemImage: "sparkles"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// 这一段回答沾不沾健康(`HealthTopics`):调过健康工具,或者他那句话/回答里出现了健康词。
    private func isHealthRelated(at index: Int) -> Bool {
        let message = model.messages[index]
        let question = model.messages[..<index].last { $0.role == .user }?.text
        return HealthTopics.applies(toolNames: message.toolCalls.map(\.name), texts: [question, message.text])
    }

    /// 第一条模型真的写了字的助手消息(见 `ChatMessage.isModelWritten`)。
    /// `first(where:)` 只读几个标量,不碰 `storedTurn` 那一坨。
    private var firstAssistantMessageID: UUID? {
        model.messages.first(where: \.isModelWritten)?.id
    }

    /// 开着隐私对话、还没开口时说清楚它到底挡住了什么。
    ///
    /// 逐条列出来,而不是笼统一句「保护你的隐私」:这个功能的全部价值就是那句承诺可信,
    /// 而承诺只有具体到「不进哪儿」才可信。最后那句同样要紧——问题终究要发给云端模型才
    /// 有人回答,不说这一句,用户迟早会自己想到,那时候前面几条也跟着不算数了。
    @ViewBuilder
    private static var privacyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("这里说的话不会被保存", systemImage: "eye.slash")
                .font(.subheadline.weight(.medium))
            Text("不进你和 Vana 的那条对话，不写进记忆，也不影响之后给你的建议。关掉就没了。")
            // 和上面两条同一个灰度。把这句压成最淡的一行,等于承认它是不想让人看见的
            // 小字——那正好毁掉了写它的意义。
            Text("能问的照样能问，Vana 也照样认得你。只是问题本身仍然要发给你配置的模型才能回答，这一步不留痕挡不住。")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// 滚到该看的地方:有消息就是最后一条,空会话就是欢迎卡顶部。
    ///
    /// `animated` 由调用方决定,不是由 `reduceMotion` 一家说了算:贴着流式内容走本来就
    /// 不该有动画,那是"位置跟着内容",不是一次跳转。
    /// 翻远了之后回到最新一条。**只有一颗箭头**,不写字:它浮在对话上面,盖住的每一个
    /// 像素都是他正在读的内容。
    private func jumpToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.footnote.weight(.bold))
                .frame(width: 36, height: 36)
                .glassEffect(.regular.interactive(), in: .circle)
                // 画出来是 36 的一颗圆,点得着的是 44 见方——低于 44 的目标在手指底下
                // 就是「按不准」,而它浮在正文上面,再画大一圈又会挡住字。
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("回到最新消息")
    }

    private func scroll(with proxy: ScrollViewProxy, animated: Bool) {
        // 今天还没说过话时「今天」排在最后一条消息下面,贴底要贴到它。
        let target: (id: AnyHashable, anchor: UnitPoint) = model.messages.last
            .map { todayStartIndex == nil && !model.isEphemeral && !model.todayCards.isEmpty
                ? (AnyHashable(Self.todayAnchor), UnitPoint.bottom)
                : (AnyHashable($0.id), UnitPoint.bottom) }
            ?? (AnyHashable(Self.welcomeAnchor), UnitPoint.top)

        if animated, !reduceMotion {
            withAnimation(.smooth(duration: 0.25)) {
                proxy.scrollTo(target.id, anchor: target.anchor)
            }
        } else {
            proxy.scrollTo(target.id, anchor: target.anchor)
        }
    }

}

/// 「还剩多少内容在看得见的部分下面」。
///
/// 拆成纯函数只有一个理由:那次算错**在界面上不报错**,只表现为一颗一直亮着的按钮,
/// 而它是几个几何量之间的关系,不看真机上的数字根本判不出对错。测试里钉着的就是
/// 那两组实测值(`VanaTests/JumpToBottomTests`)。
enum ScrollBottomDistance {
    static func below(contentHeight: CGFloat, visibleMaxY: CGFloat, bottomInset: CGFloat) -> CGFloat {
        contentHeight - visibleMaxY + bottomInset
    }

    static func isScrolledUp(
        contentHeight: CGFloat,
        visibleMaxY: CGFloat,
        bottomInset: CGFloat,
        threshold: CGFloat
    ) -> Bool {
        below(contentHeight: contentHeight, visibleMaxY: visibleMaxY, bottomInset: bottomInset) > threshold
    }
}

/// 折叠分隔线:从这里往上,模型记得的只有一句摘要,不再是逐字的对话。
///
/// 界面上的消息一条没少——压缩只发生在发给模型的那一份里。但用户得知道模型的记忆到哪儿
/// 为止,否则"你刚才不是说过吗"会变成一次莫名其妙的对话。
private struct CompactionDivider: View {
    let artifact: CompactionArtifact

    private var countText: String { String(localized: "以上 \(artifact.sourceMessageIDs.count) 条已折叠") }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                rule
                Text(countText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                rule
            }

            if !artifact.visibleSummary.isEmpty {
                Text(artifact.visibleSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(countText)。\(artifact.visibleSummary)")
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(height: 1)
    }
}

/// 模型思考的入口。和工具那颗 chip 一样,点开是一个面板。
///
/// 思考不是答案。摊在对话流里,几百字的推演会把真正的回答推到屏幕外面去,而且它每一轮
/// 都在长——列表跟着抖。想看的人点一下,不看的人只看到一颗 chip。
private struct ReasoningChip: View {
    let text: String
    /// 还在吐思考。
    let isThinking: Bool

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                // 想的时候图标自己在动,**不挂 `ProgressView`**。那颗转圈是不定式的,转速和
                // 进度没有任何关系,而旁边「正在思考…」五个字已经把同一件事说完了;它转的
                // 又是一件用户此刻完全看不见的事(思考文字全收在这颗 chip 里)。
                //
                // 更实际的代价是它占着 chevron 的位置:「这里能点开」这个唯一有用的暗示,
                // 恰好在最想点开的时候消失,想完那一刻换回来 chip 宽度还跳一下。
                Image(systemName: "brain")
                    .symbolEffect(.pulse, isActive: isThinking)
                Text(isThinking ? "正在思考…" : "思考过程")
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
            .inlineChipStyle()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isThinking ? "正在思考" : "思考过程")
        .accessibilityHint("打开模型的思考过程")
        .sheet(isPresented: $isPresented) {
            ReasoningPanel(text: text, isThinking: isThinking)
        }
    }
}

/// 从底部弹出的思考面板。开着的时候还在想,内容跟着长。
private struct ReasoningPanel: View {
    let text: String
    let isThinking: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                thought.padding(20)
            }
            // 内容长出来时贴着底走:开着面板就是想看它**现在**在想什么,而不是盯着开头那段
            // 不动,新的字全长在屏幕外面。
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(isThinking ? "正在思考" : "思考过程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// 还在想的时候**不挂** `.textSelection`(默认就是不可选)。
    ///
    /// 可选文本走的是另一条明显更重的排版路径,而这段每秒要重排十几次;何况正在动的文字
    /// 本来也选不住。想完了再挂上——那时候它一个字都不会再变了。
    @ViewBuilder
    private var thought: some View {
        let body = Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

        if isThinking {
            body
        } else {
            body.textSelection(.enabled)
        }
    }
}

private struct MessageBubble: View, Equatable {
    let message: ChatMessage
    /// `start_task` 那张确认卡读它。它自己会观察任务表,气泡本身不必跟着重画。
    let taskBoard: TaskBoard
    /// 这条正在生成:生成期间不给操作按钮,retry 一条还没写完的回复没有意义。
    let isStreaming: Bool
    let canRetry: Bool
    /// 能不能删这一条(回答连同它那句提问)。回复在跑的时候不行,不留痕那一层里也没有意义。
    let canDelete: Bool
    /// 这条里的 `ask_user` 卡现在还答得了吗(见 `AskUserCard.isLive`)。
    let canAnswerAsk: Bool
    /// 这条报错底下该给他哪颗按钮:重试,还是去设置。`nil` 是「这条不是报错」。
    ///
    /// 「重试」只对**这一次没成功**有意义;key 没填、模型没选、key 没通过验证那几种,
    /// 按几次都是同一句话——2026-08-19 那次审核就是这么按了两次然后把 build 拒掉的。
    let recovery: ErrorRecovery?
    let onRetry: () -> Void
    let onOpenSetup: () -> Void
    let onDelete: () -> Void
    let onWithdraw: () -> Void
    let onOpenTask: (UUID) -> Void
    let onAnswerAsk: (String, AskUserAnswer) -> Void

    /// 只比画出来会不一样的东西。
    ///
    /// 两个闭包让 SwiftUI 判不了等,于是流式期间上面那二三十条早就定稿的气泡每帧陪着
    /// 重跑一遍 body。闭包捕获的只有 `message.id` 和 view model,判等时忽略它们是安全的
    /// ——不重跑 body 时留在手里的那份捕获的仍然是同一个 id。
    ///
    /// 也顺手绕开 `ChatMessage` 自动合成的 `==`:那里面有 `storedTurn`,整份工具原文加
    /// 每份 `HealthReport` 的逐小时序列,而界面上一个字都不显示。
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isStreaming == rhs.isStreaming
            && lhs.canRetry == rhs.canRetry
            && lhs.recovery == rhs.recovery
            && lhs.canDelete == rhs.canDelete
            && lhs.canAnswerAsk == rhs.canAnswerAsk
            && lhs.message.rendersIdentically(to: rhs.message)
    }

    /// 「还在进行」的唯一出口,永远排在整条回复的最底下。
    ///
    /// 有工具在跑时交给那颗 chip:它自己带着转圈,而且摊平之后就是最后一段。两个都出的话,
    /// 屏幕底下会有两样东西同时在转,而它们说的是同一件事。
    private var showsTrailingIndicator: Bool {
        isStreaming && !message.hasRunningToolCall
    }


    @ViewBuilder
    var body: some View {
        if message.role == .user {
            userMessage
        } else {
            assistantMessage
        }
    }

    /// 用户的气泡。排队中的那几条淡一档,底下补一句说清它到底怎么了。
    ///
    /// 「Vana 还没看到」写得这么直白是有原因的:排队和已送达在屏幕上是同一个气泡,而猜错的
    /// 那个方向恰好是最糟的——以为说过了,其实没说。写「发送中」会让人以为只是慢一点,
    /// 而它可能一直排到这一轮结束。
    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // 拍进来的那几张排在他打的字**上面**:先有图,才有那句「这个怎么看」。
            if !message.attachments.isEmpty {
                MessageAttachmentsView(attachments: message.attachments)
            }

            // 只拍了图、一个字没打时不画那颗气泡:里面会是一个孤零零的省略号,读起来像
            // 他说了句什么没看清。
            if !message.text.isEmpty || message.attachments.isEmpty {
                HStack(alignment: .bottom, spacing: 0) {
                    Spacer(minLength: 52)

                    Text(displayText)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityLabel(message.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            message.isQueued ? Color.accentColor.opacity(0.45) : Color.accentColor,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .layoutPriority(1)
                }
            }

            if message.isQueued {
                Label("Vana 还没看到", systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("这条还在排队，Vana 还没看到")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contextMenu {
            if message.isQueued {
                // 只有排队中的能收回。已经发出去的那句模型已经看过了,从列表里抹掉它只会让
                // 屏幕上的对话和模型记得的对话对不上。
                Button(role: .destructive, action: onWithdraw) {
                    Label("收回", systemImage: "arrow.uturn.backward")
                }
            } else if canDelete {
                // 删的是本机这一份。清理对话只剩这一种细粒度的办法——没有「删这条会话」了。
                Button(role: .destructive, action: onDelete) {
                    Label("删除这条", systemImage: "trash")
                }
            }
        }
    }

    private var assistantMessage: some View {
        // 6 而不是 8:chip 自己带了撑到 44 的点击区,间距再按 8 算,几颗 chip 摞起来会散。
        VStack(alignment: .leading, spacing: 6) {
            // Vana 主动说的(check-in、到点的提醒、回头看的结论、任务结果)要认得出来:它不是
            // 对上一句的回答,看错了会以为模型答非所问。
            if message.isProactive {
                Label(message.origin.label, systemImage: message.origin.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 按发生顺序摊开(见 `ChatMessage.turnSegments`):想一段、说一段、查一次,再来一轮。
            // 全部 chip 堆在正文上面的老排法有三处代价——每插一颗 chip 底下写好的正文整个
            // 往下挪一次(那阵跳动)、「现在查这三项：」被排到它引出的那三次查询下面,以及
            // 四轮思考全被拼进顶上那**一颗** chip,屏幕上看不出哪一轮想过。
            let segments = message.turnSegments
            ForEach(segments) { segment in
                switch segment {
                case .reasoning(let chunk, _):
                    ReasoningChip(
                        // 「正在想」的只可能是最后一段:后面还有正文或 chip,就说明这一段
                        // 早就想完了。
                        text: chunk,
                        isThinking: isStreaming && segment.id == segments.last?.id
                    )
                case .tool(let call):
                    ToolCallChip(call: call)
                case .text(let chunk, _):
                    // 助手这一侧走块级渲染:模型很爱用表格列每日数据,而气泡原来只认行内语法,
                    // 那张表在屏幕上就是一堆竖线和横杠(见 `MarkdownBlocks`)。
                    MarkdownTextView(text: chunk)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(chunk)
                }
            }

            // 一个字都没说完就被插话劈开的前半段,留着思考和工具 chip 就够了——那儿再挂一个
            // "…" 会让人以为模型说了句什么没看清。真的整条空白才用它顶位。
            if !isStreaming, !message.hasVisibleTurnContent {
                MarkdownTextView(text: "…")
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 「还在进行」只由这一个指示器说,而且**永远在整条回复的最底下**。
            //
            // 原来它只在这一轮什么都还没有的那一小段出现(`isWaiting`),模型吐出第一个字就
            // 消失、再也不回来。于是工具跑的那十几秒里正文停着不动,屏幕底部是一句写完的、
            // 静止的话——「在查数据」和「已经答完了」长得一模一样,而唯一的线索(顶上那几颗
            // chip 在转)常常已经滚出屏幕了。
            //
            // 有工具在跑时不出:那颗 chip 自己带着转圈,摊平之后它就是最后一段,本来就在底下。
            if showsTrailingIndicator {
                TypingIndicator()
            }

            // 动作卡排在正文**下面**:模型先说清为什么挑这几个,图跟在后面。反过来的话,
            // 一屏图会把他自己问的那句话推出去,而他还不知道这几张图是干嘛的。
            if showsToolCards, !exerciseMoves.isEmpty {
                ExerciseCardList(moves: exerciseMoves)
                    .padding(.top, 2)
            }

            // 问题卡排在整条回复的最后:它是要他动手的那一件,离输入框越近越好。正文和动作卡
            // 都是给他读的,读完才轮到选。
            //
            // 一轮里问了两次就摆两张(理论上不该发生,系统提示里写着一轮只问一个)。**不去重、
            // 不只留最后一张**:两张卡各自对应上下文里一次真实的提问,吞掉一张会让他答了一个
            // 问题、模型却在等另一个。
            // 派后台任务的那张确认卡。和问题卡一样排在正文下面:先说清为什么要派,再给他按钮。
            ForEach(showsToolCards ? startedTasks : [], id: \.self) { taskId in
                TaskCard(board: taskBoard, taskId: taskId, onOpen: onOpenTask)
                    .padding(.top, 2)
            }

            // 后台任务的结果那条主动消息:详情(全文、来源、它建议的事)在任务页。
            if message.origin == .task, let taskId = message.refTaskId {
                Button {
                    onOpenTask(taskId)
                } label: {
                    Label("查看详情", systemImage: "chevron.right")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
            }

            ForEach(showsToolCards ? askQuestions : [], id: \.id) { asked in
                AskUserCard(
                    question: asked.question,
                    answer: asked.answer,
                    isLive: canAnswerAsk && !isStreaming,
                    onAnswer: { onAnswerAsk(asked.id, $0) }
                )
                .padding(.top, 2)
            }

            // 查询次数用光时这一轮是正常收尾的(该查的多半已经查到),但模型是被打断的,
            // 得说一声,否则用户只看到它说到一半自己停了。
            if message.stoppedAtToolRoundLimit {
                Text("这个问题需要的查询次数超出了单轮上限，缩小范围再问一次会更完整。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if message.errorDescription != nil, let recovery {
                // 用 bordered 不用 glass:它跟着对话一起滚,不是浮在内容上的那一层。
                // 见 `inlineChipStyle` 里那条边界。
                Button(action: recovery == .retry ? onRetry : onOpenSetup) {
                    Label(
                        recovery == .retry ? "重试" : "去设置",
                        systemImage: recovery == .retry ? "arrow.clockwise" : "gearshape"
                    )
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityHint(recovery == .retry ? "重新发送上一条问题" : "去设置里把云端模型配好")
            } else if !isStreaming, !message.text.isEmpty {
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 这一轮工具挑中的动作。**只认工具返回的 id**,不去正文里找标记——模型编一个库里没有的
    /// 名字出来、而正文写着「参考下面的图示」,是这套东西最糟的一种失灵。
    ///
    /// 一轮里调了两次就按顺序接起来,去重:同一个动作出现两张卡,看起来就像渲染坏了。
    private var exerciseMoves: [ExerciseMove] {
        var seen = Set<String>()
        let ids = message.toolCalls
            .flatMap { $0.exerciseIDs ?? [] }
            .filter { seen.insert($0).inserted }
        return ExerciseLibrary.shared.moves(ids: ids)
    }

    /// 卡片(动作卡、问题卡)**等这一轮写完再出**。
    ///
    /// 位置本来就是对的——正文在上、卡在下。反的是**时间顺序**:工具一跑完,`toolCalls` 上就
    /// 带着卡要的东西了,而正文要等下一次请求才吐出来。于是屏幕上先出现几张卡,底下那段本该
    /// 在它们**上面**的回答再慢慢长出来——看起来像卡从一条还没写完的回复中间钻出来的。
    ///
    /// 「等正文开口」不够:模型常常在同一轮里先说一句「我先查一下」再发工具调用,那时候
    /// `text` 已经不是空的了,卡照样抢在正式回答前面。所以判据是**这一轮结束了没有**
    /// (`isStreaming` 覆盖整轮,含中间几个工具轮),没有第二个时机能同时满足这两种情况。
    ///
    /// 代价是卡片在收尾那一刻才出现。可以接受:它本来就是"读完再动手"的东西,而在读的过程中
    /// 让它先占住屏幕底下那块,反而把还在写的正文一直往上顶。
    private var showsToolCards: Bool { !isStreaming }

    private var startedTasks: [UUID] {
        message.toolCalls.compactMap(\.startedTaskId)
    }

    /// 这一轮摆出去的问题卡。**只认工具返回的那份**,不去正文里认 A/B/C(同动作卡)。
    private var askQuestions: [(id: String, question: AskUserQuestion, answer: AskUserAnswer?)] {
        message.toolCalls.compactMap { call in
            call.askQuestion.map { (call.id, $0, call.askAnswer) }
        }
    }

    /// 复制放在外面——它是最常用的那个,不值得多点一下。
    /// 重新回答、删除和这条的时间收进菜单:都是低频操作,平时不该占着屏幕。
    private var actions: some View {
        // 0 而不是 2:两颗都自带 44 的点击区(比画出来的圆宽 4),再加间距,两颗圆之间就散开了。
        HStack(spacing: 0) {
            CopyButton(text: message.text)

            Menu {
                if let createdAt = message.createdAt {
                    Section(createdAt.formatted(date: .abbreviated, time: .shortened)) {
                        menuItems
                    }
                } else {
                    menuItems
                }
            } label: {
                Image(systemName: "ellipsis")
                    .iconChipStyle()
            }
            .accessibilityLabel("更多操作")
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var menuItems: some View {
        if !message.isProactive {
            Button(action: onRetry) {
                Label("重新回答", systemImage: "arrow.clockwise")
            }
            .disabled(!canRetry)
        }

        Button(role: .destructive, action: onDelete) {
            Label(message.isProactive ? "删除这条" : "删除这一问一答", systemImage: "trash")
        }
        .disabled(!canDelete)
    }

    /// 用户那一侧的气泡。**原样显示,不解析**:他打的字不是 markdown,把「1*2*3」当成斜体
    /// 是在替他改写他自己说过的话。助手那一侧走 `MarkdownTextView`。
    private var displayText: AttributedString {
        AttributedString(message.text.isEmpty ? "…" : message.text)
    }
}

/// 复制回复正文。点完图标变对勾,不弹 toast——这种小反馈就地给最省事。
private struct CopyButton: View {
    let text: String

    @State private var hasCopied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            withAnimation(.smooth(duration: 0.15)) { hasCopied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.smooth(duration: 0.15)) { hasCopied = false }
            }
        } label: {
            Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                .iconChipStyle(
                    tint: hasCopied ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasCopied ? "已复制" : "复制回复")
    }
}

/// 模型还没吐出第一个字时的等待态。
///
/// 原来是一个静止的"…",跟一条真的只写了省略号的回复长得一模一样,看不出在动。
private struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        Group {
            if reduceMotion {
                Text("正在回复…")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .frame(width: 7, height: 7)
                            .opacity(isAnimating ? 1 : 0.25)
                            .animation(
                                .easeInOut(duration: 0.55)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.18),
                                value: isAnimating
                            )
                    }
                }
                .foregroundStyle(.secondary)
                .onAppear { isAnimating = true }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 22)
        .accessibilityLabel("正在回复")
    }
}

/// 按天的分隔线。单线程里消息跨天,「昨天说的」和「刚才说的」在屏幕上要分得开。
private struct DaySeparator: View {
    let label: String

    static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return String(localized: "今天") }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天") }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear
            ? .dateTime.month().day().weekday(.abbreviated)
            : .dateTime.year().month().day())
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(.fill.quaternary, in: .capsule)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 打开 app 的第一段话:**现在是什么状况、要不要在意**。
///
/// 首屏原来只有三个问句——而问题的答案 app 本地早就算出来了(`HealthSituation`),用户却要
/// 点一下、再等模型联网查一遍 HealthKit,才听到和本地那句同一个意思的第一段话。
///
/// **卡片上只露前几行。** 这张卡排在欢迎卡前面,占满一屏就把下面的话题和建议全推走了;
/// 而那段话现在要先把现状说清楚,本来就写得比一句长。所以这里截断,读全的地方在详情页
/// (`HealthStatusView`)——顺带,那一页才有位置放「这话是根据哪几个读数说的」和那颗重新
/// 生成的按钮。
///
/// 于是它**成了按钮**——原来不是。理由是这一下通向的是同一件事的下一层(整段话 + 读数),
/// 不是下面那几颗 chip 的第二个入口:那几颗是去提问,这一颗是往下看。
private struct QuickSummaryCard: View {
    let text: String
    /// 家人成员那条路上没有处境可展开(读不到他的健康数据),这时候它退回一张不可点的卡。
    let onOpen: (() -> Void)?

    /// 卡片上最多几行。三行放得下"现状一句 + 判断一句",再多就开始挤下面那张欢迎卡。
    private static let lineLimit = 3

    var body: some View {
        if let onOpen {
            Button(action: onOpen) { card }
                .buttonStyle(.plain)
                .accessibilityHint("查看现在的状况")
        } else {
            card
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.body.weight(.semibold))
                .foregroundStyle(.pink)
                .accessibilityHidden(true)

            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(Self.lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 本地那句先出,模型写的那段一片一片换上去。淡入淡出而不是硬跳:说的是同一
                // 件事,跳一下会让人以为数据在这一秒变了。
                .contentTransition(.opacity)

            if onOpen != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        // 挂在这个视图上,不用 `withAnimation`:全局 transaction 会把这一帧的整个更新扫一遍,
        // 而这一屏底下还挂着话题格子和几颗按钮。
        .animation(.smooth(duration: 0.2), value: text)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// 全新安装、线程还空着时的那张卡。**插件拼出来的**:健康关掉就不提健康,家人那边整张卡
/// 换一套说法(`TenantOpening`)。
private struct WelcomeCard: View {
    let setupGuidance: String?
    let blurb: String
    let questions: [SuggestedQuestion]
    /// 这一屏是谁的。家人那边整张卡换一套说法。
    let tenant: Tenant
    /// 机主、健康开着:第一屏上要说得出数据是从 Apple「健康」来的(Guideline 2.5.1)。
    let showsHealthAttribution: Bool
    let onSelectQuestion: (String) -> Void
    let onOpenSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 没配 key 时这是这一屏最要紧的一句话,所以它排在最前面、能点、点了直接到设置页。
            // 2026-08-16 那次审核员就是从它旁边走过去、直接在输入框里打字、然后收到一个 401 的。
            if let setupGuidance {
                Button(action: onOpenSetup) {
                    HStack(spacing: 12) {
                        Image(systemName: "key.horizontal.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                            .accessibilityHidden(true)

                        Text(setupGuidance)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(12)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("去设置里配置云端模型")
                .accessibilityHint("填写 API key 之后才能开始提问")
            }

            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: tenant.isOwner ? "sparkles" : "doc.text.viewfinder")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                Text(tenant.isOwner ? "你好，我是 Vana" : "从\(tenant.displayName)的化验单和用药开始")
                    .font(.title2.weight(.semibold))

                // 家人这边不能说"直接问步数睡眠心率"——那几个工具根本没挂出去。
                Text(
                    tenant.isOwner
                        ? blurb
                        : "拍一张\(tenant.displayName)的化验单、报告或药盒，Vana 在本机识别成文字再帮你看。\(tenant.displayName)的步数、睡眠、心率这些读不到——Apple 健康数据只有本人有。"
                )
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if showsHealthAttribution {
                    Label(HealthKitAttribution.welcome, systemImage: "heart.text.square.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("试着问")
                    .font(.headline)

                ForEach(questions) { question in
                    Button {
                        onSelectQuestion(question.text)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: question.icon)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)

                            // 一行放不下就缩字号,不换行——换行会把三张卡撑得参差不齐。
                            Text(question.text)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)

                            Spacer(minLength: 8)

                            Image(systemName: "arrow.up")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(
                            .fill.tertiary,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("提问：\(question.text)")
                }
            }
        }
        .padding(20)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    ChatView()
}
