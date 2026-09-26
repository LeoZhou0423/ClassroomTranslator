# EngineArchitecture.md — 语音引擎抽象层（task-6）

> Step 1（本文件初版）：协议提取 + AppleSpeechEngine 包装，行为零变化。
> Step 2：SherpaSpeechEngine 落地（前置：SHERPA-DEMO.md 调研 + Step 1 CI 绿），
> 届时补全 §5/§6 的 sherpa 列与验证矩阵。
> 既有任务文档（SpeakerFeature.md 等）不因本任务改动。

## 1. 背景与路线

用户选定 **sherpa-onnx 双引擎** 路线：Windows 侧可调试语音核心 + macOS 发售保持
Apple 引擎质量。分两步提交，每步过 CI（GitHub Actions 是唯一编译/测试关卡）：

- **Step 1（本步，行为零变化）**：提取 `SpeechEngine` 协议；原 `AudioEngineDriver`
  更名为 `AppleSpeechEngine` 并直接实现协议（公开签名零改动 → 无转发层）；
  `speechEngine` 设置项（默认 apple，UI 暂只暴露 Apple）；`EngineArchitecture.md` 骨架；单测。
- **Step 2（未开工，双前置）**：`SherpaSpeechEngine` 实现同一协议 + 设置项追加 sherpa
  选项 + 模型资源注册。前置 = (a) SHERPA-DEMO.md（ASR 选型/延迟 + macOS Swift 绑定调研）；
  (b) Step 1 CI 绿。

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
UserDefaults key `speechEngine`；`isAvailable` 在 Step 1 对 sherpa 恒 false，
`resolved` 把任何已存值回退为 apple 并记 `engine.unavailable` 日志 ——
**无论用户/旧数据存了什么，Step 1 实例化的都是 AppleSpeechEngine（默认行为零变化，
由 7 个单测锁定）**。Step 2 只需：sherpa 的 `isAvailable` 改 true、工厂分叉。

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

## 4. 引擎选择与设置（Step 1）

- key：`speechEngine`（`SpeechEngineKind.defaultsKey`；SettingsView 的 @AppStorage
  用字面量，单测 `testDefaultsKeyIsSpeechEngine` 锁一致性），默认 `apple`。
- 设置 UI：`Section("Speech Engine")` + 单选项 Picker（"Apple SpeechAnalyzer"）+
  生效时机说明（"下次进入录音页时生效。"）。**暂只暴露 Apple**；sherpa 选项 Step 2 追加。
- About 区原有的静态 "Speech Engine / Apple SpeechAnalyzer" 行 Step 1 不动；
  Step 2 需要把它改为显示当前 resolved 引擎（已记入 Step 2 清单）。

## 5. 双引擎差异对照（sherpa 列为 Step 2 计划，待 SHERPA-DEMO.md 定稿）

| 维度 | AppleSpeechEngine（已实现） | SherpaSpeechEngine（Step 2） |
| --- | --- | --- |
| 识别核心 | SpeechAnalyzer + DictationTranscriber（macOS 26 系统框架） | sherpa-onnx C API（OnlineRecognizer，流式 zipformer；选型/延迟待调研） |
| 模型来源 | AssetInventory 系统下载（onModelStatus 回调进度） | 本地 bundle 资源注册（体积/许可记录在案，Apache-2.0）；无下载则 onModelStatus 语义 = "" |
| 音频输入 | AVAudioEngine tap → AVAudioConverter → AnalyzerInput | AVAudioEngine tap → 16k 单声道 float → sherpa AcceptWaveform（同一 tap 模式，编码/重采样复用现有工具） |
| 上下文词热更新 | `setContext` 热更 | sherpa 侧无对应能力 → 空实现（协议允许；识别内容不受影响） |
| 口音/speaker tee | tap 并联（已实现） | 同一模式自带 tee/ring（§3 决策 2） |
| 失败面 | AudioEngineError 四 case | 同协议错误语义（§3 决策 4） |

## 6. 验证矩阵

| 项 | Step 1 | Step 2 |
| --- | --- | --- |
| 编译 + 单测 | CI（swift build/test）：78 个用例含 7 个引擎选择新用例 | 同左（+ sherpa 引擎单测） |
| 行为零变化 | 录音/翻译/口音检测/说话人识别/字幕/导出全路径与 0e9e64b 逐项一致（代码层：SpeechManager 仅构造行 diff、驱动内部仅类名 diff） | 不适用 |
| 手动冒烟（Mac） | 启动、录音、翻译、暂停/打断、设置页新 Section 显示单选项 | sherpa 选项切换 → 录音识别文本一致度/延迟对比 |
| 数值一致性 | 不适用 | Apple vs sherpa 同段音频转写对照（延迟基线取自 SHERPA-DEMO.md） |
| 降级 | 不适用 | sherpa 模型缺失/加载失败 → 回退 apple 并记日志，录音翻译不受影响 |

## 7. Step 2 前置与未决（前置未齐不动工）

- [ ] SHERPA-DEMO.md：ASR 模型选型（须含英语讲座流式，如 zipformer streaming en）、
      延迟数据、macOS Swift 绑定方式（SPM/C 静态库/预编译产物）、license（Apache-2.0）
- [ ] Step 1 CI 绿（Lead 推送验证）
- [ ] sherpa 模型资源体积与 Package.swift `.copy` 注册方式（参考 AccentECAPA 写法）
- [ ] About 区静态引擎行改为动态显示（§4）

## 8. 变更记录

- Step 1（本提交）：协议提取、`AudioEngineDriver` → `AppleSpeechEngine`（文件同步更名
  `AppleSpeechEngine.swift`，`AudioEngineError` 名称与 case 不动）、SpeechManager 构造行、
  `speechEngine` 设置项与 zh-Hans 文案 2 条、`SpeechEngineSelectionTests`（7 用例）、本文件。
