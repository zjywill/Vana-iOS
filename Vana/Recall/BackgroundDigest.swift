import Foundation

/// app 切前后台时替用户跑的那点后台活。
///
/// 存在的意义是**一次只跑一件**,和「后台的模型调用同时只准跑一件」是同一把锁
/// (`BackgroundModelWork`)。眼下只有到期的待跟进;目标的每周回顾和后台任务走各自的调度。
enum BackgroundDigest {
    /// 有活就干一件,返回是否真的产出了新结论(调用方据此决定要不要重排通知)。
    ///
    /// - Parameters:
    ///   - memoryStore / thread: **机主那一份,不跟着当前选中的成员走。** 这一轮读的是 HealthKit,
    ///     而那份数据只有机主有;用户此刻正好在看妈妈那一栏,不该让后台这一轮把机主的结论
    ///     写进妈妈的对话里。
    @discardableResult
    static func runIfDue(
        now: Date = Date(),
        memoryStore: MemoryStore = TenantScope.ownerStores.memory,
        thread: ThreadStore = TenantScope.ownerStores.thread
    ) async -> Bool {
        // check-in 关掉就没有送达的路子,这一轮纯粹是花钱写给自己看。云端设置不齐则是发都发不出去。
        guard UserDefaults.standard.bool(forKey: EngineSettings.checkInsEnabledKey),
              CloudAccess.backgroundSettings() != nil
        else { return false }

        // **在飞守卫。** 「今天跑过没有」读的是线程 meta,要等这一轮跑完(几十秒)才写下去;
        // `scenePhase` 一次开合就触发两次,第二次进来时第一轮还在飞。
        let ran = await BackgroundModelWork.shared.run {
            guard let followUp = await FollowUpRunner.pending(now: now, memoryStore: memoryStore, thread: thread) else {
                return false
            }
            return await FollowUpRunner.run(
                followUp,
                now: now,
                memoryStore: memoryStore,
                thread: thread,
                tenant: TenantScope.owner
            )
        }
        return ran ?? false
    }
}
