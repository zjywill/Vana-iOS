import Foundation
import Testing
import UIKit
import AgentRuntime

@testable import Vana

/// 拍照识别:表格不能散、发出去的是什么用户看得见、图片不进上下文。
///
/// 这套东西真正会翻车的地方只有一处——**按识别顺序平铺**。「血红蛋白 132 g/L 130-175 ↓」
/// 被拆散重排之后,数值和项目对不上,而模型会一本正经地解释一个错的数。所以大半的用例都在
/// 盯 `RecognizedTextLayout`。
@Suite("Vision")
struct VisionTests {

    // MARK: - 按几何重建

    @Test("同一行的项目和数值留在一行，列之间分得开")
    func tableRowStaysTogether() {
        let text = RecognizedTextLayout.reconstruct([
            RecognizedFragment("血红蛋白", x: 0.05, y: 0.30, width: 0.20, height: 0.03),
            RecognizedFragment("132", x: 0.35, y: 0.30, width: 0.06, height: 0.03),
            RecognizedFragment("g/L", x: 0.50, y: 0.30, width: 0.06, height: 0.03),
            RecognizedFragment("130-175", x: 0.65, y: 0.30, width: 0.12, height: 0.03),
        ])
        #expect(text == "血红蛋白 | 132 | g/L | 130-175")
    }

    @Test("识别顺序不算数，按 y 从上到下、x 从左到右重排")
    func readingOrderIsRestored() {
        // Vision 给回来的顺序是它自己的,不一定是阅读顺序。
        let text = RecognizedTextLayout.reconstruct([
            RecognizedFragment("132", x: 0.35, y: 0.30, width: 0.06, height: 0.03),
            RecognizedFragment("白细胞", x: 0.05, y: 0.35, width: 0.16, height: 0.03),
            RecognizedFragment("血红蛋白", x: 0.05, y: 0.30, width: 0.20, height: 0.03),
            RecognizedFragment("6.1", x: 0.35, y: 0.35, width: 0.06, height: 0.03),
        ])
        #expect(text == "血红蛋白 | 132\n白细胞 | 6.1")
    }

    @Test("挨着的中文不补空格，那是识别把一句话切成了两段")
    func adjacentChineseIsNotPaddedWithSpaces() {
        let text = RecognizedTextLayout.reconstruct([
            RecognizedFragment("血红蛋白", x: 0.05, y: 0.30, width: 0.10, height: 0.03),
            RecognizedFragment("浓度", x: 0.155, y: 0.30, width: 0.05, height: 0.03),
        ])
        #expect(text == "血红蛋白浓度")
    }

    @Test("中文之间空出一格的照样补空格")
    func spacedChineseFieldsKeepTheirGap()  {
        // 「性别：男    年龄：34」在版面上是两格。连起来写成「男年龄」比多一个空格难读得多,
        // 而这一条是真拍出来的化验单抬头上第一眼就能看见的。
        let text = RecognizedTextLayout.reconstruct([
            RecognizedFragment("性别：男", x: 0.05, y: 0.10, width: 0.12, height: 0.03),
            RecognizedFragment("年龄：34", x: 0.185, y: 0.10, width: 0.12, height: 0.03),
        ])
        #expect(text == "性别：男 年龄：34")
    }

    @Test("一行里字号差一倍也还是一行")
    func mixedFontSizesShareARow() {
        // 箭头比项目名矮一半。按「中心点差多少」判会把它甩到下一行去,而那个箭头正是
        // 「偏高还是偏低」的全部信息。
        let text = RecognizedTextLayout.reconstruct([
            RecognizedFragment("总胆固醇", x: 0.05, y: 0.10, width: 0.20, height: 0.04),
            RecognizedFragment("↓", x: 0.80, y: 0.115, width: 0.02, height: 0.015),
        ])
        #expect(text == "总胆固醇 | ↓")
    }

    @Test("上下两行不会被并成一行")
    func separateRowsStaySeparate() {
        let rows = RecognizedTextLayout.rows(from: [
            RecognizedFragment("姓名：张三", x: 0.05, y: 0.10, width: 0.25, height: 0.02),
            RecognizedFragment("门诊号：0421", x: 0.05, y: 0.13, width: 0.30, height: 0.02),
        ])
        #expect(rows.count == 2)
    }

