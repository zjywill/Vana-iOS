# 上架清单

app 里的合规部分已经做完（见 CLAUDE.md「架构:合规」）。这份文档是**剩下那半边**：App Store
Connect 里要填的东西。填错的代价和代码里写错一样——审核看到的是这两边**合起来**的样子，对不上
就是一次被拒。

下面「发一个 TestFlight build」是把 build 送上去的流程，其余各节是 ASC 里要填的内容。
**内部测试用不到审核那几节**（备注、年龄分级、隐私标签），但发给别人之前每一节都要填完。

## 发一个 TestFlight build

### 0. 本机先过一遍

```bash
xcodegen && xcodebuild -project Vana.xcodeproj -scheme Vana \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

不过就别往下走——见下面「提交前在本机确认」。

### 1. 团队 ID 要对上

`project.yml` 里那行是 `DEVELOPMENT_TEAM: NGM7GX8DGB`。Xcode > Settings > Accounts 里登录
zjywill@gmail.com，确认这个团队在列表里，而且你的角色是 Account Holder / Admin / App
Manager——**Developer 角色建不了 app 记录**，而它报的错（`DistributionAppRecordProviderError`）
看不出是权限问题。

Team ID 在 developer.apple.com > Membership 那一页；ASC 里没有这一项（「用户和访问 > 集成」
里那个是 Issuer ID，不是一回事）。本机也读得出来：

```bash
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  security cms -D -i "$f" | plutil -p - | grep -E 'TeamName|application-identifier' | head -2; echo ---
done
```

**必须是已付费的 Apple Developer Program 团队。** 免费的个人团队能真机调试，但传不了
TestFlight，而它在 Xcode 里长得和付费团队一模一样（名字后面写着 Personal Team）。

**换团队之前先想清楚 bundle id。** 归档时 Xcode 会顺手把 bundle id 注册成当前团队名下的
App ID，而 **bundle id 在 Apple 那边全局唯一**：一旦 ASC 里为它建了记录，那个 App ID 就删不掉
（`appears to be in use by the App Store`），别的团队再也注册不了同一串，而已删除 app 的
bundle id Apple 又明写着不能重用。2026-08-12 就是这么把 `com.pinapia.vana` 丢在
Ardent Core Limited 名下的，现在这串 `.ios` 后缀是那次踩出来的。**先定团队，再归档。**

### 2. ASC 里建 app 记录

上传时 ASC 要先有一条对得上的记录，否则 Distribute 那步报
`DistributionAppRecordProviderError`（Xcode 找不到对得上的记录，就是这一句没头没尾的话）。

1. developer.apple.com > Identifiers：确认 `com.pinapia.vana.ios` 在 **NGM7GX8DGB** 名下。
   归档过一次的话 Xcode 已经自动注册好了，**勾上 HealthKit**（entitlement 里那条
   `health-records` 是它的子项）。
2. appstoreconnect.com > Apps > 新建：平台 iOS、主要语言简体中文、bundle id 选上面那个、
   SKU 随便一个唯一串。
3. 名称填 **Vana**，和主屏显示的名字一致。见下面「名称这一栏」。
4. 新账号第一次用的话，先看 ASC > 业务里有没有待签的协议。没签完同样是那个错。

#### 名称这一栏

App Store 名称是 **Vana**，`INFOPLIST_KEY_CFBundleDisplayName` 也是 **Vana**。现在两边一致，
但**它们本来就不必一致**——记住这一条，因为下次重名时它是最省事的出路。

App Store 名称**全球唯一**，主屏那个名字不要求唯一。2026-08-12 第一次建记录时报了
`The App Name you entered is already being used`——占着「Vana」的**正是自己**：更早在
Ardent Core Limited 名下建的那条记录（就是把 bundle id `com.pinapia.vana` 卡死的同一条）
用了这个名字。到那条记录的「App 信息」里改个名（从没提交过的 app 名称随便改），
「Vana」就放出来了。

所以这两件事的严重程度差很远：**名字是拿得回来的，bundle id 不是。**
`com.pinapia.vana` 永久留在老团队那边，而「Vana」这个名字收回来了。

再往下的两条：

- **名称和 bundle id 不是一类东西**：前者上架前随便改，上架后跟着新版本提交也能改；后者首次
  上传之后永久锁死。所以别为了名称这一栏拖住 build——真被别人占了，先加个后缀把 build 传上去。
- 改名称时只有一条硬约束：**不能有医疗功效的暗示**（「诊断」「筛查」「检测」都不行），而且要
  和 app 实际做的事对得上，否则是 Guideline 2.3。副标题和关键词同理。

### 3. 归档

第一次走 Xcode GUI 最省事（Product > Archive）：自动签名会自己去申请 Apple Distribution 证书
和 profile，本机现在**只有开发证书**，一张分发证书都没有。

命令行等价（`-allowProvisioningUpdates` 是让它去申请那张证书，少了会直接失败）：

```bash
xcodegen && xcodebuild -project Vana.xcodeproj -scheme Vana -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Vana.xcarchive \
  -allowProvisioningUpdates archive
