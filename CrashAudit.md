# LingoClass / ClassroomTranslator 崩溃与异常审计报告

- 审计对象：`D:\Project\ClassroomTranslator`（SwiftPM，swift-tools 6.2 / swiftLanguageModes .v5 / platforms macOS .v26）
- 执行者：macos-engineer（Team 子代理），共享任务 task-1
- 日期：本会话

## 0. 方法与局限（先读）

1. 本次审计在 **Windows 主机**上完成，**无法编译、无法运行、无法做真机回归**。
   所有标记为「已修复」的改动都只做了**逐行人工复核 + 括号/字面量一致性脚本检查**，
   **必须在 Mac 上先 `swift build` / `swift test` 通过后再合入**。
2. 凡涉及系统框架行为的结论，均给出可点击来源；**查不到来源的一律标注「未验证假设」并附 Mac 复现步骤**。
3. 修复原则：最小改动、不重构、不改公开 API 签名、不升级依赖；拿不准的只写建议。

### 结论速览

| 级别 | 条目 | 状态 |
| --- | --- | --- |
| P0 | 1. 启动被作废后麦克风/引擎残留 | 已修复 |
| P0 | 2. 录音中删除课程 → 访问已失效 SwiftData 对象 | 已修复（防御式） |
| P0 | 3. 非模态 NSSavePanel 回调访问已删除 record | 已修复 |
| P0 | 4. TranslationSession 失效后被继续调用 → 系统 fatalError | 部分修复 + 待 Mac 验证 |
| P1 | 5. AudioEngineDriver start/stop 竞态 | 已修复 |
| P1 | 6. 翻译 worker 引用被旧任务清空 → 译文不落库 | 已修复 + 单测 |
| P1 | 7. 权限弹窗无超时 → 界面卡在启动中 | 建议修复（未动代码） |
| P1 | 8. CancellationError 原文直接显示给用户 | 已修复 |
| P1 | 9. 异步启动流程中读 course 属性 | 已修复 |
| P2 | 10. zh-Hans 本地化缺 27 个 key | 已修复 |
| P2 | 11. 两个 Picker 语言名本地化行为不一致 | 已修复 |
| P2 | 12. 状态栏模型提示不走本地化 | 建议修复 |
| P2 | 13. SessionDetailView 用 @State 持有 record | 建议修复 |
| P3 | 14. segments 全量 JSON 编解码（O(n²)） | 部分缓解 + 建议 |
| P3 | 15. 搜索过滤重复解码 | 已修复 |
| P3 | 16–19. save 防重入 / 启动日志同步 IO / 重复加载 CoreML / StartupStep 泄漏 | 建议修复 |

---

## P0 — 崩溃 / 数据丢失 / 隐私级问题

### P0-1 启动流程被作废后，音频引擎与麦克风继续运行

- **位置**：`ClassroomTranslator/Services/SpeechManager.swift:204-211`（修复前 :201）、`ClassroomTranslator/Services/AudioEngineDriver.swift:181-193`
- **触发条件**：
  1. 点 Start → `RecordingStartupStep` 20 秒超时 → `onTimeout` 调 `stopRecording()`（`recordingGeneration += 1`，并 fire-and-forget `driver.stop()`）；
  2. 此时底层 `driver.start(...)` 仍卡在 `await AssetInventory.status / downloadAndInstall / prepareToAnalyze / startEngine`；
  3. 慢路径返回后引擎被真正拉起来，`SpeechManager.startRecording` 走到原来的 `guard recordingGeneration == generation else { throw CancellationError() }`——**只抛错，不再 stop**。
- **用户影响**：
  - 界面已显示「录音启动超时。」并回到 idle，但**菜单栏橙色麦克风点常亮、AVAudioEngine 持续采集、SpeechAnalyzer 持续转写**，直到用户再次点 Start（下一次 `driver.start` 开头的 `await stopAsync()` 才会顺带清理）或退出应用。属于**隐私级 + 耗电**问题。
  - 极端时序下还会把 `CancellationError.localizedDescription`（`The operation could not be completed. (Swift.CancellationError error 1.)`）原样显示在状态栏（见 P1-8）。
- **证据**：
  - `AudioEngineDriver.stop()`（:207-209）是 `Task { await stopAsync() }`，而 `stopAsync()` 的快照（:214-228）只清理**当时已经写入**的 `engine/tap/continuation`。若 stop 发生在 `start()` 的异步准备阶段，快照为空 = 什么也没停，随后 `startEngine`（:260-296）才写入 engine 并 `engine.start()`。
  - `SpeechManager.stopRecording()` 中唯一的清理调用点就是 `driver.stop()`，项目内无其他调用点（已 grep 确认）。
