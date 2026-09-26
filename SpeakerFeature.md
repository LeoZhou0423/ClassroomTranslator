# SpeakerFeature.md — 说话人识别（task-4）实现说明

> 对应任务：task-4 说话人分离（老师/学生说话人标签）。
> 结论先行：**已按 Lead 批准的方案 A（fbank 内嵌进 CoreML）完成实现并过校验门槛** —
> 波形输入包装模型对 sherpa-onnx 参考的端到端余弦**最差 0.9989**（门槛 0.98，
> 报告 §4.3）。方案 B 的回退路径与 Mac 验证清单见文末。

---

## 1. 交付内容与任务条目对照

| 任务条目 | 实现 |
| --- | --- |
| (1) TranscriptSegment 增加 speaker 字段 + HistoryStore 兼容 | `speaker: String?*，Codable 可选键向后兼容（旧 JSON 缺键 → nil，有单测）；`updateTranslation` 重建段落时保留 speaker；新增批量 `updateSpeakers(_:in:)`（只改内存，落库走现有 checkpoint 机制，不逐条 save） |
| (2) 音频层（镜像 AccentAudioTee） | `SpeakerAudioRing`：30s/16kHz 环形缓冲 + 绝对采样号；`AudioEngineDriver` tap 里与 accentTee 并联 append，`setSpeakerCapture(enabled:)` 与 accent 完全同构（reset/disable）；`SpeechManager` 在 startRecording/stopRecording 按设置开关启停 |
| (3) 端侧 CoreML 推理 + 在线聚类（纯逻辑可测） | `SpeakerEmbeddingModel*（failable init，AccentClassifier 同款；输入 waveform[1,64000] + numSamples[1,1]，输出 embedding[1,192]）；纯逻辑：`SpeakerWindowPolicy`（取窗/静音门限）、`SpeakerClusterer`（余弦 leader-follower，τ 可配、K≤4、EMA 质心 + 每 10 句平均链接全量重聚类）、`SpeakerLabeler`（老师/学生/说话人命名 + 投票滞后） |
| (4) UI 四处 | 录音页控制条 `speakerLabel`（当前说话人）；`SessionDetailView` 每段查看/编辑/清空 speaker；主转写前缀（`rebuildFinalizedText` + 实时 partial）；字幕悬浮窗前缀（`showStableCue(..., speaker:)`）。**全部经唯一 helper `SpeakerLabels.prefix`**（Lead 约束） |
| (5) 导出带说话人 | TXT：`bilingualTranscript` 加前缀；Word：`documentXML` 段落加前缀 — 同一 helper |
| (6) 设置开关 + 人数/灵敏度 | SettingsView 新 Section：开关默认**开**、最多说话人数 2...4（默认 4）、灵敏度 0.45...0.75（默认 0.60 = 阈值 τ）；`SpeakerDetectionConfiguration` 集中读写并夹取越界值 |
| (7) 模型缺失/失败降级 | `SpeakerEmbeddingModel.init?` 为 nil → `SpeakerEngine.canInfer` 恒 false → 段落无标签，只能在会话详情手动标注；单条推理失败 → 该段继承当前标签；**录音/翻译路径不经过说话人任何代码**（写窗在 tap 里旁路 append，开关关闭即为零成本） |

单元测试：**42 → 71**（`SpeakerDiarizationTests` 20 个 + `SpeakerSegmentCompatibilityTests` 9 个）。

## 2. 模型与前端来源（许可与归属）

- **CAM++ 说话人模型**：3D-Speaker `speech_campplus_sv_zh_en_16k-common_advanced`，
  ModelScope <https://www.modelscope.cn/models/iic/speech_campplus_sv_zh_en_16k-common_advanced>，
  **Apache-2.0**。本仓库中间产物（均为既有文件，未改动）：
  - checkpoint `Tools/speaker/models/campplus_cn_en_common.pt`
  - ONNX `Tools/speaker/models/campplus_zh_en_advanced.onnx`（sherpa 参考用）
  - fbank 输入版 mlpackage `Tools/speaker/models/SpeakerCAM++ZHEng.mlpackage`（方案 B 备用）
- **fbank 前端参考实现**（参数零猜测的依据）：
  - sherpa-onnx **1.13.8** PyPI sdist（`Tools/speaker/_sherpa_src/sherpa_onnx-1.13.8.tar.gz`，Apache-2.0）
  - kaldi-native-fbank **v1.22.3** 源码包（`Tools/speaker/_sherpa_src/kaldi-native-fbank-1.22.3.tar.gz`，
    SHA256 `9176cc66fc7ce1edf85cf355b06e320c57db6297df74277f575183468893cf61`，与 sdist 内 cmake pin 一致，Apache-2.0）
  - 关键参数（全部照抄源码）：dither=0、snip_edges=false、low_freq=20、high_freq=-400（7600Hz）、
    80 mel、25ms/10ms、FFT 512、povey 窗、preemph 0.97、use_power、log floor = float epsilon、
    逐句 global-mean CMN。
