import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 反问用户那张卡。
///
/// 这套东西盯的大半是「不该发生什么」:选项不许被解析成两颗一样的按钮、只有一个选项的
/// "选择"不许画出来、跳过不许被当成占位文案丢掉、后台派生那几轮不许挂这个工具、
/// 末尾那三句不许被删掉。
///
/// 最要紧的两条:**跳过必须真的到得了模型**(否则那颗按钮是假的,它下一轮会换个说法再问
/// 一遍),以及**问题和选项要原样留在上下文里**(否则他下一句只回了「半夜醒」三个字,
/// 几轮之后那三个字接不上任何东西)。
@Suite("AskUser")
struct AskUserTests {

    private func run(_ input: String) async -> CapabilityExecutionResult {
        await AskUserTools.registry().execute(
            CapabilityInvocation(toolCallId: "1", name: AskUserTools.askToolName, input: input)
        )
    }

    private func question(_ result: CapabilityExecutionResult) -> AskUserQuestion? {
        AskUserQuestion.decode(fromToolMetadata: result.output.metadata)
    }

    private static let threeOptions = """
        {"question":"昨晚主要是哪一种睡不好？","options":[\
        {"label":"入睡困难","detail":"躺下半小时以上睡不着"},\
        {"label":"半夜醒"},{"label":"醒得太早"}]}
        """

    // MARK: - 工具

    @Test("问题和选项跟着 metadata 走")
    func buildsQuestion() async {
        let result = await run(Self.threeOptions)
        #expect(!result.isError)

        let asked = try! #require(question(result))
        #expect(asked.question == "昨晚主要是哪一种睡不好？")
        #expect(asked.options.map(\.label) == ["入睡困难", "半夜醒", "醒得太早"])
        #expect(asked.options[0].detail == "躺下半小时以上睡不着")
        #expect(asked.options[1].detail.isEmpty)
        #expect(!asked.allowsMultiple)
    }

    /// **问题和选项要原样写回给模型**,不只回一句「已显示」。这一段跟着 transcript 留在
    /// 上下文里,几轮之后模型要凭它知道当初问的是什么——他下一句只回了「半夜醒」三个字。
    @Test("给模型的那份带着问题和每一条选项")
    func modelTextCarriesTheQuestion() async {
        let result = await run(Self.threeOptions)
        let text = result.output.text
        #expect(text.contains("昨晚主要是哪一种睡不好？"))
        for label in ["入睡困难", "半夜醒", "醒得太早"] {
            #expect(text.contains(label), "少了「\(label)」")
        }
        #expect(text.contains("躺下半小时以上睡不着"))
    }

    /// 少第一句,正文会把选项再抄一遍;少第二句,它问完自己挑一个答案接着分析,这张卡就成了
    /// 摆设;少第三句,他按「跳过」等于什么都没发生。三句都是这个工具真正的产出。
    @Test("末尾那三句都在")
    func footerKeepsItsThreeLines() async {
        let result = await run(Self.threeOptions)
        #expect(result.output.text.contains(AskUserTools.footer))
        #expect(AskUserTools.footer.contains("不要把上面的选项再列一遍"))
        #expect(AskUserTools.footer.contains("停下等他回答"))
        #expect(AskUserTools.footer.contains("不要再问第二遍"))
    }

