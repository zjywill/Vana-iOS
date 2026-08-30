# 回复 App Review（2026-08-30，Submission 7740d27b-ad64-4218-a648-bfa035a29f6d）

2026-08-29 被判 5.1.1(i) + 5.1.2(i)：把个人数据发给第三方 AI 服务，但「没说清发什么、
没点名发给谁、没在发送前征得同意」。审的是 1.0 (10)，审核机型 iPad Air 11-inch (M3)。

**这次要传新 build（1.0 (11)），不只是回信。** 判词三点里我们真缺两点：
「同意并继续」原来故意写成「开始使用」（告知不做成同意书——这条设计决策被推翻了），
「发给谁」全程只有「你配置的模型服务」这个代词。build 11 修的就是这两点，改动见
git log（`ProviderConsent` + `DataUseNotice` 那两笔）。

截图在 [`Docs/review-screenshots-2026-08-30/`](review-screenshots-2026-08-30/)，
iPhone 17 Pro 模拟器、英文界面：

| 文件 | 内容 |
| --- | --- |
| `1a-before-you-start-consent.png` | 首启「Before you start」：点名 DeepSeek + 同意说明 + 「Agree and continue」 |
| `1b-send-to-deepseek-consent.png` | 首次发送前的「Send to DeepSeek?」点名确认（Agree and Send / Cancel） |

流程：先在 ASC 把 build 11 加进这次提交重新送审，回信正文如下（贴之前把中文注解删掉）。

---

## 粘进 ASC 的正文

Hello,

Thank you for the review. We have addressed Guidelines 5.1.1(i) and 5.1.2(i) directly in a new
build, 1.0 (11), which is included in this submission. What changed:

**1. Explicit permission before any data is shared with the third-party AI service**

- The first-launch notice "Before you start" (screenshot 1a) is now an explicit consent screen.
  It lists exactly what is sent, states that the recipient is a third-party model service chosen
  by the user (DeepSeek is pre-selected by default), and the user must tap "Agree and continue"
  — the button is preceded by a sentence spelling out what tapping it means. The full privacy
  policy is linked on the same screen.
- In addition, the first time the app is actually about to send data to a given service, it
  shows a named confirmation dialog — "Send to DeepSeek?" (screenshot 1b) — listing what will be
  sent (the question, the conversation, aggregated Apple Health values, memory and medication
  entries) and offering "Agree and Send" / "Cancel". Nothing is sent on Cancel. Consent is
  per-provider: switching to a different service asks again, with that service's name.
- No network call to any AI service happens before this consent — this now also covers every
  background or convenience call (the home-screen status summary, suggested questions, memory
  extraction, background digests, medication descriptions). Before consent, all of those stay
  local.

**2. The recipient is identified by name**

The app has no AI service of its own; the user connects their own account with a third-party
model service chosen from a built-in catalog and pastes their own API key. The default,
pre-selected provider is DeepSeek, and it is now named in the first-launch consent screen, in
the per-send confirmation dialog, and in the privacy policy. If the user switches providers,
the confirmation dialog names the newly selected service before anything is sent to it.

**3. Privacy policy**

The privacy policy (in-app under Settings > About, and at
https://vana.pinapia.com/privacy/ / https://vana.pinapia.com/privacy/en/) was updated in this
build. It identifies what data the app collects (none, on any server — the app has no backend
and no analytics), what is stored locally on the device, what is sent to the third-party AI
service and only with the user's explicit consent, that DeepSeek is the default provider and
the user may choose another, that these third parties handle the data under their own privacy
policies, and that the data is used solely to answer the user's question — never sold, never
used for advertising or data mining.

To reproduce in build 11: first launch shows the consent screen before anything else; after
configuring the API key from our review notes, sending the first chat message shows the
"Send to DeepSeek?" confirmation before any data leaves the device.

Thank you again — please let us know if anything else needs attention.

---

## 粘之前先确认

1. **build 11 已经归档上传、并加进这次提交**（版本号仍是 1.0，build 11）。
2. **两张 PNG 附上**（1a、1b），文件名和正文引用一致。
3. **审核备注里那把 DeepSeek key 还有额度**。
4. 正文里引号内的界面文案是逐字对着英文界面抄的（"Before you start" / "Agree and
   continue" / "Send to DeepSeek?" / "Agree and Send"），改界面文案要回来同步。
5. **网站那两份隐私说明要在送审前重新发布**（`site/build.sh`）——ASC 上那个 URL 指着线上
   版本，审核员点开看到的必须和 app 里这份一致（生效日期已改成 2026-08-30）。

## 截图是怎么拍出来的

- iPhone 17 Pro 模拟器（英文系统）。重现首启同意屏：删掉
  `com.pinapia.vana.ios` UserDefaults 里的 `hasAcceptedDataUseNotice`；重现点名确认：
  再删掉 `consentedProviderIds`。填一把假 key 就能触发弹窗（它在请求发出之前）。
- Cancel 之后字留在输入框、什么都不发；Agree and Send 之后消息发出（假 key 会 401，
  但闸已经验证过了）。

## 顺手发现的（不影响这次）

- 英文界面下报错气泡前缀「无法回复：」还是中文——和 8-27 记的那两处本地化漏网是同一类，
  修的时候一起看。