- 本任务**新增脚本**（均在 `Tools/speaker/`，不改动既有脚本与测试音频）：
  - `wave_wrapper.py` — torch 版波形包装（fbank + 掩码 CMN + CAM 层掩码 + 掩码统计池）
  - `verify_wave_wrapper.py` — vs sherpa 门槛校验（含 naive A/B 基线）
  - `convert_wave_wrapper_to_coreml.py` — trace + coremltools 转换（WSL 运行）
  - `verify_coreml_parity.py` — **仅 macOS**：CoreML 运行时 vs torch vs sherpa
- 应用内资源：`ClassroomTranslator/Resources/SpeakerCAMWaveZHEng.mlpackage`
  （Package.swift 已 .copy 注册；fp16 mlprogram，spec v9；输入 waveform[1,64000] float32 +
  numSamples[1,1] float32，输出 embedding[1,192] float16；metadata 含 modelSource/license/sampleRate）。

## 3. 方案 A 校验结果（Windows 可完成的部分）

`python Tools\speaker\verify_wave_wrapper.py`（sherpa-onnx 1.13.8 为参考，门槛 0.98）：

| clip | masked（本实现） | naive（报告原"补零到 400 帧"计划） |
| --- | --- | --- |
| fangjun-full(2.30s) | **0.9989** | 0.9116 |
| fangjun-short(1.20s) | **0.9995** | 0.7301 |
| fangjun-b(4.00s) | 1.0000 | 1.0000 |
| leijun(4.00s) | 1.0000 | 1.0000 |
| fourA-spk0(3.5s) | 0.9998 | 0.9617 |
| fourA-spk0(1.5s) | 0.9997 | 0.7910 |
| fourB-spk1(3.5s) | 0.9998 | 0.9610 |
| fourC-spk2(3.0s) | 0.9998 | 0.9380 |

同人/异人余弦分布与参考几乎一致（masked SAME mean 0.8131 vs 参考 0.8142；DIFF mean 0.2414 vs 0.2406），
说明 τ=0.6 的聚类阈值可以直接沿用。**朴素补零方案达不到 0.98，已被数据否决**（A/B 基线留在脚本里）。

关键实现点（也是 naive 方案翻车的原因）：

1. 固定 4s 图内**帧数是动态的** — 用 numSamples 标量推有效帧数 n（snip_edges=false 的
   clamp(floor((L-280)/160)+1, 0, 399)），所有按时间池化的操作都要带掩码：
   - CMN：对 n 个有效帧求均值并减掉（global-mean），无效行清零；
   - conv 深度掩码：f2(n) = floor((n-1)/2)+1（整个骨干只有 xvector.tdnn 降时间分辨率）；
   - **CAM 层**（monkeypatch，`wave_wrapper.py::_ensure_cam_patch`）：入口先按掩码清零
     （局部卷积与 seg_pooling 由此与短图一致），`x.mean(-1)` 换成掩码均值；
   - 统计池：掩码 mean + 无偏 std（对应 sherpa 的 StatsPool）。
2. 每个骨干子模块输出后按该深度的掩码清零 — 否则 BN 仿射 beta 会把无效区"点亮"，
   经过带时间卷积的层后污染边界帧。

**转换日志里唯一的 RuntimeWarning**（`elementwise_unary.py:889 overflow encountered in cast`）：
coremltools 的 fp16 pass 把 `clip` 上界 FLT_MAX 常量转成 +inf。语义等价（上界 +inf ≡ 3.4e38），
无信息损失，已用 np.seterr 定位确认，**属预期、无需处理**。
Linux/WSL 的 `Failed to load _MLModelProxy: No module named 'coremltools.libcoremlpython'` 同样无害
（只影响在 Linux 上打开 mlpackage，不影响转换与序列化）。

## 4. 设计决策记录（与报告 §4.2 的差异及原因）

- **尾窗而非头窗**：报告的"跨度 >4s 取 0–4s 头窗"假定句首时间戳已知；
  `onSegmentRecognized` 回调不带时间戳，我们把句尾近似为「final 落地 − 0.2s 迟滞」、
  句首近似为「上一个窗口末端」。刚说完的语音在**尾部**（而且要避开长静音后的下一个说话人），
  因此取尾部 4s — 这是同一规则在"边界可知"前提改变后的对偶形式。
  差异已进 Mac 回归清单（§5 第 6 条）。
- **固定图输入而非动态 T**：CAM++ 的 FCM/seg_pooling reshape 烘焙了 Python 层形状，
  动态 T 转换不可行（trace 实测）；固定 waveform[1,64000] + numSamples 标量 + 掩码是唯一稳路。
- **标签存"显示字符串"**：`TranscriptSegment.speaker` 存的是判定当时的本地化显示名
  （如「老师」），**不做跨语言重翻**（Lead 确认）。切换界面语言后，老记录保持原语言标签。
- **前缀格式唯一出口**：`SpeakerLabels.prefix` 输出 `"老师: "`（英文冒号 + 空格），
  渲染/字幕/导出/详情页一律调它，禁止散拼（Lead 约束，单测锁格式）。