    /// 一个选项的"选择"不是选择。悄悄画一张只有一颗按钮的卡,模型下次还会这么调;
    /// 报错并说清「这种情况直接用一句话问」,它下次就用一句话问了。
    @Test("选项不够两条时报错，并告诉模型该直接问")
    func rejectsSingleOption() async {
        let result = await run(#"{"question":"是这样吗？","options":[{"label":"是"}]}"#)
        #expect(result.isError)
        #expect(result.output.text.contains("一句话问"))
        #expect(question(result) == nil)
    }

    /// 重复的标签在卡上是两颗一模一样的按钮,而它们发出去的是同一句话——看起来就是坏的。
    @Test("重复的选项去掉；去重之后不够两条一样报错")
    func dropsDuplicateOptions() async {
        let kept = await run(
            #"{"question":"哪种？","options":[{"label":"A"},{"label":"A"},{"label":"B"}]}"#
        )
        #expect(question(kept)?.options.map(\.label) == ["A", "B"])

        let rejected = await run(#"{"question":"哪种？","options":[{"label":"A"},{"label":"A"}]}"#)
        #expect(rejected.isError)
    }

    @Test("超出上限的选项截掉，过长的字截短")
    func clipsToLimits() async {
        let many = (1...9).map { #"{"label":"选项\#($0)"}"# }.joined(separator: ",")
        let result = await run(#"{"question":"\#(String(repeating: "长", count: 80))","options":[\#(many)]}"#)
        let asked = try! #require(question(result))
        #expect(asked.options.count == AskUserQuestion.maxOptions)
        #expect(asked.question.count == AskUserQuestion.maxQuestionCharacters)
    }

    @Test("多选跟着参数走")
    func carriesMultipleFlag() async {
        let result = await run(
            #"{"question":"有哪些？","options":[{"label":"A"},{"label":"B"}],"allowsMultiple":true}"#
        )
        #expect(question(result)?.allowsMultiple == true)
    }

    @Test("参数缺问题时报错")
    func rejectsMissingQuestion() async {
        let result = await run(#"{"options":[{"label":"A"},{"label":"B"}]}"#)
        #expect(result.isError)
    }

    // MARK: - metadata 三种并存

    /// 三种结构化 metadata 共用 `AgentToolOutput.metadata` 一个字段,靠必填键互相解不出来。
    /// 这一条塌了的表现是:一次健康查询底下冒出一张问题卡,或者反过来。
    @Test("和健康报告、动作选择互相解不出来")
    func metadataKindsDoNotCollide() async {
        let asked = try! #require(question(await run(Self.threeOptions)))
        let payload = AskUserQuestion.encodeForToolMetadata(asked)
        #expect(HealthReport.decode(fromToolMetadata: payload) == nil)
        #expect(ExerciseSelection.decode(fromToolMetadata: payload) == nil)

        let report = HealthReport(title: "睡眠", columns: ["日期", "时长"], rows: [.init("08-01", ["7.2"])])
        #expect(AskUserQuestion.decode(
            fromToolMetadata: HealthReport.encodeForToolMetadata(report)
        ) == nil)
        #expect(AskUserQuestion.decode(
            fromToolMetadata: ExerciseSelection.encodeForToolMetadata(.init(moveIDs: ["a"]))
        ) == nil)
    }

    /// 工具跑完那一刻卡片就该认得出来。这条断的表现是屏幕上只有一颗胶囊,没有卡。
    @Test("工具结果落到消息上时卡片认得出来")
    func messagePicksUpTheQuestion() async {
        let result = await run(Self.threeOptions)
        var message = ChatMessage(role: .assistant, text: "")
        message.startToolCall(.init(id: "1", name: AskUserTools.askToolName, input: Self.threeOptions))
        message.finishToolCall(id: "1", output: result.output, isError: false)

        #expect(message.toolCalls.first?.askQuestion?.options.count == 3)
        // 他还没点。空的 `AskUserAnswer` 不能拿来当"没答"——只写一句自定义也是答过了。
        #expect(message.toolCalls.first?.askAnswer == nil)
    }

    // MARK: - 答案

    @Test("单选发出去的就是那个标签")
    func singleChoiceReadsAsASentence() {
        #expect(AskUserAnswer(choices: ["半夜醒"]).messageText == "半夜醒")
    }

    @Test("多选按顿号连起来，自己写的接在后面")
    func joinsChoices() {
        #expect(AskUserAnswer(choices: ["入睡困难", "半夜醒"]).messageText == "入睡困难、半夜醒")
        #expect(
            AskUserAnswer(choices: ["半夜醒"], custom: " 天亮前会醒好几次 ").messageText
                == "半夜醒、天亮前会醒好几次"
        )
        #expect(AskUserAnswer(custom: "都不是").messageText == "都不是")
    }