- **状态**：**已修复**
  - `SpeechManager.swift:204-211`：generation 不匹配时先 `driver.stop()` 再抛错；
  - `AudioEngineDriver.swift:58 / 181-193 / 216`：新增 `stopEpoch`，把「写入 isRunning」与「比对是否已被更晚的 stop 作废」放进同一把锁；被作废就 `await stopAsync()` 后抛 `CancellationError`，保证**晚到的 stop 一定赢**。
- **Mac 验证步骤**：
  1. 新建课程 → 开始录音 → 立即拔掉网络（或把语音模型删掉）让 `AssetInventory` 下载卡住 >20s；
  2. 等界面出现「录音启动超时。」，看菜单栏**橙色麦克风点是否熄灭**；
  3. `lsof` 或活动监视器确认本进程不再持有音频输入；
  4. 复查 `~/Library/Logs/LingoClass-startup.log`，应出现 `sm.start-superseded` 和 `driver.start-superseded`（或 `driver.start-done` 之后紧接 `driver.engine-started` 且随后被 stop）。

### P0-2 录音过程中删除课程 → 访问已失效的 SwiftData 对象

- **位置**：
  - `ClassroomTranslator/Views/StableRecordingView.swift:75-77 / 339 / 359 / 420 / 478 / 628 / 633`（录音页所有 `activeRecord` 访问点）
  - `ClassroomTranslator/Models/HistoryStore.swift:63-76 / 139-144`
  - `ClassroomTranslator/Views/HomeView.swift:67`
