# EngineArchitecture.md — 语音引擎抽象层（task-6）

> Step 1：协议提取 + AppleSpeechEngine 包装，行为零变化（CI 绿，run 36218692962，13/13）。
> Step 2（本提交）：SherpaSpeechEngine 落地 —— 双前置（SHERPA-DEMO.md 交付 +
> Step 1 CI 绿）已确认，§4/§5/§6/§7 按 Lead 开工令七条补全。
> 既有任务文档（SpeakerFeature.md 等）不因本任务改动。

## 1. 背景与路线

用户选定 **sherpa-onnx 双引擎** 路线：Windows 侧可调试语音核心 + macOS 发售保持
Apple 引擎质量。分两步提交，每步过 CI（GitHub Actions 是唯一编译/测试关卡）：

- **Step 1（本步，行为零变化）**：提取 `SpeechEngine` 协议；原 `AudioEngineDriver`
  更名为 `AppleSpeechEngine` 并直接实现协议（公开签名零改动 → 无转发层）；
  `speechEngine` 设置项（默认 apple，UI 暂只暴露 Apple）；`EngineArchitecture.md` 骨架；单测。
- **Step 2（本提交，Lead 开工令七条确认执行）**：`SherpaSpeechEngine` 实现同一协议 +
  设置项追加 sherpa 选项（含首字延迟如实标注）+ 模型资源 `SherpaStreamEN` 注册 +
  About 动态行。集成路径与性能基线全部来自 SHERPA-DEMO.md（行号版 C 调用序列，Lead 要求不凭记忆）。

## 2. 协议设计（`ClassroomTranslator/Services/SpeechEngine.swift`）

**边界 = 原 AudioEngineDriver 的对外面**，逐项对账（含 SpeechManager 实际依赖的 3 项 task-4 成员）：

| 协议成员 | 来源 | 说明 |
| --- | --- | --- |
| `start(localeIdentifier:contextPhrases:onInterruption:onAudioLevel:onModelStatus:onRecognition:)` | 原公开签名 | 4 个回调随 start 携带，签名逐字未动 |
| `stop()` / `running` | 原公开 | |
| `onAccentSamples`（get/set） | 原公开 | 透传引擎内部 AccentAudioTee.onReady |
| `setAccentCapture(enabled:)` | 原公开 | |
| `updateContext(phrases:)` | 原公开 | 热更新上下文词 |
| `setSpeakerCapture(enabled:)` | task-4 新增 | 与 accent 同构（reset/disable） |
| `speakerRing` | task-4 新增 | 录音页 SpeakerEngine 直接消费 |

**SpeechManager 的改动仅一行**：构造
`private let driver = AudioEngineDriver()` →
`private let driver: any SpeechEngine = SpeechEngineFactory.make()`。
编排逻辑（权限、generation、口音检测、delta 提交、状态机）零触碰 ——
该文件是全项目修复最密集、回归历史最重的部分（Lead 硬约束）。

**工厂与可用性回退**：`SpeechEngineKind`（rawValue: apple/sherpa）读取
UserDefaults key `speechEngine`；Step 2 起 sherpa 的 `isAvailable` =
`SherpaSpeechEngine.isUsable()`（模型文件齐全 + 未被创建失败熔断），`resolved`
据此显示/回落并记 `engine.unavailable` 日志。**默认仍是 apple**（`fallback`
+ 测试环境默认值不变）；sherpa 不可用时工厂直接实例化 AppleSpeechEngine 并记
`engine.sherpa-unavailable` —— 默认路径零接触（降级纪律同 task-4）。

## 3. 音频架构决策（Step 1 定稿，Step 2 沿用）

1. **麦克风互斥（选型：单活跃引擎）**：任一时刻只实例化并启动所选引擎 ——
   引擎选择在 `SpeechManager` 初始化时读取（构造行 → 工厂），切换后**下次进入
   录音页**生效；录音会话进行中绝不换引擎、绝不同开两路 AVAudioEngine。
   理由：双引擎各持 AVAudioEngine + tap 虽在 macOS 上可同时开麦，但带来
   两倍采集成本、采样率/缓冲对齐与中断竞争问题，而产品语义上"换引擎"只需要
   在会话边界生效。互斥把复杂度压到"工厂单点选择"。
2. **accent tee 与 speaker ring 归属：引擎内部（tap 层）**。每个引擎在自己的
   mic tap 里并联 `AccentAudioTee` + `SpeakerAudioRing`，对外只经协议回调
   （`onAccentSamples`）与 `speakerRing` 属性暴露 —— SpeechManager 侧消费完全不变。
   否决的备选：把 tee 提升到 SpeechManager 共享（需要把音频样本上抛到编排层、
   改动 SpeechManager 音频路径，违反"一行不改"且回归面最大）。
   **每个引擎各带一份 tee/ring 实例**：互斥保证同一时刻只有一份在接收音频。
