import SwiftUI

/// 首屏那张卡、「今天」页「现在」那一行点开之后的一页。
///
/// 自己不带 `NavigationStack`:从「今天」页是推进去的,从首屏那张卡是一张 sheet(那边包一层、
/// 补一颗「完成」)。
///
/// 卡片上只露前几行——它排在欢迎卡前面,占满一屏就把下面的东西全推走了。可那段话被截断
/// 之后,用户既读不全,也看不到它是**根据什么**说的。这一页补的就是这两件:整段话,以及
/// 底下那几行读数。
///
/// 一页只干一件事:**说清现在是什么状况**。所以这里没有可点的问题——那是首屏那三颗 chip
/// 的活,同一屏里两个控件干同一件事,用户只会犹豫该按哪个。
struct HealthStatusView: View {
    let summary: String
    let situation: HealthSituation?
    /// 正在写。刷新按钮转圈,也靠它挡住连按。
    let isWriting: Bool
    /// 配了云端模型没有。没配的话这段话是本机拼的,刷新只重读数据——**这件事得说出来**,
    /// 否则那颗按钮在没配 key 的人手里就是按下去什么都不发生。
    let canGenerate: Bool
    let onRefresh: () -> Void

    /// 刚按过刷新。数据没变时那一下是完全无声的:句子一模一样,读数一模一样,按钮转一下
    /// 就停——用户只会当它坏了。所以按完先说一句"读过了",几秒后自己退回去。
    @State private var justRefreshed = false

    var body: some View {
        List {
            Section {
                Text(summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    // 一片一片写出来,不是一段一段跳出来。
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.2), value: summary)
            } footer: {
                Text(footnote)
                    .animation(.smooth(duration: 0.2), value: footnote)
            }

            if let vitals = situation?.vitals, !vitals.items.isEmpty {
                Section("现在是多少") {
                    ForEach(vitals.items) { item in
                        VitalRow(item: item)
                    }
                }
            }

            if let triggers = situation?.notableTriggers, !triggers.isEmpty {
                Section("这几天变了什么") {
                    ForEach(Array(triggers.enumerated()), id: \.offset) { _, trigger in
                        Text(trigger.brief)
                            .font(.callout)
                            .foregroundStyle(.primary)
                    }
                }
            }

            Section {
            } footer: {
                Text(HealthKitAttribution.statusFooter)
            }
        }
        .navigationTitle("现在的状况")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onRefresh()
                    justRefreshed = true
                } label: {
                    if isWriting {
                        ProgressView()
                    } else {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isWriting || situation == nil)
            }
        }
        // 说完那一句就退回去。留着的话下次进来还挂在那儿,说的是一件几天前的事。
        .task(id: justRefreshed) {
            guard justRefreshed else { return }
            try? await Task.sleep(for: .seconds(6))
            justRefreshed = false
        }
    }

    /// 那段话底下的一行小字。**每一种情况都得说得出话**——尤其是"按了刷新但什么都没变"。
    private var footnote: String {
        if isWriting { return String(localized: "正在重新写…") }
        if !canGenerate {
            return justRefreshed
                ? String(localized: "已重新读取健康数据。还没配置云端模型，这段话是本机按下面的读数拼的。")
                : String(localized: "还没配置云端模型，这段话是本机按下面的读数拼的。")
        }
        return justRefreshed
            ? String(localized: "已重新读取健康数据。")
            : String(localized: "根据下面这些读数写的。")
    }
}

extension HealthStatusView {
    /// 主对话手里那一份:话、处境、写没写完、能不能叫模型重写。两处入口读的是同一份。
    init(model: ChatViewModel) {
        self.init(
            summary: model.quickSummary ?? HealthSituation.calmSummary,
            situation: model.situation,
            isWriting: model.isWritingSummary,
            // 没配 key 时刷新只重读数据,不重写那段话——那一页得把这件事说清楚,
            // 否则那颗按钮按下去像是坏的。
            canGenerate: model.engineGuidance == nil,
            onRefresh: model.regenerateQuickSummary
        )
    }
}

/// 一行读数。左边是项目,右边是值和它跟常态的关系。
///
/// 读不到的那几项**也留在列表里**,写「没有记录」:直接不显示的话,用户只会以为 app 没看
/// 那一项——而"昨晚没戴表"和"昨晚睡得挺好"是完全不同的两件事。
private struct VitalRow: View {
    let item: VitalItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: item.icon)
                .font(.footnote)
                .foregroundStyle(item.value == nil ? Color.secondary : Color.pink)
                .frame(width: 20)
                .accessibilityHidden(true)

            Text(item.title)
                .font(.callout)
                .foregroundStyle(item.value == nil ? .secondary : .primary)

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                if let value = item.value {
                    Text(value)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                }
                if let note = item.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