    /// 按钮上写「发送 2 项」而实际发出去三样,是这张卡唯一会说谎的地方。这两个数只要有一次
    /// 对不上,他下次就得先发一遍看看到底发了什么。
    @Test("按钮上的条数把自己写的那句也算进去")
    func itemCountMatchesWhatGetsSent() {
        #expect(AskUserAnswer(choices: ["心慌", "睡不好"]).itemCount == 2)
        #expect(AskUserAnswer(choices: ["心慌", "睡不好"], custom: "还有点耳鸣").itemCount == 3)
        #expect(AskUserAnswer(custom: "都不是").itemCount == 1)
        #expect(AskUserAnswer().itemCount == 0)

        let answer = AskUserAnswer(choices: ["心慌", "睡不好"], custom: "还有点耳鸣")
        #expect(answer.messageText.components(separatedBy: "、").count == answer.itemCount)
        // 他自己写的那句里带顿号时,数的仍然是他做的选择,不是他句子里的分句。
        #expect(AskUserAnswer(choices: ["心慌"], custom: "还有耳鸣、手麻").itemCount == 2)
    }

    /// 一个勾没打、一个字没写时不发。空消息进去,模型只能猜他想说什么。
    @Test("什么都没选就是空的")
    func emptyAnswerIsEmpty() {
        #expect(AskUserAnswer().isEmpty)
        #expect(AskUserAnswer(custom: "   ").isEmpty)
        #expect(!AskUserAnswer(declined: true).isEmpty)
    }

    /// **这条是这颗按钮的全部意义。** 跳过要变成一条真的用户消息发给模型——
    /// 写成 `textIsPlaceholder` 的话 `ConversationHistoryPlanner` 会整条丢掉,模型永远不知道
    /// 他不想说,下一轮换个说法再问一遍。
    @Test("跳过是一条真的用户消息，不是占位文案")
    func declineReachesTheModel() {
        let answer = AskUserAnswer(declined: true)
        #expect(answer.messageText == AskUserQuestion.declineText)
        #expect(!answer.messageText.isEmpty)

        let message = ChatMessage(role: .user, text: answer.messageText)
        #expect(!message.textIsPlaceholder)
    }

    // MARK: - 挂不挂出去

    @Test("前台会话挂得出来")
    func mountedInForeground() {
        let registry = TestAssembly.engine().capabilityRegistry
        #expect(registry.definition(named: AskUserTools.askToolName) != nil)
    }

    /// 后台派生的那几轮没有人在看。挂出去的话模型会摆一张永远等不到人点的卡,然后自己替他
    /// 假设一个答案接着往下写,而那份结论会原样进早上那条通知。
    @Test("后台派生的那几轮不挂")
    func notMountedInBackground() {
        let registry = TestAssembly.engine(route: .background).capabilityRegistry
        #expect(registry.definition(named: AskUserTools.askToolName) == nil)
    }

    /// 家人成员那条路上健康工具一个都不挂,但问一句话跟谁的健康数据都没关系。
    @Test("家人成员和隐私会话照挂")
    func mountedForFamilyAndPrivateSessions() {
        let family = TestAssembly.engine(TestAssembly.environment(tenant: Tenant(name: "妈妈", kind: .managed))).capabilityRegistry
        #expect(family.definition(named: AskUserTools.askToolName) != nil)

        let privateSession = TestAssembly.engine(isPrivate: true).capabilityRegistry
        #expect(privateSession.definition(named: AskUserTools.askToolName) != nil)
    }

    // MARK: - 系统提示

    /// 同别处照着 registry 拼提示词的规矩:没挂出去就不说这段话。对着一个不存在的工具发指令,
    /// 模型只会调一次、失败一次,再自己想办法圆场。
    @Test("挂了才发那段指令")
    func instructionFollowsTheRegistry() {
        let mounted = TestAssembly.engine().systemInstruction()
        #expect(mounted.contains(AskUserTools.askToolName))
        #expect(mounted.contains("同一个问题不要问第二遍"))
        // 查得到的东西不许问他——问一遍是白花一个往返,而答案就在 HealthKit 里。
        #expect(mounted.contains("查得到的、他说过的、记忆里已有的一律不要问他"))

        let absent = TestAssembly.engine(route: .background).systemInstruction()
        #expect(!absent.contains(AskUserTools.askToolName))
    }
}
