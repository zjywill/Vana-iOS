import Foundation

/// 「这条回答算不算健康话题」——决定要不要在它下面补那句医疗免责。
///
/// 以前「不构成诊断或用药建议」挂在每一段回答下面,对一个日常助手是噪音:整理待办的回答底下
/// 写着「不构成用药建议」。现在通用的「AI 生成、可能有误」照挂,医疗那半句只在话题真的沾上
/// 健康时才出现。
///
/// 判据是**确定性**的,不靠再问一次模型:这一轮调用过健康插件的工具,或者用户的话/回答里
/// 出现健康词表里的词。宁可多显示——词表故意宽,漏掉一次比多出一句更糟。**不看健康插件的
/// 开关**:开关管的是工具和提示词;免责声明是保护读这条回答的人,他关掉健康插件不等于他不会
/// 拿一条谈症状的回答当医嘱。
enum HealthTopics {
    static var toolNames: Set<String> {
        Set(HealthTools.all.map(\.name) + [
            ExerciseTools.suggestToolName,
            MedicationTools.listToolName,
            MedicationTools.logToolName,
            MedicationTools.updateToolName
        ])
    }

    private static let keywords = [
        "症状", "用药", "吃药", "服药", "药", "剂量", "化验", "体检", "检查报告", "诊断", "确诊", "疾病", "病史",
        "血压", "血糖", "血脂", "心率", "体重", "发烧", "发热", "头痛", "头疼", "头晕", "失眠", "咳嗽", "感冒",
        "疼", "痛", "过敏", "医院", "医生", "就医", "急诊", "手术", "怀孕", "孕期", "睡眠", "步数", "HRV",
        "symptom", "medication", "medicine", "dosage", "dose", "prescription", "diagnos", "lab result",
        "blood pressure", "blood sugar", "heart rate", "fever", "headache", "allergy", "doctor", "hospital", "sleep"
    ]

    static func mentions(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let lowered = text.lowercased()
        return keywords.contains { lowered.contains($0.lowercased()) }
    }

    /// `toolNames` 是这一轮调用过的工具;`texts` 是用户那句话和助手的回答。
    static func applies(toolNames: some Sequence<String>, texts: [String?]) -> Bool {
        let health = Self.toolNames
        return toolNames.contains { health.contains($0) } || texts.contains { mentions($0) }
    }
}

extension ChatMessage.Origin {
    /// 主动消息顶上那一行小字:它不是对上一句的回答,得认得出来。
    var label: String {
        switch self {
        case .normal: ""
        case .checkIn: String(localized: "Vana 来问一句")
        case .followUp: String(localized: "说好回头看的")
        case .reminder: String(localized: "提醒")
        case .task: String(localized: "后台任务的结果")
        case .fromMain: String(localized: "从主对话接着聊")
        case .fromSideChat: String(localized: "从侧聊带回来的")
        }
    }

    var icon: String {
        switch self {
        case .normal: "text.bubble"
        case .checkIn: "sun.max"
        case .followUp: "clock.arrow.circlepath"
        case .reminder: "bell"
        case .task: "checklist"
        case .fromMain: "arrow.turn.down.right"
        case .fromSideChat: "arrowshape.turn.up.backward"
        }
    }
}
