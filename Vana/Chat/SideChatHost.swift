import Foundation
import Observation

/// 侧聊的 view model 由谁持有。
///
/// **离开侧聊时正在写的回复不停**:他问完一个要查一会儿的问题,回主对话去说别的,回来时那段
/// 回答应该已经写好了——这正是撤掉子 agent 之后侧聊要接住的那件事。所以关掉那一层时,还在写的
/// 那个对象留在这儿,写完亮一个未读点;回来时接上的是**同一个对象**,不是重新读盘——两个对象
/// 同时写一条线,位置和已删的记账会各记各的。
///
/// 没在写的那个关掉就放掉(顺手收割一次记忆)。宿主跟着主对话那一屏走:换成员时整个换掉,
/// 还在写的那几个一起停下——那是上一位成员的对话。
@MainActor
@Observable
final class SideChatHost {
    typealias Factory = @MainActor (SideChat) -> ChatViewModel

    private var models: [UUID: ChatViewModel] = [:]
    /// 关着的时候写完了的那几条。只记在内存里:进程被收走时在飞的回复本来也就停了。
    private(set) var unread: Set<UUID> = []
    private let make: Factory

    init(make: @escaping Factory = { ChatViewModel(sideChat: $0) }) {
        self.make = make
    }

    isolated deinit {
        for model in models.values { model.stopReply() }
    }

    /// 打开一条侧聊。还在写的那一个就接着用。
    func open(_ chat: SideChat) -> ChatViewModel {
        unread.remove(chat.id)
        if let existing = models[chat.id] {
            existing.onReplyFinished = nil
            return existing
        }
        let model = make(chat)
        models[chat.id] = model
        return model
    }

    /// 手里的那一个(界面拿它画,不改任何状态)。
    func model(for id: UUID) -> ChatViewModel? {
        models[id]
    }

    /// 这条侧聊的回复还在写吗(列表上那行「正在回复」)。
    func isReplying(_ id: UUID) -> Bool {
        models[id]?.isReplying ?? false
    }

    var hasUnread: Bool { !unread.isEmpty }

    /// 那一层关掉了。还在写就留着,写完亮未读点再放掉;没在写就现在放掉。
    func close(_ id: UUID) {
        guard let model = models[id] else { return }
        guard model.isReplying else { return release(id) }
        model.onReplyFinished = { [weak self] in
            guard let self else { return }
            self.models[id]?.onReplyFinished = nil
            self.unread.insert(id)
            self.release(id)
        }
    }

    /// 要删这条侧聊:当场停下,不收割(删完再去读它,线程会把刚删的目录重新建出来)。
    /// 返回的 task 等回复停下、写盘落地,删目录要排在它后面。
    @discardableResult
    func discard(_ id: UUID) -> Task<Void, Never>? {
        unread.remove(id)
        guard let model = models.removeValue(forKey: id) else { return nil }
        model.onReplyFinished = nil
        return model.leaveSideChat(harvesting: false)
    }

    private func release(_ id: UUID) {
        guard let model = models.removeValue(forKey: id) else { return }
        model.leaveSideChat()
    }
}