```

### 4. 上传

Xcode > Window > Organizer > 选那个 archive > Distribute App > **TestFlight Internal Testing
Only**（只自己测就够了；要发外部测试或上架就选 App Store Connect）。

出口合规那一问不会再弹——`ITSAppUsesNonExemptEncryption = false` 已经在 Info.plist 里。

### 5. 装到手机上

ASC > TestFlight > 内部测试：把自己（zjywill@gmail.com，Account Holder）加进一个内部测试组。
**内部测试不走 Beta App Review**，build 处理完（几分钟到半小时）就能装。手机上装 TestFlight
app、用同一个 Apple ID 登录。

**要在真机上测。** 模拟器里没有 Apple 健康数据，这个 app 的主线在模拟器上跑不起来。

### 6. 下一次上传

`CURRENT_PROJECT_VERSION`（`project.yml`）**每次 +1**，改完 `xcodegen`。同一个
`MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` 的 build，ASC 直接拒收。
`MARKETING_VERSION` 只在对外版本真的变了的时候动。

TestFlight 的 build **90 天后过期**，到期就得重传一个。

## 公开测试（外部测试 + 公开链接）

内部测试是给自己的：**不过审、几分钟就能装、上限 100 人**。给外人用要换一条路——外部测试组
加公开链接，任何人点开链接就能装，**上限 10000 人，不用收 UDID**。

代价是**要过 Beta App Review**：第一个 build 约 1–2 天，之后的 build 一般自动放行，除非改动
很大。所以「内部测试用不到的那几节」（下面的年龄分级、隐私营养标签、审核备注）到这一步全部
到期，一节都跳不过去。

### 步骤

1. ASC > TestFlight > **外部测试** > 新建群组
2. 把 build 分配给这个组
3. 组设置里**启用公开链接**，设人数上限
4. 填「测试信息」，提交审核

### 提交前必须填完的

- **审核备注**（见下面那一节）——**这一条最要紧**。必须给一把能用的 API key，没有它审核员打开
  只看到「还没配置云端模型」，核心功能一步都跑不了，这是 2.1 拒绝里最常见的一种。
- **隐私政策 URL 和 Support URL**——见下面「三个 URL」，站点源文件在 `site/`。
- **年龄分级问卷**、**隐私营养标签**——各见下面那一节。
- Beta App Description、反馈邮箱、联系人信息。

### 一件先想清楚的事

**这个 app 要用户自己填 API key 才能回答问题。** 公开链接发出去，多数人装上、打开、看到
「还没配置云端模型」，然后就走了——公开测试真正测到的是那批本来就有 key 的人。想要普通用户的
反馈，得先想清楚首次进入那一屏怎么办，否则收回来的不是产品反馈，是流失。

build **90 天过期**，公开链接上的人到期就装不了，得传新的。

## 提交前在本机确认

```bash
xcodegen && xcodebuild -project Vana.xcodeproj -scheme Vana \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

`VanaTests/ComplianceTests` 盯着下面这几件里能被自动检查的部分：权限用途字符串没有再许
「数据不离开设备」、版本号两项都在、出口合规键在、隐私说明打进了包并且和代码里的备份行为对得上、
急症规则排在系统提示第一条。**这一套过不了就别提交**，它挡住的每一条都是审核会看到的。

Release 产物再手工看一眼（写权限那句 Debug 和 Release 是两份不同的话，见下）：

```bash
plutil -p "$(xcodebuild -project Vana.xcodeproj -scheme Vana -configuration Release -destination 'generic/platform=iOS' -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d"/"n}')/Info.plist"
```

要看到：`CFBundleShortVersionString`、`CFBundleVersion`、`ITSAppUsesNonExemptEncryption = false`、
三条健康/位置/相机用途字符串，以及 **`NSHealthUpdateUsageDescription` 存在、而且是「只读、
不写」那一句**（不是 Debug 里「写入模拟健康数据」那句）。

