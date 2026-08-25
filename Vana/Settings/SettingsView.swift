import SwiftUI
import UIKit

struct SettingsView: View {
    let canClearConversation: Bool
    let onClearConversation: () -> Void

    @AppStorage(EngineSettings.providerKey) private var providerId = EngineSettings.defaultProvider
    @AppStorage(EngineSettings.modelKey) private var model = EngineSettings.defaultModel
    @AppStorage(EngineSettings.personaKey) private var persona = EngineSettings.defaultPersona
    @AppStorage(EngineSettings.thinkingEnabledKey) private var thinkingEnabled = true
    @AppStorage(EngineSettings.photoImagePolicyKey) private var photoImagePolicy = PhotoImagePolicy.askWhenNoText.rawValue
    @AppStorage(EngineSettings.checkInsEnabledKey) private var checkInsEnabled = false
    @AppStorage(EngineSettings.morningCheckInHourKey) private var morningHour = EngineSettings.defaultMorningHour
    @AppStorage(EngineSettings.eveningCheckInHourKey) private var eveningHour = EngineSettings.defaultEveningHour
    @State private var checkInStatus: HealthAuthStatus?

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
    @State private var isShowingClearConfirmation = false
    @State private var isRequestingHealth = false
    @State private var isHealthRequestInFlight = false
    @State private var healthStatus: HealthAuthStatus?
    /// 面板没弹出来的那几次,那句话要挡在他面前。见 `requestHealthAuthorization`。
    @State private var healthAlert: HealthAuthStatus?
    /// 这一次按的是哪一下。超时放行之后回来晚了的那次靠它闭嘴。
    @State private var healthRequestToken = UUID()
    @State private var location = LocationProvider.shared
    @State private var dictation = VoiceDictation.shared
    @FocusState private var focusedField: Field?
    @Environment(\.openURL) private var openURL

