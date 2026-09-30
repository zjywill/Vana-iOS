import SwiftUI

/// 「⋯ › 侧聊」:主对话旁边,他自己单独拿出来聊的那几件事。
///
/// **只有他能开**:模型不开侧聊,也不建议「挪过去」。按最近说过话排。点开是盖在主对话上的一层
/// (`ChatView(sideChat:)`),关掉回到这里。
///
/// 这一页不在首屏常驻,入口只在「⋯」里:主对话永远是家。一上来就摆一张列表、再给置顶和文件夹,
/// 等于把会话列表请回来了。
struct SideChatListView: View {
    let store: SideChatStore
    /// 关着的时候还在写、或者写完了没看的那几条(未读点、「正在回复」)。删的时候也要先经过它:
    /// 还在写的那一个要先停下。
    let host: SideChatHost
    let tenant: Tenant
    let onOpen: (SideChat) -> Void

    @State private var chats: [SideChat]?
    @State private var isNaming = false
    @State private var newTitle = ""
    @State private var renaming: SideChat?
    @State private var renameText = ""
    @State private var deleting: SideChat?

    var body: some View {
        List {
            if let chats {
                if chats.isEmpty {
                    emptyState
                } else {
                    Section {
                        ForEach(chats) { chat in
                            row(chat)
                        }
                    } footer: {
                        Text("侧聊里说的不挤主对话，Vana 记得的事两边都用得上。在侧聊里建的提醒，到点出现在主对话里。")
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("侧聊")
        // 当前是谁要一直挂在视线里,但只标家人(同记忆页、用药表)。
        .navigationSubtitle(tenant.isOwner ? "" : tenant.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startNaming()
                } label: {
                    Label("新侧聊", systemImage: "square.and.pencil")
                }
            }
        }
        .alert("新侧聊", isPresented: $isNaming) {
            TextField("比如：十月去京都", text: $newTitle)
            Button("开始") { create() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("给它起个名字。也可以留空，第一句话会拿来当名字。")
        }
        .alert(
            "改名",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            presenting: renaming
        ) { chat in
            TextField(chat.displayTitle, text: $renameText)
            Button("好") {
                let text = renameText
                Task { await store.rename(chat.id, to: text) }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            Text("删除「\(deleting?.displayTitle ?? "")」？"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { chat in
            Button("删除", role: .destructive) {
                let leaving = host.discard(chat.id)
                Task {
                    await leaving?.value
                    await store.delete(chat.id)
                }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("这条侧聊里的消息和它们带的照片都会从本机删除，无法撤销。Vana 已经记住的事不受影响。")
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .vanaSideChatsDidChange)) { note in
            guard (note.object as? URL) == store.directory else { return }
            Task { await reload() }
        }
    }

    private func row(_ chat: SideChat) -> some View {
        Button {
            onOpen(chat)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chat.displayTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if host.isReplying(chat.id) {
                        Label("正在回复", systemImage: "ellipsis")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(chat.lastActiveAt, format: .relative(presentation: .named))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 关着的时候写完了、他还没看的那条。
                if host.unread.contains(chat.id) {
                    Circle()
                        .fill(.tint)
                        .frame(width: 10, height: 10)
                        .accessibilityLabel("有新回复")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleting = chat
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                startRenaming(chat)
            } label: {
                Label("改名", systemImage: "pencil")
            }
        }
        .contextMenu {
            Button {
                startRenaming(chat)
            } label: {
                Label("改名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleting = chat
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有侧聊", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("""
                想把一件事单独拿出来聊，比如一趟行程、一次比价、一份要细看的材料，就开一条侧聊。\
                那里说的不挤主对话，Vana 记得的事两边都用得上。
                """)
        } actions: {
            Button("新侧聊", action: startNaming)
                .buttonStyle(.borderedProminent)
        }
        .listRowBackground(Color.clear)
    }

    private func startNaming() {
        newTitle = ""
        isNaming = true
    }

    private func startRenaming(_ chat: SideChat) {
        renameText = chat.title
        renaming = chat
    }

    private func create() {
        let title = newTitle
        Task {
            let chat = await store.create(title: title)
            await reload()
            onOpen(chat)
        }
    }

    private func reload() async {
        chats = await store.all()
    }
}
