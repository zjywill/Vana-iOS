# 回复 App Review（2026-08-27，Submission 7740d27b-ad64-4218-a648-bfa035a29f6d）

这次不是拒绝，是 Guideline 2.1 要补充信息，四个问题：①用没用第三方 AI 服务;②发了哪些敏感
数据;③发送前有没有明确同意（要截图）;④Clinical Health Records 的流程示例（要截图）。

**审的还是 1.0 (10)，不用传新 build，只要回信 + 附截图。**

截图在 [`Docs/review-screenshots-2026-08-27/`](review-screenshots-2026-08-27/)，五张，全部在
iPhone 17 Pro Max 模拟器（和审核机型一致）、英文界面上拍的：

| 文件 | 内容 | 回答哪一问 |
| --- | --- | --- |
| `3a-before-you-start-top.png` | 首启「Before you start」上半屏（「Sent to the model service you configure」清单） | 3 |
| `3b-before-you-start-bottom.png` | 同屏下半（「Never leaves this device」「Vana has no server of its own」+ 免责 + Get started） | 3 |
| `4a-health-records-sharing-intro.png` | 系统的「How Sharing Health Records Works」 | 4 |
| `4b-share-health-records-vana.png` | 系统授权页「grant "Vana" access to the requested health records」 | 4 |
| `4c-lab-results-conversation.png` | 聊天里问 "Can you check my recent lab results?" 的完整回合 | 4 |

**ASC 回复框限 4000 字符,真正要粘的是压缩版
[`app-review-reply-2026-08-27-4000.txt`](app-review-reply-2026-08-27-4000.txt)（3980 字符）**。
下面这版是完整版,留档对照用;中文注解只给自己看，不要一起粘过去。
ASC 的回复框支持附件，把五张 PNG 一起附上，正文里按文件名引用。

---

## 粘进 ASC 的正文

Hello,

Thank you for the questions. Answers below; the referenced screenshots are attached.

**1. Does the app use a third-party AI service?**

Yes. Vana has no server and no AI service of its own. The user connects their own account with
a third-party model service: in Settings they pick a provider from a built-in catalog (e.g.
DeepSeek — the one our review notes are set up for) and paste their own API key. The app then
talks directly from the device to that provider's API. Nothing can be sent anywhere until the
user has done this — on a fresh install the app opens, reads Apple Health locally and shows the
status summary, but it cannot answer questions and contacts no AI service at all.

**2. Which sensitive personal data is sent to the third-party AI service?**

Vana itself collects nothing: no accounts, no backend, no analytics, and the developer never
sees any user data — it never passes through any machine of ours. When, and only when, the user
asks a question in chat, the following is sent to the model service the user configured:

- The text the user types, and the back-and-forth of that conversation.
- Aggregated values read from Apple Health under the user's HealthKit authorization — daily or
  nightly aggregates such as "6.2 h of sleep on Aug 6". Raw samples are never sent.
- Clinical Health Records the user asks about — lab results and vital signs only (display name,
  date, value). Diagnoses and medication records are never read at all.
- Text recognized on-device from photos of lab reports, medical reports and medicine boxes. The
  photo itself is not sent by default; an original image is only sent after a per-photo
  confirmation by the user.
- The city name (never coordinates), if the user granted location access.
- Entries from the in-app long-term memory and medication list, unless the user turns those off.

Never sent: photo and file originals (by default), voice recordings (speech is recognized
on-device and never saved), GPS coordinates, the API key, or any identifier. This matches the
App Privacy declaration for this app (Health & Fitness, Sensitive Info, User Content, Coarse
Location — all "not linked to identity, not used for tracking").

**3. Does the app obtain the user's explicit consent before sending data?**

Yes, in three layers, all of which come before any chat interaction is possible:

1. The very first launch shows a full-screen notice, "Before you start" (screenshots 3a, 3b),
   shown before any chat and before the HealthKit permission sheet. It spells out exactly what
   is sent to the model service the user configures, what never leaves the device, and that
   Vana has no server of its own. The user must tap "Get started" to proceed, and the full
   privacy policy is linked on the same screen. The same disclosure remains permanently
   available in Settings > About Vana.