    init(
        canClearConversation: Bool = false,
        onClearConversation: @escaping () -> Void = {}
    ) {
        self.canClearConversation = canClearConversation
        self.onClearConversation = onClearConversation
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

                NavigationLink {
                    MemoryView()
                } label: {
                    Label("Vana 记住的事", systemImage: "brain")
                }
            } header: {
                Text("助手")
            } footer: {
                Text("""
                    只改语气和详略，不改数据口径——同样只引用工具返回的数字，同样不做诊断。\
                    \n思考让多步分析更准，但更慢也更贵；有些模型不支持关闭，那就还是会思考。
                    """)
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
                Toggle("每日 check-in", isOn: $checkInsEnabled)

                if checkInsEnabled {
                    Picker("早上", selection: $morningHour) {
                        ForEach(5...11, id: \.self) { hour in
                            Text("\(hour):00").tag(hour)
                        }
                    }
                    Picker("晚上", selection: $eveningHour) {
                        ForEach(18...23, id: \.self) { hour in
                            Text("\(hour):00").tag(hour)
                        }
                    }
                }

                if let checkInStatus {
                    Label(checkInStatus.message, systemImage: checkInStatus.icon)
                        .font(.footnote)
                        .foregroundStyle(checkInStatus.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .accessibilityElement(children: .combine)
                }
            } header: {
                Text("提醒")
            } footer: {
                Text("""
                    早上说昨晚的睡眠，晚上说今天的活动量，都基于本机算出来的数据；\
                    点开通知会直接带着对应话题开一条新对话。文案在每次打开 app 时刷新。
                    """)
            }

            Section {
                Button {
                    requestHealthAuthorization()
                } label: {
                    Label(
                        isRequestingHealth ? String(localized: "正在请求…") : HealthKitAttribution.authorizeAction,
                        systemImage: "heart.text.square"
                    )
                }
                .disabled(isHealthRequestInFlight)
                // 面板真的弹出来的那次不打扰他——他刚在上面做完选择。**没弹**的那几次
                // 才要挡在他面前:那时候屏幕上唯一的变化是一行灰色小字,而他刚按下的那颗
                // 按钮看起来什么都没做(2026-08-25 审核报的正是这个)。这句话还得带着
                // 下一步走——「健康」App 是这条路上唯一能改的地方。
                .alert(
                    HealthKitAttribution.authorizeAction,
                    isPresented: Binding(
                        get: { healthAlert != nil },
                        set: { if !$0 { healthAlert = nil } }
                    ),
                    presenting: healthAlert
                ) { _ in
                    Button("打开“健康”App") {
                        openURL(URL(string: "x-apple-health://")!)
                    }
                    Button("好", role: .cancel) {}
                } message: { status in
                    Text(status.message)
                }

                if let healthStatus {
                    Label(healthStatus.message, systemImage: healthStatus.icon)
                        .font(.footnote)
                        .foregroundStyle(healthStatus.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .accessibilityElement(children: .combine)
                }

                Button {
                    openURL(URL(string: "x-apple-health://")!)
                } label: {
                    Label("在“健康”App 中管理", systemImage: "arrow.up.forward.app")
                }
            } header: {
                // 界面上要说得出这些数字是从哪儿来的(Guideline 2.5.1),
                // 见 `HealthKitAttribution`。
                Text(HealthKitAttribution.settingsSection)
            } footer: {
                // iOS 从不告诉 app 读取权限被拒了(拒绝和"没数据"长得一样),所以这里
                // 不假装能显示授权状态,只说清楚该去哪儿改。
                Text(HealthKitAttribution.settingsFooter)
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
                Button(role: .destructive) {
                    isShowingClearConfirmation = true
                } label: {
                    Label {
                        Text("清空对话")
                    } icon: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                }
                .disabled(!canClearConversation)
            } header: {
                Text("对话")
            } footer: {
                Text("清空会删除本机保存的所有消息，无法撤销。")
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
        .onChange(of: checkInsEnabled) { _, enabled in
            Task { await applyCheckInSettings(enabled: enabled) }
        }
        .onChange(of: morningHour) { _, _ in
            Task { await CheckInScheduler.reschedule() }
        }
        .onChange(of: eveningHour) { _, _ in
            Task { await CheckInScheduler.reschedule() }
        }
        .confirmationDialog(
            "清空当前对话？",
            isPresented: $isShowingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空对话", role: .destructive) {
                onClearConversation()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会删除本机保存的所有消息，无法撤销。")
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

    /// 打开开关时先要通知权限;用户拒了就把开关拨回去,而不是留着一个不会响的开关。
    private func applyCheckInSettings(enabled: Bool) async {
        guard enabled else {
            await CheckInScheduler.reschedule()
            checkInStatus = nil
            return
        }

        guard await CheckInScheduler.requestAuthorization() else {
            checkInsEnabled = false
            checkInStatus = HealthAuthStatus(
                message: String(localized: "系统通知权限没有打开，请到「设置 > Vana > 通知」里允许。"),
                icon: "exclamationmark.triangle.fill",
                isError: true
            )
            return
        }

        await CheckInScheduler.reschedule()
        checkInStatus = HealthAuthStatus(
            message: String(localized: "已排程，每天 \(morningHour):00 和 \(eveningHour):00 各一条。"),
            icon: "checkmark.circle.fill",
            isError: false
        )
    }

    /// 授权面板是系统的,推上来之后这一侧只能等它回话——而**等不到的时候必须还有下一步**。
    ///
    /// 2026-08-21 审核在 iPad 上按了这颗按钮,那一行就一直停在「正在请求…」:按钮自己
    /// disable 着,屏幕上没有一句话解释,也没有第二次机会。2026-08-25 又报了一次,措辞
    /// 是「按了没有反应」。根因修在 `HealthStore`(悬着的启动请求不再堵住这条路,
    /// 那个 await 自己也会超时),但「一个永远转下去的指示器」这种形状本身不能留:
    /// 系统那一侧回不回话不归我们管,但这一行不能永远显示成正在加载。
    ///
    /// 比 `HealthStore.statusTimeout` 长一点:底层先超时,说出来的话才是准的(超时是一种
    /// 结果,不是「界面自己放弃了」)。这一层只是它没做到时的兜底。
    ///
    /// **它不再需要覆盖面板那一段**——这一侧根本不等面板了(见
    /// `HealthStore.requestAuthorizationIfNeeded`)。这一点很要紧:上一版把整条路径压在
    /// 12 秒里,而用户读着面板做决定的第 12 秒,屏幕上会冒出一句「系统的授权面板没有响应」,
    /// 指着他眼前那张面板说它不存在。
    private static let healthRequestTimeout = Duration.seconds(8)

    /// 再请求一次授权。iOS 只会为"还没问过"的类型弹窗——新增数据类型后靠这个补上,
    /// 已经拒过的项它不会再问,那种情况只能去「健康」App 改。
    private func requestHealthAuthorization() {
        guard !isHealthRequestInFlight else { return }
        isHealthRequestInFlight = true
        isRequestingHealth = true
        healthStatus = nil
        // 看门狗放行之后他可以再按一次,而上一次那个 await 仍然可能在几分钟后回话。
        // 认号:回来晚了的那次一个字都不许往屏幕上写,否则他看到的是上一次按的结果。
        let token = UUID()
        healthRequestToken = token
        // 按下去之前屏幕最上面是谁。面板上来的话,这个位置会换人。
        let topBefore = Self.topPresentedController

        // `.owner` 而不是 `.shared`:设置页说的是「这台设备怎么工作」(provider、
        // model、key、通知时间全是这一类),而 HealthKit 授权本来就是这台设备机主的
        // 授权,和此刻正在看哪位成员没关系。这一节也因此不随成员消失——切到妈妈就少
        // 一节设置,用户只会以为设置丢了。
        let request = Task { @MainActor () -> HealthAuthStatus in
            do {
                let didAsk = try await HealthStore.owner.requestAuthorizationIfNeeded(force: true)
                return HealthAuthStatus(
                    // 「已弹出」改成「已请求」:这一侧不等面板的结果,也就没有资格说它出来了。
                    // 后半句是给面板没出来的那次留的——他此刻正盯着一块没有变化的屏幕。
                    message: didAsk
                        ? String(localized: "已请求授权面板。没有出现的话，请到“健康”App > 共享 > App > Vana 里管理。")
                        : String(localized: "这些数据类型都已经问过了。要打开或关闭，请到“健康”App 里改。"),
                    icon: didAsk ? "checkmark.circle.fill" : "info.circle",
                    isError: false,
                    // 面板扔出去的那次不弹 alert:它多半正盖在屏幕上,而排在它后面的
                    // alert 会在他按完之后突然冒出来。没弹面板那次才要挡在他面前——
                    // 那时候屏幕上唯一的变化是一行灰色小字。
                    needsAttention: !didAsk
                )
            } catch {
                return HealthAuthStatus(
                    message: String(localized: "请求失败：\(error.localizedDescription)。请到“健康”App > 共享 > App > Vana 里管理。"),
                    icon: "exclamationmark.triangle.fill",
                    isError: true,
                    needsAttention: true
                )
            }
        }

        Task { @MainActor in
            // 看门狗**不取消那次请求**:HealthKit 没有取消 API。它只停止显示加载,
            // 请求按钮在底层调用真正结束前仍然禁用,避免超时后反复点击叠出并发请求。
            // 旁边「在“健康”App 中管理」那颗按钮始终可用。
            let watchdog = Task { @MainActor in
                try? await Task.sleep(for: Self.healthRequestTimeout)
                guard !Task.isCancelled, isRequestingHealth, healthRequestToken == token else { return }
                isRequestingHealth = false
                isHealthRequestInFlight = false
                let timedOut = HealthAuthStatus(
                    // 下面就是「在“健康”App 中管理」那一行,这句话指的是它。
                    message: String(localized: "系统的授权面板没有响应。请直接到“健康”App > 共享 > App > Vana 里管理。"),
                    icon: "exclamationmark.triangle.fill",
                    isError: true,
                    needsAttention: true
                )
                healthStatus = timedOut
                healthAlert = timedOut
            }

            let status = await request.value
            watchdog.cancel()
            guard healthRequestToken == token else { return }
            isRequestingHealth = false
            isHealthRequestInFlight = false
            healthStatus = status

            if status.needsAttention {
                healthAlert = status
                return
            }

            // 面板已经扔出去了,但**它到底有没有上来**,HealthKit 一个字都不说。
            // UIKit 说得出来:面板是 present 上来的,真在屏幕上时根视图挂着一个
            // presented view controller。等一下再看——present 有一段动画。
            //
            // 判错的两边代价都很小(多一张 alert / 少一张 alert);判对的那次正好是
            // 审核两次都撞上的那一种:按了,屏幕上什么都没发生。**这颗按钮上,一次
            // 静默的失败比一张多余的 alert 贵得多。**
            try? await Task.sleep(for: .milliseconds(900))
            guard healthRequestToken == token,
                  Self.topPresentedController === topBefore else { return }

            // 到这儿就确定了:面板没上来。说得比那句「没有出现的话」更实在一点——
            // 他不用再自己判断有没有出现过。
            let notPresented = HealthAuthStatus(
                message: String(localized: "系统没有把授权面板推上来。已经做过选择的数据类型 iOS 不会再问——要打开或关闭，请到“健康”App > 共享 > App > Vana。"),
                icon: "info.circle",
                isError: false
            )
            healthStatus = notPresented
            healthAlert = notPresented
        }
    }

    /// 此刻站在最上面的那个 view controller。
    ///
    /// 用来判断「刚扔出去的那张授权面板上来了没有」:按之前记一个,900 毫秒之后再看一次,
    /// **换人了才算面板真的上来了**。
    ///
    /// 不能只问「有没有 presented view controller」——SwiftUI 这一屏上它**恒为非 nil**
    /// (模拟器上实测,五次全是 true),那样写出来的是一段永远不会触发的代码,而它守的
    /// 恰恰是审核两次报的那种失败。比身份,不比有无。
    private static var topPresentedController: UIViewController? {
        var top = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
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

private struct HealthAuthStatus {
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
