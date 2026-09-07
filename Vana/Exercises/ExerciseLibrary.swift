import Foundation

/// 一个动作:名字、步骤、要领、禁忌,以及一到两张图。
///
/// **没有图的动作不在这个库里。** 一条只有文字的记录,恰恰是模型不用这个库也能写出来的东西
/// ——它进来只会占 prompt、占卡片的位置,还让「卡片上有图」这句话变成有时候成立。
/// 所以 `files` 永远非空,`ExerciseLibrary` 在载入时把不满足的整条丢掉。
struct ExerciseMove: Codable, Identifiable, Equatable, Sendable {
    let id: String
    /// 中文名。工具输出和卡片标题都用它——模型和用户说的是同一个名字。
    let zh: String
    let en: String
    /// 图的来源,决定「关于」页要署谁的名(`ExerciseLibrary.attributions`)。
    let src: String
    let scenes: [String]
    let part: String
    let gear: String
    let steps: [String]
    let cue: String
    let avoid: String
    /// 这个动作会明显吃力的关节。用户说过哪儿不好,带那个关节的整组**根本不返回**,
    /// 不是排在后面——同「他明确不能吃的绝对不要提」。
    let risk: [String]
    /// 要不要到地上去(躺/跪/趴)。办公室、年纪大的用户、腰不好的人,这一条比部位还硬。
    let floor: Bool
    /// 资源目录里的图名,按动作发生的先后排。多于一张时卡片上交叉淡入。
    ///
    /// **一张静图说不出方向。** 最早那一版里有 31 个动作只有一张彩色图标,用户的原话是
    /// 「不是动作,我都看不懂」——所以现在库里没有单张的动作:`wg` 是三帧,`ek` 是两态。
    let files: [String]

    /// SVG 进的是 asset catalog,名字是去掉扩展名的文件名。
    var imageNames: [String] { files.map { String($0.dropLast(4)) } }
}

/// 打进 app 包里的那份动作库。
///
/// **不联网、不按需下载。** 46 个动作连图 3.3MB,而下载要处理失败、要处理下到一半、
/// 要在用户正等着看图的时候转圈——换来的只是一点包体积。同「照片在本机识别」那条线。
///
/// 图源两个,**都是 Everkinetic 那一脉的线稿**,所以混排不打架:`wg` 是
/// bryllim/workout-guide(三帧、512 见方、单路径,导入时把 `fill="#fff"` 改成
/// `#333`——原件是给深色底用的,照搬进来在白垫子上是一片空白);`ek` 是 everkinetic
/// 原件的两态图,只留给 workout-guide 那 302 个动作里**没有**对应动作的那几条
/// (颈部、踝、膝绕环、毛巾三头、腹部收紧——那份目录是健身房力量库,这几类整类都没有)。
struct ExerciseLibrary: Sendable {
    let moves: [ExerciseMove]
    let scenes: [String]

    private let byID: [String: ExerciseMove]

    static let shared = ExerciseLibrary()

    /// 出处与授权。`AboutView` 要逐条列出来——CC BY-SA 要求保留出处,而声明和实际做的事
    /// 对不上是这一整块唯一的失败模式。
    ///
    /// **改编者和原始来源都要署。** workout-guide 是 Bryl Lim 在 Everkinetic 上改的
    /// (重新描线、补了两百多个新动作),CC BY-SA 的传递性要求两个名字都在。
    static let attributions: [String] = [
        "动作图示 · everkinetic/data(CC BY-SA 4.0)",
        "动作图示 · bryllim/workout-guide,Bryl Lim(CC BY-SA 4.0,改编自 everkinetic/data)"
    ]

    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "exercises", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            // 载不进来不是崩溃的理由:这个功能没了,别的照常。工具那边会照实说没有动作可推荐。
            moves = []
            scenes = []
            byID = [:]
            return
        }
        moves = file.moves.filter { !$0.files.isEmpty }
        scenes = file.scenes
        byID = Dictionary(moves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private struct File: Codable {
        let scenes: [String]
        let moves: [ExerciseMove]
    }

    subscript(id: String) -> ExerciseMove? { byID[id] }

    func moves(ids: [String]) -> [ExerciseMove] { ids.compactMap { byID[$0] } }

    /// 挑几个动作。
    ///
    /// **排除是硬的,排序是软的。** `excludeJoints` 和 `avoidsFloor` 直接把整组滤掉;
    /// 剩下的按「场景内的固定顺序」给,不做随机——同一个人在同一个场景下问两次拿到两组
    /// 不同的动作,会让人以为前一组是随口说的。
    func suggest(
        scene: String,
        excludeJoints: [String] = [],
        avoidsFloor: Bool = false,
        limit: Int = 3
    ) -> [ExerciseMove] {
        let excluded = Set(excludeJoints)
        return moves
            .filter { $0.scenes.contains(scene) }
            .filter { excluded.isDisjoint(with: $0.risk) }
            .filter { !(avoidsFloor && $0.floor) }
            .prefix(max(1, min(limit, 4)))
            .map { $0 }
    }
}