    @Test("空白碎片不占一行")
    func blankFragmentsAreDropped() {
        let text = RecognizedTextLayout.reconstruct([
            RecognizedFragment("  ", x: 0.05, y: 0.10, width: 0.05, height: 0.02),
            RecognizedFragment("体检报告", x: 0.05, y: 0.20, width: 0.20, height: 0.02),
        ])
        #expect(text == "体检报告")
    }

    // MARK: - 截断

    @Test("超长按行截，并数清楚截掉了几行")
    func truncationCutsOnLineBoundaries() {
        let text = (1...10).map { "第\($0)行数据" }.joined(separator: "\n")
        let cut = RecognizedTextLayout.truncated(text, maxCharacters: 20)
        // 半行数据比没有这行更糟:截在行边界上。
        #expect(!cut.text.hasSuffix("第"))
        #expect(cut.text.split(separator: "\n").allSatisfy { $0.hasSuffix("行数据") })
        #expect(cut.droppedLines == 10 - cut.text.split(separator: "\n").count)
        #expect(cut.droppedLines > 0)
    }

    @Test("没超就一个字不动")
    func shortTextIsUntouched() {
        let cut = RecognizedTextLayout.truncated("血红蛋白 | 132", maxCharacters: 4000)
        #expect(cut.text == "血红蛋白 | 132")
        #expect(cut.droppedLines == 0)
    }

    @Test("整张图认成一行时也得留下点东西")
    func oneVeryLongLineStillYieldsText() {
        let cut = RecognizedTextLayout.truncated(String(repeating: "数", count: 500), maxCharacters: 100)
        #expect(cut.text.count == 100)
    }

    // MARK: - 模型收到的那一份

    @Test("每张图各自编号，并说清这是机器认的不是他打的")
    func modelTextNumbersEachPhoto() {
        let text = ChatAttachment.modelText(
            typed: "这两页帮我看看",
            attachments: [
                ChatAttachment(text: "血红蛋白 | 132"),
                ChatAttachment(text: "白细胞 | 6.1"),
            ]
        )
        #expect(text.hasPrefix("这两页帮我看看"))
        #expect(text.contains("【照片 1】"))
        #expect(text.contains("【照片 2】"))
        #expect(text.contains("不是他打的字"))
        #expect(text.contains("血红蛋白 | 132"))
    }

    @Test("截掉的那几行要在发出去的文本里说清楚")
    func modelTextDeclaresTruncation() {
        let text = ChatAttachment.modelText(
            typed: "",
            attachments: [ChatAttachment(text: "第一项", droppedLines: 12)]
        )
        // 不说的话,用户问「最后那项呢」的时候模型会一口咬定没有。
        #expect(text.contains("12 行"))
    }

    @Test("一个字都没认出来不是错误")
    func emptyRecognitionIsNotAnError() {
        let text = ChatAttachment.modelText(typed: "这是什么", attachments: [ChatAttachment(text: "")])
        // 一顿饭、一处皮疹本来就没有字。照实说,别让模型对着一段空白硬编。
        #expect(text.contains("没有识别到文字"))
        #expect(text.contains("看不了图像本身"))
    }

    @Test("没有照片时原样就是他打的那句话")
    func modelTextWithoutAttachmentsIsUnchanged() {
        #expect(ChatAttachment.modelText(typed: "今天走了多少步", attachments: []) == "今天走了多少步")
    }

    // MARK: - 消息与会话

    @Test("发给模型的是拼好的那份，存在消息上的仍然只是他打的字")
    func messageKeepsTypedTextApartFromRecognizedText() {
        let message = ChatMessage(
            role: .user,
            text: "帮我看看",
            attachments: [ChatAttachment(text: "血红蛋白 | 132")]
        )
        // 标题、召回索引、记忆抽取要的是他自己说的那句话——把几千字的化验单掺进去,
        // 会话列表上那行标题会变成一行血常规。
        #expect(message.text == "帮我看看")
        #expect(message.agentDTO.text.contains("血红蛋白 | 132"))
        #expect(message.agentDTO.text.hasPrefix("帮我看看"))
    }

