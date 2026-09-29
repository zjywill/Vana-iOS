import Foundation
import Synchronization

/// 某个成员那一套 store。一起给,因为它们必须落在**同一个** parent 下面——删消息要连附件
/// 一起删,拿两个不同 parent 的实例来做这件事,删掉的是另一个人的图。
struct TenantStores: Sendable {
    let root: URL
    let thread: ThreadStore
    let memory: MemoryStore
    let medications: MedicationStore
    let attachments: AttachmentStore
    let tasks: TaskStore

    init(root: URL) {
        self.root = root
        // 旧的「一个会话一个文件」在新线程存储上线时整个清掉,不迁移(`LegacySessions`)。
        // 放在造 store 之前:清的是旧目录,和新线程互不相干,但要在任何人读盘之前做完。
        LegacySessions.clearIfNeeded(root: root)
        memory = MemoryStore(directory: root)
        medications = MedicationStore(directory: root)
        attachments = AttachmentStore(parent: root)
        tasks = TaskStore(directory: root)
        thread = ThreadStore(directory: root.appending(path: "thread", directoryHint: .isDirectory), attachments: attachments)
    }
}

/// 「此刻是谁」。全局、同步、随处可读。
///
/// 做成全局状态是有理由的:同一时刻**只有一个**成员是活的,而问「现在是谁」的地方遍布
/// nonisolated 的代码(四个 store 的 `.shared`、工具装配、`HealthStore`)。把它做成要传进去的
/// 参数,等于在每一条调用链上开一个可以传错的口子——而传错的后果正是这个功能要防的那件事。
///
/// **冷启动永远回到机主。** 不记住上次选的是谁:多数时候用户打开 app 是想问自己的事,而
/// 「拿着爸爸的身份问了自己的问题」是这个功能最糟的失灵。每次进来都可预测,和「冷启动落在
/// 新对话上」是同一个取舍。
enum TenantScope {
    private struct State: Sendable {
        var owner: Tenant
        var current: Tenant
        var isolationAvailable: Bool
        var parent: URL
    }

    private static let state = Mutex<State?>(nil)
    private static let bundles = Mutex<[UUID: TenantStores]>([:])

    /// 迁移失败时顶上的那个机主。id 固定,因为**它的数据根是 `Documents/` 本身**,不是
    /// `tenants/<id>/`——这一份 id 从不用来拼路径。
    private static let legacyOwnerId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    // MARK: - 启动

    /// 在**任何视图建起来之前**调一次(`VanaApp.init`)。
    ///
    /// 同步做完:`ChatViewModel` 一造出来就要问 `SessionStore.shared` 是哪个目录,那一步等不了
    /// 一个 async 的答案。等得起的话,启动路径上就会有一个"还不知道当前是谁"的窗口,而那个
    /// 窗口里读到的是别人的数据。
    ///
    /// 迁移失败**不抛给用户**:退回单租户,数据一条不动,成员入口整个不出现,下次启动再试。
    /// 拿一个用得好好的 app 去换一个还没人用过的功能,不值得。
    @discardableResult
    static func bootstrap(parent: URL = URL.documentsDirectory, store: TenantStore = .shared) -> Bool {
        // 排在名单之前:迁移那一步会把老布局搬进 `tenants/`,标记要在搬完之后仍然成立,
        // 而目录级的标记正好覆盖搬进去的一切。两条路(迁移成功与否)都走到。
        TenantPaths.excludeFromBackup(parent: parent)
        do {
            let owner = try store.owner()
            state.withLock {
                $0 = State(owner: owner, current: owner, isolationAvailable: true, parent: parent)
            }
            return true
        } catch {
            let owner = Tenant.owner(id: legacyOwnerId)
            state.withLock {
                $0 = State(owner: owner, current: owner, isolationAvailable: false, parent: parent)
            }
            print("成员隔离未启用，按单人模式运行：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 读

    private static func resolved() -> State {
        if let value = state.withLock({ $0 }) { return value }
        // 没 bootstrap 过就当单租户。测试和 preview 走的是这一条。
        let owner = Tenant.owner(id: legacyOwnerId)
        let fallback = State(
            owner: owner,
            current: owner,
            isolationAvailable: false,
            parent: URL.documentsDirectory
        )
        state.withLock { $0 = $0 ?? fallback }
        return state.withLock { $0 } ?? fallback
    }

    static var current: Tenant { resolved().current }
    static var owner: Tenant { resolved().owner }

    /// 这一刻能不能读这台设备的 Apple 健康数据。
    ///
    /// 这就是「数据归属」在代码里的样子:HealthKit 不是 app 的全局资源,是机主那个成员的属性。
    static var isOwnerActive: Bool { resolved().current.isOwner }

    /// 迁移成功了才算真的隔离。false 时整个成员入口不出现——一个点进去不起作用的开关,
    /// 比没有这个开关糟。
    static var isolationAvailable: Bool { resolved().isolationAvailable }

    // MARK: - 切换

    static func select(_ tenant: Tenant) {
        state.withLock { $0?.current = tenant }
    }

    /// 名单里改了名字/年龄段之后同步过来。当前这一位改了名,导航栏那行字也得跟着变。
    static func refresh(_ tenant: Tenant) {
        state.withLock {
            if $0?.current.id == tenant.id { $0?.current = tenant }
            if $0?.owner.id == tenant.id { $0?.owner = tenant }
        }
    }

    /// 删掉的正好是当前这位,退回机主。
    static func fallBackToOwnerIfNeeded(removed id: UUID) {
        state.withLock {
            guard $0?.current.id == id, let owner = $0?.owner else { return }
            $0?.current = owner
        }
        bundles.withLock { $0[id] = nil }
    }

    // MARK: - store

    /// 某个成员那一套。**按成员号缓存住**:`SessionStore` 那份增量索引的全部收益来自它活得
    /// 够久,每次现造一个等于把索引扔了,而列表刷新跑在用户已经在等的时候。
    static func stores(for tenant: Tenant) -> TenantStores {
        if let cached = bundles.withLock({ $0[tenant.id] }) { return cached }
        let made = TenantStores(root: root(for: tenant))
        return bundles.withLock {
            if let existing = $0[tenant.id] { return existing }
            $0[tenant.id] = made
            return made
        }
    }

    static var currentStores: TenantStores { stores(for: current) }

    /// 机主那一套,**不跟着当前选中的人走**。
    ///
    /// check-in、Siri 播报、后台派生这几件事从头到尾都是机主的:它们读的是 HealthKit,而
    /// HealthKit 只有机主。用户此刻正在看妈妈那一栏,不该让早上那条通知改说妈妈的事,更不该
    /// 让后台那一轮把结论写进妈妈的会话里。
    static var ownerStores: TenantStores { stores(for: owner) }

    private static func root(for tenant: Tenant) -> URL {
        let state = resolved()
        guard state.isolationAvailable else { return state.parent }
        return TenantPaths.root(for: tenant.id, parent: state.parent)
    }
}
