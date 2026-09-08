import PhotosUI
import SwiftUI

/// 底部输入区:一颗玻璃胶囊装下输入框和它的动作,快捷 chip 浮在它上方。
///
/// 整块是浮在对话上的玻璃,不是压着对话的一条不透明工具栏——iOS 26 的底部输入区都是这样,
/// 内容从它下面透出来,用户才看得出自己没滚到底。
struct ComposerBar: View {
    @Bindable var model: ChatViewModel

    /// 焦点由 `ChatView` 持有,不是这一层的私有状态。
    ///
    /// 要收键盘的那几个位置全在外面:会话列表是**盖在同一层上的 overlay**,用药表和健康
    /// 详情是 sheet——这三样谁都不会把输入框从视图层级里摘掉,也就没有人替它收掉第一
    /// 响应者。焦点丢了键盘还在,UIKit 只认后者,于是键盘一直悬在会话列表上面(踩过)。
    /// 收的动作必须发生在那几层盖上来的地方,所以这个开关得在那一层。
    @FocusState.Binding var isFocused: Bool
    /// 文档扫描器。全屏盖上来,不是 sheet:它自己就是一个相机界面。
    @State private var isScanning = false
    @State private var isPickingPhotos = false
    @State private var isImportingFiles = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    /// 正在核对哪一张。识别错一个小数点在健康场景里不是「有点脏数据」,所以发出去之前
    /// 每一张都点得开、改得动。
    @State private var reviewing: DraftAttachment.ID?

    /// 按住说话。**跟着 app 走一份**(`shared`):它管的是麦克风和本机识别模型,那是这台
    /// 设备的东西,不是这条会话的东西。跟着会话走的是词表,由 `model` 每次按下时现给。
    @State private var dictation = VoiceDictation.shared
    @State private var isCancellingVoice = false
    /// 按下去那一刻输入框里已经有的字。说出来的接在它后面,不覆盖。
    @State private var dictationBase = ""

    /// 铺开排还是一行排。**必须是存下来的状态,不能是算出来的属性**:进和出的门槛不一样,
    /// 而"不一样"这件事只有记着上一次的答案才成立。
    @State private var isStacked = false

    /// 单行时正好是半高(`ComposerLayout.rowMinHeight` 的一半),画出来就是一颗胶囊;
    /// 长成多行之后才真的当成 27 的圆角用。
    private static let cardRadius: CGFloat = 27

    /// 开聊之后的追问快捷。
    ///
    /// 只在有消息时出现:空会话的快捷输入是欢迎卡里那几条建议,在这儿再放一遍是重复。
    /// 这几句短到一个 chip 放得下,而且都是「接着上一句问」的问法——追问真正的成本是
    /// 打字,不是想不出问什么。
    ///
    /// 第一颗固定不动:「详细一点」对任何一段回答都成立,而且它正是最想在模型还在写的时候
    /// 点的那一句——生成的那几条要等这一轮答完才有。
    private static let alwaysOn = String(localized: "详细一点")
    /// 生成的还没到、或者压根没生成出来时顶上的三条。
    ///
    /// chip 那排不能空,也不能在答完的那一刻先空一下再抖出来:那一下比这几条泛泛的问法
    /// 难看得多,而它恰好发生在用户刚读完回答、正要往下问的时候。
    private static let fallbackFollowUps = [
        String(localized: "有什么建议？"),
        String(localized: "和上周比呢？"),
        String(localized: "可能是什么原因？")
    ]