- **触发条件**：录音进行中，用户在 **NavigationSplitView 左侧栏**右键课程 →「删除课程」。详情区显示的是 StableRecordingView，侧栏**仍然可交互**；`deleteCourse` 触发 `@Relationship(deleteRule: .cascade)`，把当前正在写入的 `activeRecord` 一并删掉；随后 30 秒检查点 / `shutDown` / `finishAndClose` / 翻译回填都会读该对象的属性。
- **用户影响**：SwiftData 直接 **fatal error 闪退**，且此刻的转录尚未 `finishRecord`，**整节课内容丢失**。
- **证据**：
  - SwiftData 在对象 backing data 失效后访问属性会 `Fatal error: This model instance was invalidated because its backing data could no longer be found in the store`（`SwiftData/BackingData.swift:866`）——见 [SO 79289984](https://stackoverflow.com/questions/79289984/swiftdata-backing-data-could-no-longer-be-found-in-the-store)、[SO 79158560](https://stackoverflow.com/questions/79158560/swiftdata-invalidfuturebackingdata-getvalueaforkey-when-accessing-model-p)（后者明确指向「model 在 fetch 与访问之间被删除」）。
  - `isDeleted` 检查本身不可靠，Apple 社区通行做法是不要长期持有引用：[Hacking with Swift: How to check whether a SwiftData model object has been deleted](https://www.hackingwithswift.com/quick-start/swiftdata/how-to-check-whether-a-swiftdata-model-object-has-been-deleted)（200 已验证）。
  - **本条为「未验证假设」的残留部分**：本项目里 `deleteCourse()` **是否立即**使对象失效（Core Data 通常是 save 后才 flush），无法在 Windows 上确认。
- **状态**：**已修复（防御式）**
  1. `HistoryStore.swift:63-76`：删除前先取 `courseID`（避免 delete 后读属性）、登记 `deletedCourseIDs`、同步把级联记录从 `records` 摘掉；
  2. `HistoryStore.swift:140`：`deleteRecord` 同样先取 id；
  3. `HistoryStore.swift:21-24`：新增 `isCourseAlive(_:)`（**正向**记录「确认删过」，不依赖 `courses` 列表的瞬时状态，避免误伤正常录音）；
  4. `StableRecordingView.swift:75-77` 新增 `courseExists` 闸门，覆盖 `checkpointActiveRecord / enqueueFinal / handleTranslation(.final) / finishAndClose / shutDown / ensureActiveRecord` 六处；
  5. `HomeView.swift:67`：`selection == .course(...)` 比较改用删除前保存的 id；
  6. `StableRecordingView.swift:188`：`accentCode` 在**发起权限弹窗之前**就快照成值类型，避免 `beginRecording` 的 async Task 在权限对话框停留期间读已删除的 `course.accentCode`（:219/:229/:233 三处改用本地量）。
- **Mac 验证步骤**：按 `Tests/RecordingRegression.md` 第 7 条扩展——录音中在侧栏删除该课程，应**不闪退**、回到课程列表、菜单栏麦克风点熄灭；再录音 30s 让检查点触发一次，确认无崩溃。

### P0-3 非模态 NSSavePanel 回调里访问可能已被删除的 record

- **位置**：`ClassroomTranslator/Views/ExportManager.swift:19-54 / 56-99 / 101-131`
- **触发条件**：`NSSavePanel.begin` 是**非模态**的——面板打开期间主窗口仍可操作。用户点「导出 Word / 导出文本」→ 面板挂起 → 回到列表删除这条录音 → 点「存储」→ 回调执行 `record.bilingualTranscript` / `record.course?.name` / `record.segments`。
- **用户影响**：同 P0-2 的 SwiftData fatal error；批量导出（`exportBatch`）还会遍历整个 `records`，命中概率更高。
- **状态**：**已修复** —— 三个导出入口都改成**打开面板之前同步取快照**（`exportSingle` 的 `content` @:26、`exportBatch` 的 `content` @:64-79、`exportWord` 的 `WordSnapshot` @:103-109），回调里只用值类型，不再捕获 `record`。
- **Mac 验证步骤**：导出面板打开时不点保存，先在列表里删掉那条记录，再点「存储」——应正常写出文件（内容为打开面板时的快照）或正常取消，**不得闪退**。

### P0-4 TranslationSession 失效后被继续调用 → 系统 fatalError

> 这是本报告最重要、也最需要 lead 决策的一条。

- **官方规则（已抓到原文）**：
  Apple 文档 `translationTask(source:target:action:)` Discussion 结尾写明：

  > "The system throws a **fatalError** if you use a TranslationSession instance **after the attached view disappears** or if you use it **after changing the source or target parameters**. This causes the action closure to provide a new instance."

  来源（200 已验证，正文见 Discussion 节）：
  - <https://developer.apple.com/documentation/swiftui/view/translationtask(_:action:)>
  - <https://developer.apple.com/tutorials/data/documentation/swiftui/view/translationtask(source:target:action:).json>（HTML 页 <https://developer.apple.com/documentation/swiftui/view/translationtask(source:target:action:)> 本次抓取时偶发网络失败）
  - TranslationSession 总览：<https://developer.apple.com/documentation/translation/translationsession>
- **触发条件（本项目特有、且高频）**：
  1. `TranslationSessionHost.syncConfig()` 在 `detectedRecognitionLanguage` 变化时会**换掉** `TranslationSession.Configuration.source`；
  2. Auto English 录音约 2.5s 后口音检测完成 → `SpeechManager.applyDetectedAccent` 写入 `detectedRecognitionLanguage = "en-US"` → 触发上面第 2 条 → **系统作废旧会话**；
  3. 同一时刻实时翻译每 700ms 就在发请求（`LiveTranslationCoordinator` → `TranslationManager.translate` → `sessionStorage` 里存的**旧** session）。
  4. 另一条路径：`onDisappear`（录音结束 `showRecording=false`、关闭详情 sheet）→ 视图消失 → 旧 session 作废，而 `finishAndClose` 的 10s 等待超时后 `cancelAll()` 仍可能留下一条 in-flight 的 `await session.translate`。
- **用户影响**：**进程直接 fatalError 闪退**，整节课录音丢失（`finishRecord` 可能还没执行）。
- **状态**：**部分修复 + 待 Mac 验证**
  - 已修复（`TranslationSessionProvider.swift:73-97`）：`syncConfig()` 改为**只在跨语言变化时**才重建 Configuration——同语言内的方言切换（en-GB → en-US）不再使会话失效；这是录音期间唯一会反复发生的配置变化，等于**把最高频的触发源关掉**。
  - 已修复（`TranslationSessionProvider.swift:55 / 61-66 / 86` + `TranslationManager.swift:54-62`）：新增 `detachSession()`，在 `config.invalidate()`、真正换语言、`onDisappear` 之前先把 `sessionStorage` 清空，让**新发起**的 translate 走「无会话」分支返回空串，而不是踩到已失效的会话。
  - **未解决（残留风险，需 Mac 验证）**：**已经在 `await session.translate(...)` 中途**遇到会话作废的调用，以上两招都拦不住。真正根治需要把实时翻译搬进 `translationTask` 的 action closure 内执行（Apple 推荐用法），属于结构性改动，**本次未做**。
  - **未验证假设**：`session.translate` 在会话被作废的瞬间，到底是抛可捕获的错误还是文档所说的 `fatalError`。文档只写了 "throws a fatalError"，未区分 in-flight 与 after-the-fact。
- **Mac 验证步骤（关键）**：
  1. 新建课程、老师语言选 **Auto English (detect accent)**、目标中文，开录；
  2. 对着麦克风说 5 秒纯正美式英语，让口音检测在 ~2.5s 触发切换；
  3. 期间保证悬浮字幕在刷译文（即翻译确实在跑）；
  4. 反复 10 次；观察 Console 有无 `Fatal error`/`TranslationSession`；
  5. 再测：录 1 分钟后立刻点 End，在 10 秒等待结束的瞬间观察是否崩溃。
  6. 若仍复现，**下一步建议**（需 lead 决策）：把 translate 调用移入 `.translationTask` closure，或在录音期间固定 translation source 为 `en`（不随口音变）。

---

## P1 — 卡死 / 状态错乱 / 数据没落库

### P1-5 AudioEngineDriver.start 与 stop 并发竞态（lead 疑点 b）

- **位置**：`ClassroomTranslator/Services/AudioEngineDriver.swift:49-194 / 207-216`
- **结论**：**部分成立**。竞态在代码上真实存在：`stopAsync()` 先做快照（:214-228），若快照发生在 `start()` 写入状态之前就等于空转，随后 `startEngine` 才 `engine.start()`。
  但在本项目里，**所有 stop 都来自 `SpeechManager.stopRecording()`**（已 grep 确认唯一调用点），而它之后必然伴随 P0-1 中 `startRecording` 的 generation 守卫——所以单独由 (b) 造成的泄漏，实际会被 (a) 的修复兜住。
  为避免未来出现绕过 SpeechManager 的直接 `driver.stop()`，仍加了**驱动层自愈**。
- **状态**：**已修复**
  - `AudioEngineDriver.swift:28` 新增 `stopEpoch`；`:58` 在 `start()` 的 `await stopAsync()` 之后取快照；`:216` `stopAsync()` 自增；`:181-193` 用 `stateLock.withLock { () -> Bool in ... }` **在写 `isRunning = true` 的同一临界区**里比对 epoch，被作废就 `await stopAsync()` + 抛 `CancellationError()`。
  - 这样「stop 的快照早于 start 写入」与「stop 恰好夹在 startEngine 与 isRunning 之间」两种交错都被关闭。
- **Mac 验证步骤**：回归清单第 4、6、7 条（连续 10 次暂停/恢复、启动期间拔 USB 麦克风），`~/Library/Logs/LingoClass-startup.log` 中不应出现 `driver.start-done` 之后没有任何 `driver.stop` 记录的情况。

### P1-6 翻译 worker 引用被旧任务清空 → `waitUntilIdle()` 提前返回

- **位置**：`ClassroomTranslator/Services/LiveTranslationCoordinator.swift:74-121`
- **触发条件**：`cancelAll()` 会 `worker?.cancel()` 并把 `worker = nil`，但**旧任务本身仍在运行**；旧任务退出循环后的收尾代码 `self.worker = nil` 会在**新 worker 已经启动**的情况下把新 worker 的引用清掉。
- **用户影响**：
  1. `finishAndClose` 里的 `await translationCoordinator.waitUntilIdle()`（`StableRecordingView.swift:334-338`）拿到的是 nil → **立即返回** → `finishRecord` 先落库，之后回填的译文**不再 save**，详情页译文缺失（对应回归清单第 13 条）；
  2. 同时可能有**两个 worker 并发**跑，白耗翻译配额。
- **状态**：**已修复 + 已补单测**
  - `LiveTranslationCoordinator.swift:53 / 77 / 96-97 / 114-115`：新增 `workerToken`，`cancelAll()` 与 `startWorkerIfNeeded()` 各自 +1，收尾时 `guard self.workerToken == token` 才清引用并决定是否重启。
  - 单测：`Tests/ClassroomTranslatorTests/LiveTranslationCoordinatorTests.swift` 新增 `testCancelledWorkerCannotClearItsSuccessor`。
- **Mac 验证步骤**：`swift test`；再按回归清单第 13 条（模型缺失/翻译失败时结束录音）确认原文+译文都在。

### P1-7 权限弹窗没有超时，界面可永久卡在「正在请求权限」

- **位置**：`ClassroomTranslator/Services/SpeechManager.swift:118-127 / 142-147`；`ClassroomTranslator/Views/StableRecordingView.swift:206-217`
- **触发条件**：`SFSpeechRecognizer.requestAuthorization` / `AVCaptureDevice.requestAccess` 的回调**不返回**时（临时签名/未打包 Info.plist 用途说明/用户从不点按），`withCheckedContinuation` 永远挂起。此时 `RecordingStartupStep` 还没创建，**20 秒超时兜不住**。
- **用户影响**：`sessionState.phase == .starting` 永远不解除，Start 按钮被 `startPressed` 的 guard（:179）锁死 → **界面停在"正在请求语音识别权限…"，用户只能重启**。属于权限流程死路。
- **证据**：`Localizable.strings:107-108 / 183-184` 存在四条**从未被代码引用**的"权限请求超时"文案，说明该超时曾经设计过但当前实现缺失（已 grep 确认无引用）。
- **状态**：**建议修复（本次未动代码）**
  - 原因：无法在 Windows 上验证 TCC 回调的真实时延，贸然加 20s/60s 超时可能在用户还在读弹窗时就误报；
  - **安全做法**（不会双重 resume、也不会泄漏 continuation）：把 continuation 交给一个带 `NSLock` 的 "resume-once" 小盒子，超时路径先 resume 并把 generation+1，之后真正的 TCC 回调发现已 resume 就直接丢弃；这样既能超时回到 idle，又不会"超时后又突然开始录音"。
- **Mac 验证步骤**：`tccutil reset Speech` + `tccutil reset Microphone` 后启动，故意不点弹窗 60 秒，看界面是否还能自己回到 idle。

### P1-8 `CancellationError.localizedDescription` 原样显示给用户

- **位置**：`ClassroomTranslator/Views/StableRecordingView.swift:255-258`（catch → `failStart(error.localizedDescription)`）；`SpeechManager.swift:201 / 210`
- **触发条件**：启动期间发生**音频设备配置变化**（`SpeechManager.handleConfigurationChange` :47-51 会 `stopRecording()` 并触发 `onRecordingInterrupted`，但**不递增 UI 侧 `generation`**）→ 此后 `driver.start` 返回 → 守卫抛 `CancellationError` → UI catch 里 `failStart` 的 generation 守卫**能通过** → 把原始英文错误串显示到状态栏。
- **用户影响**：中文界面显示 `The operation could not be completed. (Swift.CancellationError error 1.)`。
- **状态**：**已修复** —— 新增 `SpeechError.startSuperseded`（`SpeechManager.swift:451 / 471-472`）并配中文词条，`startRecording` 的两处抛错都改用它；`AudioEngineDriver` 抛出的 `CancellationError` 也会被 :201 转换。
- **Mac 验证步骤**：录音准备阶段插拔一次耳机，状态栏应显示中文明白文案，而不是 `Swift.CancellationError error 1`。

### P1-9 `beginRecording` 异步流程中读取 SwiftData 对象

- **位置**：`ClassroomTranslator/Views/StableRecordingView.swift:188 / 219 / 229 / 233`
- **触发条件**：权限弹窗停留期间课程被删除（见 P0-2）。
- **状态**：**已修复** —— `accentCode` 在发起弹窗前快照为局部常量；`course.name` 的读取（:187）本来就在任何 `await` 之前，保持不变。

---

## P2 — 版本兼容 / 本地化 / 行为差异

### P2-10 zh-Hans 本地化缺失 27 个 key（lead 疑点 f）

- **位置**：`ClassroomTranslator/Resources/zh-Hans.lproj/Localizable.strings`
- **结论**：**成立**。脚本比对「代码里所有会走 `LocalizedStringKey` / `String(localized:)` 的字面量」与 `.strings` 表，修复前缺 **28** 条，全部会在中文界面露英文，例如：
  `%lld recordings`、`Storage Error`、`Edit`、`Original`、`Translate Missing`、`Translating…`、`Changes saved`、`Recording title`、`Downloading models…`、`Auto English starts with UK English…`、`Save`、`OK`、`Course Name`、`Transcript`、`No Transcript`、`No transcript content.`、`Translation service is not ready. Try again.`、`Translations updated`、`Translating missing text…`、`Export as Word`、`App package is missing speech/microphone…`、`%lld segments`、`%lld languages/models`、`The recording was stopped before it finished starting.`（本次新增错误）、`Recording was interrupted…` 等。
- **状态**：**已修复** —— 追加一节「崩溃审计补充」，新增 **27** 条词条（纯追加，不改动任何既有 key/value）。
- **仍保留 7 条不补（有意为之）**：`LingoClass`（品牌名）、`1.0.0`、`Apple SpeechAnalyzer`（引擎名）、`中文`、`…pt`、`…%`（回退到 key 即可正确显示）、`Microphone input level`（`toolTip` 接收 `String`，根本不会查表，见 P2-12）。
- **Mac 验证步骤**：设置里切到中文重启，逐屏对照：首页课程行的「N 条录音」、全部录音页搜索、录音详情编辑态的 Edit/Original/Changes saved/Translating…、Storage Error 弹窗、设置页 About 区。

### P2-11 两个 Picker 对语言名的本地化行为不一致

- **位置**：`SettingsView.swift:89 / 108`、`CourseDetailView.swift:175 / 178`、`NewCourseView.swift:54`
- **结论**：**成立**。修复前 NewCourseView 的**口音** picker 用 `Text(LocalizedStringKey(accent.name))`，而它的目标语言 picker 与 Settings/CourseSettings 的四个 picker 用 `Text(language.name)`（`StringProtocol` 重载 → **verbatim，永远不查表**）。
- **状态**：**已修复** —— 五处统一为 `Text(LocalizedStringKey(...))`，与 `Localizable.key` 的查表语义一致。
  - 影响说明：语言名（如 "English (US)"）**没有**对应词条，查表失败会原样回显，视觉无变化；而 `targets` 里的 `"English"` 因为已有词条会变成「英语」——这正是"该翻译的能翻译"的期望行为。
- **Mac 验证步骤**：设置 → 老师语言 / 目标语言两个下拉，中文界面下确认显示一致、无空白项。

### P2-12 模型状态提示是纯 `String`，不走本地化

- **位置**：`SpeechManager.swift:93 / 414 / 427`、`AudioEngineDriver.swift:86 / 93`、`StableRecordingView.swift:394-397`（`statusLabel.stringValue = message`）
- **结论**：**成立**。这些消息（`Downloading en-US speech model…`、`Detected en-US (us).`、`Preparing…`）从 Service 层以普通字符串拼出来，`NSTextField.stringValue` 也不会查表，中文界面必然显示英文。
- **状态**：**建议修复（本次只修了 SettingsView 内的三处）**
  - `SettingsView.swift:194 / 201 / 203-207`：`downloadProgress` 赋值改为 `String(localized:)`，动态拼接用 `String(format:)`（避免 `String(localized:)` 插值的格式说明符在不同 Foundation 版本上是 `%lld` 还是 `%d` 的不确定性），并补了 `%lld/%lld models ready.` 词条；`:97` 的三元表达式因会把字面量推断成 `String`，也显式包了 `String(localized:)`。
  - Service 层的多条消息建议后续统一改成 `String(localized:)` + `String(format:)`；本次**未改**，因为涉及多处 `Int` 插值的 key 格式，未经真机验证不贸然动。
- **Mac 验证步骤**：设置里点「Download All English Models」，按钮下方进度文案应逐步中文化。

### P2-13 SessionDetailView 用 `@State` 长期持有 `TranscriptRecord`

- **位置**：`ClassroomTranslator/Views/SessionDetailView.swift:16 / 21`
- **结论**：**成立但触发概率低**。详情页是 sheet，`HistoryView` 的删除入口在 sheet 之下，正常流程点不到。
- **状态**：**建议修复** —— 打开详情时把 `record` 的数据快照成值类型（与 P0-3 同思路），`saveChanges` 再按 `recordID` 回写；本次**未改**，因为要动 `saveChanges/retranslate` 三个写回点，风险大于收益。

### P2-14 平台与签名

- `Package.swift` 声明 `platforms: [.macOS(.v26)]`，且用到 `SpeechAnalyzer / DictationTranscriber / AssetInventory / AnalysisContext`（macOS 26）与 `TranslationSession`（macOS 15）——**macOS 15 及以下无法运行本包**，不是崩溃而是分发面问题；`TranslationSessionCompat` 已经做了 `#available` 透传（`TranslationSessionProvider.swift:108-127`），`@available(macOS 15, *)` 守卫**没有缺口**。
- 临时签名（ad-hoc / 未公证）下 TCC 与 Translation 会话交付不稳定是项目注释里已知问题（`TranslationSessionProvider.swift:7-8`），本次未改。
- CI 日志 `Build/job-appkit-2b980ba.log`、`Build/job-e22fb32.log` 均为 macOS 15.7.9 runner 的历史构建记录，**本次审计未发现新的编译错误线索**（日志只有 checkout 阶段内容）。

---

## P3 — 性能 / 技术债

### P3-14 `TranscriptRecord.segments` 每次访问全量 JSON 编解码（lead 疑点 d）

- **位置**：`ClassroomTranslator/Models/TranscriptRecord.swift:13-26 / 36-48`
- **结论**：**成立（O(n²)），但常数很小，暂不构成实际卡顿**。
  - 录音中每出一句 final：`addSegmentIfNew` 解 1 次 + 编 1 次，`rebuildFinalizedText` 解 1 次，译文回填 `updateTranslation` 再各 1 次 → **每句 2–4 次全量编解码**。
  - 一节 60 分钟、约 800 句、转录 ~100 KB 的课，总处理量约 300 MB JSON，摊到一小时里**每句不到 1 ms**，主线程感知不到。
  - 真正的痛点是**列表/搜索**：`HistoryView/CourseDetailView` 每行 `fullTranscript` + `fullTranslation` 各解一次，几十条记录 × 每条几百 KB，搜索按键时主线程会明显抖。
- **状态**：**部分缓解（已修）+ 完整修复为建议**
  - 已修：`HistoryView.swift:64-77`、`CourseDetailView.swift:116-127` —— 过滤器改为**每条记录只解一次 JSON**，语义与原来完全一致（仍是 `joined(separator: " ")` 后 `localizedCaseInsensitiveContains`），主线程解码量直接减半。
  - **建议（未动代码，属存储模型改造）**：给 `TranscriptRecord` 增加一个 `@Attribute(.ephemeral)` 的解码缓存 + `segmentsData` 变更时失效；或把"搜索用的 haystack"作为单独列持久化。这会改 `@Model` 的 schema，必须在 Mac 上验证轻量迁移，**本次不做**。
- **Mac 验证步骤**：造 50 条、每条 200+ 段的记录，在全部录音页连续输入搜索词，用 Instruments 看 `JSONDecoder` 占比是否较改前下降。

### P3-15 搜索过滤重复解码

见 P3-14，**已修复**。

### P3-16 `HistoryStore.save()` 的防重入会**静默跳过**保存

- **位置**：`ClassroomTranslator/Models/HistoryStore.swift:146-161`
- **问题**：`guard !isSaving else { return }` 在重入时直接返回，调用方**以为存好了**。目前 `save()` 内部没有同步回调会再次进入 `save()`，实际触发概率极低。
- **状态**：**建议修复** —— 重入时不 return 而是置一个 `needsSave` 标记，外层 `defer` 里补一次；本次未改（改动会触及所有保存路径，收益低）。

### P3-17 `StartupLog.mark` 在主线程做同步文件 IO

- **位置**：`ClassroomTranslator/Services/StartupLog.swift:12-31`
- **问题**：每次 mark 都 `FileHandle(forWritingTo:)` + `seekToEnd` + `write`，且被大量调用在 `@MainActor` 的启动路径上（`sm.*` / `ui.*`）；多线程并发 mark 还可能交错写。单次几十微秒，但主线程上属于不该有的阻塞点；并发写可能让日志行错位。
- **状态**：**建议修复** —— 持有一个常驻 `FileHandle` + 串行队列，或改成 `os.Logger`。本次未改（面包屑日志的可靠性在崩溃排查里很有价值，改动需要真机确认写入行为）。

### P3-18 设置页下载模型会新建第二个 `SpeechManager`

- **位置**：`ClassroomTranslator/Views/SettingsView.swift:197`
- **问题**：`SpeechManager.init` 会 `AccentClassifier(bundle: .module)` **加载 CoreML 口音模型**；设置页为了复用权限/下载接口 new 了一个，等于**同一进程内模型加载两次**（内存 + CPU）。
- **状态**：**建议修复** —— 把"下载英语模型"提成不依赖 `SpeechManager` 的静态函数；本次未改（涉及新增 API）。

### P3-19 `RecordingStartupStep` 与视图控制器互相持有

- **位置**：`ClassroomTranslator/Services/RecordingStartupStep.swift:30-42`、`StableRecordingView.swift:220-241`
- **问题**：`operationTask` 的闭包强引用 controller，controller 又持有 `startupStep`；当底层 `driver.start` **永不返回**时（回归清单第 27 行已承认这种情况），循环引用不会解开 → **控制器泄漏**，悬浮字幕窗口等子对象也一起泄漏。
- **状态**：**建议修复** —— `beginRecording` 的两个闭包把 `self` 改成 `[weak self]`；本次**未改**，因为 `onTimeout` 里需要 `self.speechManager`，改成 weak 后的语义（超时后 self 已释放是否还要 stop）需要真机确认。

---

## lead 初查 6 个疑点的逐条结论

| # | 疑点 | 结论 | 处理 |
| --- | --- | --- | --- |
| a | `SpeechManager` 守卫只抛错不再 stop → 麦克风残留 + CancellationError 文案 | **成立（P0-1 / P1-8）** | 已修复（两处） |
| b | `AudioEngineDriver` start/stop 并发竞态 | **代码上成立，实际被 a 兜住（P1-5）** | 已加驱动层 epoch 自愈 |
| c | `translationTask` closure 返回后 session 是否失效 | **基本不成立**——Apple 官方示例本身就是 closure 内开 `Task` 后立即返回，Discussion 只把 **视图消失 / source-target 变化** 列为作废条件。**但由此暴露出更严重的 P0-4**（失效后仍被使用 = fatalError） | 已做高频触发源的规避 + detach；in-flight 残留待 Mac 验证 |
| d | `segments` 全量 JSON 编解码 O(n²) | **成立但常数小（P3-14）**；列表/搜索是真痛点 | 搜索路径已减半；完整修复需改存储模型，只写建议 |
| e | 非模态 `NSSavePanel` 回调读可能已删除的 record | **成立（P0-3）** | 已修复（三个入口全部前置快照） |
| f | zh-Hans 缺 key + 两个 Picker 行为不一致 | **成立（P2-10 / P2-11）**，实测缺 28 条 | 已补 27 条 + 五处 Picker 统一 |

## 本次新增单元测试

- `Tests/ClassroomTranslatorTests/HistoryStoreTests.swift` → `testDeletingCourseMarksItDeadAndDropsCascadedRecords`
- `Tests/ClassroomTranslatorTests/LiveTranslationCoordinatorTests.swift` → `testCancelledWorkerCannotClearItsSuccessor`

> 两者都是纯逻辑（SwiftData in-memory + @MainActor 协调器），**不依赖 AppKit / Speech / 网络**，可在 Mac 上直接 `swift test` 验证。

## Mac 上的完整验证清单

1. `swift build`、`swift test` 先全绿（本次改动全部需要这一步背书）。
2. 按 `Tests/RecordingRegression.md` 的 18 条逐条过一遍，重点第 2、4、6、7、13、15、16 条（与本次改动直接相关）。
3. 本报告 P0-1 / P0-2 / P0-3 / P0-4 四条各自的「Mac 验证步骤」。
4. 崩溃复现时保留 Console 的 `.ips`，并比对 `~/Library/Logs/LingoClass-startup.log` 里新增的 `sm.start-superseded` / `driver.start-superseded` 面包屑。
5. 中文界面逐屏对照本地化（P2-10）。

## 来源

- SwiftUI `translationTask(_:action:)`（含 fatalError 原文与官方示例）：<https://developer.apple.com/documentation/swiftui/view/translationtask(_:action:)>
- SwiftUI `translationTask(source:target:action:)` JSON 正文：<https://developer.apple.com/tutorials/data/documentation/swiftui/view/translationtask(source:target:action:).json>
- Translation `TranslationSession`：<https://developer.apple.com/documentation/translation/translationsession>
- Translation `prepareTranslation()`：<https://developer.apple.com/documentation/translation/translationsession/preparetranslation()>
- SwiftData 删除后访问属性的 fatal error（Stack Overflow，2026）：<https://stackoverflow.com/questions/79289984/swiftdata-backing-data-could-no-longer-be-found-in-the-store> 、<https://stackoverflow.com/questions/79158560/swiftdata-invalidfuturebackingdata-getvalueaforkey-when-accessing-model-p>
- SwiftData `isDeleted` 检查不可靠（Hacking with Swift）：<https://www.hackingwithswift.com/quick-start/swiftdata/how-to-check-whether-a-swiftdata-model-object-has-been-deleted>
- **未能取得来源（标注为未验证假设）**：`session.translate` 在会话被作废的**瞬间**是否也走 fatalError（Apple 只写了 "throws a fatalError"，未区分 in-flight）；`SFSpeechRecognizer.requestAuthorization` 回调是否会永久不返回（P1-7）。两者都需要 Mac 实测。
- **本会话检索限制**：`web_search` 因缺少 API Key 不可用；Stack Overflow 正文抓取返回 403，是通过 Stack Exchange API 取得答案正文的。已尽最大可能给出可点击的原始链接。
