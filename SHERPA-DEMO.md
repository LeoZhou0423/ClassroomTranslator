# sherpa-onnx 语音链路验证报告（Windows 本机 demo + macOS Swift 接入调研）

> 范围：仅新增本文件与 `Tools/sherpa/` 下的脚本/模型；未改动项目其他文件。
> 环境：Windows 11（26200），Intel Core Ultra 9 285H（16 逻辑核），31.4 GB RAM，
> Python 3.12.14（DSH 自带 runtime），sherpa-onnx **1.13.8**（PyPI LATEST 即此版本）。

---

## 一、结论速览

1. **本机 demo 跑通** ✅：英语流式 zipformer（int8，73.6 MB）与中英双语流式 zipformer（int8，198.5 MB）
   两个模型均从 hf-mirror 下载成功并跑通 wav → sherpa-onnx → 转录文本。
   - **聚合 RTF ≈ 0.038**（2 线程、CPU、greedy_search），即 1 秒音频约 38 ms 计算。
   - **英语客观质量**：LibriSpeech 测试句 WER **5.6% / 2.1%**（0.wav / 1.wav，追加 1s 静音后最后一词恢复完整）。
   - **中文主观质量**：短句可用（"我们要做一个说话人识别的测试" 完全正确），长音频词汇正确但有**口吃式重复、无标点**。
   - **流式**：0.32 s chunk 下单次解码 **12–14 ms**（远小于 320 ms 实时预算，余量 ~23×）；
     首个 partial 在**消耗 1.12–1.28 s 音频**后出现（模型需要上下文，非算力瓶颈）。
2. **Swift 接入推荐（一句话）**：**用官方 SPM 包**（仓库根 `Package.swift`，swift-tools 5.9，
   `binaryTarget` 指向 v1.13.8 `macos-static.xcframework` 11.6 MB + 依赖 `csukuangfj/onnxruntime-libs`
   1.28.2 静态 xcframework 23.7 MB），Swift 层直接用仓库自带的 `swift-api-examples/SherpaOnnx.swift`
   薄封装（`import SherpaOnnxC`）；**静态链接、无嵌入 dylib，最适合 ad-hoc 签名 + dmg 分发**。
   不需要自己 vendored 静态库，也不需要自己打 xcframework。

### 产出物
| 路径 | 说明 |
|---|---|
| `Tools/sherpa/asr_demo.py` | 主 demo：全量解码 + 分块流式，输出耗时/RTF/WER/文本 |
| `Tools/sherpa/latency_probe.py` | chunk 尺寸扫描（0.08–0.64 s）+ 结尾静音修复验证 |
| `Tools/sherpa/download_models.py` | 从 hf-mirror 下载 EN/ZH 流式模型（github/hf 直连不通） |
| `Tools/sherpa/fetch_macos_xcframework.py` | 经 api.github.com release asset 端点下载 macOS xcframework |
| `Tools/sherpa/inspect_xcframework.py` / `probe_libs.py` / `probe_libs2.py` | 解包检查切片/modulemap/onnxruntime 链接方式 |
| `Tools/sherpa/inspect_assets.py` | wav 元数据与模型体积清单 |
| `Tools/sherpa/models/` | 下载的模型（EN 73.6 MB + ZH 198.5 MB） |
| `Tools/sherpa/models/_macos_check/` | macOS xcframework 样本（static 11.6 MB / shared 3.6 MB） |

**复现命令**（Python 为 `C:\Users\uking\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe`）：
```bash
python -m pip install sherpa-onnx            # 本机已满足 1.13.8
python Tools/sherpa/download_models.py       # ~273 MB，来自 hf-mirror
python Tools/sherpa/asr_demo.py --model en
python Tools/sherpa/asr_demo.py --model zh   # 中文输出需 PYTHONIOENCODING=utf-8 否则控制台乱码
python Tools/sherpa/latency_probe.py --model en
```

---

## 二、任务 A：Windows 本机 ASR 实测

### A0 安装（pip）

