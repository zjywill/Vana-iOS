import CoreGraphics
import Testing
@testable import Vana

/// 输入卡片两侧那几颗按钮停在哪儿。
///
/// 这套东西唯一的失败模式是**打字时按钮跳**:界面上不报错,只表现为第二行字一出来,
/// 加号和发送键换个地方。所以下面盯的是"同一个公式、连续地走",不是"好不好看"。
struct ComposerLayoutTests {
    private let row = ComposerLayout.rowMinHeight

    /// 单行时正好是胶囊的正中,上下对称。
    @Test func singleLineIsCentered() {
        #expect(ComposerLayout.buttonCenterY(height: row) == row / 2)
    }

    /// 多行时按钮跟着底边走:离底边的距离和单行时一模一样,一个点都不挪。
    @Test func growingKeepsButtonsOnTheLastLine() {
        for height in stride(from: row, through: row * 4, by: 11) {
            let fromBottom = height - ComposerLayout.buttonCenterY(height: height)
            #expect(fromBottom == row / 2)
        }
    }
}
