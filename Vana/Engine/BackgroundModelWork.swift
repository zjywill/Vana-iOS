import Foundation

/// 后台的模型调用,**同时只准跑一件**。
///
/// 前台那条回复不归这里管:用户在等它,它永远优先,而且 `ChatViewModel` 那边本来就只允许
/// 一条。这里管的是用户看不见的那几件——会话结束抽记忆、到期的待跟进、目标的周进展。
///
/// 手机上并发的模型调用抢的是同一条窄网络和同一份电量,而这几件用户一件都看不见:两件一起跑
/// 不会让任何一件更快到达他眼前,只会让正在等回复的那条更慢。
///
/// **拿不到位子就不跑,不排队。** 后台这几件都是「下次还有机会」的:切一次前后台、换一次会话
/// 就会再来一遍,而且各自的闸门(跑过没有、抽过没有)都还在,不会漏。排队反而是坏的——用户
/// 连着切五次前后台,就攒出五轮待跑的调用,而它们说的是同一件事。
actor BackgroundModelWork {
    static let shared = BackgroundModelWork()

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// **排队等这把锁**,不是「忙就跳过」:用户点了开始的后台任务不能因为这一刻恰好有别的活
    /// 就丢掉。抽记忆、待跟进那几件照旧走 `run`(拿不到就这次不跑)。
    func runExclusive<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        while isBusy {
            await withCheckedContinuation { waiters.append($0) }
        }
        isBusy = true
        defer { release() }
        return await work()
    }

    private func release() {
        isBusy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    /// 有位子就跑,没有就返回 nil。
    ///
    /// `isBusy` 在 `await work()` 期间一直是 true:actor 在 await 处是可重入的,别的调用
    /// 这时候进得来——那正是要挡的那一下(`scenePhase` 连着触发两次)。
    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { release() }
        return await work()
    }

    /// 只给测试看。线上没人该依赖这个值做判断——问完到用的那一瞬它就可能变了。
    var isRunning: Bool { isBusy }
}
