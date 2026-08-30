import SwiftUI

/// 第一次打开时说清楚:**你的健康数据会去哪儿**。
///
/// 在这之前 app 里唯一提到「问题要发给云端模型」的地方是隐私会话那张卡
/// (`ChatView.privacyNote`),而它只在用户主动开了隐私对话时才显示——也就是说,绝大多数人
/// 从头到尾没被告知过。首屏欢迎卡说的是「Vana 只读取你授权的数据,不会修改健康记录」,
/// 只讲了不写回,没讲会发出去。
///
/// 几条边界:
///
/// - **一屏说完,只讲三件事**:什么会发出去、什么不会、发给谁。写成一份条款就没人读,而这一屏
///   的全部价值就是它真的被读到了一次。真要看细节的走底下那行「隐私说明」。
/// - **正反两组都要有,不能只写「我们保护你的隐私」**。可信来自具体:「照片原件不会离开这台
///   设备,只发识别出来的文字」是可以被验证的一句话,「我们重视你的隐私」不是。
/// - **它是一次明确的同意,按钮写「同意并继续」**。第一版故意不做成同意书(「告知不是签协议」),
///   2026-08-29 被 5.1.1(i)/5.1.2(i) 判回来:Apple 要求把数据发给第三方 AI 服务之前必须
///   obtain the user's permission,「开始使用」在审核眼里不是 permission。同意的对象写在按钮
///   上方那句 `consentFootnote` 里,和三组内容同一屏——同意必须发生在读完告知之后、又不另开
///   一屏。配套的另一半在 `ProviderConsent`:第一次真的要发给某一家之前,还会点名再问一次。
/// - **「发给谁」要有名字**。「你配置的模型服务」是个代词;默认预选的是 DeepSeek,这一屏就
///   写出 DeepSeek——审核判词里 "identify who the data is sent to" 缺的正是这个名字。
/// - **这是设备级的,不跟着成员走**(同 provider、model、API key)。它说的是「这台手机怎么
///   工作」,不是「我和谁在聊」,所以不在 `TenantPaths.perTenantItems` 里。
enum DataUseNotice {
    /// 见过这一屏没有。老用户升级上来也会看到一次——这段告知本来就是新的。
    static let acceptedKey = "hasAcceptedDataUseNotice"

    struct Group: Identifiable {
        let icon: String
        let title: String
        let tint: Color
        let points: [String]

        var id: String { title }
    }

    /// 会离开这台设备的。**逐条对着代码写**,多写一条是许一个空诺,少写一条是漏一次告知。
    static let leaves = Group(
        icon: "arrow.up.forward.app",
        title: String(localized: "会发给你配置的模型服务"),
        tint: .orange,
        points: [
            String(localized: "对方是一家由你选定的第三方模型服务——默认预选的是 DeepSeek（深度求索），可以在设置里换成目录里的其他家。第一次真的要发给某一家之前，Vana 还会点名问你一次"),
            String(localized: "你打的字，以及这条对话里的往来"),
            String(localized: "从 Apple 健康读到的聚合数值，例如「8 月 6 日睡眠 6.2 小时」"),
            String(localized: "化验单、报告、药盒在本机识别出来的文字"),
            String(localized: "照片原图——默认不发；本机认不出文字的那些会问你一句，你点了才发"),
            String(localized: "你所在的城市（授权了位置的话）"),
            String(localized: "长期记忆和用药表里的内容（没关掉的话）")
        ]
    )

    static let stays = Group(
        icon: "iphone",
        title: String(localized: "不会离开这台设备"),
        tint: .green,
        points: [
            String(localized: "照片和文件原件——识别在本机做，发出去的默认只有文字；原图发不发在设置里定，每一张发送前还能单独改"),
            String(localized: "按住说话的录音——识别在本机做，录音不保存，只留识别出来的文字"),
            String(localized: "经纬度坐标——只发城市名，坐标一个字都不发"),
            String(localized: "你的 API key——只在系统钥匙串里"),
            String(localized: "对话记录、记忆、用药表——存在本机，没有云端副本，也不进 iCloud 备份")
        ]
    )