这一项**少了就传不上去**：上传时的静态检查只看二进制里有没有引用
`requestAuthorization(toShare:read:)`，不管你传的是不是空集合，少了就报
`Missing purpose string in Info.plist`。HealthKit 没有只读的授权 API，所以躲不掉——
别照着「声明一个从不申请的权限是白送审核一个问号」把它删回 Debug-only，那条在这里让位。

## 三个 URL（站点在 `site/`）

| ASC 那一栏 | 地址 | 必填？ |
| --- | --- | --- |
| Marketing URL | `https://vana.pinapia.com/` | 选填 |
| Support URL | `https://vana.pinapia.com/support/` | **必填**，审核会真的点进来 |
| Privacy Policy URL | `https://vana.pinapia.com/privacy/` | **必填** |

源文件在 [`site/`](site/)，发布前先组装：

```bash
./site/build.sh
npx wrangler@latest pages deploy build/site --project-name=vana
```

三条不要破坏的：

- **隐私说明每种语言一份**，在 [`Vana/Legal/zh-Hans.lproj/PrivacyPolicy.html`](Vana/Legal/zh-Hans.lproj/PrivacyPolicy.html) 和 [`en.lproj`](Vana/Legal/en.lproj/PrivacyPolicy.html)。
  它同时打进 app 包（设置 > 关于 > 隐私说明），`build.sh` 在发布时把它复制成
  `privacy/index.html`。**`site/` 里没有它的副本，也别加一份**——两处必须逐字相同，而审核
  核对的正是这个；留两份就是改一处忘一处。改了这个文件要重新发布一次。
- **支持页不能只有一个邮箱。** 排第一的问题是「打开之后不能用」——这个 app 要用户自己填
  API key，不在支持页里解释清楚，那会变成一星差评，而那种差评收不回来。第二是「换手机之后
  数据没了」，那是「健康数据不进备份」这条设计的代价，隐私说明里写了，支持页也要写，否则
  用户会当成 bug 报过来。
- **介绍页上的每一句话都要和 app 实际做的事对得上**，和权限用途字符串、首启那屏
  （`DataUseNotice`）、隐私说明是同一套口径。审核看到的是这几处**合起来**的样子。

## 年龄分级

问卷里勾 **「医疗/治疗信息」（Medical/Treatment Information）—— 频繁/强烈**。这个 app 的主线
就是解读健康数据和化验单。别为了拿低分级往轻里填：分级问卷答得和 app 实际做的事不符，是
Guideline 2.3（准确的元数据）。

其余项全是「无」：不含暴力、性、赌博、酒精药物（用药表是用户自己的用药记录，不是药物内容）。

## 隐私营养标签（App Privacy）

判据是**「离开设备了吗」**。Vana 自己没有服务器，但数据会发给用户配置的模型服务——那仍然算
「收集」，因为它离开了设备。不能因为「不是我们收的」就全填 Not Collected。

| 类别 | 填什么 | 说明 |
| --- | --- | --- |
| Health & Fitness | Data Used to Link to You? **否**；Used for Tracking? **否**；Purpose: App Functionality | 聚合数值随问题发给用户自选的模型服务 |
| Sensitive Info | 同上 | 化验单、体检记录识别出来的文字 |
| User Content（Photos, Other User Content） | 同上 | **照片本身不发**，只有本机识别出来的文字；仍按 User Content 填 |
| Coarse Location | 同上 | 只到城市，且只在用户授权后 |
| Contact Info / Identifiers / Usage Data / Diagnostics | **Not Collected** | 没有账号、没有埋点、没有崩溃上报 |

三项都要勾 **Not Linked to You**（没有账号，服务端没有可以关联的身份）和 **Not Used for
Tracking**（不做广告、不和第三方数据做匹配）。

## 审核备注（App Review Notes）

**「Sign-in required」不要勾。** Vana 没有账号、没有登录，勾了会让审核员去找一个不存在的
登录界面，然后以「无法完成审核」退回。**API key 不是登录凭据**，它属于下面的 Notes。

**必须给一把能用的测试 API key**，否则审核员打开 app 只看到「还没配置云端模型」，核心功能一步都
跑不了——这是 2.1 拒绝里最常见的一种。现开一把、给足额度、上架通过之后作废。

**整段用英文写。** 前两轮的审核意见和回信都是英文，审核员读的也是英文；app 现在自带英文界面，
下面每一处引号里的字**和英文界面上的字逐字相同**——审核员按着找得到，不用在中文界面里猜。