```
$ python -m pip install sherpa-onnx
Requirement already satisfied: sherpa-onnx ... (1.13.8)          # 本机此前已安装
Requirement already satisfied: sherpa-onnx-core==1.13.8 ...

$ python -m pip index versions sherpa-onnx
sherpa-onnx (1.13.8)   LATEST: 1.13.8     # pypi.org 可达，无需镜像

$ python -m pip install sherpa-onnx --dry-run --ignore-installed
Downloading sherpa_onnx-1.13.8-cp312-cp312-win_amd64.whl.metadata (54 kB)
Downloading sherpa_onnx_core-1.13.8-py3-none-win_amd64.whl.metadata (532 bytes)
Would install sherpa-onnx-core-1.13.8 sherpa_onnx-1.13.8
```
- **Windows wheel 存在**（win_amd64，cp312）。因本机已安装，未实际执行全新安装，**未触发镜像回退**；
  清华/阿里镜像未测试（仅作为备用，未验证）。
- 包内自带推理运行时（`Lib/site-packages/sherpa_onnx/lib/`）：
  `_sherpa_onnx.cp312-win_amd64.pyd` 5.8 MB、**`onnxruntime.dll` 17.8 MB**、
  `sherpa-onnx-c-api.dll` 4.6 MB、`sherpa-onnx-cxx-api.dll` 0.26 MB；
  头文件 `include/sherpa-onnx/c-api/c-api.h`（172,380 B）与 `cxx-api.h`（69,049 B）随包分发（任务 B 直接用了它）。

### A1 模型选型与下载