    @Test("附件跟着会话存下来又读回来")
    func attachmentsSurviveARoundTrip() throws {
        let message = ChatMessage(
            role: .user,
            text: "这个能吃吗",
            attachments: [ChatAttachment(text: "布洛芬 | 0.3g", droppedLines: 2, imageFileName: "a.jpg")]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(ChatMessage.self, from: encoder.encode(message))
        let attachment = try #require(restored.attachments.first)
        #expect(attachment.text == "布洛芬 | 0.3g")
        #expect(attachment.droppedLines == 2)
        #expect(attachment.imageFileName == "a.jpg")
    }

    // MARK: - 接到用药表上

    @Test("从识别结果里猜出的名字是第一行的第一格")
    func guessesMedicationNameFromFirstCell() {
        let name = MedicationDraft.guessedName(from: "布洛芬缓释胶囊 | 0.3g × 20粒\n用法：口服")
        #expect(name == "布洛芬缓释胶囊")
    }

    @Test("猜名字跳过空行")
    func guessedNameSkipsBlankLines() {
        #expect(MedicationDraft.guessedName(from: "\n\n褪黑素\n每晚一片") == "褪黑素")
    }

    // MARK: - 隐私会话

    /// 隐私会话是按「有哪些写入路径」定义的,不是按名字。照片是新开的一条写入路径,
    /// 所以这里必须堵上——**图片不落盘**,而识别照常在本机跑、文字照常发得出去。
    @MainActor
    @Test("隐私会话里的照片不落盘，但话照样问得出去")
    func privateSessionKeepsPhotosOffDisk() async throws {
        let client = ScriptedModelClient(
            profile: .init(
                providerId: "anthropic",
                modelId: "claude-sonnet-5",
                contextWindow: 200_000,
                maxOutputTokens: 4_000
            ),
            turns: [.init(text: "这张图里没有文字。")]
        )
        let viewModel = ChatViewModel(
            engineFactory: { LoopEngine(client: client, capabilities: stubRegistry([:])) },
            // 不留痕的那条对话:不读盘、不写盘。
            loadsPersistedThread: false,
            isEphemeral: true
        )

        AttachmentIntake.scanned([Self.blankImage()], into: viewModel)
        try await waitUntil("识别跑完") { !viewModel.isRecognizingAttachments }
        viewModel.send("这是什么")
        try await waitUntil("这轮结束") { !viewModel.isReplying }

        let sent = try #require(viewModel.messages.first { $0.role == .user })
        let attachment = try #require(sent.attachments.first)
        #expect(attachment.imageFileName == nil)
        // 发出去的仍然是文本:图不出本机,而这句话照样有人回答。
        #expect(client.lastPromptText.contains("【照片 1】"))
        #expect(client.lastPromptText.contains("这是什么"))
    }

    /// 选完到摆上之间原来是几秒钟的空白:选择器已经关掉了,输入框上方还是空的,而他刚做完
    /// 一个动作——那读起来不是「慢」,是「没反应」,他会再点一次加号。所以这一排必须在他选完
    /// 的**那一刻**就多出几个格子来,东西还在路上也照样占位。
    @MainActor
    @Test("选完那一刻格子就在，东西还在路上")
    func selectionShowsPlaceholdersImmediately() async throws {
        let viewModel = ChatViewModel(loadsPersistedThread: false)

        AttachmentIntake.scanned([Self.blankImage(), Self.blankImage()], into: viewModel)

        // 这几句之间一个 await 都没有:格子是同步摆上去的。
        #expect(viewModel.draftAttachments.count == 2)
        #expect(viewModel.draftAttachments.allSatisfy { $0.isLoading })
        // 还没读进来的东西发不出去——发出去的会是一条空附件。
        #expect(viewModel.isRecognizingAttachments)

        try await waitUntil("两张都读进来了") {
            viewModel.draftAttachments.allSatisfy { !$0.isLoading }
        }
        // 占位翻面之后是同一格,不是又追加了两张。
        #expect(viewModel.draftAttachments.count == 2)
        #expect(viewModel.draftAttachments.count { $0.preview != nil } == 2)
    }

    /// 六件是上限,占位也要守着它——占位不算数的话,他一次选十张,前六张读进来之后
    /// 后面四个格子会一直转下去,而那时候发送键正被 `isRecognizingAttachments` 压着。
    @MainActor
    @Test("占位也守着一句话最多六件")
    func placeholdersRespectTheAttachmentLimit() throws {
        let viewModel = ChatViewModel(loadsPersistedThread: false)

        let ids = viewModel.reserveAttachments(10)

        #expect(ids.count == ChatViewModel.maxAttachments)
        #expect(viewModel.draftAttachments.count == ChatViewModel.maxAttachments)
        #expect(viewModel.reserveAttachments(1).isEmpty)
    }

    // MARK: - 原图发不发

    /// **默认那档的全部分寸所在。** 认出了字的那些是化验单、药盒、成分表——本机那份文本
    /// 已经把要的都给了,再把带着姓名和就诊号的原图发出去是净亏。所以有字就不主动问。
    @Test("默认那档只问认不出字的那几张")
    func askWhenNoTextOnlyOffersBlankPhotos() {
        var draft = DraftAttachment(preview: UIImage())
        draft.isRecognizing = false
        draft.text = "血红蛋白 | 132"
        #expect(!draft.suggestsImage(under: .askWhenNoText))

        draft.text = ""
        #expect(draft.suggestsImage(under: .askWhenNoText))

        // 还在读、还在认、读不出来的那几格也不问:那时候还不知道认没认出字。
        draft.isRecognizing = true
        #expect(!draft.suggestsImage(under: .askWhenNoText))
        draft.isRecognizing = false
        draft.failure = "这张图读不出来。"
        #expect(!draft.suggestsImage(under: .askWhenNoText))
    }

    /// 三档管的是**主动问不问**,不是**能不能发**。合成一件事的话,一个只拍饭菜的人和一个
    /// 只拍化验单的人会被同一条规则各自逼到一边——那正是「认不出字才发」写死之后固化掉的。
    @Test("认出了字的照片照样发得出去，只是没人主动问")
    func policyGovernsTheOfferNotThePermission() {
        var withText = DraftAttachment(preview: UIImage())
        withText.isRecognizing = false
        withText.text = "血红蛋白 | 132"

        // 开关对任何一张读得出来的照片都开着。
        #expect(withText.canSendImage)

        #expect(!withText.suggestsImage(under: .textOnly))
        #expect(!withText.suggestsImage(under: .askWhenNoText))
        // 「每张都发原图」那档连化验单也要出那一行——他自己设过一次,但每一次真的要交出去
        // 之前仍然该看得见。
        #expect(withText.suggestsImage(under: .always))

        var blank = DraftAttachment(preview: UIImage())
        blank.isRecognizing = false
        // 「只发文字」那档一句话都不说,要发的自己去核对面板里开。
        #expect(!blank.suggestsImage(under: .textOnly))
        #expect(blank.canSendImage)
    }

    /// `.always` 是「默认翻过去」,`.askWhenNoText` 是「问一句」——后者不许替他答应。
    @Test("只有「每张都发原图」那档是默认翻过去的")
    func onlyAlwaysFlipsByDefault() {
        #expect(!PhotoImagePolicy.textOnly.sendsImageByDefault)
        #expect(!PhotoImagePolicy.askWhenNoText.sendsImageByDefault)
        #expect(PhotoImagePolicy.always.sendsImageByDefault)
    }

    /// 文件里的字是原样取出来的,没有「图」这回事——一份 Word 不存在「让模型直接看图」,
    /// 哪一档都一样。
    @Test("文件从来不发原图")
    func documentsNeverSendAnImage() {
        let draft = DraftAttachment(
            documentName: "体检报告.docx",
            text: "",
            droppedLines: 0,
            failure: nil
        )
        #expect(!draft.canSendImage)
        for policy in PhotoImagePolicy.allCases {
            #expect(!draft.suggestsImage(under: policy))
        }
    }

    /// 开了开关,发出去的那条消息里就真的有一张图,而正文里那句「第 N 张」要和它对上。
    @MainActor
    @Test("同意之后原图真的跟着这句话发出去")
    func agreedImageTravelsWithTheMessage() async throws {
        let client = ScriptedModelClient(
            profile: .init(
                providerId: "anthropic",
                modelId: "claude-sonnet-5",
                contextWindow: 200_000,
                maxOutputTokens: 4_000
            ),
            turns: [.init(text: "这看着像一份炒饭。")]
        )
        let viewModel = ChatViewModel(
            engineFactory: { LoopEngine(client: client, capabilities: stubRegistry([:])) },
            loadsPersistedThread: false
        )

        AttachmentIntake.scanned([Self.blankImage()], into: viewModel)
        try await waitUntil("识别跑完") { !viewModel.isRecognizingAttachments }
        // 白纸认不出字,所以这一格是问得出口的那一类。
        #expect(viewModel.draftAttachments.allSatisfy { $0.suggestsImage(under: .askWhenNoText) })
        viewModel.setSendsImage(true)
        #expect(viewModel.sendingImageCount == 1)

        viewModel.send("这是什么")
        try await waitUntil("这轮结束") { !viewModel.isReplying }

        let request = try #require(client.requests.last)
        let files = request.prompt.messages.flatMap { message in
            message.parts.compactMap { part -> AgentTranscript.FilePart? in
                if case .file(let file) = part { return file }
                return nil
            }
        }
        #expect(files.count == 1)
        #expect(files.first?.mediaType == "image/jpeg")

        // 正文换了一句话说。老那句「看不了图像本身」在这一次是假的,而模型会照着它说自己
        // 看不见——那正是这颗开关要消掉的那句回答。
        #expect(client.lastPromptText.contains("随附的第 1 张图"))
        #expect(!client.lastPromptText.contains("看不了图像本身"))
    }

    /// 他设了「每张都发原图」,或者手动翻开了某一张,然后换到一个看不了图的模型上。
    ///
    /// **最后一道闸在发送那一步**,而且认的是这一轮手上那个引擎、不是设置:图是跟着历史每一轮
    /// 重发的,原样发过去是一个 400,而这条对话从此发不出去。摘掉之后正文自动退回那句
    /// 「看不了图像本身」——两句话同源(`carriesImage`),不会出现「说了有图、其实没发」。
    @MainActor
    @Test("模型看不了图时，说好要发的原图在发送那一步被摘掉")
    func imagesAreStrippedForAModelThatCannotSeeThem() async throws {
        let client = ScriptedModelClient(
            profile: .init(
                providerId: "deepseek",
                modelId: "deepseek-chat",
                contextWindow: 64_000,
                maxOutputTokens: 4_000
            ),
            turns: [.init(text: "我看不了图像本身。")]
        )
        let viewModel = ChatViewModel(
            engineFactory: {
                var engine = LoopEngine(client: client, capabilities: stubRegistry([:]))
                engine.supportsVision = false
                return engine
            },
            loadsPersistedThread: false
        )

        AttachmentIntake.scanned([Self.blankImage()], into: viewModel)
        try await waitUntil("识别跑完") { !viewModel.isRecognizingAttachments }
        // 界面那层不该让他走到这儿,但这条闸不能依赖界面:设置是跟着设备走的,
        // 而「在能看图的模型上翻开、然后换模型」是一条真实的路径。
        viewModel.setSendsImage(true, for: try #require(viewModel.draftAttachments.first).id)
        #expect(viewModel.sendingImageCount == 1)

        viewModel.send("这是什么")
        try await waitUntil("这轮结束") { !viewModel.isReplying }

        let request = try #require(client.requests.last)
        let hasFile = request.prompt.messages.contains { message in
            message.parts.contains { if case .file = $0 { return true } else { return false } }
        }
        #expect(!hasFile, "图发给了一个收不了图的模型")
        #expect(client.lastPromptText.contains("看不了图像本身"))
        #expect(!client.lastPromptText.contains("随附的第"), "说了有图，其实没发")
    }

    /// 没点同意就一张图都不发,正文也照旧说「看不了图像本身」。
    @MainActor
    @Test("没点同意就还是只发文字")
    func withoutConsentOnlyTextIsSent() async throws {
        let client = ScriptedModelClient(
            profile: .init(
                providerId: "anthropic",
                modelId: "claude-sonnet-5",
                contextWindow: 200_000,
                maxOutputTokens: 4_000
            ),
            turns: [.init(text: "我看不了图像本身。")]
        )
        let viewModel = ChatViewModel(
            engineFactory: { LoopEngine(client: client, capabilities: stubRegistry([:])) },
            loadsPersistedThread: false
        )

        AttachmentIntake.scanned([Self.blankImage()], into: viewModel)
        try await waitUntil("识别跑完") { !viewModel.isRecognizingAttachments }
        viewModel.send("这是什么")
        try await waitUntil("这轮结束") { !viewModel.isReplying }

        let request = try #require(client.requests.last)
        let hasFile = request.prompt.messages.contains { message in
            message.parts.contains { if case .file = $0 { return true } else { return false } }
        }
        #expect(!hasFile)
        #expect(client.lastPromptText.contains("看不了图像本身"))
    }

    /// 开了开关但图还没从盘上补回来时,正文里那句「原图在下面」不能写。
    ///
    /// 两句话同源(`carriesImage`):说了有图、其实没发,模型会去找一张不存在的图然后
    /// 自己编一个描述出来,而这是用户最没法察觉的一种错。
    @Test("图还没补回来时正文不许说原图在下面")
    func promisedImageNeverOutrunsThePayload() {
        let pending = ChatAttachment(text: "", sendsImage: true, imagePayload: nil)
        let text = ChatAttachment.modelText(typed: "这是什么", attachments: [pending])
        #expect(!text.contains("随附的第"))
        #expect(text.contains("看不了图像本身"))

        let ready = ChatAttachment(text: "", sendsImage: true, imagePayload: "AAAA")
        let readyText = ChatAttachment.modelText(typed: "这是什么", attachments: [ready])
        #expect(readyText.contains("随附的第 1 张图"))
    }

    /// 「第几件」和「随附的第几张图」不是一回事:三件里只有第 3 件带了图,它就是第 1 张。
    /// 对不上的话,模型会去看它上面那张图然后解释错东西。
    @Test("随附图片的编号只数带图的那几件")
    func attachedImagesAreNumberedAmongThemselves() {
        let text = ChatAttachment.modelText(typed: "看看", attachments: [
            ChatAttachment(text: "血红蛋白 | 132"),
            ChatAttachment(text: "白细胞 | 6.1"),
            ChatAttachment(text: "", sendsImage: true, imagePayload: "AAAA"),
        ])
        #expect(text.contains("【照片 3】"))
        #expect(text.contains("随附的第 1 张图"))
        #expect(text.contains("其中 1 张本机一个字都没认出来"))
    }

    /// `sendsImage` 是后加的字段。合成的 decoder 碰到一份老会话会直接抛 `keyNotFound`,
    /// 而那意味着这条会话再也打不开了。
    @Test("老会话里没有这个字段也读得开")
    func olderSessionsDecodeWithoutTheFlag() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","text":"血红蛋白 | 132","droppedLines":0}"#
        let attachment = try JSONDecoder().decode(ChatAttachment.self, from: Data(legacy.utf8))
        #expect(attachment.text == "血红蛋白 | 132")
        #expect(!attachment.sendsImage)
    }

    /// base64 是几十上百 KB,而会话文件是这个 app 里最大的一类数据——`SessionIndexEntry`
    /// 那套增量索引的收益全部来自「只解用得上的键」。图归 `AttachmentStore`,这里只留文件名。
    @Test("图片内容不进会话文件")
    func imagePayloadStaysOutOfTheSessionFile() throws {
        let attachment = ChatAttachment(
            text: "",
            imageFileName: "a.jpg",
            sendsImage: true,
            imagePayload: "VEhJU0lTVEhFSU1BR0U="
        )
        let encoded = try JSONEncoder().encode(attachment)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("VEhJU0lTVEhFSU1BR0U="))
        #expect(json.contains("sendsImage"))
        #expect(json.contains("a.jpg"))
    }

    /// 一张白纸。识别不出文字是**确定**的结果,所以这条用例不会因为 Vision 认得准不准而飘。
    private static func blankImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }
}
