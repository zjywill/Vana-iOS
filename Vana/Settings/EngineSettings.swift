import Foundation
import AIKit

/// 云端引擎的设置项。provider / model 不是秘密,走 UserDefaults;API key 只进 Keychain。
enum EngineSettings {
    static let providerKey = "providerId"
    static let modelKey = "model"
    static let personaKey = "assistantPersona"
    static let thinkingEnabledKey = "thinkingEnabled"
    static let checkInsEnabledKey = "checkInsEnabled"
    static let memoryEnabledKey = "memoryEnabled"
    static let medicationsEnabledKey = "medicationsEnabled"
    static let photoImagePolicyKey = "photoImagePolicy"
    static let morningCheckInHourKey = "morningCheckInHour"
    static let eveningCheckInHourKey = "eveningCheckInHour"

    /// 默认 provider 和模型。**只对全新安装生效**——存过的那份在 UserDefaults 里,
    /// 这两个常量只是 `?? defaultProvider` 那一侧的兜底,老用户一个字都不会被改动。
    ///
    /// 2026-08-16 从 anthropic / claude-sonnet-5 换成 deepseek / deepseek-chat,两个理由:
    ///
    /// - **界面整个是中文的,主力用户在国内**,而 DeepSeek 是这几家里 key 最容易拿到的
    ///   (国内支付、不用绕路)。让第一屏的默认值指向一个多数人拿不到 key 的 provider,
    ///   等于给每个新用户先设一道坎。
    /// - 那次 App Store 审核就栽在这上面:审核员按备注粘了一把 DeepSeek 的 key,
    ///   **provider 停在默认的 Anthropic 没动**,于是拿着这把钥匙去敲了另一家的门——
    ///   Anthropic 回 401 "API key is invalid",被判 Guideline 2.1(a)。
    ///
    /// 模型是 `deepseek-v4-flash`。**它看不了图**——DeepSeek 这几个里只有 `deepseek-chat`
    /// 和 `deepseek-reasoner` 能收图,所以默认状态下「照片原图」那一项不起作用(设置页那句
    /// 「当前模型看不了图」会照实说出来,不是静默的)。代价可控:化验单的文字识别本来就在
    /// 本机做,发出去的默认只有文字;要发原图的人换个能看图的模型即可。
    static let defaultProvider = "deepseek"
    static let defaultModel = "deepseek-v4-flash"
    static let defaultPersona = AssistantPersona.balanced.rawValue
    static let defaultMorningHour = 8
    static let defaultEveningHour = 21

    /// 全新安装时把默认 provider 和模型**真的写进** UserDefaults。
    ///
    /// **2026-08-19 那次审核就栽在这条缝里。** `@AppStorage(modelKey) = defaultModel` 只是
    /// 「读不到时显示什么」,它一个字都不会写进 UserDefaults;而发请求那一侧读的是
    /// `string(forKey:)`,拿到的是 nil。于是设置页上 Provider 写着 DeepSeek、模型写着
    /// DeepSeek V4 Flash、key 也存好了,一发消息却是「需要先在设置里选择云端模型」——
    /// 而屏幕上**没有任何一处**能让他把这个看着已经选好的模型再选一遍。审核员照着截图
    /// 一步都没做错。
    ///
    /// 默认值只能有一份,而且必须是存下来的那一份:显示的那份和发请求的那份各算各的,
    /// 迟早会像这次一样对不上,而对不上的表现是一句「你还没选」指着一个明明写在屏幕上的
    /// 选择。所以补的不是那句文案,是让它们从同一个地方读。
    ///
    /// 幂等,且**只填空**:存过的那份一个字不动(`?? defaultProvider` 那一侧的兜底本来
    /// 就只对全新安装生效),用户自己清空的也照样留空——那是他明确的选择,不是没配过。
    static func seedDefaultsIfNeeded(_ defaults: UserDefaults = .standard) {
        if defaults.string(forKey: providerKey) == nil {
            defaults.set(defaultProvider, forKey: providerKey)
        }
        if defaults.string(forKey: modelKey) == nil {
            defaults.set(defaultModel, forKey: modelKey)
        }
    }

    /// 这次请求该发给谁。**所有发请求的地方都从这儿读**(聊天、后台派生、用药说明),
    /// 各写一遍 `string(forKey:) ?? ""` 的话,漏掉兜底的那一处就是上面那个 bug 的下一次。
    ///
    /// 先补一次种子再读:`VanaApp.init` 已经补过了,这一句是为了让「谁先跑」不再是一个
    /// 要靠启动顺序保证的事——它幂等,而且只在全新安装的第一次真的写一下。
    ///
    /// 模型为空**不兜底**:那只可能是用户在设置页把它清掉了,或者换到了一个目录里没有内置
    /// 模型的 provider。这时候拿 DeepSeek 的模型名去顶,是拿这把钥匙去敲另一家的门。
    static var selection: (provider: String, model: String) { selection(from: .standard) }