3. **回调与线程语义保持原样**：协议不承诺回调线程（原 driver 在自有 queue/
   主线程混合投递，SpeechManager 现有写法已适配）；SherpaSpeechEngine 必须
   自行满足同样的到达顺序（start 回调 → 识别回调 → stop 后不再回调）。
4. **错误语义**：协议沿用 `AudioEngineError`（RecordingErrorPhraser 依赖的
   case 不改名不增删）；sherpa 引擎无法表达的错误（如系统模型下载）映射到
   最接近的既有 case，不新增 UI 文案路径。

## 4. 引擎选择与设置（Step 2 完成态）

- key：`speechEngine`（`SpeechEngineKind.defaultsKey`；SettingsView 的 @AppStorage
  用字面量，单测锁一致性），默认 `apple`。
- 设置 UI：`Section("Speech Engine")` + Picker 两选项 —— "Apple SpeechAnalyzer" +
  "Sherpa-onnx · English streaming"（仅当 `SherpaSpeechEngine.modelsPresent()` 列出）；
  生效时机说明保留；**选中 sherpa 时追加首字延迟说明**（"出字需约 1–1.3 秒语音积累
  （模型上下文所需，非故障）"，Lead 开工令第 5 条，zh-Hans 新 key 3 条）。
- About 区引擎行已改动态：`resolvedEngineDisplayName`（isAvailable + fallback 推导，
  刻意不走 `resolved` 以免渲染触发 StartupLog），缺失/熔断时如实显示 Apple。

## 5. 双引擎差异对照（Step 2 已按 SHERPA-DEMO.md + Lead 确认实现）

| 维度 | AppleSpeechEngine（已实现） | SherpaSpeechEngine（Step 2 已实现） |
| --- | --- | --- |
| 识别核心 | SpeechAnalyzer + DictationTranscriber（macOS 26 系统框架） | sherpa-onnx **1.13.8**：SPM `.package(url:"k2-fsa/sherpa-onnx", exact:"1.13.8")`（钉死在 requirement —— .gitignore 忽略 Package.resolved，Lead 开工令第 2 条）；传递 onnxruntime-libs exact 1.28.2 由上游钉死；`import SherpaOnnx` 用官方薄封装 `SherpaOnnxRecognizer` |
| SherpaOnnx.swift 归属 | — | **product 内置，无需 vendor**：已核上游 Package.swift —— product "sherpa-onnx" 的 target `SherpaOnnx` `sources: ["SherpaOnnx.swift"]`（Lead 开工令第 3 条的二选一，选"在 product 里"） |
| 模型来源与体积 | AssetInventory 系统下载（onModelStatus 进度回调） | 本地 bundle `Resources/SherpaStreamEN`（`.copy`，6 文件 **69.5MB**：encoder int8 chunk-16-left-128 67.79MB + decoder 1.25MB + joiner 0.25MB + bpe 0.23MB + tokens + README；**Apache-2.0** HF cardData 实测双模型同）；ZH 双语 198.5MB **不进包**（HEAD 输入为英语+口音 only，Lead 批准备报 1）；onModelStatus = "Loading %@ speech model…" → "%@ model ready."（复用 Apple 文案形状） |
| 音频输入 | AVAudioEngine tap → AVAudioConverter → AnalyzerInput | 同一 tap 模式 → AVAudioConverter → **16k 单声道 float** → `acceptWaveform(samples:sampleRate:16000)` → `isReady()/decode()` 循环 → `getResult().text`（C 调用序列逐项对照 SHERPA-DEMO.md §B2 行号版） |
| 句末切分 | DictationTranscriber 结果 `isFinal` | `enableEndpoint=true`，rule1/2/3 = **2.0s / 1.0s / 30s**（课堂语速调参基线）→ `isEndpoint()` 发整句 final + `reset()`；partial = 句内累积文本，与 Apple 语义对齐 |
| 性能基线（demo 实测，A/B 对照锚点） | — | **RTF 0.038**（2 线程 CPU greedy）、0.32s chunk 单解码 **14ms**（~23× 实时余量）、**首字 1.1–1.3s**（模型上下文所需，设置页如实标注）、LibriSpeech WER **5.6%/2.1%**、尾部 +1s 静音兜底末词 |
| 上下文词热更新 | `setContext` 热更 | 空实现（sherpa MVP 无热词通道，Lead 确认；本机上下文词本只影响 Apple 候选） |
| 口音/speaker tee | tap 并联（已实现） | 同一模式自带 tee/ring（§3 决策 2） |
| 并发 | analyzer/tasks 自有结构 | C 指针非 Sendable → 识别器仅在**串行 queue** 上使用（与引擎 setup 同队列，tap 只产样本）；创建在 start 的 **detached 任务**（1.6s 加载不冻结主线程，Lead 开工令第 6 条批准） |
| 失败面 | AudioEngineError 四 case | 同协议错误语义；**降级纪律（Lead 第 4 条）**：模型缺失/创建失败 → 进程内熔断 `isUsable=false` → 工厂回退 apple + 记日志；未选 sherpa 时整条链路零接触 |
| 分发/体积 | 系统框架，0 增量 | 静态 xcframework（0 嵌入 dylib，适配现有 ad-hoc+dmg）+ 模型 69.5MB；app 体积增量估 **+20–40MB**（未验证估算） |

