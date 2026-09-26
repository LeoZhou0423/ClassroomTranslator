# LingoClass（ClassroomTranslator）使用体验 / 视觉传达 / 用户心理学审计报告

- 审计人：lead（静态代码审阅，逐文件通读）
- 范围：D:\Project\ClassroomTranslator 全部 Swift 源码 + zh-Hans 本地化 + 现有测试与回归清单
- 分工：本报告聚焦**体验动线、视觉传达、用户心理学、中文本地化**；崩溃/并发类深挖与代码修复由 macos-engineer 负责，产出见 `CrashAudit.md`。两边重叠处本文只做交叉引用（STAB 编号）。
- 环境限制：Windows 主机，无法编译运行 macOS 程序；所有结论基于源码推理，标注 ⚠️ 的项需在 Mac 上验证。

---

## 一、体验动线问题（UX）

### UX-01（P0）录音中点侧栏 = 静默杀死录音，没有任何告知 ✅已修
- 位置：[HomeView.swift:18](ClassroomTranslator/Views/HomeView.swift#L18)（List selection 无锁定）→ detail 切换使 CourseDetailView 卸载 → [StableRecordingView.swift:27](ClassroomTranslator/Views/StableRecordingView.swift#L27) dismantle → [shutDown()](ClassroomTranslator/Views/StableRecordingView.swift#L336)
- 现象：录音进行中，用户点侧栏"课程 / 全部录音 / 设置 / 其他课程"任意一项，detail 视图被替换，录音界面被 dismantle，shutDown 直接结束并保存。**没有确认框、没有"录音已结束"提示、悬浮字幕窗同步消失**。
- 影响：老师正讲到一半，学生以为还在录，继续记了 10 分钟 → 这 10 分钟永久丢失；且再点回课程页是"全新录音"，无法续上。这是"信任崩塌"级问题：录音类工具最不能出现的就是"我以为在录"。
- 建议：录音中（starting/recording/paused/interrupted）锁定侧栏选择（List selection binding 拦截 + 视觉禁用），只允许走界面上的"结束/返回"按钮并弹确认；或切换时弹"结束并保存本次录音？"。

### UX-02（P1）"End Session" 无确认，"Back" 反而有确认 —— 语义倒挂 ✅已修
- 位置：[StableRecordingView.swift:277-301](ClassroomTranslator/Views/StableRecordingView.swift#L277-L301)
- 现象：点红色语义的"End Session"（endPressed）直接 finishAndClose；点看似无害的"Back"（closePressed）却弹"End and save this recording?"。
- 影响：用户对哪个按钮安全没有稳定预期；顺手点"结束录制"（最显眼的破坏性操作）零确认，点"返回"却要确认。桌面端惯例是"停止"可直接停（因为可恢复），"关闭窗口"才需确认；本项目恰好相反。
- 建议：统一为——任何会终止当前录音的路径都走同一个确认 sheet（"结束并保存 / 取消"）；Back 与 End Session 行为一致。

### UX-03（P1）权限被拒后是"死路"，且已经写好的引导文案没有被使用 ✅已修
- 位置：[StableRecordingView.swift:196-207](ClassroomTranslator/Views/StableRecordingView.swift#L196-L207) 只把短句写进 statusLabel；而 [Localizable.strings:109-110](ClassroomTranslator/Resources/zh-Hans.lproj/Localizable.strings#L109-L110) 里躺着完整的"请在系统设置→隐私与安全性→麦克风中允许后重试"长引导（**死文案，代码从未引用**）。
- 现象：拒绝授权后只有一行灰色小字（还不是红色），没有"打开系统设置"按钮；`x-apple.systempreferences:` 深链在 SettingsView 里有现成写法（[SettingsView.swift:129](ClassroomTranslator/Views/SettingsView.swift#L129)）却没用在权限失败处。
- 影响：权限是主流程第一道闸，被拒后用户处于"不知道去哪改"的无助状态，心理学上直接导致放弃。
- 建议：failStart 权限类错误改用 NSAlert/SwiftUI alert，主按钮"打开系统设置"（Privacy_Microphone / Privacy_SpeechRecognition 深链），并启用已有的长文案 key。

### UX-04（P1）结束录音时界面可能"冻结"最长约 10 秒，无进度、无法取消 ✅已修（「跳过剩余翻译」按钮 ⏸defer）
- 位置：[StableRecordingView.swift:309-334](ClassroomTranslator/Views/StableRecordingView.swift#L309-L334)（10s 等翻译 + 450ms 关闭）；[renderState()](ClassroomTranslator/Views/StableRecordingView.swift#L565-L573) 在 .ended 下把 Start/Pause/End/**Back/Overlay 全部 disable**。
- 现象：点"结束录制"后 statusLabel 显示"正在完成翻译并保存…"，期间所有按钮禁用、无进度条、无取消途径；若翻译卡死要吃满 10s 超时。
- 影响：课间只有几分钟的学生盯着灰掉的按钮，会怀疑"卡死了/崩了"而强制退出——恰好会造成数据丢失。
- 建议：结束阶段保留 Back 可点（走兜底保存），把"最后 N 句翻译中 (x/y)"显示出来；翻译等待超过 ~1.5s 时允许"跳过剩余翻译，立即保存"。

### UX-05（P1）首次开录才下载语音模型；固定口音用户连预下载入口都没有 ✅已修（预下载入口放开到英语口音；「开录前先提示需下载体积」⏸defer）
- 位置：模型下载只发生在开录时 [AudioEngineDriver.swift:81-102](ClassroomTranslator/Services/AudioEngineDriver.swift#L81-L102)；设置里的"Download All English Models"按钮仅当 `recognitionLanguage == "auto"` 才显示（[SettingsView.swift:93-102](ClassroomTranslator/Views/SettingsView.swift#L93-L102)）。
- 现象：选了"English (US)"等固定口音的用户，第一次点 Start 面对的是"Downloading en-US speech model… (x%)"，且进度只在那行会被截断（byTruncatingTail）的灰色小字里。
- 影响：核心动作（点开始）与最长时间等待（模型下载）耦合，首次体验=点了没反应；进度文案还可能被截断。
- 建议：新建课程/开录前就检查 AssetInventory 状态并给出"预计需下载 XX MB"提示；预下载入口对所有语言开放（不限 auto）。

### UX-06（P2）打开历史详情会"自动"批量翻译，还可能开门先看一个失败提示 ✅已修
- 位置：[SessionDetailView.swift:104-108](ClassroomTranslator/Views/SessionDetailView.swift#L104-L108) `.task` → translateMissingSegments
- 现象：只要记录里有缺译段，打开即自动逐段翻译（无进度计数、无法取消）；会话未就绪时直接显示"Translation service is not ready. Try again."。
- 影响：用户只是想"看一眼"，却触发后台长任务；首屏先看到红/失败语义文案，负面首因效应；多段顺序翻译时 footer 长期停在"Translating missing text…"。
- 建议：改为显式按钮 + 进度"正在翻译 3/12…"；打开详情只读不自动写库（自动保存还发生在 save() 里，悄悄改数据）。

### UX-07（P2）"取消导出"被判成错误并弹 alert ✅已修
- 位置：[ExportManager.swift:25-30](ClassroomTranslator/Views/ExportManager.swift#L25-L30)、[104-108](ClassroomTranslator/Views/ExportManager.swift#L104-L108) 取消 → `failure(ExportError.cancelled)` → [HistoryView.swift:35-39](ClassroomTranslator/Views/HistoryView.swift#L35-L39) / [CourseDetailView.swift:46-51](ClassroomTranslator/Views/CourseDetailView.swift#L46-L51) 弹出标题为"Export"的 alert 显示"Export cancelled."。
- 影响：用户主动取消却收到系统"报错"，心理学上被指责感；也是把控制流错误当业务错误的经典反模式。
- 建议：取消（.cancelled）静默忽略，仅失败才 alert；SessionDetail 的 footer 反馈同样区分成功/取消/失败三态（见 VIS-10）。

### UX-08（P2）保存结果只闪现 450ms，之后无处可查"这次到底存了没有" ✅已修（停留 900ms + 「已保存 · N 段」；侧栏计数即时刷新 ⏸defer）
- 位置：[StableRecordingView.swift:330-332](ClassroomTranslator/Views/StableRecordingView.swift#L330-L332) "Saved" → sleep 450ms → onClose()
- 建议：结束成功页停留一拍（显示时长/段落数/保存位置），或 toast + 侧栏计数即时刷新的强反馈。

### UX-09（P2）切换语言必须重启，但没有给用户"重启"的下一步 ⏸defer：理由：改法有两条互斥路线（进程内 relaunch 按钮 vs. 摆脱进程级 AppleLanguages 的新方案），属产品决策；在无 Mac 构建的环境下改动 App 启动 / 生命周期风险过高。
- 位置：[SettingsView.swift:48-55](ClassroomTranslator/Views/SettingsView.swift#L48-L55) 仅一行 caption。
- 另注：onChange 里直接改 AppleLanguages（[ClassroomTranslatorApp.swift:12-19](ClassroomTranslator/ClassroomTranslatorApp.swift#L12-L19)），当次会话部分新出现的字符串会立即变中文、旧的还是英文 → **混合语言直到重启**。
- 建议：提供"重启以生效"按钮（relaunch），或改用不依赖进程级 AppleLanguages 的方案。

### UX-10（P2）首页"有课程"时的概览态浪费整个 detail 区 ⏸defer：理由：需重设计首页信息架构（最近录音 / 一键续上次课程），是新功能而非缺陷修复，且必须与 UX-01 的侧栏锁定一起做真机动线验证。
- 位置：[HomeView.swift:104-115](ClassroomTranslator/Views/HomeView.swift#L104-L115)：一个大图标 + "Select a course from the sidebar"。
- 建议：改为"最近录音/一键开始上次课程"，让回访用户第一眼直达上次场景（减少一次导航）。

### UX-11（P3）列表/搜索的全量 JSON 解码开销 ⏸defer：理由：改动落在 TranscriptRecord 的 SwiftData @Model 访问器（与 STAB-04 同源），属高风险区；性能收益必须在 Mac 上用大量记录实测，Windows 侧只能推测。
- 位置：[HistoryView.swift:65-73](ClassroomTranslator/Views/HistoryView.swift#L65-L73)、[CourseDetailView.swift:116-124](ClassroomTranslator/Views/CourseDetailView.swift#L116-L124) 每行 `record.fullTranscript`；[TranscriptRecord.swift:13-26](ClassroomTranslator/Models/TranscriptRecord.swift#L13-L26) 每次 get 全量解码。
- 影响：记录一多（长学期），每敲一个搜索键 = 每条记录解码两次 → 输入卡顿，被感知为"系统卡"。STAB-04 关联。

---

## 二、视觉传达问题（VIS）

### VIS-01（P0）一行灰色状态标签承载全部系统状态，错误不红、长文被截断 ✅已修
- 位置：[StableRecordingView.swift:125-126](ClassroomTranslator/Views/StableRecordingView.swift#L125-L126) `textColor = .secondaryLabelColor`、`lineBreakMode = .byTruncatingTail`；写入点散布于 178-486 行（权限、下载、识别、翻译、超时、保存共 15+ 种状态）。
- 问题：状态与错误同一颜色同一字号同一行；错误信息（如权限拒绝）视觉权重比"录音中"还低；长消息尾部截断。
- 建议：状态分级——普通 secondary、警告 orange、错误 red + icon（symbolName）；错误类允许换行或改用 alert；同一时刻只允许一个"主动状态"。

### VIS-02（P0）主转录区里原文和译文**没有任何视觉区分** ✅已修
- 位置：[StableRecordingView.swift:558-563](ClassroomTranslator/Views/StableRecordingView.swift#L558-L563) rebuildFinalizedText 只是 `original + "\n" + translation` 拼接；[refreshTranscript()](ClassroomTranslator/Views/StableRecordingView.swift#L532-L556) 用**无任何属性**的 NSAttributedString 写入 textStorage。
- 问题 1：两行文字一模一样，用户分不清哪句是译文（翻译工具的核心价值不可辨认）。
- 问题 2（⚠️需 Mac 验证）：向 NSTextView 的 textStorage 写入无属性字符串时，字体可能不按 `transcriptView.font = 15pt` 渲染（typingAttributes 只对首帧 "Ready to Listen" 生效），导致首行 15pt、正文回落默认 12pt 的突变。
- 建议：写入时显式给 attributes（原文 label 色 13pt / 译文强调色 15pt，或译文加前缀图标），一处封装两处共用。

### VIS-03（P1）详情页译文比原文**更小**，主次颠倒；且仅靠颜色区分 ✅已修
- 位置：[SessionDetailView.swift:69-70](ClassroomTranslator/Views/SessionDetailView.swift#L69-L70)：原文 14pt medium 黑色、译文 13pt 蓝色。
- 问题：目标用户是"听不懂需要看译文"的人，译文才是主内容，却视觉降级；蓝 vs 黑对红绿色盲/低对比环境不友好（颜色是唯一区分手段，WCAG 1.4.1 反模式）。
- 建议：译文 ≥ 原文字号且加粗/主文本色，原文降为 caption 色；用"原文/译文"小标签或图标前缀替代纯颜色编码。

### VIS-04（P1）悬浮字幕窗的可读性下限失守 ✅已修（字号下限 12pt / 1pt 描边 / #FFD866；透明度下限按产品决定保持 0.3 不变）
- 位置：[SubtitleOverlay.swift:111-118](ClassroomTranslator/Views/SubtitleOverlay.swift#L111-L118)（原文黄、`fontSize - 4`）+ [SubtitleDisplayConfiguration.swift:10-19](ClassroomTranslator/Models/SubtitleDisplayConfiguration.swift#L10-L19)（字号下限 12、透明度下限 0.3）。
- 问题：
  - 字号拉到 12 时原文 = **8pt**（后排同学完全看不见）；
  - 不透明度可低到 30%，白色文字叠在亮色投影/白底 PPT 上不可读；
  - 纯色无描边/投影，PPT 花哨背景上白字糊掉；
  - 深底 + 纯黄（#FFCC00）高饱和对比有"振动感"，长时间注视易疲劳；
  - 没有任何图例说明"黄=原文、白=译文"，颜色语义靠猜。
- 建议：原文下限 ≥ 12pt；透明度下限 0.6 或为浅色背景提供"深色文字+浅色底"反相模式；文字加 1pt 描边或阴影；首行加"原文/译文"前缀标签；黄色改用更柔和的 #FFD866 或直接用 secondary white。

### VIS-05（P1）悬浮窗**拦截鼠标**，盖住幻灯片点击区 ✅已修（点击穿透开关默认关 + 初始位置改为屏幕底部居中）
- 位置：[SubtitleOverlay.swift:12-27](ClassroomTranslator/Views/SubtitleOverlay.swift#L12-L27)：NSPanel 未设 `ignoresMouseEvents`，默认 600×200 整个区域吞掉点击（isOpaque=false 只影响绘制，不影响 hit-test）；`window.center()` 初始落在屏幕正中。
- 问题：老师/学生用点击翻页时，点在悬浮窗上 → 幻灯片没反应，用户以为"卡了"。
- 建议：默认 `ignoresMouseEvents = true`，提供边角锚定（不占屏幕中央）+ 按住 Option 拖动/独立小把手来移动；或仅标题栏可拖。

### VIS-06（P1）其他窗口一进全屏，字幕窗就藏起来，且**整段全屏期间不再恢复** ✅已修
- 位置：[SubtitleOverlay.swift:74-86](ClassroomTranslator/Views/SubtitleOverlay.swift#L74-L86) willEnterFullScreen → hideWindow；didExitFullScreen → 才恢复。
- 问题：投影演示必然全屏 → 恰恰在最需要字幕的时候（全屏放映）字幕消失，退出全屏才回来。悬浮窗明明声明了 `fullScreenAuxiliary`（本可显示在全屏之上）。
- 建议：确认当年"进场即隐藏"要规避的具体问题；优先改为全屏期间保留显示（它本来就有 fullScreenAuxiliary），至少给用户"全屏时也显示"的开关。

### VIS-07（P2）录音控制条无层级 ✅已修（电平条 mic 图标前缀）/ ⏸defer：Start/Pause/End 的强调样式与 End 的 destructive 红 —— 理由：NSButton bezel 的强调 / 着色必须实机渲染确认，无构建时改色只能靠猜，风险是「改了更难看」。
- 位置：[StableRecordingView.swift:146-150](ClassroomTranslator/Views/StableRecordingView.swift#L146-L150)：状态、电平条、计时、悬浮窗开关、Start、Pause、End 全部同一 bezel 样式横排；End 不用 destructive 红色；96pt 电平条仅 tooltip 解释。
- 建议：Start/Pause 用强调样式（录音中 Pause 变主按钮）、End 用 destructive 色；电平条加 mic 图标前缀（无需 tooltip 即自明）。

### VIS-08（P2）详情页 footer 的所有反馈**恒为绿色**（含错误文案） ✅已修
- 位置：[SessionDetailView.swift:83-84](ClassroomTranslator/Views/SessionDetailView.swift#L83-L84)：`foregroundColor(feedback.isEmpty ? .secondary : .green)`——"Export cancelled."、I/O 错误、"Translation service is not ready." 全绿。
- 建议：feedback 增加语义枚举（info/success/error）驱动颜色与图标。

### VIS-09（P2）计时格式不一致 ✅已修
- 位置：录音页 `%02d:%02d`（[StableRecordingView.swift:590-593](ClassroomTranslator/Views/StableRecordingView.swift#L590-L593)）超过 1 小时显示"75:33"；导出/历史用 h:mm:ss（[ExportManager.swift:245-255](ClassroomTranslator/Views/ExportManager.swift#L245-L255)）。
- 建议：统一 h:mm:ss（超 1 小时的课是常态）。

### VIS-10（P3）其他 ✅已修（删除按钮 accessibilityLabel）/ ⏸defer：About 版本号与「Apple SFSpeechRecognizer」过期文案 —— 理由：属 4.3 死条目对账，需读取打包 Info.plist 的版本字段一并处理。
- 工具栏删除按钮只有图标无 accessibilityLabel（[CourseDetailView.swift:109-113](ClassroomTranslator/Views/CourseDetailView.swift#L109-L113)），VoiceOver 读不出。
- About 里版本号硬编码 "1.0.0"、"Speech Engine: Apple SpeechAnalyzer" 与 .strings 中过期的 "Apple SFSpeechRecognizer" 并存（[SettingsView.swift:153-174](ClassroomTranslator/Views/SettingsView.swift#L153-L174)）。

---

## 三、用户心理学问题（PSY）

### PSY-01（P0）"我以为在录"——见 UX-01。录音工具的头号信任红线。 ✅已修（随 UX-01）
### PSY-02（P1）技术性错误原文直接砸给用户 ✅已修
- 位置：[StableRecordingView.swift:245-248](ClassroomTranslator/Views/StableRecordingView.swift#L245-L248) `failStart(error.localizedDescription)`——CancellationError 等会显示 "The operation couldn't be completed. (Swift.CancellationError error 1.)"。
- 关联 STAB-01：启动超时竞态下用户就可能看到这条。
- 建议：所有 error.localizedDescription 过一层"人话 + 可执行下一步"映射表。

### PSY-03（P1）翻译不可用时反复示警，却不给修复入口 ⏸defer：理由：需要在状态行内嵌可点按钮 + 「首次失败只提示一次」的持久化去重，且翻译不可用的触发点在 TranslationManager（属上一轮 16 个已审文件），本轮不扩大改动面。
- 位置：[StableRecordingView.swift:451-454](ClassroomTranslator/Views/StableRecordingView.swift#L451-L454) 状态行反复出现"翻译暂不可用"；下载入口埋在 设置→翻译→两层按钮。
- 建议：状态行附"去下载模型"小按钮，或首次失败弹一次带深链的引导，之后降级不再重复吵。

### PSY-04（P1）破坏性确认的三套标准 ✅已修（统一确认矩阵 + 取消不再报错，见 UX-02 / UX-07）
| 操作 | 是否确认 | 评价 |
|---|---|---|
| 删除课程/录音 | ✅ confirmationDialog | 合理 |
| End Session | ❌ 直接执行 | 危险（UX-02） |
| Back（录音中） | ✅ | 与 End 语义倒挂 |
| 取消导出 | ❹ 弹"错误"alert | 把用户行为当错误（UX-07） |
- 建议：统一矩阵——"不可逆删除"与"终止进行中的采集"都确认；"取消"永远不弹错。

### PSY-05（P2）等待焦虑无进度、无退出 ✅已修（翻译 x/y、结束保存进度、状态行两行不截断）/ ⏸defer：模型下载的独立进度条
- 翻译补段无计数（UX-06）、结束保存 10s 无进度（UX-04）、模型下载进度会被截断（VIS-01）。三处都违反"任何 >2s 的等待必须有进度和预期"。
- 反面教材之外也有做得好的：启动期 20s 超时会因下载进度消息 `kick()` 续期（[RecordingStartupStep.swift:45-50](ClassroomTranslator/Services/RecordingStartupStep.swift#L45-L50)），说明团队已有此意识，只差落到 UI。

### PSY-06（P2）自动保存机制对用户完全隐形 ✅已修
- 位置：30s checkpoint（[StableRecordingView.swift:599-604](ClassroomTranslator/Views/StableRecordingView.swift#L599-L604)）。
- 用户不知道"崩溃最多丢 30 秒"，也没有"已自动保存"的微指示；一旦真丢，感知为"数据丢失 bug"。
- 建议：状态区小字"每 30 秒自动保存"或保存成功时打勾脉冲一次。

### PSY-07（P2）文案口吻不一致："Tap Start to resume"（触屏词）出现在桌面端 ✅已修（仅改 value，key 保持英文）
- 位置：[Localizable.strings:44/113](ClassroomTranslator/Resources/zh-Hans.lproj/Localizable.strings#L44)。另有引号用 \" 开头的英文直译式中文（如 \"点开始\"）。
- 建议：桌面统一用"点按/点击"，全文案过一遍母语校对。

### PSY-08（P3）认知负荷：默认值救了大半，但"Professor's Accent"仍是开录前的概念税 ⏸defer：理由：改的是新建课程表单的字段文案与信息层级，属产品文案决策，且与 4.2 的口音名本地化耦合，需一并设计后再动。
- 新建课程要求理解"教授口音 + 目标语言 + 日期"三个概念（[NewCourseView.swift:30-57](ClassroomTranslator/Views/NewCourseView.swift#L30-L57)）；好在默认值全部继承全局设置、可直接回车创建。
- 建议：把"口音"标成"可选，识别不准时再改"，降低首次决策压力；配合 UX-05 的模型预检。

---

## 四、中文本地化缺口（LOC）

**结论：默认界面语言是中文（appLanguage 默认 zh-Hans → 写入 AppleLanguages），但 Localizable.strings 相对代码已明显失配，中文用户会看到中英混排——直接损伤"专业完成度"感知。**

### 4.1 代码在用、.strings 缺失（中文下显示英文）——约 20 处 ✅已修（19 个 key 全部核对存在）
| Key | 位置 |
|---|---|
| "%lld recordings" | [HomeView.swift:32](ClassroomTranslator/Views/HomeView.swift#L32) |
| "Storage Error" | [HomeView.swift:76](ClassroomTranslator/Views/HomeView.swift#L76) |
| "Recording title" / "Edit" / "Original" / "No Transcript" / "%lld segments" / "Translate Missing" / "Translating…" / "Translating missing text…" / "Translation service is not ready. Try again." / "Translations updated" / "Changes saved" | [SessionDetailView.swift:36,47,58,77,83,90,151,159,171,119](ClassroomTranslator/Views/SessionDetailView.swift#L36) |
| "Auto English starts with UK English, then detects the teacher's accent and switches if needed" | [SettingsView.swift:83](ClassroomTranslator/Views/SettingsView.swift#L83) |
| "%lld languages/models" | [SettingsView.swift:171](ClassroomTranslator/Views/SettingsView.swift#L171) |
| "App package is missing speech/microphone usage descriptions…" / "Microphone input level" | [StableRecordingView.swift:187,132](ClassroomTranslator/Views/StableRecordingView.swift#L187) |
| "No transcript content." | [ExportManager.swift:179](ClassroomTranslator/Views/ExportManager.swift#L179) |

### 4.2 完全硬编码、连本地化查询都不做——约 15 处 ✅已修（状态 / 进度类 8 处）/ ⏸defer：LanguageOptions 的 22 个口音、语言名与 Course.accentName 反查显示 —— 理由：需同时补 22 个 key 并把 code→显示名的反查改为 String(localized:)，涉及 3 处 Picker + 历史课程回显，须真机核对中英一致性；不在本轮既定 10 项修复范围内。
- [SettingsView.swift:193,200,202](ClassroomTranslator/Views/SettingsView.swift#L193)："Preparing…" / "Downloading models…" / "%lld/%lld models ready."
- [SpeechManager.swift:93,108,405,417](ClassroomTranslator/Services/SpeechManager.swift#L93)："Downloading %@…" / "%lld/%lld English models ready." / "Detected %@ (%@)…" / "Detected %@."
- [LanguageOptions.swift:10-37](ClassroomTranslator/Models/LanguageOptions.swift#L10-L37)：全部口音/语言选项名（"Auto English (detect accent)"、"English (US)"…）；且两个 Picker 机制不一致——NewCourseView 走 `LocalizedStringKey`（[NewCourseView.swift:45](ClassroomTranslator/Views/NewCourseView.swift#L45)），Settings/CourseSettings 走纯字符串（[SettingsView.swift:89](ClassroomTranslator/Views/SettingsView.swift#L89)、[CourseDetailView.swift:171](ClassroomTranslator/Views/CourseDetailView.swift#L171)），行为不同。

### 4.3 .strings 里的死条目——约 25 处（代码已改走别的 key） ⏸defer（已修 1 处：长版权限引导已被 UX-03 真正启用）/ 理由：批量删 key 是不可逆的双向对账，必须与 4.2 的口音名本地化一起做，否则刚删就要用回来；在无构建的环境下不批量删除。
- 长版权限引导（第 107-110 行，**最可惜：正是 UX-03 需要的**）、"Click Start to begin recording"、"Stop"、"Detecting accent…"、"Accent detection timed out."、"Start First Recording"、"sessions"、口音名"Auto/American/British…"（第 89-101 行）、"Apple SFSpeechRecognizer"、"Speech Recognition - Teacher's Accent"、"English Accent"、"Other Languages"、"Or select if teacher speaks another language" 等。
- 建议：以代码为准做一次双向对账（grep 所有 String(localized:)/Text/Label/Button 字面量 vs .strings key），缺失补齐、死条目清理；并把"禁止硬编码用户可见字符串"写进 PR 检查。

---

## 五、稳定性疑点交叉引用（STAB，详见 CrashAudit.md）

| 编号 | 疑点 | 位置 | 状态 |
|---|---|---|---|
| STAB-01 | 启动超时竞态：底层 start 后返回时只 throw CancellationError 而不再 stop → **麦克风可能残留开启** + 用户看到原始错误串 | [SpeechManager.swift:201](ClassroomTranslator/Services/SpeechManager.swift#L201) | macos-engineer 验证中 |
| STAB-02 | driver.start()/stop() 并发快照竞态，engine/tap 可能在 stop 之后被写入并置 isRunning=true | [AudioEngineDriver.swift:155-181,198-241](ClassroomTranslator/Services/AudioEngineDriver.swift#L155-L181) | 同上 |
| STAB-03 | .translationTask closure 内 attach 后立即 return，session 生命周期是否随即失效（影响全部实时翻译） | [TranslationSessionProvider.swift:57-60](ClassroomTranslator/Services/TranslationSessionProvider.swift#L57-L60) | 同上（需查 Apple 文档） |
| STAB-04 | segments 全量 JSON 编解码在录音中每句多次触发 → 主线程 O(n²) | [TranscriptRecord.swift:13-26](ClassroomTranslator/Models/TranscriptRecord.swift#L13-L26) | 同上 |
| STAB-05 | 非模态 NSSavePanel 打开期间删除记录 → 回调访问已 delete 的 SwiftData 对象 | [ExportManager.swift:25](ClassroomTranslator/Views/ExportManager.swift#L25) | 同上 |
| STAB-06 | ModelContainer 创建失败只弹一次可关 alert，之后**静默无持久化**（每次重启数据"消失"） | [HistoryStore.swift:21-32](ClassroomTranslator/Models/HistoryStore.swift#L21-L32) | 同上 |
| STAB-07 | `window.center()` 在 `setFrameAutosaveName` 之后调用，疑似覆盖用户拖动保存的位置 | [SubtitleOverlay.swift:28,55](ClassroomTranslator/Views/SubtitleOverlay.swift#L28) | 待 Mac 验证 |
| STAB-08 | 多处同时挂 .translationTask（HomeView 全局 + 录音页 + 详情页 + Settings scene）→ 多个并发系统翻译会话 | [HomeView.swift:75](ClassroomTranslator/Views/HomeView.swift#L75) 等 | 待评估 |
| STAB-09 | UserDefaults.didChangeNotification 触发字幕窗全量重渲染（任意 key 变化） | [SubtitleOverlay.swift:52-68](ClassroomTranslator/Views/SubtitleOverlay.swift#L52-L68) | 低风险 |

---

## 六、修复优先级路线图

**第一梯队（先做，直接关系信任与数据）**
1. UX-01 录音中锁定侧栏（或切换即确认）——防"以为在录"
2. UX-02/PSY-04 统一终止/删除的确认矩阵
3. UX-03 权限死路：启用已有长文案 + "打开系统设置"深链按钮
4. STAB-01/02 麦克风残留（工程师负责）
5. VIS-02 主转录原文/译文区分 + attributes 修复

**第二梯队（体验质量）**
6. VIS-01 状态/错误视觉分级；VIS-04/05/06 字幕窗可读性与交互；VIS-08 反馈语义色
7. UX-04 结束保存进度与可取消；UX-05 模型预下载入口
8. LOC 中英对账（4.1 + 4.2 补齐，4.3 清理）

**第三梯队（打磨）**
9. UX-06/07/08/09/10、VIS-03/07/09、PSY-05/06/07、STAB-04 性能、STAB-06 存储失败降级策略

---
*本报告不含代码修改；源码修复与崩溃深挖见 CrashAudit.md（macos-engineer）。*

---

## 修复记录

> 修复人：macos-engineer（task-3）；状态图例：**✅已修** = 已改代码，**⏸defer** = 已评估但暂不改动（附理由）。
> 下列行号为修复完成后的静态行号，会随代码演进漂移，仅作定位参考。
> 主机为 Windows，无法编译运行 macOS 程序 —— 每条「Mac 验证」步骤都必须在 macOS 26 实机上执行后才算闭环。

### 一、已修项（逐条）

#### UX-01 ✅已修 — 录音中锁定侧栏
- **文件**：`ClassroomTranslator/Models/RecordingActivity.swift`（新增）、`ClassroomTranslator/Views/HomeView.swift:17,21,25,51-53,63-82`、`ClassroomTranslator/Views/StableRecordingView.swift` 的 `renderState()` / `syncRecordingActivity()` / `shutDown()`
- **改动**：新增 `@Observable @MainActor final class RecordingActivity`（`static let shared`，`markActive()` / `markIdle()`）。录音控制器在 `renderState()` 里按 phase（starting / recording / paused / interrupted / ended）写入，在 `shutDown()` 里清零。HomeView 在 `body` 中只读一次 `RecordingActivity.shared.isActive`，用自定义 `selectionBinding(locked:)` 拦下 List 的选中变更并置 `showRecordingLockHint`（2.5 秒后自动消失的底部胶囊提示），侧栏整体 `opacity 0.55`。**representable 内部没有任何条件视图 / 分支子树**，维持 macOS 26 上 `NSHostingView` 的布局前提。
- **Mac 验证**：①开始录音后点侧栏「全部录音 / 设置 / 其他课程」→ 不应切换，底部出现「录音进行中，请先结束录音。」，侧栏变灰；②点录音页「返回」→ 仍弹原确认 sheet，确认后侧栏恢复；③暂停 / 被打断 / 失败启动（无既有记录）三种状态下侧栏行为分别核对；④保存返回首页后 1 秒内侧栏必须恢复可点，否则说明 `markIdle()` 有分支遗漏。

#### UX-02 ✅已修 — 终止确认统一
- **文件**：`StableRecordingView.swift` 的 `endPressed()` / `closePressed()` / `confirmEndAndClose()`
- **改动**：`End Session` 与 `Back` 汇入同一条 `confirmEndAndClose()`；只有 recording / starting / paused / interrupted 才弹 sheet，其余状态直接走 `finishAndClose()`。
- **Mac 验证**：四种状态下分别点「End Session」和「返回」都弹同一 sheet；「Save and End」完成保存，「Cancel」停在原状态且录音仍在跑（计时器不中断）。

#### UX-03 ✅已修 — 权限死路打通
- **文件**：`StableRecordingView.swift:225-230`（深链常量）、`failStart(_:generation:permissionURL:)`、`presentPermissionRecovery(message:url:)`、`openSettingsPressed()`、`loadView()` 中的 `openSettingsButton`
- **改动**：权限被拒时改用 `.strings` 里长期未被引用的长引导文案（`Localizable.strings` 原 109-110 行），弹 `NSAlert`，主按钮「打开系统设置」跳 `Privacy_SpeechRecognition` / `Privacy_Microphone` 深链；状态区同时保留常驻的「打开系统设置」按钮（仅权限类失败出现，`controls.detachesHiddenViews = true` 保证隐藏时不留空位）。非权限类错误不弹 alert、不出现按钮。
- **Mac 验证**：①首次点 Start → 拒绝语音权限 → 弹 alert、状态区红色长文案完整、控制条出现按钮；②点按钮应直接落到「隐私与安全性 → 语音识别」；③麦克风权限同理落到「麦克风」；④反向测试：把 Info.plist 的 usage description 删掉后安装 → 只应有错误态，不出现「打开系统设置」按钮。

#### UX-04 ✅已修 — 结束阶段有进度、返回可用（「跳过剩余翻译」⏸defer）
- **文件**：`StableRecordingView.swift:461-483`（`startEndingStatusUpdates` / `updateEndingStatus` / `stopEndingStatusUpdates`）、`finishAndClose()`、`renderState()`、`closePressed()`
- **改动**：`.ended` 期间 0.5s 轮播「正在完成翻译（还剩 N 段）…」→「正在完成翻译并保存…」→「正在保存…」→「已保存 · N 段」；停留时间 450ms → 900ms；`closeButton.isEnabled` 在 `.ended` 保持 `true`，点击立即返回（`shutDown()` 内的 `checkpoint` / `finishRecord` 兜底保存）。
- **⏸defer 理由**：「跳过剩余翻译，立即保存」会绕过 `waitUntilIdle()` 收尾并改变 segments 写库顺序，需要 Mac 端能稳定复现翻译卡死才能验证，本轮不引入。
- **Mac 验证**：①结束一段长录音 → 状态行应持续变化，不出现「灰死」画面；②结束过程中点返回 → 立即回到首页，且切回课程能看到这条记录；③日志确认 `finishRecord` 与 `checkpoint` 二选一，不双写。

#### UX-05 ✅已修 — 预下载入口放开
- **文件**：`ClassroomTranslator/Views/SettingsView.swift:100-103`
- **改动**：`recognitionLanguage == "auto" || recognitionLanguage.hasPrefix("en")` 时都显示「Download All English Models」。
- **⏸defer 理由**：「开录前先用 AssetInventory 检查并提示需下载体积」需要在 UI 层调用 `AssetInventory.status` 并做体积估算，属新功能。
- **Mac 验证**：设置里口音依次选「Auto English / English (US) / 中文」→ 前两者显示按钮、中文不显示；点按钮后进度依次为「Preparing… / Downloading models… / x/y models ready.」。

#### UX-06 ✅已修 — 详情页不再自动批量翻译
- **文件**：`ClassroomTranslator/Views/SessionDetailView.swift`（删除 `.task`）、`translateMissingSegments()`
- **改动**：移除「打开详情即自动翻译」的 `.task`；保留显式按钮，翻译时 footer 显示 `Translating %lld/%lld…`；顺带修正 footer 的 `%lld segments` —— 它原本处在三元表达式里被推断成 `String`，`Text(String)` 是 verbatim、根本不会查表，改为 `String(format: String(localized: …), drafts.count)`。
- **Mac 验证**：①打开一条有缺译段的记录 → footer 只显示「N segments」，不自动翻译、不出现「Translation service is not ready.」；②点「Translate Missing」→ footer 逐段跳号直到「Translations updated」（绿色 + ✓ 图标）；③中文界面下无英文残留。

#### UX-07 ✅已修 — 取消导出静默
- **文件**：`ClassroomTranslator/Views/ExportManager.swift:19-25`（新增 `isCancellation(_:)`）、`HistoryView.swift`、`CourseDetailView.swift`、`SessionDetailView.swift` 的 `exportMessage(for:)` / `exportWord()` / `exportText()`
- **改动**：`.cancelled` 不再产生 alert 与 footer 错误态 —— 反馈置空并回落到「N segments」；真实失败照常上报（详情页为红色错误态）。
- **Mac 验证**：导出 Word → 在保存面板点「取消」→ 不应出现任何 alert；导出到只读目录 → 应出现红色错误提示。

#### UX-08 ✅已修 — 保存结果可被读到（侧栏计数即时刷新 ⏸defer）
- 见 UX-04（同一段代码）：900ms 停留 +「已保存 · N 段」。

#### VIS-01 ✅已修 — 状态 / 错误视觉分级
- **文件**：`StableRecordingView.swift` 的 `StatusSeverity` 枚举与 `setStatus(_:severity:)`，全部 17 处 `statusLabel.stringValue =` 已改走该方法
- **改动**：普通 = secondary、`byTruncatingTail`、最多 **2 行**（下载进度这类长文案不再被一行吃掉）；警告 = 「⚠︎ 」+ 橙色 + `byWordWrapping` 2 行；错误 = 「⛔︎ 」+ 红色 + `byWordWrapping` 3 行；结尾 `invalidateIntrinsicContentSize()`。
- **Mac 验证**：①拒绝权限 → 红色 ⛔ 且整句完整；②录音中翻译失败 → 橙色 ⚠︎；③正常状态仍为灰色；④状态切换后控制条高度自适应，不与电平条 / 按钮重叠。

#### VIS-02 ✅已修 — 主转录原文 / 译文区分
- **文件**：`StableRecordingView.swift` 的 `finalizedAttributed`、`Self.originalTextAttributes`（13pt secondary）、`Self.translatedTextAttributes`（15pt label）、`refreshTranscript()`、`rebuildFinalizedText(from:)`
- **改动**：每次写入 `textStorage` 都是带显式 attributes 的字符串，占位文案同样带属性 —— 消除「首行 15pt、正文回落 12pt」的可能；原文降级、译文强调。
- **Mac 验证**：①录一段话并出译文 → 转录区一眼可分辨（上小下大、灰 / 黑）；②全选复制出去文本完整；③空记录的「Ready to Listen」应为 13pt 灰色，与正文同级；④⚠️重点观察 NSTextView 是否还有 12pt 回落（本条原报告就标注了需实机验证）。

#### VIS-03 ✅已修 — 详情页主次颠倒 + 纯颜色编码
- **文件**：`ClassroomTranslator/Views/SessionDetailView.swift` 的 `roleTag(_:)` 与只读态行
- **改动**：译文 15pt medium + `.primary`（≥ 原文 13pt），原文 13pt `.secondary`；行首加「原文 / 译文」小标签（Capsule + caption2），不再靠颜色区分（WCAG 1.4.1）。
- **Mac 验证**：①把系统切到灰度 / 开启「辅助功能 → 显示器 → 灰度」后仍能分辨两行角色；②空译文段落只显示原文行，不多出空行；③编辑模式（TextEditor）不受影响。

#### VIS-04 ✅已修 — 悬浮字幕可读性下限
- **文件**：`ClassroomTranslator/Views/SubtitleOverlay.swift` 的 `subtitleAttrs(fontSize:color:)` 与 `renderLatestCue()`、新增 `Self.softOriginalYellow`
- **改动**：原文字号 `max(fontSize - 4, 12)`（12pt 设置下不再出现 8pt）；文字加 1pt 黑描边 `.strokeWidth: NSNumber(value: -1.0)`（负值 = 先描边后填充，正值会变空心字）；纯 `#FFCC00` → 柔和 `#FFD866`。**透明度滑块下限保持 0.3 不变**（避免配置 schema 变更）。
- **⏸defer 理由**：「透明度下限提到 0.6 / 浅色背景反相模式 / 首行原文译文前缀标签」按产品决定不动，且反相模式是新功能。
- **Mac 验证**：①字号调到最小 12 → 原文仍 ≥12pt；②白底 PPT 上字幕可读性明显改善；③黄色不再刺眼；④老用户偏好（字号 / 透明度 / 最大词数）读取正常。

#### VIS-05 ✅已修 — 点击穿透 + 初始位置
- **文件**：`SettingsView.swift:83-86`（新 Toggle）、`SubtitleDisplayConfiguration.swift:9-10,21`、`SubtitleOverlay.swift:28-30,55-75,175-180`
- **改动**：新增 `@AppStorage("overlayClickThrough")`，默认 **false**（保住可拖动）；`applyDisplaySettings()` 同步 `window.ignoresMouseEvents`；初始位置：`setFrameAutosaveName` 返回 `true`（有存档）→ 尊重存档，返回 `false` → 屏幕底部居中（`visibleFrame.midX - w/2`、`visibleFrame.minY + 40`），**不再无条件 `window.center()`** —— 顺带修正了 STAB-07 的疑点（原 `center()` 写在 autosave 之后，会盖掉用户拖出来的位置）。
- **Mac 验证**：①删掉 `SubtitleOverlayFrame` 存档后首启 → 悬浮窗在屏幕底部居中；②拖到右上角 → 重开 app → 仍在右上角；③勾选「悬浮窗点击穿透」→ 点击穿透到幻灯片（同时按设计不能再拖）；④取消勾选 → 拖动恢复；⑤多显示器下应在主屏（origin 为 0 的那块）。

#### VIS-06 ✅已修 — 全屏期间字幕保留
- **文件**：`ClassroomTranslator/Views/SubtitleOverlay.swift` 的 `mainWindowWillEnterFullScreen(_:)`
- **改动**：删除 `hideWindow()`，保留 `overlayWasVisible` 记录与退出全屏的恢复逻辑。
- **git 考据**：`git blame` / `git log -S willEnterFullScreen` → 原提交 message 为 `fix: stepwise permission with watchdog; overlay auto-hide on fullscreen`，原注释写「主窗口进全屏前收起悬浮窗（floating panel 会干扰全屏切换），退出后恢复」；当时 `window.contentView` 还是 `NSHostingView(rootView: subtitleView)`，而后续提交 `3a4eaf2 fix: replace SwiftUI subtitle panel with pure AppKit to eliminate layout crash` 已把面板换成纯 AppKit `NSTextView`。→ 当年的理由属 SwiftUI 面板时代，已无崩溃级依据，故移除隐藏。
- **Mac 验证**：①课堂播放窗口全屏 → 字幕窗应**继续显示**；②退出全屏 → 仍在；③反复进出全屏 10 次，无布局跳动 / 无闪烁 / 无崩溃（这是当年隐藏要规避的问题，必须重点回归）；④`collectionBehavior` 仍为 `.canJoinAllSpaces + .fullScreenAuxiliary`。

#### VIS-07 部分 ✅已修 / 按钮强调 ⏸defer
- **文件**：`StableRecordingView.swift` 的 `micIconView`（16×16 `mic.fill`，带 `accessibilityDescription`）
- **⏸defer 理由**：Start / Pause 的强调样式与 End 的 destructive 红依赖 NSButton bezel 的实机渲染效果，无 Mac 构建时改色只能靠猜，风险是「改了更难看 / 与系统风格不一致」。
- **Mac 验证**：①控制条出现麦克风图标且不挤压电平条；②窗口缩到最小宽度时图标不被压扁。

#### VIS-08 ✅已修 — footer 反馈语义色
- **文件**：`SessionDetailView.swift` 的 `FeedbackSeverity`（info / success / error）、`setFeedback(_:severity:)`、footer
- **改动**：info = 灰 + `info.circle`，success = 绿 + `checkmark.circle.fill`，error = 红 + `exclamationmark.triangle.fill`，替换原来的恒 `.green`。
- **Mac 验证**：导出成功 → 绿色 ✓；取消导出 → 无图标、灰色「N segments」；翻译服务未就绪 → 红色 ⚠。

#### VIS-09 ✅已修 — 计时格式统一
- **文件**：`StableRecordingView.swift`（`elapsedLabel` 初值 `0:00:00` + `formatDuration`）、`HistoryView.swift`、`ExportManager.swift`（各自 `formatDuration`）
- **改动**：三处统一 `h:mm:ss`，`max(0, Int(duration))` 防负值。
- **Mac 验证**：①录 1 小时 5 秒 → 记录页 / 列表 / 导出文本都显示 `1:00:05`；②中断或时钟回拨不出现负值。

#### VIS-10 部分 ✅已修 / About 文案 ⏸defer
- **文件**：`CourseDetailView.swift` 的删除按钮 `.accessibilityLabel(Text("Delete Course"))`
- **⏸defer 理由**：About 的硬编码 `1.0.0` / `Apple SpeechAnalyzer` 与 `.strings` 中过期的 `Apple SFSpeechRecognizer` 属 4.3 死条目对账，需一并读取打包 Info.plist 的版本字段。

#### PSY-02 ✅已修 — 错误 → 人话
- **文件**：新增 `ClassroomTranslator/Services/RecordingErrorPhraser.swift`、`StableRecordingView.swift` 的 `catch` 分支
- **改动**：`RecordingErrorPhraser.humanMessage(for:)` 覆盖 `RecordingStartupStep.StartupError.timedOut`、`AudioEngineError` 全部 4 个 case、`SpeechError` 全部 9 个 case、`CancellationError`（含 `String(reflecting:)` 类型名兜底）；未知错误返回 `nil` 并回落 `error.localizedDescription`，不吞真实信息。
- **新增测试**：`Tests/ClassroomTranslatorTests/RecordingErrorPhraserTests.swift`（5 个用例）。
- **Mac 验证**：①连点 Start 或占用麦克风触发超时 → 状态行是中文人话而非 `(Swift.CancellationError error 1.)`；②拔掉麦克风 → 提示「未检测到输入设备」；③中英切换后文案跟随。

#### PSY-04 ✅已修 / PSY-01 ✅已修 / PSY-05 部分 ✅已修 / PSY-06 ✅已修 / PSY-07 ✅已修
- **PSY-01**：随 UX-01 一起解决（「我以为在录」的信任红线）。
- **PSY-04**：随 UX-02（统一确认矩阵）与 UX-07（取消不报错）解决。
- **PSY-05**：随 UX-06（翻译 x/y）、UX-04（结束进度）、VIS-01（状态行两行不截断）解决；独立下载进度条 ⏸defer。
- **PSY-06**：`StableRecordingView.swift` header 常驻 11pt 小字「每 30 秒自动保存」（`hugging = .required`、`compression = .defaultLow`，空间不足先截断这行，永不挤压课程名与返回按钮）。**Mac 验证**：窗口缩到最小宽度 → 小字出省略号，标题 / 返回按钮仍完整。
- **PSY-07**：`Localizable.strings` 第 44、113 行**只改 value**（`点"开始"` → `点击"开始"`），key 保持英文。**Mac 验证**：触发「录音被打断」→ 提示里是「点击」。

#### LOC 4.1 ✅已修 / 4.2 部分 ✅已修 / 4.3 部分 ✅已修
- **4.1**：报告列出的 key 全部核对存在（注意 `Auto English starts with UK English, then detects the teacher’s accent…` 用的是弯引号 `’`，按直引号搜会误判为缺失）。
- **4.2 已修 8 处**：`SpeechManager.swift`（`Downloading %@… (%lld/%lld)`、`%lld/%lld English models ready.`、`Detected %@ (%@)…`、`Detected %@.`）、`AudioEngineDriver.swift`（`Downloading %@ speech model…`、`…(%lld%%)`、`%@ model ready.`）—— 这些字符串由 `NSTextField.stringValue` 承载，不会走 `Text(String)` 之外的任何查表路径，必须 `String(format: String(localized: …))`；百分号用 `%%` 转义，否则 `String(format:)` 会把结尾的 `%` 当成转换说明符。
**Mac 验证**：中文界面下下载模型 →「正在下载 en-US 语音模型…（45%）」，百分号不乱码；口音切换日志显示「已识别为 …」。
- **⏸defer（4.2 剩余）**：`LanguageOptions` 的 22 个口音 / 语言名，以及 `Course.accentName` / `targetLanguageName`（`Course.swift` 内 `String` 直返，`NSTextField` 与 `Label` 都不查表）。理由：需要同时补 22 个 key 并把 code→显示名的反查全部改为 `String(localized:)`，涉及 3 处 Picker 与历史课程回显，必须在 Mac 上核对中英切换一致性；不在本轮既定 10 项修复范围内。（三处 Picker 均以 `code` 打 tag 存储，改显示名不影响已有数据，可安全单独立项。）
- **⏸defer（4.3）**：其余约 24 条死条目批量删除 —— 删 key 是不可逆的双向对账，必须与 4.2 的口音名本地化一起做，否则「刚删就要用回来」；在无构建的环境下不批量删除。**已修 1 处**：长版权限引导（原 107-110 行）已被 UX-03 真正启用。

### 二、本轮 defer 汇总

| 编号 | 理由 |
|---|---|
| UX-04（跳过按钮） | 需绕过 `waitUntilIdle` 收尾并改变写库顺序，须在 Mac 上复现翻译卡死才能验证 |
| UX-05（体积预检） | 属新功能（UI 层调 AssetInventory + 体积估算），非缺陷修复 |
| UX-08（侧栏计数刷新） | 依赖 SwiftData 变更通知的真机行为 |
| UX-09 | relaunch 按钮 vs. 摆脱 AppleLanguages 是两条互斥的产品路线，且动 App 启动 / 生命周期风险高 |
| UX-10 | 首页信息架构重设计属新功能，且需与 UX-01 联动做真机动线验证 |
| UX-11 | 触碰 SwiftData `@Model` 访问器（与 STAB-04 同源），属高风险区，收益需实测 |
| VIS-04（透明度 / 反相 / 图例） | 按产品决定保持透明度下限不变；反相模式是新功能 |
| VIS-07（按钮强调 / destructive 红） | NSButton bezel 着色必须实机渲染确认 |
| VIS-10（About 版本 / 引擎名） | 属 4.3 死条目对账，需读 Info.plist |
| PSY-03 | 状态行内嵌按钮 + 首次提示去重需新增持久化状态，且触发点在 TranslationManager（上一轮 16 个已审文件），不扩大改动面 |
| PSY-08 | 新建课程表单文案决策，与 4.2 口音名本地化耦合 |
| LOC 4.2（口音 / 语言名） | 22 个 key + code→显示名反查 + 3 处 Picker + 历史回显，须真机核对 |
| LOC 4.3（死条目清理） | 与 4.2 绑定的不可逆双向对账 |

### 三、本轮新增测试

| 测试文件 | 用例数 | 覆盖 |
|---|---|---|
| `Tests/ClassroomTranslatorTests/RecordingErrorPhraserTests.swift` | 5 | PSY-02 错误映射（超时 / 无设备 / 识别器不可用 / 取消 / 未知回退） |
| `Tests/ClassroomTranslatorTests/ExportFormatTests.swift` | 3 | VIS-09 `formatDuration` 三态 + 负值钳制；UX-07 `isCancellation` |
| `Tests/ClassroomTranslatorTests/SubtitleDisplayConfigurationTests.swift`（+1） | 1 | VIS-05 `clickThrough` 默认关闭与开关联动 |

测试总数：42（原 38 + 新增 4）。
