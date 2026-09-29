import SwiftUI
import UIKit

struct SettingsView: View {
    /// 聊天那一屏的 view model。「对话历史」那一页要用它清理——正在回复时不许清,
    /// 清完手里那一段也要跟着换。
    let chat: ChatViewModel?
    /// 插件页里「打开用药与补剂」要回到聊天那一屏去开 sheet。nil 就不给那个入口。
    let openMedications: (() -> Void)?

    @AppStorage(EngineSettings.providerKey) private var providerId = EngineSettings.defaultProvider
    @AppStorage(EngineSettings.modelKey) private var model = EngineSettings.defaultModel
    @AppStorage(EngineSettings.personaKey) private var persona = EngineSettings.defaultPersona
    @AppStorage(EngineSettings.thinkingEnabledKey) private var thinkingEnabled = true
    @AppStorage(EngineSettings.photoImagePolicyKey) private var photoImagePolicy = PhotoImagePolicy.askWhenNoText.rawValue
    @AppStorage(EngineSettings.autoStartTasksKey) private var autoStartTasks = false

    @State private var apiKey = ""
    @State private var persistedAPIKey = ""
    @State private var hasStoredAPIKey = false
    @State private var hasLoadedAPIKey = false
    @State private var keyStatus = KeyStatus.notSet
    @State private var searchKey = ""
    @State private var persistedSearchKey = ""
    @State private var searchKeyStatus = KeyStatus.notSet
    @State private var isTestingConnection = false
    /// 上一次测试的结果。**换了 key / provider / 模型就作废**——一句绿色的「连接正常」
    /// 指着一套已经不存在的配置,比不显示更糟。
    @State private var connectionResult: ConnectionTest.Result?
    @State private var location = LocationProvider.shared
    @State private var dictation = VoiceDictation.shared
    @FocusState private var focusedField: Field?
    @Environment(\.openURL) private var openURL

