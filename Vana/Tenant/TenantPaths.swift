import Foundation

/// 每个成员一个目录:`Documents/tenants/<uuid>/{thread,attachments,memory.json,medications.json}`。
///
/// **目录隔离,不是给每条记录加 tenantId。** 判据是失败模式:加字段要求每一处查询都记得带上
/// 过滤条件,而漏一处的后果是**串数据**——拿妹妹的化验单去解释爸爸的心率,静默、看着正常、
/// 事后查不出来。目录隔离漏写代码的失败模式是"看不到",用户当场就发现了。在健康 app 里这两种
/// 错误的代价差着一个数量级。
///
/// 白拿的还有两样:四个 store 早就为了测试留好了目录注入口(那条「测试必须传自己的临时目录」
/// 的血泪),所以租户化就是**换一个 parent**,不用动任何数据模型;删一个成员就是删一个目录,
/// 不用扫全库确认删干净了。
enum TenantPaths {
    static let rootName = "tenants"

    struct Item: Sendable {
        let name: String
        let hint: URL.DirectoryHint
    }

    /// 跟着成员走的那几样东西。**这份清单就是"隔离"这句话的定义**——隐私会话那条规矩
    /// (按有哪些写入路径定义,不按名字)在这儿同样成立,漏一条,整个承诺就是假的。
    ///
    /// 少了谁:Keychain 里那两把 key(那是机主的账单,不是成员的属性)、provider / model /
    /// persona / 思考开关(那是"这台设备怎么连模型")、位置授权(系统级的)。
    ///
    /// `sessions` 是旧的会话存储,新线程上线之后首次启动就清掉(`LegacySessions`);留在单子上是为了
    /// 老布局迁移时它也跟着搬进成员目录,在那儿被清掉,而不是赖在 `Documents/` 下面。
    static let perTenantItems: [Item] = [
        Item(name: "thread", hint: .isDirectory),
        Item(name: "sessions", hint: .isDirectory),
        Item(name: "attachments", hint: .isDirectory),
        Item(name: "memory.json", hint: .notDirectory),
        Item(name: "medications.json", hint: .notDirectory)
    ]

    /// 某个成员的数据根。四个 store 拿它当 parent。
    static func root(for id: UUID, parent: URL = URL.documentsDirectory) -> URL {
        parent
            .appending(path: rootName, directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// 把成员数据整个排除出备份。启动时跑一次(`TenantScope.bootstrap`)。
    ///
    /// **HealthKit 的规矩是健康数据不许进 iCloud**,而 `Documents/` 默认是要进设备备份的,
    /// 那份备份多数人存在 iCloud 上。会话文件里逐轮记着从 HealthKit 查到的数值,附件目录里
    /// 是带姓名和就诊号的化验单——这两样正是那条规矩说的东西。
    ///
    /// **代价要说清楚:换新手机时这些数据不会跟着走。** 这是拿"换机重来一次"换"健康数据不
    /// 出这台设备",在一个连原始照片都不往外发的 app 里,这个取舍是一致的。
    /// 隐私说明里照实写了这一条——盘上的行为和那份文件必须逐字对上。
    ///
    /// 标在**目录**上,底下的东西一并排除,所以新建的会话和照片不用各自再标一次。
    /// 名单文件单独标:它自己不是健康数据,但它是通往几个成员那几个目录的索引。
    static func excludeFromBackup(parent: URL = URL.documentsDirectory) {
        let manager = FileManager.default
        let root = parent.appending(path: rootName, directoryHint: .isDirectory)
        // 先建出来再标。等它被第一次写入时才标的话,中间那一段时间里的备份已经带上了。
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)

        var targets = [root, parent.appending(path: "tenants.json", directoryHint: .notDirectory)]
        // 迁移失败退回单人模式时,数据还直接躺在 `Documents/` 下。那一份同样要排除——
        // 隔离没启用不是把健康数据交出去的理由。
        targets += perTenantItems.map { parent.appending(path: $0.name, directoryHint: $0.hint) }

        for target in targets {
            guard manager.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
            var url = target
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }
}
