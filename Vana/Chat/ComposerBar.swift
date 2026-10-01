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

    /// 单行时正好是半高(`ComposerLayout.rowMinHeight` 的一半),画出来就是一颗胶囊;
    /// 长成多行之后才真的当成 27 的圆角用。
    private static let cardRadius: CGFloat = 27

    var body: some View {
        VStack(spacing: 8) {
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

    /// 只剩用药焦点那一颗。没有焦点时整排不存在,不白占 `VStack` 的那一格间距。
    @ViewBuilder
    private var quickRow: some View {
        if model.focusMedication != nil {
            focusChip
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
        }
    }

    /// 「问问这个药」带进来的焦点。只管下一轮回复,回完就撤;点一下提前撤掉。
    @ViewBuilder
    private var focusChip: some View {
        if let focus = model.focusMedication {
            Button {
                model.clearFocus()
            } label: {
                ChipLabel(icon: focus.status.icon, title: focus.name, isOn: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("正在问：\(focus.name)。点一下取消")
        }
    }

    // MARK: - 输入卡片

    /// 一行:加号、输入框、右边的按钮,空着的时候就是一颗胶囊。
    ///
    /// 字多了**只往上长,不换排法**。原来一行放不下就换成上下两层(输入框独占整幅宽,
    /// 按钮沉到底边),而那一下躲不掉是一次跳:按钮挪到字下面,底边又贴着键盘不动,
    /// 正在打的那行字就只能整个往上蹿一颗按钮的高度,同时向左挪一颗加号的宽度、按新宽度
    /// 重新折行——三样一起发生,恰好在他敲字的那一刻。再加上换排靠 `onChange` 改状态,
    /// 比输入框里的字晚一拍,先在窄栏里折出第二行、再翻面。动画只能把这几下拖长,抹不平:
    /// 输入框里的折行是 UIKit 当场排的,不跟着动画走。
    ///
    /// 现在多一行就多一行高,加号和右边那几颗一直停在最底下那一行的高度上(信息、
    /// ChatGPT 都是这个形状)。没有状态、没有门槛,也就没有可以在门槛上来回抖的东西。
    /// 代价是多行时输入框还是夹在两侧按钮中间那一栏里——换来的是打字时它不会动。
    ///
    /// 仍然走同一个 `Layout`,不是 `if` 出两棵树:输入框重建的那一下焦点会丢,敲进去的
    /// 字直接掉在地上。
    private var card: some View {
        ComposerLayout {
            moreMenu
            field
            // 这台设备上认不了中文时整颗不出现,`ComposerLayout` 认三个也认四个。
            if dictation.isEnabled {
                voiceButton
            }
            sendButton
        }
        .padding(.horizontal, 4)
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
        // 家人那边换成他的名字:这一条对话问的是他的事。机主这边不写「问问你的健康数据」——
        // Vana 是日常助手,健康只是其中一个插件。
        TextField(
            model.currentTenant.isOwner
                ? String(localized: "跟 Vana 说点什么…")
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

/// 加号、输入框、右边那一到两颗按钮排成一行。
///
/// 写成 `Layout` 而不是 `HStack(alignment: .bottom)`,是因为按钮要对的不是输入框的底边,
/// 而是「一行高的胶囊」的中线:单行时整排居中,多行时停在最底下那一行的高度上——
/// 两种情况是同一个公式(`ComposerLayout.buttonCenterY`),所以字一行行长出来时按钮
/// 一个点都不跳。
///
/// 右边按几颗算几颗(`subviews[2...]`),不写死是因为按住说话那颗在认不了中文的设备上整个
/// 不出现——按下标点名的话,那时候发送键会被当成麦克风来摆。
struct ComposerLayout: Layout {
    var spacing: CGFloat = 4
    /// 一行时胶囊的最低高度。
    ///
    /// 不靠加输入框的 padding 去撑:那个数字同时决定多行时每一行的松紧,为了让空着的胶囊
    /// 好看一点而把粘进来的六行文字撑开一倍,是拿常见情况换少见情况。写成下限则只在
    /// "一行字撑不满"时起作用,文字一多它自己就让位了。
    nonisolated static let rowMinHeight: CGFloat = 54

    /// 两侧按钮的中线,从卡片顶边量。
    ///
    /// 单行时卡片正好是 `rowMinHeight` 高,这就是正中;多行时卡片往上长,它跟着底边走,
    /// 停在最底下那一行。**不能写成「单行居中、多行沉底」两支**:那是两个公式,第二行
    /// 出来的那一下按钮会从一个跳到另一个,而那正是这一版要去掉的东西。
    ///
    /// 不沉到底边(`height - 按钮高 / 2`):单行时那样会上宽下窄,一条水平对称的胶囊,
    /// 眼睛对这种两三点的偏移比对绝对尺寸敏感得多。
    nonisolated static func buttonCenterY(height: CGFloat) -> CGFloat {
        height - rowMinHeight / 2
    }

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
        let buttonY = bounds.minY + Self.buttonCenterY(height: bounds.height)
        // 右边那几颗从最右往左摆,最后一个 subview 永远贴着右边——发送键的位置不该因为
        // 多出一颗麦克风而挪走。
        var x = bounds.maxX
        for (index, size) in Array(zip(subviews.indices.dropFirst(2), m.trailing)).reversed() {
            subviews[index].place(
                at: CGPoint(x: x, y: buttonY),
                anchor: .trailing,
                proposal: ProposedViewSize(size)
            )
            x -= size.width + spacing
        }
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: buttonY),
            anchor: .leading,
            proposal: ProposedViewSize(m.plus)
        )
        // 输入框竖着居中:单行时它比胶囊矮一点,居中才上下对称;多行时它就是整张卡片的
        // 高度,居中和顶齐是同一个位置。
        subviews[1].place(
            at: CGPoint(x: bounds.minX + m.plus.width + spacing, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: m.fieldWidth, height: m.fieldHeight)
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

        let fieldWidth = max(0, width - plus.width - trailingWidth - spacing * 2)
        // 高度让输入框自己说了算:它内部有 lineLimit 的上限,到第六行就不再长。
        let fieldHeight = subviews[1]
            .sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil))
            .height

        return Metrics(
            plus: plus,
            trailing: trailing,
            fieldWidth: fieldWidth,
            fieldHeight: fieldHeight,
            height: max(Self.rowMinHeight, max(buttons, fieldHeight))
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
