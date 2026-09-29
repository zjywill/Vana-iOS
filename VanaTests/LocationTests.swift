import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 位置:进 system 段的只有一行地名,拒绝之后一个字都不进。
///
/// 这套东西盯的大半是「不该发生什么」——没授权不许发一句「位置未知」、坐标不许进 prompt、
/// 没挂搜索工具时不许提搜索。真正会翻车的两处地名拼接(直辖市、没有 locality 的郊县)
/// 也在这儿。
@Suite("Location")
struct LocationTests {

    // MARK: - 地名拼接

    @Test("系统排好序的那一份有就直接用")
    func prefersCityWithContext() {
        let place = LocationSnapshot.describe(
            cityWithContext: "杭州市, 浙江省, 中国",
            cityName: "杭州市",
            regionName: "中国"
        )
        #expect(place == "杭州市, 浙江省, 中国")
    }

    @Test("城邦的城市名和国家名是同一个词，不重复写两遍")
    func cityStateIsNotRepeated() {
        // 「新加坡，新加坡」读起来像数据出错了。海上和无名区域会走到这条退路上,
        // 那时候只剩这两个字段。
        let place = LocationSnapshot.describe(
            cityWithContext: nil,
            cityName: "新加坡",
            regionName: "新加坡"
        )
        #expect(place == "新加坡")
    }

    @Test("只剩国家名时就报国家名")
    func fallsBackToRegion() {
        #expect(LocationSnapshot.describe(cityWithContext: nil, cityName: nil, regionName: "冰岛") == "冰岛")
    }

    @Test("一个字段都没有就是没有位置")
    func emptyPlacemarkYieldsNil() {
        #expect(LocationSnapshot.describe(cityWithContext: nil) == nil)
        // 空白串和 nil 是一回事——反地理编码返回空字符串的字段并不罕见。
        #expect(LocationSnapshot.describe(cityWithContext: "  ", cityName: "", regionName: nil) == nil)
    }

    // MARK: - 进 system 段的那一块

    @Test("没有位置时那一段整个不发")
    func unknownProducesNoBlock() {
        // 不发一句「位置未知」:那只会让模型去解释为什么没有,或者反过来向用户要位置。
        #expect(LocationSnapshot.unknown.instructionBlock() == nil)
        #expect(LocationSnapshot(place: "").instructionBlock() == nil)
    }

    @Test("有位置时说清它有多粗，以及不许往下猜")
    func blockStatesItsLimits() throws {
        let block = try #require(LocationSnapshot(place: "杭州市, 浙江省, 中国").instructionBlock())

        #expect(block.contains("杭州市, 浙江省, 中国"))
        // 三句缺一不可:粗到什么程度(可核对)、什么时候才用(不用位置的问题占多数)、
        // 不许顺着往下猜(猜出来的每一句都是编的,而用户会以为 app 真的知道)。
        #expect(block.contains("只精确到城市"))
        #expect(block.contains("其余时候不要提起"))
        #expect(block.contains("不要据此推断他的具体住址"))
    }

    @Test("没挂搜索工具就不提搜索")
    func searchCaveatFollowsTheTool() {
        let snapshot = LocationSnapshot(place: "杭州市, 浙江省, 中国")
        #expect(snapshot.instructionBlock(canSearchWeb: false)?.contains("查询词") != true)
        #expect(snapshot.instructionBlock(canSearchWeb: true)?.contains("查询词") == true)
    }

    // MARK: - 引擎

    @Test("位置进 system 段，没位置时一个字都不进")
    func engineInjectsPlace() {
        let engine = TestAssembly.engine(TestAssembly.environment(location: LocationSnapshot(place: "杭州市, 浙江省, 中国")))
        #expect(engine.systemInstruction().contains("杭州市, 浙江省, 中国"))

        // 默认没有位置。用户拒绝授权走的就是这条路——不是降级成一句模糊的话,是整段不发。
        #expect(!TestAssembly.engine().systemInstruction().contains("他此刻大概在"))
    }
}
