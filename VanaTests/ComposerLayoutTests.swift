import Testing
@testable import Vana

/// 输入卡片什么时候从一行排换成铺开排。
///
/// 这套东西唯一的失败模式是**在门槛上来回抖**:界面上不报错,只表现为敲一个字整块输入区
/// 翻一次面,而那正好发生在他打字的时候。所以下面这几条盯的都是"翻不翻面",不是"好不好看"。
struct ComposerLayoutTests {
    /// 窄排一行约十一个汉字,满两行(第三行开始)才铺开。
    ///
    /// 原来的门槛按一行 34 格估,要到第四行才换排——注释里说的一直是第三行。
    @Test func stacksOnThirdNarrowLine() {
        #expect(!ComposerBar.stacks(String(repeating: "字", count: 22), wasStacked: false))
        #expect(ComposerBar.stacks(String(repeating: "字", count: 23), wasStacked: false))
    }

    @Test func newlineAlwaysStacks() {
        #expect(ComposerBar.stacks("一\n二", wasStacked: false))
    }

    /// **进和出的门槛不一样。** 一样的话,光标停在门槛上的那一刻每敲一下就翻一次面。
    @Test func hysteresisKeepsStackedNearTheEdge() {
        let edge = String(repeating: "字", count: 22)
        #expect(!ComposerBar.stacks(edge, wasStacked: false))
        #expect(ComposerBar.stacks(edge, wasStacked: true))
    }

    /// 中文输入法让抖动**必然发生**:拼音串按一格宽算,上屏成汉字之后反而变短,所以同一句
    /// 话在敲的过程中宽度是来回跳的。那一跳不许翻面。
    @Test func pinyinInFlightDoesNotFlip() {
        let committed = String(repeating: "字", count: 19)          // 38 格,刚好铺开一行
        let composing = committed + "kankan"                        // 44 格,拼音还挂在后面
        #expect(ComposerBar.stacks(composing, wasStacked: false) == false)
        #expect(ComposerBar.stacks(composing, wasStacked: true))
        #expect(ComposerBar.stacks(committed + "看看", wasStacked: true))
    }

    /// 收回窄排的那个数要留够余量:收回去之后必须还在两行以内,否则下一帧又被推出去。
    @Test func unstackThresholdStillFitsTwoNarrowLines() {
        #expect(ComposerBar.unstackWidth <= ComposerBar.stackWidth)
        #expect(!ComposerBar.stacks(String(repeating: "a", count: ComposerBar.unstackWidth),
                                    wasStacked: false))
    }
}
