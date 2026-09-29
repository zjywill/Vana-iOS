import SwiftUI

/// 「Vana 记住的事」。
///
/// 这些内容会随每次提问发给模型 provider,所以它必须是可看、可改、可删的。一个用户看不见
/// 的记忆等于一个他没同意过的画像;而只能整体清空、不能单条改的,他一发现某条记错了,
/// 只能把对的那些一起扔掉。
struct MemoryView: View {
    @AppStorage(EngineSettings.memoryEnabledKey) private var memoryEnabled = true

    @State private var items: [MemoryItem] = []
    @State private var hasLoaded = false
    @State private var draft: MemoryDraft?
    @State private var isShowingClearConfirmation = false
    @State private var errorMessage: String?
    @State private var query = ""

    /// 搜索框从这么多条起才出现。条数少的时候它只是一行多余的控件。
    private static let searchThreshold = 8

    private var visibleItems: [MemoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        Form {
            Section {
                Toggle("记住我说过的事", isOn: $memoryEnabled)
            } footer: {
                Text("""
                    开着时，Vana 会从对话里记下你的长期情况、表达偏好和最近的事，并在之后的提问里带上。\
                    关掉只是先不用，已经记下的还在下面，可以逐条删，也可以全部忘掉。
                    """)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityElement(children: .combine)
                }
            }

            if items.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("还没有记住什么", systemImage: "brain")
                    } description: {
                        Text("多聊几次之后，你的作息、偏好和最近在忙的事会记在这里。也可以现在就自己加一条。")
                    }
                    .listRowBackground(Color.clear)
                }
            }

            ForEach(MemoryKind.allCases) { kind in
                let matching = visibleItems.filter { $0.kind == kind }
                if !matching.isEmpty {
                    Section {
                        ForEach(matching) { item in
                            Button {
                                draft = MemoryDraft(item)
                            } label: {
                                row(item)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            delete(offsets.map { matching[$0].id })
                        }
                    } header: {
                        Text(kind.title)
                    } footer: {
                        // 它的主人(健康插件)关着:数据还在,只是暂时不带进对话。不说的话,
                        // 他会以为这几条还在起作用。
                        if let owner = PluginRegistry.memoryOwner(kind),
                           !EngineSettings.isPluginEnabled(owner.manifest.id) {
                            Text("「\(owner.manifest.name)」关着，这一类暂不使用。重新打开就回来。")
                        } else {
                            Text(kind.hint)
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    isShowingClearConfirmation = true
                } label: {
                    Label("忘掉全部", systemImage: "trash")
                }
                .disabled(items.isEmpty)
            } footer: {
                Text("""
                    已记 \(items.count)/\(MemoryStore.maxItems) 条。\
                    这里只记查不到的事——作息、限制、你的偏好、最近的事；\
                    具体的数字每次都会重新查，不会记进来。\
                    \n对话时这些内容会随问题一起发给你选的模型 provider。
                    """)
            }
        }
        .modifier(MemorySearch(query: $query, isShown: items.count >= Self.searchThreshold))
        .navigationTitle("Vana 记住的事")
        // 记忆也跟着当前成员走(`MemoryStore.shared`)。同用药表:看不见名字,用户会以为
        // 自己在改的是"Vana 对我的印象"。
        .navigationSubtitle(TenantScope.isOwnerActive ? "" : TenantScope.current.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    draft = MemoryDraft()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加一条")
            }
        }
        .sheet(item: $draft) { editing in
            MemoryEditor(draft: editing, onSave: save)
        }
        .confirmationDialog(
            "忘掉全部记忆？",
            isPresented: $isShowingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("忘掉全部", role: .destructive) { removeAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("包括你自己添加的那些，无法撤销。对话记录和其他数据不受影响。")
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            items = await MemoryStore.shared.items()
        }
    }

    private func row(_ item: MemoryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.text)
                .foregroundStyle(.primary)
            Text(subtitle(item))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// 每条都要能回答「这句哪来的」。分不清是自己写的、自己让记的,还是模型自己记的,
    /// 用户就没法判断该不该信它。
    private func subtitle(_ item: MemoryItem) -> String {
        var parts = [item.originLabel]
        parts.append(item.updatedAt.formatted(.relative(presentation: .named)))
        if let dueAt = item.dueAt, item.kind.expires {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: dueAt).day ?? 0
            if item.kind == .episode {
                parts.append(days <= 0 ? String(localized: "今天淡出") : String(localized: "\(days) 天后淡出"))
            } else {
                parts.append(days <= 0 ? String(localized: "该回头看了") : String(localized: "\(days) 天后回头看"))
            }
        }
        return parts.joined(separator: " · ")
    }

    private func save(_ draft: MemoryDraft) {
        let dueAt = MemoryItem.dueDate(kind: draft.kind, days: draft.days, now: Date())
        perform {
            if let id = draft.editing {
                return try await MemoryStore.shared.update(
                    id: id,
                    kind: draft.kind,
                    text: draft.text,
                    dueAt: dueAt
                )
            }
            return try await MemoryStore.shared.add(
                kind: draft.kind,
                text: draft.text,
                origin: .manual,
                dueAt: dueAt
            )
        }
    }

    private func delete(_ ids: [UUID]) {
        perform {
            var latest = items
            for id in ids {
                latest = try await MemoryStore.shared.delete(id: id)
            }
            return latest
        }
    }

    private func removeAll() {
        perform { try await MemoryStore.shared.removeAll() }
    }

    private func perform(_ work: @escaping () async throws -> [MemoryItem]) {
        Task {
            do {
                items = try await work()
                errorMessage = nil
            } catch {
                errorMessage = String(localized: "保存失败：\(error.localizedDescription)")
            }
        }
    }
}

/// 条数够多才出现的搜索框。
private struct MemorySearch: ViewModifier {
    @Binding var query: String
    let isShown: Bool

    func body(content: Content) -> some View {
        if isShown {
            content.searchable(text: $query, prompt: "搜索记忆")
        } else {
            content
        }
    }
}

/// 正在编辑(或新建)的一条。`editing` 为 nil 就是新建。
struct MemoryDraft: Identifiable {
    let id = UUID()
    var editing: UUID?
    var kind: MemoryKind = .profile
    var text = ""
    var days = 14

    init() {}

    init(_ item: MemoryItem) {
        editing = item.id
        kind = item.kind
        text = item.text
        if let dueAt = item.dueAt {
            days = max(Calendar.current.dateComponents([.day], from: Date(), to: dueAt).day ?? 14, 1)
        }
    }
}

private struct MemoryEditor: View {
    @State var draft: MemoryDraft
    let onSave: (MemoryDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTextFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("比如：他上夜班，白天补觉", text: $draft.text, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($isTextFocused)
                } footer: {
                    Text("""
                        一句话说清就行。不要写具体数字——那些每次都会重新查，\
                        写死在这里明天就是错的。
                        """)
                }

                Section {
                    Picker("类别", selection: $draft.kind) {
                        ForEach(MemoryKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }

                    if draft.kind.expires {
                        Picker(draft.kind == .episode ? "多久后淡出" : "多久后回头看", selection: $draft.days) {
                            ForEach([3, 7, 14, 30, 60, 90], id: \.self) { days in
                                Text("\(days) 天").tag(days)
                            }
                        }
                    }
                } footer: {
                    Text(draft.kind.hint)
                }
            }
            .navigationTitle(draft.editing == nil ? "添加记忆" : "编辑记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { isTextFocused = true }
        }
    }
}