- **回写节奏**：嵌入到标签变化的段落才写；每 10 条语句全量重聚类（平均链接 + τ + K≤4），
  命名用旧标签投票做滞后（老师时长差 <2s 且旧票占优不翻转，学生编号同理）；
  批量 `updateSpeakers` 只改内存，**落库交给现有 30s checkpoint / finishRecord**（Lead 约束）。
- **控制条只加纯 AppKit 控件**（NSTextField + detachesHiddenViews），未引入任何 SwiftUI 条件视图
  （macOS 26 NSHostingView 布局死循环红线），未触碰 RecordingActivity/侧栏锁。

## 5. Mac 验证清单（最终把关，按序执行）

1. **单测**：`swift test` → 71 个用例全绿（重点：旧 JSON 无 speaker 键 → nil、前缀格式、
   聚类 τ/K/EMA、命名与滞后、取窗策略、设置默认值）。
2. **前端门槛（torch）**：`python3 Tools/speaker/verify_wave_wrapper.py` → worst ≥ 0.98。
3. **CoreML 运行时端到端**：`python3 Tools/speaker/verify_coreml_parity.py`
   → coreml-vs-sherpa ≥ 0.98、coreml-vs-torch ≥ 0.99（此步只有 macOS 能做，Windows/WSL 无 CoreML 运行时）。
   若第 3 步不达标 → 走 §6 方案 B。
4. **构建运行**：`swift run`（或 Xcode）正常启动、正常录音翻译 — 说话人开关开/关两种情况都试。
5. **端到端体验**（可用 `Tools/speaker/models/0-four-speakers-zh.wav` 外放模拟多说话人）：
   - 第 2 句之后控制条出现「说话人：老师」这类标签；
   - 主转写每段带 `老师: 正文` 前缀；字幕悬浮窗原文行带前缀（截断不吞前缀）；
   - 会话详情可见/可改/可清空 speaker；TXT 与 Word 导出带前缀；
   - 连说 10 句触发重聚类时，字幕刷新不卡顿（回写在 MainActor 批量一次性完成）；
   - 教师长语音 + 学生短答场景下，长语音方最终为「老师」，学生按发言时长编号。
6. **取窗对偶规则回归**：长静音后学生「嗯」这类短答，应命中继承规则或尾窗规则
   （不能因为静音跨度大而把窗口开到静音里 — RMS 门限兜底）。
7. **降级路径**：把 App 包内 `SpeakerCAMWaveZHEng.mlpackage` 改名 → 启动录音，
   预期：无任何标签、录音与翻译完全正常、会话详情仍可手动标注 —
   这是 Lead 点名的硬约束。
8. **性能**：CPU 单窗推理应在几十 ms 量级（fp16、4s 窗）；若明显更慢，
   把 `SpeakerEmbeddingModel` 的 `computeUnits` 从 `.cpuOnly` 改 `.all` 再测（改动一行）。

## 6. 方案 B（回退路径，若 §5 第 3 步过不了）

前提判断：torch↔sherpa 已 0.99+（§3），若 CoreML 运行时数值不对，只可能是
转换/精度问题而非前端问题。回退顺序：

1. 用**既有的 fbank 输入版** `Tools/speaker/models/SpeakerCAM++ZHEng.mlpackage`
   （报告 §3.5 产物，输入 fbank[1,T,80]）+ **Swift 端 fbank**（按 §2 参数 kaldi 对齐）：
   - Swift fbank 逐帧实现（DFT 矩阵、povey 窗、mel 权重、log floor 可直接照抄
     `wave_wrapper.py` 的移植版，它是逐比特对齐过 sherpa 的）；
   - `SpeakerEmbeddingModel.embed` 改为：波形 → Swift fbank → CMN → 模型；
   - 取窗/聚类/命名/UI/导出/设置层**零改动**（它们只消费 [Float] 嵌入）。
2. fp16 可疑时先试 `--no-fp16` 重新转换（`convert_wave_wrapper_to_coreml.py --no-fp16`）。
3. 仍不过：核对输入绑定（numSamples 单位是"采样数"不是"帧数"）、`.cpuOnly` 下的
   布局转换（MLMultiArray 默认行主序，模型为 NHWC 约定已在 coremltools 侧处理）。
4. Mac 对齐步骤不变：`verify_coreml_parity.py --mlpackage <回退产物>` + §5 第 5 条体验项。

## 7. 已知限制 / 明确顺延

- 句子级时间戳不可得 → 窗口是近似（尾窗 + 迟滞 + RMS 门限），极端断句可能继承旧标签；
  有时间戳时可平滑升级（`SpeakerWindowPolicy.decision` 单点可改）。
- 会话最后一批段落若在页面销毁前未解析完成，保持临时标签（`shutDown` 先作废在途推理
  再 checkpoint，**绝不留下未落库的写**）。
- 设置修改对**下一次录音会话**生效（`activate` 时读取），会话中途改灵敏度不热更。
- 手动标注只在会话详情（任务条目 (7) 的降级面）；没有做录音页逐段打标 UI。
- 跨语言标签不重翻（Lead 确认的取舍，见 §4）。
