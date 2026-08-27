import SwiftUI

/// 气泡上方那一行:一次健康查询的入口。
///
/// 原来是就地展开一段等宽文本,聊天流里只有一列的宽度,睡眠那种七八列的数据只能糊成
/// 一坨。改成点开面板:数据留在下面弹出的那一层,聊天流保持干净。
struct ToolCallChip: View {
    let call: ToolCallRecord

    @State private var isPresented = false

    var body: some View {
        Button {
            guard canOpenPanel else { return }
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                // 记一件事的那条能有二三十个字。不截断的话胶囊会被撑成两行,圆角跟着变成
                // 一个椭圆——看着像渲染坏了。
                Text(note)
                    .truncationMode(.tail)
                if call.output == nil {
                    ProgressView().controlSize(.mini)
                } else if canOpenPanel {
                    if let count = call.report?.rows.count, count > 0 {
                        Text("\(count) 行")
                            .foregroundStyle(.tertiary)
                            .layoutPriority(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .layoutPriority(1)
                }
            }
            .inlineChipStyle(
                tint: call.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
            )
        }
        .buttonStyle(.plain)
        // 只有"还在查"才该显示成灰的。记一件事的那条已经完成了,拿 disabled 去表达
        // "点不开"会把它一起变淡,看起来像失败了。
        .disabled(call.output == nil)
        .accessibilityLabel(note)
        .accessibilityHint(canOpenPanel ? "打开查询到的数据" : "")
        .sheet(isPresented: $isPresented) {
            ToolResultPanel(call: call)
        }
    }

    /// 记一件事没有「查到的数据」可看:面板里只会是同一句话再抄一遍。
    private var isMemory: Bool { call.name == MemoryTools.rememberToolName }

    /// 翻过往对话。这两条有东西可看——用户有权知道 Vana 到底翻到了哪次对话、读回了什么,
    /// 「它怎么知道的」说不清楚,记性好就变成了让人不安。
    private var isRecall: Bool {
        call.name == SessionRecallTools.searchToolName || call.name == SessionRecallTools.readToolName
    }

    /// 上网搜过。这条**尤其**要能点开:回答里引的是外部说法,用户有权看到到底搜到了什么、
    /// 出自哪个站、哪一年——健康结论说不出处,和编的没区别。
    private var isWebSearch: Bool { call.name == WebSearchTools.searchToolName }

    /// 挑动作的那一条。**点不开**——图和步骤已经在下面的卡片上了,再开一层面板是同一件事的
    /// 第二个入口(同记忆那条)。
    private var isExercise: Bool { call.name == ExerciseTools.suggestToolName }

    /// 反问用户。**成功的那次根本不出这颗胶囊**(见 `MessageBubble`,卡片就在下面);
    /// 走到这儿的只有两种:还在执行的那一瞬,和参数不合法、卡画不出来的那次。
    private var isAsk: Bool { call.name == AskUserTools.askToolName }

    private var canOpenPanel: Bool { call.output != nil && !isMemory && !isExercise && !isAsk }

    private var icon: String {
        if call.isError { return "exclamationmark.triangle" }
        if isAsk { return "questionmark.bubble" }
        if isExercise { return "figure.flexibility" }
        if isMemory { return "brain" }
        if isWebSearch { return "globe" }
        return isRecall ? "clock.arrow.circlepath" : "heart.text.square"
    }

    private var note: String {
        if isAsk {
            return call.isError ? String(localized: "没能把问题显示出来") : String(localized: "想问你一句")
        }
        if isExercise {
            let count = call.exerciseIDs?.count ?? 0
            return count > 0 ? String(localized: "挑了 \(count) 个动作") : String(localized: "没找到合适的动作")
        }
        if isWebSearch {
            guard let query = WebSearchTools.query(fromInput: call.input), !query.isEmpty else {
                return String(localized: "上网搜了一下")
            }
            return call.isError ? String(localized: "没能搜到「\(query)」") : String(localized: "上网搜了「\(query)」")
        }
        if isMemory {
            guard let text = MemoryTools.text(fromInput: call.input) else { return String(localized: "记下了一条") }
            return call.isError ? String(localized: "没能记下「\(text)」") : String(localized: "记住了「\(text)」")
        }
        if isRecall {
            guard call.name == SessionRecallTools.readToolName else { return String(localized: "翻了翻过往对话") }
            // 一轮里常常连着回顾好几次。三个一模一样的胶囊等于没说,而日期正好在读回来的
            // 那段开头——它本来就是给模型标日期用的,顺手也给了用户。
            return SessionRecallTranscript.dateLabel(inOutput: call.output)
                .map { String(localized: "回顾了 \($0) 的对话") } ?? String(localized: "回顾了之前的一次对话")
        }
        return HealthTools.note(
            for: call.name,
            days: HealthTools.days(fromInput: call.input),
            activity: HealthTools.activity(fromInput: call.input)
        )
    }
}

/// 从底部弹出的数据面板:工具这次到底查到了什么。
///
/// 模型在回复里只说结论,数字摆在这儿——想核对的人翻得到,不想看的人不会被一屏表格淹掉。
struct ToolResultPanel: View {
    let call: ToolCallRecord

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let report = call.report {
                        header(report)
                        if !report.summary.isEmpty {
                            summary(report.summary)
                        }
                        if !report.rows.isEmpty {
                            table(report)
                        }
                        ForEach(Array(report.series.enumerated()), id: \.offset) { _, series in
                            HourlyChart(series: series)
                        }
                        if !report.notes.isEmpty {
                            notes(report.notes)
                        }
                        rawText(report.modelText)
                    } else {
                        // 查询失败,或者是旧版本存下来的会话——那时候只留了文本。
                        // `??` 拼出来的是 String 不是字面量,占位那句要自己包 `String(localized:)`。
                        Text(call.output ?? String(localized: "正在查询…"))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
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

    /// 召回那两条不是健康数据,套 `HealthTools.label` 会得到一个「健康数据」的标题,
    /// 而面板里摆的是过往对话——对不上的标题比没有标题更让人困惑。
    private var title: String {
        switch call.name {
        case SessionRecallTools.searchToolName: String(localized: "翻过的对话")
        case SessionRecallTools.readToolName: String(localized: "回顾的对话")
        case WebSearchTools.searchToolName: String(localized: "网页搜索结果")
        default: HealthTools.localizedLabel(for: call.name, activity: HealthTools.activity(fromInput: call.input))
        }
    }

    private func header(_ report: HealthReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(report.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            Text(HealthKitAttribution.panelNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summary(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(line)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private static let headerHeight: CGFloat = 26
    private static let rowHeight: CGFloat = 34

    /// 数值横向滚动,日期那一列钉住不动。
    ///
    /// 睡眠有十列,再怎么排版也塞不进一个手机宽度;但如果日期跟着滚出去,右边那堆数字
    /// 就不知道是哪天的了。
    private func table(_ report: HealthReport) -> some View {
        let valueColumns = Array(report.columns.dropFirst())

        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(report.columns.first ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(height: Self.headerHeight, alignment: .leading)

                ForEach(Array(report.rows.enumerated()), id: \.offset) { _, row in
                    separator
                    Text(row.label)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .frame(height: Self.rowHeight, alignment: .leading)
                }
            }
            // 分隔线是横向贪心的,不钉住宽度的话整列会撑到半个屏幕。
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, 14)
            .padding(.trailing, 12)

            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(valueColumns.enumerated()), id: \.offset) { _, column in
                            Text(column)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(height: Self.headerHeight)
                        }
                    }

                    ForEach(Array(report.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            separator.gridCellColumns(max(valueColumns.count, 1))
                        }
                        GridRow {
                            ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                                Text(value)
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(value == HealthReport.missing ? .tertiary : .primary)
                                    .lineLimit(1)
                                    .frame(height: Self.rowHeight)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.trailing, 14)
            }
        }
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    /// 左右两半各画各的分隔线,高度写死才能对齐——用 Divider 会因为两边容器不同而错位。
    private var separator: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 1)
    }