2. No data can flow to any AI service until the user deliberately connects one: choosing the
   provider and pasting their own API key in Settings is itself the opt-in. Without that step
   the app cannot send anything.
3. Each data source additionally has its own system-level consent: Apple Health data requires
   the iOS HealthKit permission sheet, location requires the iOS location permission, and
   sending a photo original requires a per-photo confirmation in the composer.

**4. Clinical Health Records flow (screenshots 4a, 4b, 4c)**

The health-records entitlement is used to read lab results and vital signs the user has already
connected in the Health app, so they can be explained in conversation. Diagnoses and medication
records are never read. The flow on the attached screenshots:

1. The user asks about lab results in chat — e.g. "Can you check my recent lab results?"
   (screenshot 4c). Clinical records are read only at that moment, never in the background.
2. On the first such question, iOS presents its own Health Records authorization flow: "How
   Sharing Health Records Works" (screenshot 4a), then "Share Health Records — add your
   provider accounts to grant 'Vana' access to the requested health records" (screenshot 4b).
   Granting access, and which provider accounts are connected, stays entirely inside this
   system UI.
3. Vana then reads the granted records (lab results and vital signs: display name, date, value)
   and explains them in the conversation. If no provider account is connected — as on the
   review device in screenshot 4c — the app says so honestly and offers the alternatives:
   connect an institution in the Health app, or photograph a paper lab report, which is
   recognized on-device so that only the recognized text is sent. Every AI answer in the app
   carries the label "Written by AI and may be wrong. Not a diagnosis or medication advice —
   check key numbers against the original records."

Clinical data is read only when the user asks about it, is never used for advertising or data
mining, is never sold to any third party, and is never stored in iCloud — the app's local files
are excluded from device backups.

Privacy policy: https://vana.pinapia.com/privacy/ (Simplified Chinese) and
https://vana.pinapia.com/privacy/en/ (English).

---

## 粘之前先确认

1. **五张 PNG 都附上了**，文件名和正文里的引用一致（3a、3b、4a、4b、4c）。
2. **审核备注里那把 DeepSeek key 还有额度**——回信可能引来一次复测。
3. 正文里引号内的界面文案是逐字对着英文界面抄的（"Before you start" / "Get started" /
   "Written by AI and may be wrong…"），改界面文案要回来同步。

## 截图是怎么拍出来的（下次要重拍时照抄）

- 设备:iPhone 17 Pro Max 模拟器（iOS 26.5），系统语言英文。**地区必须改成 US**
  （`defaults write -g AppleLocale en_US` 后重启模拟器）:Health Records 按地区开放，
  CN 地区下 `supportsHealthRecords` 是 false,整条病历路径不会出现。
- 首启告知屏:删掉 app 容器 `Library/Preferences/com.pinapia.vana.ios.plist` 里的
  `hasAcceptedDataUseNotice` 键再启动即可重现，不必卸载重装（卸载会把钥匙串里的
  API key 一起丢掉，聊天那张就拍不成了）。
- 病历授权那两张（4a/4b）**一台设备只弹一次**:clinical 类型一旦决定过，iOS 不再弹。
  要重拍就得换一台模拟器（或 erase 后重来，那样 key 也没了）。
- 模拟器「健康」App 里搜到的「Sample Family Medicine, LLC」是真实机构目录，门户登录
  报错，没有测试账号，连不上——所以 4c 里走的是「没有连接机构」这条诚实路径,它本来
  也是审核设备上会看到的那条。

## 顺手发现的两个毛病（不影响这次回信）

- 英文界面下,健康工具跑完的摘要胶囊显示中文「查询了最近 30 天化验与体检记录」——
  界面字符串漏了本地化,已登记成后台任务。
- 英文界面下,首屏那段状态摘要仍是中文（模型写的那段没跟着 `replyLanguage` 走,或者
  喂进去的结论行是中文的）。和上一条同根,修的时候一起看。