| 项 | 英语流式 | 中英双语流式 |
|---|---|---|
| 仓库（hf-mirror） | `csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26` | `csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20` |
| 采用文件 | encoder/decoder/joiner `*-chunk-16-left-128.int8.onnx` + `bpe.model` + `tokens.txt` | encoder/decoder/joiner `*.int8.onnx` + `bpe.model` + `tokens.txt` |
| **体积（目录合计）** | **73,647,280 B ≈ 70.2 MiB**（encoder 71.08 MB 占绝对主体） | **198,515,925 B ≈ 189.3 MiB**（encoder 181.9 MB） |
| **license** | **apache-2.0**（HF cardData 实测） | **apache-2.0**（HF cardData 实测） |
| 来源说明 | README：模型来自 icefall-asr-librispeech-streaming-zipformer-2023-05-17（[icefall PR #1058](https://github.com/k2-fsa/icefall/pull/1058)） | icefall stateless7 streaming zh |
| 下载地址 | https://hf-mirror.com/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26 | https://hf-mirror.com/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20 |

- **ModelScope 不可用**：`/api/v1/models/csukuangfj/...` 返回 404 "record not found"
  （实测 EN/ZH/zipformer-en 三个候选仓库均不存在），**改走 hf-mirror 成功**。
- 非 int8 版本 EN encoder 262 MB / ZH encoder 330 MB，未下载（体积翻倍，收益小）。
- 英语音频：**不用合成**——`Tools/accent/models/accent-id-commonaccent_ecapa/data/` 有 13 段 16 kHz 英语
  （us/england/indian/… 口音样本），另有模型自带 LibriSpeech 测试句（带参考文本，可算 WER）。
  因此**"英语待 Mac 实测"的情形未发生**，英语链路本机已验证。

### A2 运行输出摘录

```
$ python Tools/sherpa/asr_demo.py --model en
== env: python 3.12.14 | sherpa-onnx 1.13.8 | Windows-11-10.0.26200-SP0
== model=en threads=2 chunk=0.32s
== model load: 1.645s, core model size: 72.7 MB

-- .../test_wavs/0.wav
   audio 6.62s | full-decode warm 259ms (avg 261ms of 3) | RTF 0.0392 | cold 260ms
   TEXT: AFTER EARLY NIGHTFALL THE YELLOW LAMPS WOULD LIGHT UP HERE AND THERE THE SQUALID QUARTER OF THE BROTHEL
   WER vs reference: 5.6%  (ref: ... THE SQUALID QUARTER OF THE BROTHELS)
   STREAM[0.32s chunk]: chunks=21 first-partial-wall=41ms first-partial-after-audio=1.28s
                        partials=16 decode-sum=271ms chunk-avg=12.9ms chunk-max=20.0ms stream-RTF=0.0409

-- .../test_wavs/1.wav
   audio 16.71s | full-decode warm 665ms | RTF 0.0398
   WER vs reference: 2.1%
   TEXT: GOD AS A DIRECT CONSEQUENCE OF THE SIN WHICH MAN THUS PUNISHED HAD GIVEN HER A LOVELY CHILD ... BLESSED SOUL IN HE
== aggregate warm full-decode: audio 80.94s, decode 3081ms, RTF 0.0381
```

```
$ python Tools/sherpa/asr_demo.py --model zh    # 已设 PYTHONIOENCODING=utf-8
== model=zh threads=2 chunk=0.32s | model load: 1.070s, core model size: 198.3 MB

-- Tools/speaker/models/fangjun-sr-2.wav   audio 5.17s | warm 186ms | RTF 0.0359
   TEXT: 我们要做一个说话人识别的测试                       # 与已知内容一致
-- Tools/speaker/models/leijun-sr-1.wav     audio 4.20s | warm 149ms | RTF 0.0354
   TEXT: 这是我第四次颁连度演讲                             # 应为"年度/连度"类，形近错
-- Tools/speaker/models/fangjun-sr-1.wav    audio 2.30s | warm 74ms  | RTF 0.0324
   TEXT: 今天是星星起二                                     # 无参考文本，主观可疑
-- Tools/speaker/models/0-four-speakers-zh.wav  audio 56.86s | warm 2213ms | RTF 0.0389
   TEXT: 这是一个测测试说话的日日志志明的音频频下面我们来来播放一些测试试音音频道悲歌的时候请就站在阳台上吹吹风...（长，见脚本输出）
== aggregate warm full-decode: audio 68.53s, decode 2622ms, RTF 0.0383
```

### A3 数据表（全量解码，threads=2，warm 取 3 次最小值）

**英语**（`asr_demo.py --model en`，合计 80.94 s 音频 / 3081 ms 计算 / **RTF 0.0381**）

| 音频 | 时长 | warm 耗时 | RTF | WER | 备注 |
|---|---|---|---|---|---|
| test_wavs/0.wav（LibriSpeech） | 6.62 s | 259 ms | 0.0392 | **5.6%** | 未补静音时末词被截断（BROTHERL） |
| test_wavs/1.wav（LibriSpeech） | 16.71 s | 665 ms | 0.0398 | **2.1%** | 末词同样差一个字母 |
| accent 口音样本 ×13（2.16–7.32 s） | 合计 57.6 s | 76–282 ms | 0.034–0.041 | 无参考 | 见下"主观评价" |

**中文**（`--model zh`，合计 68.53 s / 2622 ms / **RTF 0.0383**）

| 音频 | 时长 | warm 耗时 | RTF | 质量主观 |
|---|---|---|---|---|
| 0-four-speakers-zh.wav | 56.86 s | 2213 ms | 0.0389 | 词汇基本正确，**口吃式重复**（"测测试""日日志志明"）、无标点、说话人混在一起 |
| fangjun-sr-2.wav | 5.17 s | 186 ms | 0.0359 | ✅ 完全正确 |
| leijun-sr-1.wav | 4.20 s | 149 ms | 0.0354 | 大意正确，形近字错（"颁连度"） |
| fangjun-sr-1.wav | 2.30 s | 74 ms | 0.0324 | ⚠️ 疑似识别错 |

- 模型加载：EN **1.65–1.74 s**、ZH **1.00–1.07 s**（进程内一次性）。
- 冷/热差异可忽略（cold 260 ms vs warm 259 ms）——session 建立开销在 warm-up 已摊销。

### A4 流式（chunked）延迟数据

喂法：按固定 chunk 把波形喂入 `OnlineRecognizer`（不 sleep，喂得比实时快），
`first-partial-after-audio` = 出现首个非空 partial 时**已消耗的音频时长**（算法延迟），
`first-partial-wall` = 从开始到出字的墙钟时间（≈纯计算耗时）。

**英语 chunk 扫描**（`latency_probe.py --model en`）

| chunk | 首 partial（消耗音频）0.wav | 1.wav | us_1 | 单 chunk 解码均值 | stream RTF |
|---|---|---|---|---|---|
| 0.08 s | 1.12 s | 1.12 s | 1.44 s | **3.4 ms** | 0.043 |
| 0.16 s | 1.12 s | 1.12 s | 1.44 s | 7.1 ms | 0.045 |
| 0.32 s | 1.28 s | 1.28 s | 1.60 s | 14.1 ms | 0.045 |
| 0.64 s | 1.28 s | 1.28 s | 1.92 s | 27.7 ms | 0.046 |

**中文（chunk=0.32 s）**：首 partial 出现在消耗 **0.64–1.28 s** 音频后；单 chunk 解码 **9.6–14.2 ms**；
56.86 s 长音频 decode-sum 2211 ms（stream RTF 0.0389），partial 更新 91 次。

结论：
- **算力不是延迟瓶颈**：14 ms 计算 vs 320 ms 实时预算（23× 余量）；就算 chunk 缩到 80 ms 也只有 3.4 ms。
- **模型上下文决定首字延迟 ≈ 1.1–1.3 s**（缩 chunk 只能从 1.28 s 优化到 1.12 s）。
  若产品需要"更快出字"，得换模型或做更激进的部分结果策略——**这是与 Apple SpeechAnalyzer 对比时的关键指标**。
- `first-partial-wall ≈ 40–60 ms`：出字所需纯计算时间。

### A5 已验证的工程细节

1. **结尾丢字**：`input_finished()` 后直接 drain 仍会丢最后一个词/字
   （0.wav 输出 `...BROTHERL`，参考为 `BROTHELS`）。**在音频尾部补 1.0 s 静音即可恢复**
   （`latency_probe.py` 实测：`+1.0s sil → ...BROTHELS`）。实时流式场景下靠 endpoint/尾静音自然解决。
2. **编码**：全部测试 wav 均为 16 kHz / 单声道 / 16-bit，无需重采样；PowerShell 控制台默认 GBK，
   中文输出需 `$env:PYTHONIOENCODING="utf-8"`（或 chcp 65001）。
3. **标点**：sherpa-onnx 自带 offline/online **punctuation** 能力
   （`c-api.h` 文档页与 swift 例程 `add-punctuation-online.swift` 均存在，模型需另下，**本次未跑，未验证**）。

### A6 说话人（对照，复用现有 CAM++ 方案，未新做）

现有 `Tools/speaker/test_diarization.py` 本身就是 **sherpa-onnx Python API + pyannote 切分 + CAM++ embedding**，
直接运行即得同 wav 对照数据（**未修改该文件**）：

```
[emb] fangjun-sr-1.wav: dur=2.30s dim=(192,) infer=32ms
[emb] fangjun-sr-2.wav: dur=5.17s dim=(192,) infer=66ms
[emb] leijun-sr-1.wav : dur=4.20s dim=(192,) infer=56ms
[emb] cosine: SAME fangjun1-fangjun2 0.8088 | DIFF fangjun1-leijun 0.2490 | DIFF fangjun2-leijun 0.3284
[diar] audio=56.86s wall=4.88s RTF=0.0858 | segments=10 speakers=4
```
- 单条 embedding 32–66 ms（192 维），四说话人文件上聚类出 4 个说话人、10 段，端到端 RTF 0.086。
- 即：**sherpa-onnx 的 embedding 提取器可直接吃现有的 `campplus_zh_en_advanced.onnx`**，无需另找 3dspeaker 模型。
- 结论：说话人部分无需为 sherpa 重做，已有脚本即可复用。

---

## 三、任务 B：macOS Swift 接入调研

> 本环境 github.com / huggingface.co 不通；**api.github.com、raw.githubusercontent.com、hf-mirror.com、
> www.modelscope.cn、k2-fsa.github.io 均可用**。release 资产可通过
> `https://api.github.com/repos/<owner>/<repo>/releases/assets/<id>` + `Accept: application/octet-stream`
> 下载（**已实测成功取回 11.6 MB 的 macOS xcframework**）。

### B1 集成方式：SPM 官方支持（已验证，非假设）

**证据 1 — 仓库根有 `Package.swift`**（6,091 B，swift-tools 5.9，经 api.github.com contents 端点读取全文）：
- `platforms: [.iOS(.v15), .macOS(.v10_15)]` → **macOS 15/26 完全覆盖**，Swift 6 可直接消费 tools 5.9 包。
- products：`sherpa-onnx`（静态 xcframework，默认）、`sherpa-onnx-shared`（动态）。
- `binaryTarget` 指向 **GitHub release 的 `xcframework` tag**，例：
  `https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-macos-static.xcframework.zip`
  （checksum 已写死在 Package.swift）。
- 依赖 `csukuangfj/onnxruntime-libs` **exact 1.28.2**（同样是 SPM binaryTarget）。
- 源码 target 直接把 `swift-api-examples/SherpaOnnx.swift`（69 KB 封装）作为库源，`linkerSettings: [.linkedLibrary("c++")]`。

**证据 2 — 官方 iOS 示例工程就是这么用的**（`ios-swift/SherpaOnnxAsr/.../project.pbxproj`）：
```
XCRemoteSwiftPackageReference "sherpa-onnx"
  repositoryURL = "https://github.com/k2-fsa/sherpa-onnx";
  requirement = { kind = exactVersion; version = 1.13.8; };
productName = "sherpa-onnx";
```

**证据 3 — xcframework 实物已下载解包**（`_macos_check/`，经 api.github.com asset 端点）：

| 资产（release tag `xcframework`，v1.13.8） | zip 体积 | 解包后 | 结构 |
|---|---|---|---|
| `sherpa-onnx-v1.13.8-macos-static.xcframework.zip` | **11.6 MB** | 43.75 MB | 单切片 `macos-arm64_x86_64`（**arm64+x86_64 双架构 fat**），`SherpaOnnxC.framework` 含 `Headers/sherpa-onnx/c-api/c-api.h`(167,657 B) + `Modules/module.modulemap` |
| `sherpa-onnx-v1.13.8-macos-shared.xcframework.zip` | **3.6 MB** | 8.9 MB | 同上切片，二进制为 8.74 MB Mach-O dylib |
| `sherpa-onnx-v1.13.8-macos-shared-onnxruntime-static.xcframework.zip` | **18.3 MB**（未下载） | – | 按命名应为"dylib + ORT 静态内置"（**未验证假设**） |
| ios 侧：`ios-static` 17.0 MB / `ios-shared` 6.2 MB / `ios-shared-onnxruntime-static` 31.9 MB | – | – | – |

`module.modulemap` 内容（实测）：
```
framework module SherpaOnnxC {
  header "sherpa-onnx/c-api/c-api.h"
  export *
}
```
`SherpaOnnx.swift` 开头：`#if SWIFT_PACKAGE / import SherpaOnnxC / #endif`。

**结论**：SPM **直接可用**（Xcode Add Package Dependency 或 `Package.swift` 里加
`.package(url:"https://github.com/k2-fsa/sherpa-onnx", exact: "1.13.8")` + product `sherpa-onnx`）。
无需自己 vendored 静态库+modulemap，无需自己打 xcframework；这两种是"离线/无网构建"时才需要的兜底路。

### B2 核心 C API 与最小调用序列

头文件清单（`sherpa-onnx/c-api/`，api.github.com 目录树 + 本地 pip 包双源核对）：
| 文件 | 大小 | 用途 |
|---|---|---|
| `c-api.h` | 169,199 B（仓库）/ 172,380 B（pip 1.13.8）/ 167,657 B（xcframework 内） | **唯一需要的 C 头**，稳定 C ABI |
| `cxx-api.h` | 67,563 B | C++ RAII 封装（Swift 用不到） |
| `c-api.cc` / `cxx-api.cc` | 118 KB / 57 KB | 实现 |
| `sherpa-onnx-symbols-c.exp/.lds` | – | 符号导出控制 |
| `mainpage.md` / `Doxyfile` / `docs/` | – | doxygen 文档：https://k2-fsa.github.io/sherpa/onnx/c-api/html/index.html （实测 200） |

**流式识别最小调用序列**（函数名与签名均已核对本地 `c-api.h`，含行号）：
1. `SherpaOnnxOnlineRecognizerConfig cfg`：`feat_config`、`model_config`
   （`encoder/decoder/joiner/tokens` 路径、`provider="cpu"`（头文件注释：`"cpu","cuda","coreml"`）、`num_threads`）、
   `decoding_method="greedy_search"`、endpoint 三规则（`rule1/2/3`）。
2. `const SherpaOnnxOnlineRecognizer *SherpaOnnxCreateOnlineRecognizer(&cfg)`  — 行 346 结构体 / 400+ 创建
3. `SherpaOnnxCreateOnlineStream(recognizer)`（行 510；销毁 `SherpaOnnxDestroyOnlineStream` 行 543）
4. `SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, const float *samples, int32_t n)`（行 566，样本范围 [-1,1]；
   官方注释示例 chunk_size=3200 = 0.2 s）
5. `while (SherpaOnnxIsOnlineStreamReady(rec, stream)) SherpaOnnxDecodeOnlineStream(rec, stream);`（行 578 / 603）
6. `const SherpaOnnxOnlineRecognizerResult *r = SherpaOnnxGetOnlineStreamResult(rec, stream)` → `r->text`
   → 用完 `SherpaOnnxDestroyOnlineRecognizerResult(r)`（行 661）
   （JSON 变体：`SherpaOnnxGetOnlineStreamResultAsJson` 行 679 + `SherpaOnnxDestroyOnlineStreamResultJson` 行 694）
7. 分句：`SherpaOnnxOnlineStreamIsEndpoint(rec, stream)` → `SherpaOnnxOnlineStreamReset(rec, stream)`（行 706/711）
8. 结束：`SherpaOnnxOnlineStreamInputFinished(stream)`（行 726）→ drain → 销毁 stream →
   `SherpaOnnxDestroyOnlineRecognizer`（行 489）
9. 工具：`SherpaOnnxReadWave(filename)`（行 2879，仅示例用；正式 app 建议自己从 AVAudioEngine 喂）

Swift 侧现成封装（`swift-api-examples/SherpaOnnx.swift`，随 SPM target 暴露）：
`SherpaOnnxRecognizer`（在线）——`init(config:)` 内部即完成 2+3；
方法 `acceptWaveform(samples:sampleRate:)` / `isReady()` / `decode()` / `getResult()` /
`reset(hotwords:)` / `inputFinished()` / `isEndpoint()`；`deinit` 自动释放。
⚠️ 它**默认一个实例持有一条 stream**（多路并发需直接用 C API 或多实例——会重复加载模型）。

### B3 许可证

| 对象 | 许可证 | 来源/URL | 验证状态 |
|---|---|---|---|
| sherpa-onnx 代码 | **Apache-2.0** | https://github.com/k2-fsa/sherpa-onnx/blob/master/LICENSE （文件头 "Apache License Version 2.0, January 2004"） | ✅ 已读文件核对 |
| EN 流式模型 | **apache-2.0** | https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26 （镜像 https://hf-mirror.com/…）；源自 icefall librispeech streaming zipformer | ✅ HF API `cardData.license` 实测 |
| ZH 双语流式模型 | **apache-2.0** | https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20 | ✅ 同上 |
| onnxruntime 本体 | MIT（业界常识） | https://github.com/microsoft/onnxruntime/blob/main/LICENSE | ⚠️ **未在本环境验证内容**（假设） |
| csukuangfj/onnxruntime-libs 打包仓库 | 未核对 | https://github.com/csukuangfj/onnxruntime-libs | ⚠️ 未验证 |
| 项目既有 CAM++/pyannote | 见 `Tools/speaker/thirdparty/ATTRIBUTION.md` | 本仓库既有 | 未改动 |

### B4 与 onnxruntime 的依赖关系（二进制级实测）+ 签名影响

| 变体 | 实测结论 |
|---|---|
| **Windows pip wheel** | ORT 是**独立 DLL**：`lib/onnxruntime.dll` 17.8 MB，与 `sherpa-onnx-c-api.dll` 分离 |
| **macos-static（默认，SPM 推荐）** | 43.6 MB fat 静态库；**无 dylib 引用、无 ORT 代码标记** → ORT 必须由 `onnxruntime-libs`（静态 xcframework，zip **23.7 MB**）另行链接 → **最终全部静态进主二进制，0 个嵌入 dylib** |
| **macos-shared** | 8.74 MB dylib，**明确依赖 `@rpath/libonnxruntime*.dylib`**（二进制里能扫到该路径）→ 需要嵌入 onnxruntime shared（zip 17.5 MB）+ SherpaOnnxC.framework |
| macos-shared-onnxruntime-static | 18.3 MB zip，未下载（按命名推断为"dylib 内静态含 ORT"，**未验证假设**） |

**对 ad-hoc 签名 + dmg 分发的影响**（分析，非本机实测）：
- ✅ **走默认静态产品**：app 只有一个二进制 + 资源，`codesign -s -` 一次完成，没有
  "嵌入 dylib 与主 app 签名不一致 / Library Validation"问题；**不需要 `--deep`**（--deep 反而不推荐）。
- ⚠️ 若走 shared 变体：每个嵌入 framework/dylib 都要签，ad-hoc 下能跑，但一旦将来要公证（notarization）
  必须统一 Developer ID；hardened runtime + library validation 只允许同 team 的库。
- ⚠️ 体积（**未验证假设**）：静态链接后 app 二进制预计增加约 20–40 MB（43.6 MB .a + 23.7 MB ORT zip 中被实际引用的部分）；
  模型文件（70 MB 英 / 189 MB 中）作为资源另行打包或首启下载。
- 依赖版本被 `exact: "1.28.2"` 锁定，升级 sherpa 时需同步看它的 Package.swift。

### B5 工作量与风险预估（macOS 15+/26 + Swift 6）

**工作量（MVP，1 名 Swift 开发）≈ 5–7 人日**：
| # | 事项 | 估时 |
|---|---|---|
| 1 | SPM 加包 + `SherpaOnnx.swift` 冒烟（跑通 test-version / decode-file 等价逻辑） | 0.5 d |
| 2 | 在现有 SpeechAnalyzer 之上抽象 `ASREngine` 协议的 sherpa 实现：AVAudioEngine tap → 48k→16k 重采样 → float32 [-1,1] → chunk 喂入 → partial/final 回调 + endpoint 分句 | 1.5–2 d |
| 3 | 模型资源管理（随 app 打包 / 首启下载 + SHA 校验） | 0.5–1 d |
| 4 | 与 SpeechAnalyzer 的切换、兜底策略、状态同步 | 1 d |
| 5 | （可选）标点后处理接入 | 0.5–1 d |
| 6 | 真机/录屏回归 + 性能基线（RSS、RTF、首字延迟） | 1 d |

**风险清单**：
1. **首字延迟 1.1–1.3 s**（模型上下文决定，非算力）——与 SpeechAnalyzer 对比时的体验差异点（中）。
2. **中文长音频口吃重复 + 无标点**——需要标点模型或后处理，且可能要调 endpoint 规则（中高）。
3. **Swift 6 并发**：C API 指针非 `Sendable`，识别器/stream 必须单线程持有（actor 或
   final class + 锁）；`SherpaOnnx.swift` 自带 `NSLock` 但只保护 stream 替换（中）。
4. **内存**：ZH int8 模型文件 198 MB，运行时 RSS 未知（**未验证**，Mac 上需用 Instruments 实测）。
5. **二进制体积增长 20–40 MB**（未验证估算）+ 模型 70/189 MB（中）。
6. 双架构 arm64+x86_64 都在 fat slice（✅ 已验证）→ Intel Mac 不掉队；但 iOS/macOS 两套 xcframework 都要 SPM 自动选。
7. 构建期 SPM 需访问 github.com（Mac 正常；离线/受限网络需 vendored 兜底）（低）。
8. `exact` 版本锁定（sherpa 1.13.8 ↔ onnxruntime-libs 1.28.2）（低）。
9. ad-hoc + dmg 在其他 Mac 上仍会被 Gatekeeper 拦——这是**现有分发方式固有**，静态链接不新增风险（既有）。

---

## 四、Mac 侧验证清单（按顺序执行）

1. **SPM 冒烟**：Xcode → Add Package Dependency → `https://github.com/k2-fsa/sherpa-onnx`，
   version `1.13.8`（或 Package.swift 里 `exact`），product `sherpa-onnx`；
   编译官方例程（`swift-api-examples/test-version.swift` 逻辑）确认 `import` 与链接通过。
2. **确认链接形态**：`codesign -dv --verbose=4 YourApp.app` + `otool -L YourApp`：
   静态路线应**无** `SherpaOnnxC`/`onnxruntime` 的 dylib 依赖；`lipo -info` 看二进制架构。
3. **模型就位**：把 `Tools/sherpa/models/` 两个目录拷进 app Resources（或下载脚本移植），
   跑文件解码对照本报告文本（EN 0.wav 应得 `...BROTHELS`，补静音后）。
4. **性能基线**（同一台 Mac）：模型加载秒数、全量 RTF（对照本机 0.038）、
   0.32 s chunk 下单次解码 ms、**首字延迟（消耗音频秒数）**、峰值 RSS（Instruments Allocations）。
5. **实时管线**：AVAudioEngine input tap（48 kHz）→ 重采样 16 kHz → float32 [-1,1] →
   0.16–0.32 s chunk 喂入；验证 endpoint 分句（`rule1/2/3` 按课堂语速调参）。
6. **A/B 对照**：同一段课堂录音分别过 SpeechAnalyzer 与 sherpa，对比字错率/延迟/标点/说话人切分。
7. **试 CoreML EP**：`provider="coreml"`（`c-api.h` 注释允许）看是否比 CPU 快——**未验证，需实测**。
8. **签名与分发**：`codesign -s -`（ad-hoc）→ 打 dmg → 在干净 Mac 上验证启动与首启模型加载；
   确认无需 `--deep`、无嵌入 dylib。
9. **（可选）标点模型**、**（可选）双引擎切换兜底**的故障注入测试。

---

## 五、风险与未验证项（诚实清单）

| 状态 | 项 |
|---|---|
| ❌ 未验证 | 静态链接后 app 体积增量（估 20–40 MB）、ZH 模型运行时 RSS、CoreML EP 提速、标点模型效果 |
| ❌ 未验证 | `macos-shared-onnxruntime-static` 资产内部结构（未下载）；清华/阿里 pip 镜像（未触发） |
| ❌ 未验证 | onnxruntime / onnxruntime-libs 的具体许可证文本（未读取） |
| ⚠️ 已知局限 | 中文长音频口吃重复、无标点；短句偶发错识；英语末词需尾静音兜底 |
| ⚠️ 已知局限 | Swift 封装 `SherpaOnnxRecognizer` 单实例单 stream（多路并发需 C API） |
| ✅ 已实测 | Windows wheel、hf-mirror 下载、EN/ZH 转录与 RTF/WER、流式 chunk 延迟、xcframework 下载与解包、modulemap、静态/动态链接差异、SPM 与示例工程引用、Apache-2.0 |
| ℹ️ 本环境网络 | api.github.com ✓ / raw.githubusercontent.com ✓（偶发失败）/ hf-mirror ✓ / modelscope 页面 ✓ 但**该镜像仓库不存在** / github.com releases 直连 ✗（可用 api asset 端点替代） |
