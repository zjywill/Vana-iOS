# 回复 App Review（2026-08-25，Submission 7740d27b-ad64-4218-a648-bfa035a29f6d）

同一条第三次：Guideline 2.1(a)，iPad Air 11-inch (M3) / iPadOS 26.6，「there was no response
after tapping on the "Request Apple Health (HealthKit) access" in Settings」。

**要点：被审的是 build 8，它只带了上一轮那条修复（病历类型）。** 第二次修复（不等面板 +
按完必有回话）在 build 9 里，审核员没见过；build 10 又补上了第三处。回信里必须把这件事说
清楚——不说的话，读起来就像「同一个 bug 修了两次都没修好」。

**下面英文部分是直接粘进 App Store Connect 的正文**，中文注解只给自己看，不要一起粘过去。

---

## 粘进 ASC 的正文

Hello,

Fixed in build 1.0 (10). Thank you for the device details — we reproduced it and found two more
causes, both on our side.

**First, one correction that matters for reading the rest.** The build you tested, 1.0 (8),
contained only the first of our fixes. It addressed the clinical (Health Records) precondition
we described last time. We have since found two further causes of the same symptom, and both of
them are in our own code, not in HealthKit.

**What was actually wrong.**

1. On a fresh install, the permission sheet was requested from within the dismissal of our
   "Before you start" screen. Presenting a system sheet while another presentation is still
   animating away silently does not happen — and the HealthKit call it belongs to then never
   returns. A first launch is exactly the path a reviewer takes.
2. Our code awaited the result of the permission sheet before it would re-enable the button. That
   result is of no use to us — iOS deliberately never tells an app that read access was denied —
   so we were trading nothing for a button that could stay disabled forever.
3. When iOS has nothing left to ask about, it correctly presents nothing. We showed that outcome
   as an alert, but the alert was attached to the button's own row in the settings list. List
   rows are rebuilt as the section changes, and an alert attached to one can be dropped instead
   of presented. What remained on screen was a single line of grey text — which reads exactly as
   "nothing happened".

**What build 10 does.**

- The authorization request is now made after the intro screen has fully finished dismissing, so
  the system sheet always has a clear presentation to come up on.
- We no longer await the sheet at all. We hand it to the system and return immediately. Every
  remaining HealthKit call the app makes now carries its own deadline, so no part of the app can
  wait indefinitely on a system call that never answers.
- The button always reports back on screen, and when nothing visible happened it now does so in
  an alert that cannot be dropped, with a shortcut to the Health app — the only place a past
  decision can be changed.

**How to verify on your device.** We tested this on an iPad Air 11-inch (M3), fresh install,
English:

1. First launch shows "Before you start". Tap "Get started" — the Health permission sheet
   appears. Choose either option.
2. Open Settings (gear, top right), scroll to "Apple Health (HealthKit)", tap "Request Apple
   Health (HealthKit) access" — the permission sheet appears again for the data types not yet
   decided (blood pressure, blood oxygen, respiratory rate, body temperature).
3. Tap the same button once more. Now that every type has been decided, an alert appears: "All of
   these data types have already been asked about. To turn them on or off, use the Health app.",
   with an "Open the Health app" button.

Each of the three taps produces a visible response. The row never stays on "Requesting…".

**Setup (the test key is in App Review Information > Notes):**

1. Settings (gear, top right) > "Cloud model" > "API key" > paste the key.
2. The rows below should already read Provider: DeepSeek, Model: DeepSeek V4 Flash. Our key works
   only with DeepSeek.
3. Tap "Test connection" — it validates key, provider and model together. Expect "Connected.
   You're ready to ask."
4. Ask a question, e.g. "How did I sleep last night?". Apple Health on a new device has no data,
   so add a few samples in the Health app first.

Privacy policy: https://vana.pinapia.com/privacy/ (Simplified Chinese) and
https://vana.pinapia.com/privacy/en/ (English).

---

## 粘之前先确认

1. **build 号**。正文写的是 1.0 (10)，和 `project.yml` 里的 `CURRENT_PROJECT_VERSION` 一致。
   ASC 里要是已经有一个 10（比如 9 之后又传过一次），继续加一位，并同步改工程和正文；
   ASC 拒收同号的 build。
2. **审核备注里那把 DeepSeek key 还有额度**。传之前自己用「测试连接」验一次——2026-08-16
   那次就是这条路上出的事。
3. **正文里那三步是逐字对着英文界面写的**，改任何一句界面文案都要回来同步这里。
4. **本机跑一遍**：`(cd AgentRuntime && swift test)` 和 iPhone 17 上那套 `xcodebuild test`
   （394 个），再归档。

## 这次改了什么（自己看的）

- `SettingsView`：那句「已经问过了」的 alert 从按钮所在的 `Form` 行挪到 `Form` 上。
  它弹出来的同一个事务里同一个 section 正好插入一行状态小字，而 `Form` 的行是懒的、会被
  重建——撞上那次重建 alert 就悄悄不 present，屏幕上只剩一行灰色小字，正好是「按了没反应」
  的形状。**这是 build 10 相对 build 9 唯一的行为改动。**
- build 9 里已经有、审核员没见过的两条：授权请求挂到
  `ChatView.fullScreenCover(onDismiss:)`；`HealthStore.requestAuthorizationIfNeeded` 不再
  await 面板，每处 await 各带一个 `withDeadline`。
- `project.yml`：AIKit 从本地包 `../aikitswift` 换成远端并**钉在 commit** 上
  （`608944b`）。旁边不再需要 checkout，`Package.resolved` 跟着工程进仓库——一个过审的
  build 必须说得出自己里面是哪一版依赖。
- 顺带带进上游两条 Google 修复（`google.json` 补上 `api`），Google 现在真的出现在 provider
  列表里；`CloudSetupTests.exposesGoogleGeminiProvider` 从此是真的（之前一直在挂）。

## 验证记录

iPad Air 11-inch (M3) 模拟器、全新安装、英文系统，走了一遍审核员的路径：

| 动作 | 结果 |
| --- | --- |
| 首屏告知 → Get started | HealthKit 面板弹出 |
| Don't Allow → 进设置 → 点那颗按钮 | 面板再次弹出（血压那几类） |
| 再点一次 | alert：「All of these data types have already been asked about…」+「Open the Health app」 |

三次点击三次都有可见回应，没有一次停在「Requesting…」。
