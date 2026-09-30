import SwiftUI

/// 设置 › 对话历史。一条永远的对话里没有「删这条会话」了,清理只剩三种粒度:
/// 某一条(对话里长按)、某天以前的、全部。侧聊算在里面:占用空间、清 30 天前、清空全部都连侧聊
/// 一起(`ChatViewModel.historySizeBytes` / `clearHistory`);单删一条侧聊在「侧聊」页。
///
/// 占用空间摆在最上面:这是用户决定要不要清的唯一依据,而一条攒了一年的对话到底多大,
/// 不说他根本没概念。
struct ConversationHistoryView: View {
    let model: ChatViewModel

    @State private var sizeBytes: Int?
    @State private var confirming: Action?
    @State private var result: String?

    private enum Action: Identifiable {
        case olderThanMonth
        case all
        var id: Self { self }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("占用空间") {
                    if let sizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))
                    } else {
                        ProgressView()
                    }
                }
            } footer: {
                Text("""
                    对话（包括侧聊）只存在这台设备上，不进 iCloud 备份，换新手机时不会跟着走。\
                    单条消息可以在对话里长按删除；删掉的消息连同它带的照片一起从本机清掉。
                    """)
            }

            Section {
                Button(role: .destructive) {
                    confirming = .olderThanMonth
                } label: {
                    Label("清掉 30 天前的对话", systemImage: "calendar.badge.minus")
                }
                Button(role: .destructive) {
                    confirming = .all
                } label: {
                    Label("清空全部对话", systemImage: "trash")
                }
            } footer: {
                if let result {
                    Text(result)
                } else {
                    Text("清掉的无法恢复。Vana 记住的事和用药表不受影响，要清它们到各自的页面里。")
                }
            }
            .disabled(model.isReplying)
        }
        .navigationTitle("对话历史")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshSize() }
        .confirmationDialog(
            confirming == .all ? "清空全部对话？" : "清掉 30 天前的对话？",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { action in
            Button(action == .all ? "清空全部" : "清掉", role: .destructive) {
                Task { await perform(action) }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("主对话和全部侧聊里保存的消息、以及它们带的照片都会被删除，无法撤销。")
        }
    }

    private func perform(_ action: Action) async {
        switch action {
        case .all:
            await model.clearHistory()
            result = String(localized: "已清空。")
        case .olderThanMonth:
            let removed = await model.clearHistory(olderThanDays: 30)
            result = removed == 0 ? String(localized: "没有 30 天前的消息。") : String(localized: "清掉了 \(removed) 条。")
        }
        await refreshSize()
    }

    private func refreshSize() async {
        sizeBytes = await model.historySizeBytes()
    }
}