**每一步都点名那两行要显示什么**（Provider = DeepSeek、Model = DeepSeek V4 Flash）。它们现在是
默认值而且真的存下来了，正常情况下不用他动手；写出来是为了让他**一眼核对**，而不是让他去设置。
2026-08-16 被拒的那次就是 key 和 provider 对不上（拿 DeepSeek 的 key 敲了 Anthropic 的门），
而屏幕上没有一处能让他发现这件事——「Test connection」这一步就是为这个存在的，别省。

Notes 整段（健康档案那一节也并进来了，审核看的是一整段）：

```
NO ACCOUNT, NO SIGN-IN
Vana has no accounts and no login. Open it and it works. The API key below is not a
credential for Vana — it is the reviewer's key for a third-party AI service.

SETUP — PLEASE DO THIS FIRST (about 30 seconds)
Vana has no server of its own and resells nothing. Answering a question depends on a cloud
model service that the user configures with their own key. Without a key the app opens,
reads Apple Health and shows the status summary on the first screen, but it cannot answer
questions.

1. Open Vana and tap the gear icon (top right) to open Settings.
2. Under "Cloud model", tap "API key" and paste the test key at the end of this note.
3. Confirm the two rows below it read exactly:
      Provider  DeepSeek
      Model     DeepSeek V4 Flash
   Both are pre-selected and already saved on a fresh install — no change should be needed.
   The key we provide works only with DeepSeek; if Provider shows anything else, the
   provider will reject the key.
4. Tap "Test connection". This sends one real request and checks the key, the provider and
   the model together. Expect: "Connected. You're ready to ask."
5. Go back and ask a question in the input box, for example:
      "How did I sleep last night?"   or   "How active have I been lately?"

Test API key: <PASTE A KEY WITH SUFFICIENT CREDIT HERE>

APPLE HEALTH (HEALTHKIT)
Vana reads Apple Health read-only and never writes to or modifies any health record.
HealthKit is identified in the interface in four places: the welcome card on the first
screen, the Settings section titled "Apple Health (HealthKit)", the footer of the health
status detail screen (tap the summary card at the top of the first screen), and the header
of every query result panel inside a conversation.

A simulator has no Apple Health data. Please test on a physical device, or add a few steps
and sleep samples in the Health app first, then ask a question.

CLINICAL HEALTH RECORDS
The entitlement com.apple.developer.healthkit.access: health-records is used to read lab
results and vital signs the user has already connected in the Health app, so they can be
explained in conversation. Diagnoses and medication records are not read. The data is read
only when the user asks about it, is never used for advertising or data mining, is never
sold to any third party, and is never stored in iCloud (the related files are excluded from
device backups).

THE "REQUEST APPLE HEALTH (HEALTHKIT) ACCESS" BUTTON IN SETTINGS
iOS only presents its permission sheet for data types the user has not decided on yet; for
types already decided it returns without showing anything, which is expected system
behaviour and not an app bug. Because of that the button now always reports back on screen:
either the sheet appears, or an alert says nothing needed to be asked (with a shortcut to
the Health app, the only place a past decision can be changed). It never stays on
"Requesting…" — if the system does not answer within a few seconds the app says so and the
button becomes tappable again. On a fresh install the sheet appears at first launch, right
after the "Before you start" screen.

FIRST LAUNCH
The first launch shows a "Before you start" screen stating exactly what is sent to the model
service the user configures and what never leaves the device. The disclaimer and the full
privacy policy are in Settings > About Vana.

LANGUAGE
The app ships in Simplified Chinese and English and follows the device language.
```

## 健康档案（Clinical Health Records）权限

entitlement 里申请了 `com.apple.developer.healthkit.access: health-records`。这一项审核更严，备注里
要说明用途和边界：

```
用于读取用户已在「健康」App 中连接的化验结果与体征（不读取诊断和用药记录），
以便在对话中解释这些数值。数据只在用户提问时读取，不用于广告或数据挖掘，
不出售给任何第三方，也不保存到 iCloud（相关文件已排除出设备备份）。
```