**已知局限（如实记录）**：上游 wrapper 的 `SherpaOnnxRecognizer.init` 对 C 创建失败
是 **trap 而非 nil** —— `makeRecognizer` 创建前先做"文件齐全 + 最小体积"校验
（防截断；同批文件 demo 已端到端跑通），截断模型属打包完整性问题；中文长音频
口吃/无标点不影响（EN-only）；Swift wrapper 单实例单 stream = 单活跃引擎恰好够用。

## 6. 验证矩阵

| 项 | Step 1 | Step 2 |
| --- | --- | --- |
| 编译 + 单测 | CI 绿（run 36218692962，13/13，78 用例） | CI 目标：**82 用例**（引擎选择测试重构为 11 个：可用性/工厂回退/工厂实例化/文件校验/**真实模型 C 创建全链路**），`import SherpaOnnx` 编译即 SPM 链接守门 |
| 行为零变化 | 录音/翻译/口音检测/说话人识别/字幕/导出全路径与 0e9e64b 逐项一致 | 默认 apple 路径零变化（未选 sherpa 时工厂/设置/About 不进 sherpa 分支） |
| 手动冒烟（Mac） | 启动、录音、翻译、暂停/打断、设置页单选项 | sherpa 选项切换 → 下次进录音页出字（首字 ~1.1–1.3s 属预期）→ 识别/翻译/说话人标签走通；About 行随选择变化 |
| 数值一致性 | 不适用 | Apple vs sherpa 同段录音对照；锚点 = SHERPA-DEMO.md 基线（RTF 0.038 / 首字 1.1–1.3s / WER 5.6–2.1%） |
| 降级 | 不适用 | 单测注入：temp bundle 模型缺失 → 工厂回退 apple（`testFactorySherpaFallsBackWhenModelMissing`）；创建失败 → 熔断 + 下次回退（运行路径记 `sherpa.creation-failed` 日志） |
| 无麦 CI 覆盖 | 不适用 | `testMakeRecognizerCreatesRealModelEndToEnd`：真实 69.5MB 模型 → config → C 创建 → 释放（不含 start/麦克风） |

## 7. Step 2 前置与确认项（全部完成）

- [x] SHERPA-DEMO.md 交付（Lead 确认双前置之一）：EN streaming zipformer int8 选型、
      延迟数据（§5 性能基线行）、SPM 绑定、Apache-2.0 双源核实
- [x] Step 1 CI 绿（run 36218692962，13/13，78 用例，Lead 确认之二）
- [x] 模型注册：Package.swift `.copy("Resources/SherpaStreamEN")`（与 AccentECAPA/
      SpeakerCAMWave 同写法）+ SPM 依赖 exact requirement 钉死（因 Package.resolved 被 gitignore）
- [x] SherpaOnnx.swift 归属核实（Lead 第 3 条）：上游 product target `sources` 含该文件
      → 直接 `import SherpaOnnx`，不 vendor
- [x] 降级纪律复刻（Lead 第 4 条）：缺失/创建失败 → 熔断 → 回退 apple + 日志
- [x] 首字延迟如实标注（Lead 第 5 条）：设置页 sherpa 选项 caption + zh-Hans key
- [x] 回调线程边界维持 Step 1 形状（Lead 第 6 条）
- [ ] 未决（不阻塞，如实记录）：app 体积增量 +20–40MB 为估算；endpoint rule1/2/3
      基线 2.0/1.0/30s 待真课录音调参；sherpa vs Apple 同段录音 A/B 冒烟待 Mac 手测

## 8. 变更记录

- Step 1（commit 712a9a3）：协议提取、`AudioEngineDriver` → `AppleSpeechEngine`（文件同步更名
  `AppleSpeechEngine.swift`，`AudioEngineError` 名称与 case 不动）、SpeechManager 构造行、
  `speechEngine` 设置项与 zh-Hans 文案 2 条、`SpeechEngineSelectionTests`（7 用例）、本文件。
- Step 2（本提交）：`SherpaSpeechEngine`（协议第二实现，串行队列解码 + endpoint 分句 +
  创建熔断）、SPM 依赖 exact 1.13.8 + product `sherpa-onnx`、`Resources/SherpaStreamEN`
  69.5MB Apache-2.0 模型 `.copy` 注册、SpeechEngineFactory 分叉与 `isUsable`、
  Settings sherpa 选项 + 首字延迟文案 + About 动态行、zh-Hans 新增 3 key、
  `SpeechEngineSelectionTests` 重构至 11 用例（总数 78 → **82**）、本文件 §1/§2/§4–§7 补全。
