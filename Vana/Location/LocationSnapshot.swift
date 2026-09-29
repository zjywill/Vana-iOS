import Foundation

/// 用户此刻大概在哪儿,**只到城市**。
///
/// 记忆存「关于这位用户」,用药表存「他和这些东西的关系」,HealthKit 给「他的数字」——这一条
/// 补的是模型看不见的最后一样环境信息:**他人在哪**。同一句「最近总睡不好」,在四十度的重庆
/// 和在极夜的北欧不是同一个问题;「这个季节该注意什么」「附近怎么就医」没有地点根本答不了。
///
/// 只到城市,是这块东西唯一的形状:
///
/// - **粗定位就够了。** 城市决定气候、季节、时差、饮食和就医方式,而这几件正是要位置的全部
///   理由。街道地址回答不了其中任何一件,只是多给模型一样它可以说漏嘴的东西。所以申请的是
///   `kCLLocationAccuracyReduced`,连坐标都不进 prompt——进去的只有一行地名。
/// - **拒绝就是不注入,不是降级。** 没授权、还没定到、反地理编码失败,三种情况在 system 段里
///   是同一件事:这一段根本不发。不发一句「位置未知」——那只会让模型去解释为什么没有,
///   或者反过来向用户要位置(同 `MemorySnapshot` 空记忆返回 nil 的理由)。
struct LocationSnapshot: Equatable, Sendable {
    static let unknown = LocationSnapshot(place: nil)

    /// 「中国 浙江省 杭州市」。拿不到就是 nil。
    let place: String?

    var isKnown: Bool { place?.isEmpty == false }

    /// 拼进 system 段的那一块。
    ///
    /// - Parameter canSearchWeb: 这一轮挂着 `web_search`。挂着才说那句「搜本地信息最多写到
    ///   城市」——对着一个没挂出去的工具发指令,只会让模型去调一次、失败一次(同 `remember`
    ///   / `search_sessions` 那几处的处理)。
    func instructionBlock(canSearchWeb: Bool = false) -> String? {
        guard let place, !place.isEmpty else { return nil }

        var text = "他此刻大概在：\(place)（设备粗定位，只精确到城市，可能有偏差）。"
            // 不写这一句,模型会拿地点当成一个必须用上的条件,于是每答一个问题都要先扯一句
            // 「杭州这个季节…」。要位置的场合是少数,多数问题里它就该安静待着。
            + "只有季节气候、时差、当地习惯或者当地能找到的服务真的影响到答案时才用它，其余时候不要提起。"
            // 城市是粗定位能给的全部。模型顺着往下猜住址、单位、行程,猜出来的每一句都是编的,
            // 而用户会以为 app 真的知道。
            + "不要据此推断他的具体住址、单位或行程，他没说的地点信息一律不要替他补。"
        if canSearchWeb {
            // 「查询词里不许有他的个人情况」那条在这儿要放开一格,否则本地信息压根搜不了;
            // 放开的也只有一格——城市。
            text += "要上网搜本地信息时，查询词里最多写到城市，不要连着他的个人情况一起搜。"
        }
        return text
    }

    /// 把反地理编码的结果拼成那一行地名。
    ///
    /// 取的三个字段**都是城市级的**——`MKAddressRepresentations` 里另外那几个
    /// (`fullAddress`、`MKAddress.shortAddress`)带街道门牌,这块东西从头到尾没有理由碰它们。
    /// 单独拎成纯函数,是为了让测试能盯住这条边界和下面那处去重。
    ///
    /// - Parameters:
    ///   - cityWithContext: 「杭州市, 浙江省, 中国」。系统按当地习惯排好序的那一份,有就直接用。
    ///   - cityName: 只有城市名。上一项拿不到时的退路。
    ///   - regionName: 国家/地区名。海上、无名区域这类地方只剩它。
    static func describe(
        cityWithContext: String?,
        cityName: String? = nil,
        regionName: String? = nil
    ) -> String? {
        if let full = trimmed(cityWithContext) { return full }
        var parts: [String] = []
        for part in [trimmed(cityName), trimmed(regionName)] {
            guard let part else { continue }
            // 城邦和直辖市会让两个字段是同一个词(「新加坡 新加坡」)。同一个名字连着出现
            // 两遍,读起来像数据出错了。
            guard parts.last != part else { continue }
            parts.append(part)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
