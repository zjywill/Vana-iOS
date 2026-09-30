import CoreGraphics
import Testing
@testable import Vana

/// 输入卡片什么时候从一行排换成铺开排。
///
/// 这套东西唯一的失败模式是**在门槛上来回抖**:界面上不报错,只表现为敲一个字整块输入区
/// 翻一次面,而那正好发生在他打字的时候。所以下面这几条盯的都是"翻不翻面",不是"好不好看"。
struct ComposerLayoutTests {
    /// 一行排那一栏 200 点宽、正文 17 点。
    private let line: CGFloat = 200
    private let hysteresis: CGFloat = 17 * ComposerBar.hysteresisEms

    private func stacks(_ width: CGFloat, wasStacked: Bool, newline: Bool = false) -> Bool {
        ComposerBar.stacks(
            textWidth: width,
            hasNewline: newline,
            wasStacked: wasStacked,
            lineWidth: line,
            hysteresis: hysteresis
        )
    }

    /// 一行放得下就不铺开,第二行一出来就铺开。
    @Test func stacksAsSoonAsTheSecondLineAppears() {
        #expect(!stacks(line - ComposerBar.caretSlack, wasStacked: false))
        #expect(stacks(line - ComposerBar.caretSlack + 1, wasStacked: false))
    }

    @Test func newlineAlwaysStacks() {
        #expect(stacks(10, wasStacked: false, newline: true))
        #expect(stacks(10, wasStacked: true, newline: true))
    }

    /// **进和出的门槛不一样。** 一样的话,光标停在门槛上的那一刻每敲一下就翻一次面。
    @Test func hysteresisKeepsStackedNearTheEdge() {
        let edge = line - ComposerBar.caretSlack - 10
        #expect(!stacks(edge, wasStacked: false))
        #expect(stacks(edge, wasStacked: true))
        #expect(!stacks(edge - hysteresis, wasStacked: true))
    }

    /// 中文输入法让抖动**必然发生**:拼音串比上屏之后的汉字宽,同一句话在敲的过程中宽度是
    /// 来回跳的。「kankan」(约 55 点)上屏成「看看」(34 点),那一缩不许翻面。
    @Test func pinyinCommitDoesNotFlip() {
        let composing = line - ComposerBar.caretSlack + 5
        let committed = composing - 21
        #expect(stacks(composing, wasStacked: false))
        #expect(stacks(committed, wasStacked: true))
    }
}