    static func selection(from defaults: UserDefaults) -> (provider: String, model: String) {
        seedDefaultsIfNeeded(defaults)
        let provider = defaults.string(forKey: providerKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = defaults.string(forKey: modelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (provider.isEmpty ? defaultProvider : provider, model)
    }

    static var persona: AssistantPersona {
        AssistantPersona(rawValue: UserDefaults.standard.string(forKey: personaKey) ?? "")
            ?? .balanced
    }

    /// 让模型先思考再回答。默认开。
    ///
    /// `UserDefaults.bool` 没存过的时候返回 false,直接用会把默认值悄悄翻成「关」。
    static var thinkingEnabled: Bool {
        UserDefaults.standard.object(forKey: thinkingEnabledKey) as? Bool ?? true
    }

    /// 记住用户说过的长期情况和偏好。默认开,关掉之后既不注入也不再抽取,已经记下的
    /// 还留在设置页里——关开关是"先别用",不是"删干净",后者有专门的按钮。
    static var memoryEnabled: Bool {
        UserDefaults.standard.object(forKey: memoryEnabledKey) as? Bool ?? true
    }

    /// 让模型看到用药与补剂清单。默认开。
    ///
    /// **不归在 `memoryEnabled` 下面。** 关掉记忆的人不指望 Vana 还记得他随口说过的话,但他
    /// 仍然会指望这张自己一条条录进去的表还在——那是他的东西,不是模型对他的印象。
    /// 关掉之后 system 段不带名单、三个工具都不挂,但**列表页照常能看能改**:关开关是
    /// 「先别用」,不是「看不见」。
    static var medicationsEnabled: Bool {
        UserDefaults.standard.object(forKey: medicationsEnabledKey) as? Bool ?? true
    }

    /// 健康插件的总开关。默认开。关掉之后 system 段和全部工具定义里一个健康词都没有
    /// (`PromptAssemblyTests` 盯着),只留核心那两条不分话题的安全底线;用药表、家人档案这些
    /// 数据一条不动,重新打开就回来。
    static let healthEnabledKey = "plugin.health"
    static let notesEnabledKey = "plugin.notes"

    /// 插件开关。**一处定义**:装配、抽取器、插件页读的都是它。子开关(用药表)和记忆沿用各自
    /// 原来的键——那两个早就存在于已装设备上,换键名等于替用户把开关拨回默认。
    @Sendable
    static func isPluginEnabled(_ id: String) -> Bool {
        isPluginEnabled(id, defaults: .standard)
    }

    static func isPluginEnabled(_ id: String, defaults: UserDefaults) -> Bool {
        switch id {
        case PluginIds.core: true
        case PluginIds.memory: defaults.object(forKey: memoryEnabledKey) as? Bool ?? true
        case PluginIds.healthMedications: defaults.object(forKey: medicationsEnabledKey) as? Bool ?? true
        case PluginIds.health: defaults.object(forKey: healthEnabledKey) as? Bool ?? true
        case PluginIds.notes: defaults.object(forKey: notesEnabledKey) as? Bool ?? true
        default: false
        }
    }

    static func key(forPlugin id: String) -> String? {
        switch id {
        case PluginIds.memory: memoryEnabledKey
        case PluginIds.healthMedications: medicationsEnabledKey
        case PluginIds.health: healthEnabledKey
        case PluginIds.notes: notesEnabledKey
        default: nil
        }
    }

    static var healthEnabled: Bool { isPluginEnabled(PluginIds.health) }

    /// 照片原图默认发不发。**只是默认**——每一张在核对面板里都还能单独翻。
    ///
    /// 做成设置项而不是写死在「认不出字才发」上,是因为那条规则替用户做完了两个决定:
    /// 「什么时候该发」和「他愿不愿意发」。前一个 app 判得了(有没有认出字是客观的),
    /// 后一个判不了——一个只拍饭菜的人希望每张都直接发,一个只拍化验单的人一张都不想发,
    /// 而默认那档对他们俩都不对。
    ///
    /// **默认仍然是「认不出字时问一句」**:它是三档里唯一不需要用户先想清楚一件事的那档。
    static var photoImagePolicy: PhotoImagePolicy {
        PhotoImagePolicy(rawValue: UserDefaults.standard.string(forKey: photoImagePolicyKey) ?? "")
            ?? .askWhenNoText
    }

    /// 这台设备上配的那个模型看得了图吗。
    ///
    /// **不做成设置项**,和「没配 key 就不挂 `web_search`」、「没授权位置就不注入那一段」
    /// 同一条:模型有没有视觉是它自己的属性,给一个填了却不生效的开关只会让用户猜该改哪个。
    ///
    /// 这一份只给界面用(要不要出那行「让 Vana 直接看图」)——纯查表,没有副作用,
    /// 而 `resolveEngine()` 每问一次就现造一个引擎。真正决定带不带图的那一步在 `runTurn`
    /// 里问**这一轮手上的那个引擎**(`AgentEngine.supportsVision`):设置说的是下一次会用
    /// 哪个模型,而带出去的图必须和真的要跑这一轮的那个对上。
    ///
    /// 目录里没有的模型(自建 endpoint、比目录新)按**没有**算:多问一句「要不要发图」而它
    /// 其实收不了图,换来的是一次白花的往返;少问一句最多是他接着用文字描述,而那本来就是
    /// 这个 app 一直以来的样子。
    static var modelSupportsVision: Bool {
        let selection = selection
        return ProviderCatalog.model(selection.model, provider: selection.provider)?.1.supportsVision ?? false
    }
}