**2026-08-25 又被同一条打回一次**(iPad Air 11" M3 / iPadOS 26.6,措辞变成「按了没有反应」)。
病历那条修完之后还剩两处能让这颗按钮哑掉,都在 app 这一侧:首次那一屏刚按完就去 present
系统面板(present 撞上还在进行的 dismiss,悄悄不发生),以及**一个悬着的启动请求会把设置页
那次 await 永远堵住**。现在授权请求挂在 `onDismiss` 上、这一侧的 await 自己会超时、force
不再去等启动那次,而按完必定说一句话。详见 CLAUDE.md 里「HealthKit 授权」那一节。

**这一项在不支持的设备上必须整个让开。** Health Records 按地区开放,`supportsHealthRecords()`
为 false 时**连授权都不能申请**——2026-08-21 那次被拒(iPad Air M4,「Apple Health」按钮一直转)
就是这么来的,详见 CLAUDE.md 里「HealthKit 授权」那一节。entitlement 照留,它只是允许申请。

## 出口合规

`ITSAppUsesNonExemptEncryption = false` 已经写进 Info.plist，上传时不会再被问。只用 HTTPS 和系统
自带的加密（Keychain、文件保护），属于豁免范围。**如果以后自己实现了加密算法，这一项要重填。**

## 上架地区

**这一栏随时能改，不用重新提交版本**，所以起步收窄是零成本的；反过来（先开全球、出了事再收）
代价大得多。先按 None 全清，再勾这十个：

**台湾、香港、澳门、新加坡、马来西亚、美国、加拿大、澳大利亚、新西兰、日本**

app 是纯简体中文，所以「安全」和「相关」在这里恰好是同一个答案。

排除的几个，理由分两类——**「进不去」和「不想进」**，别混为一谈：

- **中国大陆：进不去。** 上架中国区要 ICP 备案号，而备案要中国大陆的公司主体。就算有主体，
  PIPL 下把健康数据传给境外模型服务属于个人信息出境，这个架构（用户自己配境外 provider）
  在那条线上很难走通。**最扎心的是最大的简体中文市场恰恰是唯一进不去的那个。**
- **欧盟 / EEA / 英国：不想进**，三条叠一起。① 2025 年 2 月起在欧盟分发必须申报交易者身份，
  **免费 app 也要**，而姓名、地址、电话会**公开显示在商店页上**——个人开发者填的就是家庭住址，
  这一条和法规风险无关。② MDR 对「提供用于诊断或预后的信息」的软件划得比 FDA 严，Vana 明确
  不做诊断、大概率算 wellness，但那条线在欧盟更模糊，而认定错的代价是下架加调查。
  ③ AI 法案的透明度义务已经生效。真要开欧盟之前，「解读化验单」那个功能值得找个懂医疗软件的人
  问一句——它比「看步数」离那条线近得多。
- **俄罗斯 / 白俄罗斯**：数据本地化法要求俄罗斯公民的个人数据存在境内，这个架构不可能满足。

## 三处必须说同一句话

| 在哪 | 填什么 | 说的是 |
| --- | --- | --- |
| 主分类 | **健康健美**，不是「医疗」 | 这不是医疗软件 |
| 上架地区 | **排除欧盟 / EEA / 英国** | 不去那条线模糊的法域证明自己 |
| Regulated Medical Device Declaration | **No** | 没有在任何地区注册为受监管的器械 |

任何一处答得不一样就是自相矛盾，而审核看的正是这几处**合起来**的样子。

**这个 No 成立的前提只有一条**：所有对外文案永远待在「帮你看懂自己的数据」这一侧。一旦出现
「诊断」「筛查」「检测」「预防」「治疗」——描述里、截图上、副标题里、关键词里——这一栏就变成了
不实声明。

为什么「解读化验单」不推翻它：它解释的是**用户已有的、别人测出来的**数值，不产生新的诊断结论，
也不建议治疗方案。「拍张照告诉你这颗痣有没有问题」才是器械。真正靠近那条线的是欧盟 MDR 里的
「监测」（monitoring physiological conditions）——而 Vana 确实在从健康数据里找波动。这正是
排除欧盟那个决定的价值：在实际上架的那十个地区里，这个问题不会被提出来。

## 容易忘的几条

- **截图和描述里不能宣称医疗功效**。「帮你看懂自己的健康数据」可以，「诊断」「治疗」「筛查」不行。
- app 名称、副标题、关键词里同样不要出现疾病名当卖点。
- 换机之后数据不跟着走（健康数据不进备份，见隐私说明）。这一条最好在商店描述里也写一句，
  否则用户换手机之后会当成 bug 来投诉。
- 每次改动权限用途字符串、隐私说明、年龄分级问卷任意一处，都要回头看另外两处还对不对。