    private func notes(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 模型看到的原文。面板里的表格是它排版出来的,想核对"模型到底读到了什么"就看这段。
    private func rawText(_ text: String) -> some View {
        DisclosureGroup("模型收到的原文") {
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        }
        .font(.subheadline)
        .tint(.secondary)
    }
}

/// 日内分布。一天 24 根柱子,没测到的那格是空的而不是 0。
private struct HourlyChart: View {
    let series: HealthReport.Series

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let peak {
                    Text("峰值 \(format(peak)) \(series.unit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(series.points.enumerated()), id: \.offset) { _, point in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(point.value == nil ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(Color.accentColor))
                            .frame(height: height(of: point.value))
                            .frame(maxHeight: .infinity, alignment: .bottom)

                        // 24 个小时标签挤不下,每三格标一个。
                        Text(showsLabel(point.label) ? point.label : " ")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 76)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var peak: Double? {
        series.points.compactMap(\.value).max()
    }

    /// 心率那种基线不在 0 的曲线,从 0 起画会全是一样高的柱子;从最低值下探一点起画,
    /// 差异才看得出来。
    private var floor: Double {
        let values = series.points.compactMap(\.value).filter { $0 > 0 }
        guard let minimum = values.min(), let maximum = values.max(), maximum > 0 else { return 0 }
        return minimum / maximum > 0.5 ? minimum * 0.9 : 0
    }

    private func height(of value: Double?) -> CGFloat {
        guard let value, let peak, peak > floor else { return 3 }
        let ratio = (value - floor) / (peak - floor)
        return max(3, CGFloat(ratio) * 58)
    }

    private func showsLabel(_ label: String) -> Bool {
        (Int(label) ?? 0).isMultiple(of: 3)
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    private var accessibilityText: String {
        guard let peak else { return series.title }
        return String(localized: "\(series.title)，峰值 \(format(peak)) \(series.unit)")
    }
}