    static let noServer = Group(
        icon: "network.slash",
        title: String(localized: "Vana 自己没有服务器"),
        tint: .secondary,
        points: [
            String(localized: "没有账号，没有后台，没有任何统计埋点"),
            String(localized: "开发者看不到你的数据——它不经过我们的任何一台机器"),
            String(localized: "发给哪家模型服务由你决定，对方如何处理适用它自己的隐私政策")
        ]
    )

    static let groups: [Group] = [leaves, stays, noServer]

    /// 按钮上方那句:点下去到底同意了什么。**单独一个常量而不是散在视图里**,
    /// `ComplianceTests` 要能盯住它——这一句掉了,那颗按钮就退化回「开始使用」。
    static let consentFootnote = String(localized: """
        点「同意并继续」，表示你已读过上面的说明，并同意 Vana 在你提问时，\
        把「会发出去」那一组里列出的内容发给你选定的模型服务来生成回答。
        """)

    /// 按钮文字。和 `consentFootnote` 里引号中的那四个字必须是同一串。
    static let consentActionTitle = String(localized: "同意并继续")

    /// 免责。分三段,最后一段是急症——把它放在最后一段而不是塞进第一段的从句里,是因为
    /// 那是这三段里唯一一句要在几秒钟内被想起来的话。
    static let medicalDisclaimer = String(localized: """
        Vana 不是医疗器械，也不是医生。它给出的分析基于你的健康数据和一个通用语言模型，仅供参考，\
        不构成医疗诊断、治疗方案或用药建议，也不会给出任何剂量建议，不能替代医生、药师或其他专业医疗人员的判断。

        模型会出错——它可能读错化验单上的一个小数点，也可能把一段过去的数据当成最近的。\
        据此做出的任何健康决定，请先和专业人员确认。

        身体出现急症（例如胸痛、呼吸困难、意识改变、严重出血），或者有伤害自己的念头时，\
        请立即就医或拨打当地急救电话，不要等 Vana 回答。
        """)
}

// MARK: - 首次使用的那一屏

struct DataUseNoticeSheet: View {
    let onAccept: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.pink)
                            .accessibilityHidden(true)

                        Text("Vana 要靠一个模型来回答你的问题，而那个模型跑在你自己选的那家服务上。所以有些东西必须发出去，有些不用——这一屏说清是哪些。")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    DataUseNoticeContent()

                    Text(DataUseNotice.medicalDisclaimer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .padding(.bottom, 8)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    NavigationLink {
                        PrivacyPolicyView()
                    } label: {
                        Text("完整的隐私说明")
                            .font(.subheadline)
                    }

                    // 同意的内容写在按钮正上方,不塞进滚动区:滚动区可以不被读完,
                    // 而「点这一下等于同意了什么」必须和那一下同框。
                    Text(DataUseNotice.consentFootnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: onAccept) {
                        Text(DataUseNotice.consentActionTitle)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(.bar)
            }
            // 标题交给导航栏,不自己画一个。这一屏没有返回键,看着像"没有导航栏",但那条栏
            // 是滚动时把文字和状态栏隔开的那层材质——自己画标题的话,滚两行就有一句话压在
            // 时间上面。
            .navigationTitle("在开始之前")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

/// 三组内容本身。首次那一屏和「设置 > 关于 > 数据会发送到哪里」是同一份——
/// 用户过两个月想再看一眼时,读到的必须是同样的承诺。
struct DataUseNoticeContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(DataUseNotice.groups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text(group.title)
                            .font(.headline)
                    } icon: {
                        Image(systemName: group.icon)
                            .foregroundStyle(group.tint)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(group.points, id: \.self) { point in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)

                                Text(point)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .accessibilityElement(children: .contain)
            }
        }
    }
}

#Preview("首次使用") {
    DataUseNoticeSheet(onAccept: {})
}
