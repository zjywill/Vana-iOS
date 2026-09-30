import Foundation

/// system 段里每一块排在哪。
///
/// **按「会不会变」分区,不按「谁的」分区**:prompt 缓存认的是前缀,前缀里任何一个字变了,
/// 它后面的全部都要重新按全价算。所以一段对话里不变的排前面,会变的排后面,一变只打掉尾巴:
///
/// - `0–99`    核心静态:身份与规则、插话、侧聊说明、人格。
/// - `100–199` 核心插件的工具用法。只在对应工具挂出去时才有,挂载集合在两次淘汰之间不变。
/// - `200–299` 健康插件:规则与它自己的工具用法,同上。
/// - `300–399` 易变快照:今天、成员、位置、记忆、用药、目标……随时会变,一律排在最后。
///
/// 数字之间留了空,新插件往自己的区间里加,不用挪别人的。同一个数字按插件注册顺序稳定排序。
/// 和 Android 那份 `PromptOrder` 同一张表。
enum PromptOrder {
    // MARK: 核心静态
    static let base = 0
    static let interjection = 20
    /// 侧聊的说明:这是哪件事、主对话在别处。只有侧聊有;侧聊存在期间逐字不变(改名时变一次)。
    static let sideChat = 25
    static let persona = 30

    // MARK: 核心插件的工具用法
    static let guideRecall = 100
    static let guideRemember = 110
    static let guideWebSearch = 120
    static let guideWebFetch = 125
    static let guideAskUser = 130
    static let guideTasks = 140
    static let guideNotes = 150

    // MARK: 健康插件
    static let healthRules = 200
    /// Apple 健康那几个工具怎么用(日期口径、没有记录的那几项)。只有机主、只在工具挂出去时。
    static let guideHealthData = 205
    static let guideExercise = 210
    static let guideMedicationLog = 220
    static let guideMedicationList = 230
    /// 健康插件对核心工具的补充(搜索、反问、召回、记忆),各自按那个工具是否挂出去门控。
    static let healthToolNotes = 260

    // MARK: 易变快照
    static let today = 300
    static let tenant = 310
    static let location = 320
    static let memory = 330
    static let medications = 340
    static let focusMedication = 360
    static let goals = 370
    /// 主对话里挂的侧聊名单:几个名字加最近一次的日期。侧聊一有人说话就可能变,排在最后。
    static let sideChats = 380
}