    init(chat: ChatViewModel? = nil, openMedications: (() -> Void)? = nil) {
        self.chat = chat
        self.openMedications = openMedications
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("API key") {
                    HStack(spacing: 8) {
                        SecureField("必填", text: $apiKey)
                            .focused($focusedField, equals: .apiKey)
                            .multilineTextAlignment(.trailing)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .privacySensitive()
                            .onSubmit(saveAPIKey)
                            .accessibilityLabel("云端 API key")

                        if !apiKey.isEmpty {
                            Button {
                                apiKey = ""
                                focusedField = .apiKey
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除 API key")
                        }
                    }
                }

                Label {
                    // key 全遮住就没法核对填的是哪一把,露头尾足够认人。
                    if keyStatus == .saved, let hint = maskedKey(persistedAPIKey) {
                        Text("\(keyStatus.message) · \(Text(hint).monospaced())")
                    } else {
                        Text(keyStatus.message)
                    }
                } icon: {
                    Image(systemName: keyStatus.icon)
                }
                .font(.footnote)
                .foregroundStyle(keyStatus.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .privacySensitive()
                .accessibilityElement(children: .combine)


                if CloudCatalog.isLoaded {
                    NavigationLink {
                        ProviderPickerView(selectedId: providerId, onSelect: selectProvider)
                    } label: {
                        LabeledContent("Provider", value: CloudCatalog.providerName(for: providerId))
                    }

                    NavigationLink {
                        ModelPickerView(
                            providerId: providerId,
                            selectedId: model,
                            onSelect: { model = $0 }
                        )
                    } label: {
                        LabeledContent(
                            "模型",
                            value: model.isEmpty ? String(localized: "未选择") : CloudCatalog.modelName(for: model, in: providerId)
                        )
                    }

                    // 选中那个模型能做什么,挂在它自己那一行下面。
                    //
                    // 下面几节的行为直接跟着这几颗走:「回答前先思考」在没有「思考」的模型上
                    // 是空的,「照片原图」在没有「看图」的模型上不生效。让它们在同一屏上离得
                    // 近一点,用户不用把两件事在脑子里对起来。
                    if !model.isEmpty {
                        ModelCapabilityTags.forModel(model, in: providerId)
                    }

                    if model.isEmpty {
                        Label("请先选择模型", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityElement(children: .combine)
                    }
                } else {
                    // catalog 资源没打进 app,退回手输,别把人卡死
                    LabeledContent("Provider ID") {
                        TextField(EngineSettings.defaultProvider, text: $providerId)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .accessibilityLabel("Provider ID")
                    }

                    LabeledContent("模型") {
                        TextField(EngineSettings.defaultModel, text: $model)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .accessibilityLabel("模型")
                    }

                    Label("未能载入 AIKit provider 目录，暂时只能手动填写。", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityElement(children: .combine)
                }

                // 真发一次请求,看这套配置通不通。
                //
                // **这一颗回答的是「我现在能用吗」**,而那正是 key 和 provider 分成两个
                // 字段之后,屏幕上一直没人回答的问题(2026-08-16 审核员就卡在这儿:两个
                // 字段各自填得好好的,合起来必然失败)。判 key 长什么样是猜,这一下是问。
                Button(action: runConnectionTest) {
                    HStack {
                        Label("测试连接", systemImage: "bolt.horizontal.circle")
                        if isTestingConnection {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isTestingConnection || !canTestConnection)

                if let connectionResult {
                    connectionResultRow(connectionResult)
                }

                if hasStoredAPIKey {
                    Button(role: .destructive) {
                        apiKey = ""
                        saveAPIKey()
                    } label: {
                        // `role: .destructive` 只染文字,Form 里的图标照样跟着 accent
                        // 走——一行里红字配蓝图标。`.tint(.red)` 在这儿也管不着,得直接
                        // 给图标上色。
                        Label {
                            Text("移除 API key")
                        } icon: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                    }
                }
            } header: {
                Text("云端模型")
            } footer: {
                Text("Provider 和模型都从 AIKit 内置目录里选。API key 只保存在本机钥匙串。")
            }

            Section {
                LabeledContent("Serper key") {
                    HStack(spacing: 8) {
                        SecureField("选填", text: $searchKey)
                            .focused($focusedField, equals: .searchKey)
                            .multilineTextAlignment(.trailing)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .privacySensitive()
                            .onSubmit(saveSearchKey)
                            .accessibilityLabel("网页搜索 key")

                        if !searchKey.isEmpty {
                            Button {
                                searchKey = ""
                                focusedField = .searchKey
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除网页搜索 key")
                        }
                    }
                }

                Label {
                    if searchKeyStatus == .saved, let hint = maskedKey(persistedSearchKey) {
                        Text("已保存 · \(Text(hint).monospaced())")
                    } else {
                        Text(searchKeyStatus.searchMessage)
                    }
                } icon: {
                    Image(systemName: searchKeyStatus.icon)
                }
                .font(.footnote)
                .foregroundStyle(searchKeyStatus.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .privacySensitive()
                .accessibilityElement(children: .combine)

                if !persistedSearchKey.isEmpty {
                    Button(role: .destructive) {
                        searchKey = ""
                        saveSearchKey()
                    } label: {
                        Label {
                            Text("移除搜索 key")
                        } icon: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                    }
                }
            } header: {
                Text("网页搜索")
            } footer: {
                // key 的有无就是开关,所以这句话要说清「填了会怎样、不填会怎样」,
                // 不然用户会去找一个并不存在的开关。
                Text("""
                    填了 serper.dev 的 key，Vana 遇到自己不知道的事就能上网查一下，并给出出处。\
                    不填就只用它已有的知识回答。搜索词不会带上你的健康数据。key 只保存在本机钥匙串。
                    """)
            }

            Section {
                Picker("说话方式", selection: $persona) {
                    ForEach(AssistantPersona.allCases) { option in
                        Text(option.name).tag(option.rawValue)
                    }
                }

                Text(AssistantPersona(rawValue: persona)?.summary ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("回答前先思考", isOn: $thinkingEnabled)
            } header: {
                Text("助手")
            } footer: {
                Text("""
                    只改语气和详略，不改数据口径——同样只引用工具返回的数字，同样不做诊断。\
                    \n思考让多步分析更准，但更慢也更贵；有些模型不支持关闭，那就还是会思考。
                    """)
            }

            // 记忆、对话、后台任务:三件都是「Vana 替你留着或替你做的事」,和插件无关,关不掉。
            Section {
                NavigationLink {
                    MemoryView()
                } label: {
                    Label("Vana 记住的事", systemImage: "brain")
                }
                if let chat {
                    NavigationLink {
                        ConversationHistoryView(model: chat)
                    } label: {
                        Label("对话历史", systemImage: "text.bubble")
                    }
                }
                Toggle(isOn: $autoStartTasks) {
                    Label("只读的后台任务自动开始", systemImage: "checklist")
                }
            } header: {
                Text("记忆与对话")
            } footer: {
                Text("""
                    对话历史里可以看占用空间、清掉很早以前的，或者全部清空。\
                    Vana 可以把一件要花几分钟的事（查资料、比较方案）交给后台助手去做。默认每一件都先给你一张确认卡，你点了「开始」才跑。\
                    打开这一项之后，它派出去的任务直接开始。后台助手只读——想设提醒、记目标都只能先提议，你点了才执行；\
                    任务的说明和它查到的资料会发给你配置的模型服务。一次只跑一件，每天最多 \(SubagentLimits.maxRunsPerDay) 件，每件最多 5 分钟。
                    """)
            }

            // 插件自己的设置(Apple 健康授权、check-in、用药表……)在插件详情页里,不散在这一页。
            Section {
                NavigationLink {
                    PluginsView(openMedications: openMedications)
                } label: {
                    Label("插件", systemImage: "puzzlepiece.extension")
                }
            } footer: {
                Text("健康、笔记与清单这些能整个开关的能力，以及它们各自的设置（比如 Apple 健康的读取权限、每日 check-in）。")
            }

            // 模型看不了图的时候这一节**照样显示**,只是多一行说它现在不起作用。
            //
            // 藏起来看着更干净,但那条路上有一个静默的坑:他在能看图的模型上选了「每张都发
            // 原图」,换个模型之后这一节整个消失——设置还在(存的是这台设备的偏好),行为
            // 却停了,而屏幕上没有一个字解释为什么。同刷新按钮那条:按下去必须说一句话。
            Section {
                Picker("照片原图", selection: $photoImagePolicy) {
                    ForEach(PhotoImagePolicy.allCases) { option in
                        Text(option.name).tag(option.rawValue)
                    }
                }

                Text(PhotoImagePolicy(rawValue: photoImagePolicy)?.summary ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !EngineSettings.modelSupportsVision {
                    Label {
                        Text("""
                            当前模型（\(model)）看不了图，这一项暂时不起作用——\
                            原图一张都不会发出去，换一个支持看图的模型才会生效。
                            """)
                    } icon: {
                        Image(systemName: "eye.slash")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("照片")
            } footer: {
                // 这一节说的是默认值,不是一道锁。不写清楚的话,选了「只发文字」的人会
                // 以为那颗单张开关坏了。
                //
                // 这里**不能用 `**` 加粗**:markdown 只对字符串字面量生效,而这几段是拼出来
                // 的 `String`,那两颗星会原样显示在屏幕上(踩过)。要强调就分句,别靠符号。
                Text("""
                    照片里的文字一律在本机识别，发出去的默认只有文字。这一项管的只是原图要不要\
                    跟着走，而且只是默认——发送之前点开任意一张，都能单独决定这一张发不发。
                    """)
            }

            Section {
                if location.isAuthorized {
                    LabeledContent("当前位置", value: location.snapshot.place ?? "正在定位…")
                        .privacySensitive()
                } else if location.isDenied {
                    Button {
                        openURL(URL(string: UIApplication.openSettingsURLString)!)
                    } label: {
                        Label("在系统设置里打开位置", systemImage: "arrow.up.forward.app")
                    }
                } else {
                    Button {
                        location.requestAccess()
                    } label: {
                        Label("允许使用大概位置", systemImage: "location")
                    }
                }

                Label(locationStatus.message, systemImage: locationStatus.icon)
                    .font(.footnote)
                    .foregroundStyle(locationStatus.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .accessibilityElement(children: .combine)
            } header: {
                Text("位置")
            } footer: {
                // 授权本身就是开关,所以这段话得说清「给了会怎样、不给会怎样」,不然用户会去找
                // 一个并不存在的开关(同上面那把搜索 key)。也要说清它到底拿到了什么——
                // 「大概位置」四个字在 iOS 那张面板上有确切含义,这里不该说得比它更模糊。
                Text("""
                    给了之后 Vana 每次回答都知道你大概在哪个城市，季节气候、时差、当地饮食和就医方式才答得准。\
                    只取到城市，不取街道地址，也不会保存在本机；不给就完全不带位置，其余功能照常。
                    """)
            }

            // **用不了的时候整节不出现。**
            //
            // 这一节以前一直在,靠里面那行文案说「为什么用不了」。但绝大多数人打开设置页
            // 并不是来查语音识别的,而这台设备装没装那份模型是他改不动的事——留在这儿,
            // 它就是一条永远说着坏消息的橙色横杠,而下面还跟着三行介绍一个他按不到的按钮。
            //
            // 能用的时候它才有话可说:识别语言是哪个、录音去了哪、和键盘听写差在哪。
            //
            // 代价是 `.unsupportedLocale` 那行列出的「这台设备支持哪几种语言」也跟着不
            // 显示了——那是排查时唯一的线索(`supportedLocales` 只有真机答得了)。接受:
            // 它服务的是开发期,而开发期有「设置 › 开发」那一页。
            if dictation.availability.isReady {
                Section {
                    Label(voiceStatus.message, systemImage: voiceStatus.icon)
                        .font(.footnote)
                        .foregroundStyle(voiceStatus.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .accessibilityElement(children: .combine)

                    // 这里**没有下载按钮**,是有意的:Vana 一个字节都不下,那份模型归系统管
                    // (见 `VoiceDictation` 头上那段)。
                } header: {
                    Text("语音输入")
                } footer: {
                    // 说清「自己做的这颗和键盘上那颗差在哪」——差别全在词表上,而那是用户
                    // 唯一能验证的东西(说一次「甘氨酸镁」)。
                    Text(Self.voiceFooter)
                }
            }

            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    Label("关于 Vana", systemImage: "info.circle")
                }
            } footer: {
                Text("免责声明、数据去向和隐私说明。")
            }

            #if DEBUG
            Section {
                NavigationLink {
                    DeveloperView()
                } label: {
                    Label("开发", systemImage: "hammer")
                }
            } footer: {
                Text("只在 Debug 构建里出现。")
            }
            #endif
        }
        .navigationTitle("设置")
        .task(loadAPIKey)
        // 刚在 iOS 设置里把位置打开又切回来的那种情况:授权状态由 delegate 更新,但那时候
        // 还没有人去定过位,页面上会一直停在「还没定到位置」。
        .onAppear { location.refresh() }
        // 语音那一段是这个功能在这台设备上成不成立的唯一显示口,进设置页就重查一遍
        // (刚下载完模型、刚换了系统语言都会改变它)。
        .task { await dictation.refresh() }
        // 测的是「这一套」通不通,三个字段动了任何一个,上一次的结论就不再指着屏幕上这套了。
        // 尤其是那句绿色的「连接正常」——留着它,用户会拿一个旧结论去信一套新配置。
        .onChange(of: providerId) { _, _ in connectionResult = nil }
        .onChange(of: model) { _, _ in connectionResult = nil }
        .onChange(of: apiKey) { _, _ in connectionResult = nil }
        .onChange(of: apiKey) { _, newValue in
            guard hasLoadedAPIKey else { return }
            if newValue == persistedAPIKey {
                keyStatus = newValue.isEmpty ? .notSet : .saved
            } else {
                keyStatus = .pending
            }
        }
        .onChange(of: searchKey) { _, newValue in
            guard hasLoadedAPIKey else { return }
            if newValue == persistedSearchKey {
                searchKeyStatus = newValue.isEmpty ? .notSet : .saved
            } else {
                searchKeyStatus = .pending
            }
        }
        .onChange(of: focusedField) { oldField, newField in
            if oldField == .apiKey, newField != .apiKey {
                saveAPIKey()
            }
            if oldField == .searchKey, newField != .searchKey {
                saveSearchKey()
            }
        }
        .onDisappear {
            if apiKey != persistedAPIKey {
                saveAPIKey()
            }
            if searchKey != persistedSearchKey {
                saveSearchKey()
            }
        }
    }

    /// 三种状态各说各的话:没问过(可以问)、拒了(只能去 iOS 设置改)、给了但还没定到
    /// (等一下就有)。合并成一句「位置不可用」的话,前两种会被当成第三种,用户就一直在等
    /// 一件永远不会发生的事。
    private var locationStatus: HealthAuthStatus {
        if location.isDenied {
            return HealthAuthStatus(
                message: String(localized: "已拒绝，Vana 不会带上位置。要打开请到「设置 > Vana > 位置」。"),
                icon: "location.slash",
                isError: true
            )
        }
        if !location.isAuthorized {
            return HealthAuthStatus(
                message: String(localized: "还没授权，回答里不会带位置。"),
                icon: "location",
                isError: false
            )
        }
        if location.snapshot.isKnown {
            return HealthAuthStatus(
                message: String(localized: "只到城市这一级，模型看到的就是上面这一行。"),
                icon: "checkmark.circle.fill",
                isError: false
            )
        }
        return HealthAuthStatus(
            message: String(localized: "已授权，还没定到位置。"),
            icon: "location",
            isError: false
        )
    }

    /// 语音识别在这台设备上是什么状况。
    ///
    /// **这一行同时是这个功能成不成立的验证口**:`SpeechTranscriber.supportedLocales` 是运行时
    /// 的,SDK 里查不出来,模拟器上更是一个都没有。中文不在名单里的话,「按住说话」那颗按钮
    /// 整个不出现,而这里要说清为什么——并指一条还走得通的路(键盘上那颗麦克风)。
    /// 拼在常量里而不是 ViewBuilder 里:`Form` 那一大坨本来就在类型检查的边缘,
    /// 往里再塞一个三段 `+` 的字符串,编译器直接报 "unable to type-check in reasonable time"。
    private static let voiceFooter = """
        输入框里按住麦克风说话，识别在本机完成，录音不保存也不联网。\
        你记在用药表里的药名和常问的指标名会作为提示交给识别器，\
        这是键盘听写做不到的一件事。松开只把文字填进输入框，不会直接发送。
        """

    private var canTestConnection: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isEmpty
    }

    @ViewBuilder
    private func connectionResultRow(_ result: ConnectionTest.Result) -> some View {
        switch result {
        case .ok:
            Label("连接正常，可以开始问了。", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
                .accessibilityElement(children: .combine)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
        }
    }

    /// 测之前先把 key 存下来:他多半是刚粘完就按这一颗,没按过回车。不存的话测的是上一把,
    /// 而"测试通过了但聊天还是不行"是这颗按钮唯一不能有的结果。
    private func runConnectionTest() {
        saveAPIKey()
        connectionResult = nil
        isTestingConnection = true
        Task {
            let result = await ConnectionTest.run(
                providerId: providerId,
                model: model,
                apiKey: apiKey
            )
            isTestingConnection = false
            connectionResult = result
        }
    }

    private var voiceStatus: HealthAuthStatus {
        switch dictation.availability {
        case .ready:
            let locale = dictation.resolvedLocale?.identifier ?? ""
            return HealthAuthStatus(
                message: String(localized: "可以用，识别语言 \(locale)，全程在本机。"),
                icon: "checkmark.circle.fill",
                isError: false
            )
        case .needsDownload:
            // **一句话说完。** Vana 不下载那份模型(见 `VoiceDictation` 头上那段),所以
            // 这一行能给的只有一个事实;把「到设置里启用听写系统就会装上」那一串写进来,
            // 是替系统写说明书,而多数人根本不需要这个功能。
            return HealthAuthStatus(
                message: String(localized: "这台设备还没装本机语音模型，按住说话不会出现。"),
                icon: "mic.slash",
                isError: false
            )
        case .downloading:
            return HealthAuthStatus(
                message: String(localized: "系统正在装本机语音模型。"),
                icon: "arrow.down.circle",
                isError: false
            )
        case .unsupportedLocale:
            // 把这台设备到底认得哪几种语言一并说出来。`supportedLocales` 只有真机答得了,
            // 而「不支持」三个字说不清缺的是什么——这一行是这个功能能不能成立的唯一证据。
            let available = dictation.supportedLocaleIdentifiers
            let listing = available.isEmpty
                ? String(localized: "这台设备一种语言都没读到。")
                : String(localized: "这台设备支持的是：\(available.prefix(8).joined(separator: "、"))\(available.count > 8 ? " 等" : "")。")
            return HealthAuthStatus(
                message: String(localized: "没有可用的中文语音识别，按住说话不会出现。\(listing)键盘上那颗麦克风照样能用。"),
                icon: "mic.slash",
                isError: true
            )
        case .unavailable:
            return HealthAuthStatus(
                message: String(localized: "这台设备用不了本机语音识别。"),
                icon: "mic.slash",
                isError: true
            )
        case .unknown:
            return HealthAuthStatus(message: String(localized: "正在检查…"), icon: "mic", isError: false)
        }
    }

    /// 换 provider 时,旧模型多半不属于新 provider,直接换成新 provider 的第一个可用模型。
    private func selectProvider(_ id: String) {
        guard id != providerId else { return }
        providerId = id
        if CloudCatalog.model(model, in: id) == nil {
            model = CloudCatalog.defaultModel(for: id) ?? ""
        }
    }

    /// "sk-ant…7f2a":露头尾够认出是哪一把 key,又不至于把整串摆在屏幕上。太短的不露。
    private func maskedKey(_ key: String) -> String? {
        guard key.count >= 12 else { return nil }
        return "\(key.prefix(6))…\(key.suffix(4))"
    }

    private func loadAPIKey() {
        guard !hasLoadedAPIKey else { return }
        do {
            let stored = try KeychainStore.get(account: KeychainStore.apiKeyAccount) ?? ""
            apiKey = stored
            persistedAPIKey = stored
            hasStoredAPIKey = !stored.isEmpty
            keyStatus = stored.isEmpty ? .notSet : .saved
        } catch {
            keyStatus = .error(error.localizedDescription)
        }
        // 搜索那把单独读,单独报错。它读失败不该让上面那把也显示成出错——两把 key 是
        // 两回事,一起报会让用户去改本来没问题的那一把。
        do {
            let stored = try KeychainStore.get(account: KeychainStore.searchAPIKeyAccount) ?? ""
            searchKey = stored
            persistedSearchKey = stored
            searchKeyStatus = stored.isEmpty ? .notSet : .saved
        } catch {
            searchKeyStatus = .error(error.localizedDescription)
        }
        hasLoadedAPIKey = true
    }

    private func saveSearchKey() {
        guard hasLoadedAPIKey else { return }
        let value = searchKey.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            if value.isEmpty {
                try KeychainStore.delete(account: KeychainStore.searchAPIKeyAccount)
                searchKey = ""
                persistedSearchKey = ""
                searchKeyStatus = .notSet
            } else {
                try KeychainStore.set(value, account: KeychainStore.searchAPIKeyAccount)
                searchKey = value
                persistedSearchKey = value
                searchKeyStatus = .saved
            }
        } catch {
            searchKeyStatus = .error(error.localizedDescription)
        }
    }

    private func saveAPIKey() {
        guard hasLoadedAPIKey else { return }
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            if value.isEmpty {
                try KeychainStore.delete(account: KeychainStore.apiKeyAccount)
                apiKey = ""
                persistedAPIKey = ""
                hasStoredAPIKey = false
                keyStatus = .notSet
            } else {
                try KeychainStore.set(value, account: KeychainStore.apiKeyAccount)
                apiKey = value
                persistedAPIKey = value
                hasStoredAPIKey = true
                keyStatus = .saved
            }
        } catch {
            keyStatus = .error(error.localizedDescription)
        }
    }

}

private enum Field: Hashable {
    case apiKey
    case searchKey
}

/// 设置页和插件详情页里那种「一行状态小字」。
struct HealthAuthStatus {
    let message: String
    let icon: String
    let isError: Bool
    /// 这句话要不要挡在他面前。
    ///
    /// 只有**屏幕上其余部分什么都没变**的那几次才为真:面板没弹、请求失败、系统没回话。
    /// 面板真的弹出来的那次不为真——他刚在上面做完选择,再弹一张确认框是纯粹的多一下。
    var needsAttention = false
}

private enum KeyStatus: Equatable {
    case notSet
    case pending
    case saved
    case error(String)

    var message: String {
        switch self {
        case .notSet:
            return String(localized: "尚未保存 API key")
        case .pending:
            return String(localized: "更改尚未保存")
        case .saved:
            return String(localized: "API key 已保存")
        case .error(let message):
            return String(localized: "无法保存：\(message)")
        }
    }

    /// 搜索那把是选填的,「尚未保存」听起来像少配了什么。说清不填会怎样。
    var searchMessage: String {
        switch self {
        case .notSet:
            return String(localized: "没填，Vana 不会上网搜")
        case .pending:
            return String(localized: "更改尚未保存")
        case .saved:
            return String(localized: "已保存")
        case .error(let message):
            return String(localized: "无法保存：\(message)")
        }
    }

    var icon: String {
        switch self {
        case .notSet:
            return "key"
        case .pending:
            return "pencil"
        case .saved:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var isError: Bool {
        if case .error = self {
            return true
        }
        return false
    }
}