    /// 固定那颗 + 三条按刚才那段回答生成的(`FollowUpSuggestionHook`),没有就用兜底。
    ///
    /// 去重不是洁癖:`id` 就是这句话本身,重复的 id 会让 `ForEach` 在换的那一下错位——
    /// 而模型偶尔真的会写出两条一样的,或者写出一条正好等于「详细一点」。
    private var followUpChips: [String] {
        let rest = model.followUps.isEmpty ? Self.fallbackFollowUps : model.followUps
        var seen: Set<String> = [Self.alwaysOn]
        return [Self.alwaysOn] + rest.filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(spacing: 8) {
            // chip 那排自己贴到屏幕两边:横向滚动的东西在离边 12pt 处被切断,看着像是
            // 排版错了而不是「右边还有」。
            quickRow
            // 排在输入框**上方**而不是塞进胶囊里:一张缩略图加一行说明比一行字高得多,
            // 塞进去会把输入框顶成两层,而多数时候这一排根本不存在。
            if !model.draftAttachments.isEmpty {
                attachmentStrip
                imageSendOffer
            }
            // 正在听的时候波形顶掉那句提示:两条一起摞在输入框上方,把对话又往上推一截,
            // 而它们说的是同一件事的两半。
            if dictation.isListening {
                VoiceLevelStrip(level: dictation.level, isCancelling: isCancellingVoice)
            } else if let notice = dictation.notice {
                voiceNotice(notice)
            }
            card.padding(.horizontal, 12)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                scrim
                composerHitShield
            }
        }
        .animation(.smooth(duration: 0.2), value: model.draftAttachments.count)
        // 那一行是识别跑完之后才冒出来的(在那之前不知道认没认出字),所以它自己要有
        // 一次淡入,不能跟着上面那条按件数走的动画。
        .animation(.smooth(duration: 0.2), value: model.imageSendCandidates.count)
        .animation(.smooth(duration: 0.2), value: model.sendingImageCount)
        .animation(.smooth(duration: 0.2), value: dictation.isListening)
        .animation(.smooth(duration: 0.2), value: dictation.notice)
        // 查一遍这台设备上能不能用。查不到中文时那颗按钮整个不出现——一颗按下去只会说
        // 「不支持」的按钮,比没有这颗按钮更糟。
        .task { await dictation.refresh() }
        // 实时上屏:说的字直接落进输入框,他一边说一边看得见认成了什么。松手不发送,所以
        // 这一路和打字是同一条路,`send()` 那边一个字都不用改。
        .onChange(of: dictation.transcript) { _, spoken in
            guard dictation.isListening else { return }
            model.input = VoiceTranscript.merge(base: dictationBase, spoken: spoken)
        }
        .fullScreenCover(isPresented: $isScanning) {
            DocumentScannerView { pages in
                isScanning = false
                AttachmentIntake.scanned(pages, into: model)
            }
            .ignoresSafeArea()
        }
        .photosPicker(
            isPresented: $isPickingPhotos,
            selection: $pickedPhotos,
            maxSelectionCount: ChatViewModel.maxAttachments,
            matching: .images
        )
        .fileImporter(
            isPresented: $isImportingFiles,
            allowedContentTypes: AttachmentImporter.contentTypes,
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            AttachmentIntake.files(urls, into: model)
        }
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            AttachmentIntake.photos(items, into: model)
        }
        .sheet(item: reviewingBinding) { draft in
            AttachmentReviewView(
                draft: draft,
                onChangeText: { model.updateAttachmentText(draft.id, to: $0) },
                // 模型看不了图的时候这颗开关整个不出现:一颗按下去什么都不会改变的开关,
                // 比没有这颗开关更糟(同没配 key 时不挂 `web_search`)。
                onChangeSendsImage: model.modelSupportsVision
                    ? { model.setSendsImage($0, for: draft.id) }
                    : nil,
                visionUnavailableNote: model.visionUnavailableNote,
                onRemove: { model.removeAttachment(draft.id) }
            )
        }
    }

    /// 正在核对的那一张。存的是 id 不是整份 draft:识别是异步回来的,存着旧值的话
    /// 面板会一直显示"正在识别"。
    private var reviewingBinding: Binding<DraftAttachment?> {
        Binding(
            get: { model.draftAttachments.first { $0.id == reviewing } },
            set: { reviewing = $0?.id }
        )
    }

    // MARK: - 待发的照片

    /// 已经拍进来、还没发出去的那几张。
    ///
    /// 每一张都显示识别到了多少行,而不是只放一张缩略图:发出去的是**文字**不是图,
    /// 用户得看得出来这一步到底认到了没有。
    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.draftAttachments) { draft in
                    AttachmentThumbnail(draft: draft) {
                        reviewing = draft.id
                    } onRemove: {
                        model.removeAttachment(draft.id)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// 「这张图里没有字，要让 Vana 直接看图吗？」
    ///
    /// **必须摆在这儿,不能只藏在核对面板里。** 他拍了一顿饭、一处皮疹,那一格显示「没有
    /// 文字」,按发送之后听到的是「我看不了图像本身」——而那正是这颗开关要消掉的那句话。
    /// 藏起来的开关等于没有:他不会为了一件他还不知道存在的事去点开缩略图。
    ///
    /// 反过来,**认出字的照片这一行根本不出现**。化验单、药盒、成分表的信息就是字,本机
    /// 那份文本已经把要的都给了;再问一句「要不要发原图」,是主动请他把一张带着姓名和就诊号
    /// 的照片交出去,而这次对话根本不需要它。
    @ViewBuilder
    private var imageSendOffer: some View {
        let candidates = model.imageSendCandidates
        if !candidates.isEmpty {
            let sending = candidates.count { $0.sendsImage }
            Button {
                model.setSendsImage(sending == 0)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: sending > 0 ? "eye.fill" : "eye")
                        .foregroundStyle(sending > 0 ? Color.accentColor : .secondary)
                    Text(Self.imageSendTitle(candidates: candidates, sending: sending))
                        .font(.footnote)
                        .foregroundStyle(sending > 0 ? .primary : .secondary)
                    Text(sending > 0 ? "撤销" : "好")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// 那一行上写什么。
    ///
    /// 翻过去之后说的是**已经发生的事**(「原图会随这句话发出去」),不是又一次邀请——
    /// 它比「已开启」更像一句能被核对的话,而这一行的全部作用就是在真的交出去之前被看见。
    ///
    /// 还没翻的时候,「没有文字」这半句只在**真的一张都没认出字**时才说。
    /// `.always` 那档下面这几张里可能有化验单,照抄那句话就是在骗他。
    private static func imageSendTitle(candidates: [DraftAttachment], sending: Int) -> String {
        if sending > 0 {
            return sending == 1
                ? String(localized: "原图会随这句话发出去")
                : String(localized: "\(sending) 张原图会随这句话发出去")
        }
        let allBlank = candidates.allSatisfy { !$0.hasText }
        if candidates.count == 1 {
            return allBlank
                ? String(localized: "这张图没有文字，让 Vana 直接看图？")
                : String(localized: "让 Vana 直接看这张图？")
        }
        return allBlank
            ? String(localized: "有 \(candidates.count) 张没有文字，让 Vana 直接看图？")
            : String(localized: "让 Vana 直接看这 \(candidates.count) 张图？")
    }

    /// 玻璃底下的一层渐隐。
    ///
    /// 玻璃本身几乎不挡光,深色下尤其明显:背景纯黑、正文纯白,滚上来的字会和输入框里的字
    /// 直接叠在一起,两句话谁也读不出来(模拟器背景浅,这个只在真机上看得见)。
    ///
    /// 挡掉的是**重叠**,不是「没滚到底」那个提示:字仍然是一路淡出去的,不是被一条硬边
    /// 切断——所以这里是渐变而不是给输入区铺一层不透明底。淡出发生在 chip 那排上方,
    /// 到输入卡片那儿已经全不透明,底下那截安全区也一并盖住。
    private var scrim: some View {
        let background = Color(.systemGroupedBackground)
        return LinearGradient(
            stops: [
                .init(color: background.opacity(0), location: 0),
                .init(color: background.opacity(0.92), location: 0.34),
                .init(color: background, location: 0.55),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        // 往上多铺一截,让淡出从 chip 上方就开始;不加的话渐变只能在 chip 那排里面完成,
        // 等于给 chip 铺了一层灰底。
        .padding(.top, -56)
        .ignoresSafeArea(edges: .bottom)
        // 多出来的那 56pt 压在对话上,不挡掉点击的话,那一条的气泡和工具面板都点不开。
        .allowsHitTesting(false)
    }

    /// 输入区盖在欢迎卡和消息列表上。玻璃之间看起来是空的,但这整块空间已经属于输入区;
    /// 点击不能穿过去落到下面的话题格子上。
    ///
    /// 2026-08-22 真机上点「这张图没有文字，让 Vana 直接看图？ · 好」时,触点穿到了
    /// 欢迎卡同一位置的「睡眠」格子,于是原图没打开,话题却变成了睡眠。透明底本身不参与
    /// 命中测试,所以给它一条空手势来真正接住点击。它只占 `ComposerBar` 自己的高度;
    /// `scrim` 往上多铺的 56pt 仍然不挡聊天内容。
    private var composerHitShield: some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture {}
            .accessibilityHidden(true)
    }

    // MARK: - 快捷 chip

    /// 回复期间这排不再收起来。
    ///
    /// 原来收起来是因为那时候点了也没用。现在点一下就排进队列,下一个工具轮边界就送到模型
    /// 眼前——「详细一点」正是最想在它还在写的时候说的那句。话题和隐私那两颗本来就只在空
    /// 会话时出现,回复期间不会露面。
    @ViewBuilder
    private var quickRow: some View {
        ScrollView(.horizontal) {
            // 一个容器里的玻璃互相认识:靠近时会融到一起,而不是各糊各的背景。
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    goalChip
                    topicChip
                    privacyChip

                    if !model.messages.isEmpty {
                        ForEach(Array(followUpChips.enumerated()), id: \.element) { index, question in
                            Button {
                                model.send(question)
                            } label: {
                                ChipLabel(icon: nil, title: question, isOn: false)
                            }
                            .buttonStyle(.plain)
                            .transition(Self.chipSwap(at: index))
                            .accessibilityLabel("追问：\(question)")
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .scrollIndicators(.hidden)
        // 生成的那几条到了(或者被清掉了)就是这一排在换人。动画挂在这儿而不是交付那一步:
        // 那是 ViewModel,它不该知道屏幕上这一下要花多久。
        .animation(.smooth(duration: 0.3), value: followUpChips)
    }

    /// 换 chip 的那一下。
    ///
    /// 要读成「新的到了」,不是「这一排重建了」——所以是**淡入淡出加一点缩放**,不是横向推走:
    /// 推走会让人以为自己不小心滑了一下这排,而它其实是自己换的。
    ///
    /// 退出比进入快一倍:先把位子空出来,新的再进来。两边一样快的话中间那几帧是两套 chip
    /// 挤在一起,宽度还在变,看着像抖了一下。
    ///
    /// 进入按位次错开 60ms,读起来是三条依次落位而不是整排闪一下。第一颗不参与——它的 id
    /// 从头到尾没变,SwiftUI 根本不会去动它,这是 `id: \.self` 免费换来的。
    private static func chipSwap(at index: Int) -> AnyTransition {
        let shape = AnyTransition.opacity.combined(with: .scale(scale: 0.94, anchor: .leading))
        return .asymmetric(
            insertion: shape.animation(.smooth(duration: 0.3).delay(Double(index) * 0.06)),
            removal: shape.animation(.easeOut(duration: 0.15))
        )
    }

    /// 正在哪条目标线里。
    ///
    /// 只显示,不可点:换目标是换一件事,该回列表里挑,不是在输入框上方顺手切掉。用户得
    /// 一眼看见这句话会落进哪条线——尤其是刚从列表点进来、屏幕上还什么都没有的时候。
    @ViewBuilder
    private var goalChip: some View {
        if model.session.thread?.isGoal == true {
            ChipLabel(
                icon: "target",
                title: model.session.threadTitle ?? SessionThread.goal(UUID()).title,
                isOn: true
            )
            .accessibilityLabel("目标：\(model.session.threadTitle ?? String(localized: "长期目标"))")
        }
    }

    /// 话题。会话还空着时是个可选的菜单,开聊之后只剩显示——中途换话题,前面的上下文就
    /// 对不上了(`selectTopic` 本身也拦着)。
    ///
    /// 目标线不给话题:那条线本来就是横跨好几个话题的一件事,而话题一旦写进 system 段,
    /// 聊到第三段就和正在问的事对不上了(同 `ChatViewModel.open`)。
    @ViewBuilder
    private var topicChip: some View {
        // 话题(跑步、睡眠、心率与 HRV…)每一个都指着一个健康工具。家人那边它们一个都不挂,
        // 选了只会让 system 段声明一个查不了的话题——同这一屏上的话题格子整个不出现。
        if !model.hasHealthData {
            EmptyView()
        } else if model.session.thread?.isGoal == true {
            EmptyView()
        } else if model.messages.isEmpty {
            Menu {
                Button {
                    model.selectTopic(nil)
                } label: {
                    Label("不限话题", systemImage: "circle.dashed")
                }

                Section("运动") {
                    ForEach(ChatTopics.workouts) { topic in
                        Button {
                            model.selectTopic(topic)
                        } label: {
                            Label(topic.name, systemImage: topic.icon)
                        }
                    }
                }

                Section("指标") {
                    ForEach(ChatTopics.metrics) { topic in
                        Button {
                            model.selectTopic(topic)
                        } label: {
                            Label(topic.name, systemImage: topic.icon)
                        }
                    }
                }
            } label: {
                ChipLabel(
                    icon: model.session.topic?.icon ?? "text.bubble",
                    title: model.session.topic?.name ?? String(localized: "话题"),
                    isOn: model.session.topic != nil
                )
            }
            // Menu 会拿 tint 给 label 上色,盖过 chip 自己的前景色——不改的话没选话题
            // 的 chip 也是一颗蓝的,和「已选中」长得一样。
            .tint(model.session.topic == nil ? Color.secondary : Color.accentColor)
            .accessibilityLabel("话题：\(model.session.topic?.name ?? String(localized: "不限"))")
        } else if let topic = model.session.topic {
            ChipLabel(icon: topic.icon, title: topic.name, isOn: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("话题：\(topic.name)")
        }
    }

    /// 隐私对话开关。**只在会话还空着时出现**。
    ///
    /// 开聊之后这颗就整个消失,不留一条不可点的说明文字:那条文字长得和旁边的追问 chip
    /// 一模一样,点不动只会让人以为坏了。开聊之后的状态归导航栏副标题
    /// (`ChatView`),那是整条会话的属性,本来就该一直挂在那儿,而不是混在一排动作里。
    ///
    /// 开关本身也只在空会话时能动:说好不存就是不存,不给中途推翻的机会。
    @ViewBuilder
    private var privacyChip: some View {
        if model.messages.isEmpty {
            Button {
                model.setPrivate(!model.session.isPrivate)
            } label: {
                // 用 eye.slash 而不是 lock:锁在这个语境里读作「加密了」,而这一句照样
                // 要发给云端模型。图标也是承诺的一部分,不能替文案吹一个做不到的牛。
                ChipLabel(
                    icon: "eye.slash",
                    title: String(localized: "隐私"),
                    isOn: model.session.isPrivate
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("隐私对话，不保存这条对话")
            .accessibilityAddTraits(model.session.isPrivate ? [.isButton, .isSelected] : .isButton)
        }
    }

    // MARK: - 输入卡片

    /// 平时是一行:加号、输入框、发送,空着的时候就是一颗胶囊。
    ///
    /// 长到三行就换成上下两层,输入框独占一整幅宽度,按钮沉到底边:粘一整段病历进来的时候,
    /// 夹在两颗按钮中间的那一栏只有七成宽,同样的字要多占两行,还越读越窄。
    ///
    /// 两种排法走同一个 `Layout`,不是 `if` 出两棵树:`if` 换支的那一下输入框会被拆了
    /// 重建,焦点跟着没,重建之后敲进去的字直接掉在地上——打到第三行正好触发,再打就没了。
    private var card: some View {
        ComposerLayout(isStacked: isStacked) {
            moreMenu
            field
            // 这台设备上认不了中文时整颗不出现,`ComposerLayout` 认三个也认四个。
            if dictation.isEnabled {
                voiceButton
            }
            sendButton
        }
        .onChange(of: model.input, initial: true) {
            isStacked = Self.stacks(model.input, wasStacked: isStacked)
        }
        .animation(.smooth(duration: 0.2), value: isStacked)
        .padding(.horizontal, 4)
        .padding(.bottom, isStacked ? 4 : 0)
        // iOS 26 的底部输入区是浮在内容上的玻璃,不是压在内容上的一条不透明工具栏:
        // 对话往上滚的时候从它下面透出来,用户才知道自己没滚到底。
        .glassEffect(.regular, in: .rect(cornerRadius: Self.cardRadius, style: .continuous))
        // 卡片比输入框大一圈,点空白处理应也能落进输入框。
        .contentShape(.rect(cornerRadius: Self.cardRadius, style: .continuous))
        .onTapGesture { isFocused = true }
    }

    /// 输入框本体。
    ///
    /// `lineLimit(1...6)` 是给超长粘贴兜底的那一档:到第六行就不再长,里面自己滚。没有它
    /// 的话粘一篇文章进来,输入框会一路顶到屏幕顶上,对话一条都看不见。
    private var field: some View {
        // 家人那边不写「问问你的健康数据」——那句话许的正是这条路上唯一给不了的东西。
        TextField(
            model.hasHealthData
                ? String(localized: "问问你的健康数据…")
                : String(localized: "问问\(model.currentTenant.displayName)的情况…"),
            text: $model.input,
            axis: .vertical
        )
            .lineLimit(1...6)
            .focused($isFocused)
            .submitLabel(.send)
            .onSubmit { model.send() }
            .padding(.vertical, 13)
            .accessibilityLabel("消息")
    }

    /// 换不换排,只看这段文字本身,不看输入框量出来多高。
    ///
    /// 量高度那版会绕回来:高度决定排版,排版决定输入框有多宽,宽度又决定高度。SwiftUI
    /// 在这个环里会拿着一份过期的行数排版,粘进来的长文有一半根本不显示。
    ///
    /// **门槛必须是两个,不是一个。** 只有一个门槛时,光标停在门槛上的那一刻,每敲一下
    /// 键盘整块输入区就翻一次面——而中文输入法让这件事必然发生:拼音串「kankan」按一格
    /// 宽算是 6,上屏成「看看」之后是 4,**同一句话在敲的过程中宽度是来回跳的**,于是它
    /// 在两种排法之间来回抖(那 0.2 秒的动画把每一次都放大成一次可见的跳动)。所以进和
    /// 出用不同的数:铺开之后要短回 `unstackWidth` 才收回去,中间那 6 格正好盖住一个
    /// 拼音音节的长度。
    ///
    /// 汉字按两格宽估。**这两个数要对着真实的宽度给**:窄排下那一栏被两侧三颗按钮夹着,
    /// 一行只有 22 格上下(十一个汉字),不是原来写的 34——按 34 估的那版要到第四行才
    /// 铺开,而注释里说的一直是第三行。
    nonisolated static func stacks(_ text: String, wasStacked: Bool) -> Bool {
        if text.contains("\n") { return true }

        let limit = wasStacked ? unstackWidth : stackWidth
        var width = 0
        for scalar in text.unicodeScalars {
            width += scalar.value > 0x2E80 ? 2 : 1
            if width > limit { return true }
        }
        return false
    }

    /// 窄排一行约 22 格,满两行就该铺开。
    nonisolated static let stackWidth = 44
    /// 铺开之后一行约 38 格:短到这个数以内,收回窄排也还是两行以内,不会立刻又被推出去。
    nonisolated static let unstackWidth = 38

    /// 加号是**给这句话添东西**,不是「开一条新对话」。
    ///
    /// 原来这颗菜单里放的是新对话和隐私对话——那是「离开这条会话」,和它旁边的输入框、发送
    /// 键根本不是一件事,而输入区里唯一那个"加"的位置本该属于"给这句话加点什么"。两条都挪到
    /// 会话列表那颗「新建」里去了,那儿本来就管这个。
    ///
    /// 三条入口,不是一条的三种降级:文档扫描自己找边纠偏,拍纸质化验单最好;相册是已经拍过
    /// 的那些;文件是医院导出来的 PDF。模拟器上没有摄像头(`isSupported` 为 false),那时候
    /// 相册那条是唯一验得动的入口。
    private var moreMenu: some View {
        Menu {
            // 标题说清这几件东西会怎么被处理。用户按下去之前就该知道图和文件不出这台手机——
            // 而这正是这个功能选择本机识别、不直传图片的全部理由。
            Section("照片在本机识别成文字，文件直接取文字；原图默认不发，发送之前每一张都能单独决定") {
                if DocumentScannerView.isSupported {
                    Button {
                        isScanning = true
                    } label: {
                        Label("拍文件", systemImage: "doc.viewfinder")
                    }
                }

                Button {
                    isPickingPhotos = true
                } label: {
                    Label("从相册选取", systemImage: "photo.on.rectangle")
                }

                Button {
                    isImportingFiles = true
                } label: {
                    Label("选取文件", systemImage: "folder")
                }
            }
        } label: {
            RoundIcon(
                systemName: "plus",
                foreground: AnyShapeStyle(.secondary),
                background: AnyShapeStyle(.fill.tertiary)
            )
        }
        .tint(Color.secondary)
        // 回复期间照样能拍:这一排是排队等着跟下一句一起走的东西,和插话同一个道理。
        // 满了就不再给入口——不然点进相册选完才发现没加进来。
        .disabled(!model.canAttachMore)
        .accessibilityLabel("添加照片或文件")
    }

    // MARK: - 按住说话

    /// 键盘上那颗麦克风一直都在,这一颗多出来的是**上下文**:药名和指标名靠
    /// `VoiceVocabulary` 提示给识别器,而那份东西键盘永远拿不到。
    ///
    /// **回复期间照样能按**:模型正在查数据、用户想起来还要补一句,恰恰是最不方便打字的
    /// 时刻。说出来的字落进输入框,按发送就走现有那条插话队列(`AgentPendingInput`),
    /// loop 那边一行都不用改。
    private var voiceButton: some View {
        VoiceInputButton(
            isListening: dictation.isListening,
            isCancelling: $isCancellingVoice,
            onPress: {
                dictationBase = model.input
                Task {
                    let started = await dictation.start(vocabulary: model.voiceVocabulary)
                    // 资产还没下载好、没给麦克风权限:照实说一句,并把键盘调出来。
                    // 按了没反应是这条路上唯一不能接受的表现。
                    if !started { isFocused = true }
                }
            },
            onRelease: { cancelled in
                guard cancelled else {
                    Task {
                        let spoken = await dictation.stop()
                        model.input = VoiceTranscript.merge(base: dictationBase, spoken: spoken)
                        // 认出字来才调键盘:他多半要改一两个词再发。什么都没认出来的时候
                        // 弹一次键盘只是把屏幕又占掉一半。
                        if !spoken.isEmpty { isFocused = true }
                    }
                    return
                }
                dictation.cancel()
                model.input = dictationBase
            }
        )
    }

    /// 没能录起来时那句话。**必须有**:没有它,按下去只是什么都没发生。
    private func voiceNotice(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .accessibilityAddTraits(.isStaticText)
    }

    /// 这颗按钮做什么,只看输入框里有没有字。
    ///
    /// 以前是「正在回复就是停止」,因为那时候根本发不出去。现在打了字就一定是要发的——
    /// 手指刚敲完一句话,按下去却把上一条答到一半的回复掐了,是这一版最容易惹恼人的一个
    /// 误触。停止仍然一直够得着:输入框空着的时候它就在原位。
    private enum SendAction {
        case send
        case stop
        /// 还有图在认。发出去的会是一条空附件——不如让他等这几百毫秒,而且要看得出在等什么。
        case recognizing
        case idle
    }

    private var sendAction: SendAction {
        guard !model.isLoadingConversation else { return .idle }
        if model.isRecognizingAttachments { return .recognizing }
        let hasText = !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText || !model.draftAttachments.isEmpty { return .send }
        if model.isReplying { return .stop }
        // 停止之后队列里可能还剩着东西,这颗就是「把排着的那几句发出去」。
        return model.hasQueuedInput ? .send : .idle
    }

    private var sendButton: some View {
        let action = sendAction

        return Button {
            switch action {
            case .send: model.send()
            case .stop: model.stopReply()
            case .recognizing, .idle: break
            }
        } label: {
            if action == .recognizing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 44, height: 44)
            } else {
                RoundIcon(
                    systemName: action == .stop ? "stop.fill" : "arrow.up",
                    foreground: AnyShapeStyle(action == .idle ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white)),
                    background: {
                        switch action {
                        case .stop: AnyShapeStyle(Color(.systemRed))
                        case .send: AnyShapeStyle(Color.accentColor)
                        case .recognizing, .idle: AnyShapeStyle(.fill.tertiary)
                        }
                    }()
                )
            }
        }
        .buttonStyle(.plain)
        .disabled(action == .idle || action == .recognizing)
        .accessibilityLabel(accessibilityLabel(for: action))
    }

    private func accessibilityLabel(for action: SendAction) -> String {
        switch action {
        case .stop: String(localized: "停止回复")
        case .recognizing: String(localized: "正在识别照片里的文字")
        case .send, .idle: String(localized: "发送")
        }
    }
}

/// 加号、输入框、右边那一到两颗按钮的两种排法。
///
/// 写成 `Layout` 而不是两个 `HStack`/`VStack` 分支,是为了让这几个视图从头到尾是同一份:
/// 换排的时候输入框不重建,焦点、选区、正在输入的拼音都还在。
///
/// 右边按几颗算几颗(`subviews[2...]`),不写死是因为按住说话那颗在认不了中文的设备上整个
/// 不出现——按下标点名的话,那时候发送键会被当成麦克风来摆。
private struct ComposerLayout: Layout {
    /// 铺开排:输入框独占一整幅宽度在上,两颗按钮沉到底边。
    var isStacked: Bool
    var spacing: CGFloat = 4
    /// 铺开时输入框两侧留的空,让文字和下面那颗加号对不齐得不难看。
    var stackedInset: CGFloat = 8
    /// 一行排时胶囊的最低高度。
    ///
    /// 不靠加输入框的 padding 去撑:那个数字同时决定多行时每一行的松紧,为了让空着的胶囊
    /// 好看一点而把粘进来的六行文字撑开一倍,是拿常见情况换少见情况。写成下限则只在
    /// "一行字撑不满"时起作用,文字一多它自己就让位了。
    var rowMinHeight: CGFloat = 54

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        return CGSize(width: width, height: metrics(width: width, subviews: subviews).height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let m = metrics(width: bounds.width, subviews: subviews)
        let fieldProposal = ProposedViewSize(width: m.fieldWidth, height: m.fieldHeight)
        // 右边那几颗从最右往左摆,最后一个 subview 永远贴着右边——发送键的位置不该因为
        // 多出一颗麦克风而挪走。
        let trailingY = isStacked ? bounds.maxY : bounds.midY
        let trailingAnchor: UnitPoint = isStacked ? .bottomTrailing : .trailing
        var x = bounds.maxX
        for (index, size) in Array(zip(subviews.indices.dropFirst(2), m.trailing)).reversed() {
            subviews[index].place(
                at: CGPoint(x: x, y: trailingY),
                anchor: trailingAnchor,
                proposal: ProposedViewSize(size)
            )
            x -= size.width + spacing
        }

        guard isStacked else {
            // 一行排:所有东西一律**居中**,不是沉到底边。
            //
            // 沉底那版的高度由输入框说了算(它比 44 的按钮高出一点),于是那几颗圆钮上面
            // 空出那一截、下面顶死——胶囊看着上宽下窄。差的只有两三点,但这是一条水平
            // 对称的胶囊,眼睛对这种偏移比对绝对尺寸敏感得多。
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(m.plus)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX + m.plus.width + spacing, y: bounds.midY),
                anchor: .leading,
                proposal: fieldProposal
            )
            return
        }

        // 铺开排:输入框独占一整幅宽度在上,按钮沉到底边。这儿的沉底是对的——它们
        // 本来就是排在文字下面的第二行。
        subviews[1].place(
            at: CGPoint(x: bounds.minX + stackedInset, y: bounds.minY),
            anchor: .topLeading,
            proposal: fieldProposal
        )
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY),
            anchor: .bottomLeading,
            proposal: ProposedViewSize(m.plus)
        )
    }

    private struct Metrics {
        var plus: CGSize
        /// 右边那一到两颗,按 `subviews` 里的先后。
        var trailing: [CGSize]
        var fieldWidth: CGFloat
        var fieldHeight: CGFloat
        var height: CGFloat
    }

    private func metrics(width: CGFloat, subviews: Subviews) -> Metrics {
        let plus = subviews[0].sizeThatFits(.unspecified)
        // 走整数下标,不用 `subviews[2...]`:`LayoutSubviews` 的区间下标会切出另一份
        // `LayoutSubviews`,在这儿量一次尺寸就当场 trap(踩过,崩在启动的第一次排版上)。
        let trailing = subviews.indices.dropFirst(2).map { subviews[$0].sizeThatFits(.unspecified) }
        let trailingWidth = trailing.reduce(0) { $0 + $1.width }
            + spacing * CGFloat(max(0, trailing.count - 1))
        let buttons = max(plus.height, trailing.map(\.height).max() ?? 0)

        let fieldWidth = max(
            0,
            isStacked
                ? width - stackedInset * 2
                : width - plus.width - trailingWidth - spacing * 2
        )
        // 高度让输入框自己说了算:它内部有 lineLimit 的上限,到第六行就不再长。
        let fieldHeight = subviews[1]
            .sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil))
            .height

        return Metrics(
            plus: plus,
            trailing: trailing,
            fieldWidth: fieldWidth,
            fieldHeight: fieldHeight,
            height: isStacked
                ? fieldHeight + spacing + buttons
                : max(rowMinHeight, max(buttons, fieldHeight))
        )
    }
}

/// 卡片底边那两颗圆钮。画到 34,点得到 44——图标再大就把卡片撑高了,但手指够不到的
/// 按钮等于没有。
private struct RoundIcon: View {
    let systemName: String
    let foreground: AnyShapeStyle
    let background: AnyShapeStyle

    var body: some View {
        Image(systemName: systemName)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(foreground)
            .frame(width: 34, height: 34)
            .background(background, in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }
}

private struct ChipLabel: View {
    var icon: String?
    let title: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption)
            }
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
        }
        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 14)
        .frame(height: 38)
        // 选中的那颗染成主色玻璃,不是换一层不透明底色:同一排东西一半玻璃一半实心,
        // 看着像两套控件。
        .glassEffect(
            isOn ? .regular.tint(Color.accentColor).interactive() : .regular.interactive(),
            in: .capsule
        )
        .contentShape(.capsule)
    }
}
