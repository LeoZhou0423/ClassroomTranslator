# 说话人区分（Speaker Diarization）端侧开源模型选型与可行性实测

> 调研日期：2026（本机 Windows 主机实测 + 来源网页核验）。所有「实测」均有命令输出摘录，未找到来源的结论标注**未验证假设**。
> 本机环境：Windows / Python 3.12.14（numpy/coremltools 9.0/onnx 1.23/onnxruntime 1.30/torch 2.14.0+cpu/onnx2pytorch 0.6.0/onnx2torch 1.5.15/sherpa-onnx 1.13.8 均为本次安装）。

---

## 1. 结论速览

**主选：3D-Speaker CAM++（zh_en advanced，Apache-2.0）声纹 embedding 模型 —— 走「ModelScope 原始 checkpoint → torch.jit.trace → coremltools → .mlpackage」路径，产物 `SpeakerCAM++ZHEng.mlpackage` 已在本机（WSL）实测转换成功（13.8MB, FP16, 输入 fbank[1,400,80] → 输出 embedding[1,192]），配套 Silero VAD（MIT，可选门控）与 Swift 端增量聚类（余弦阈值 ≈0.6），完全离线；备选：sherpa-onnx 全 ONNX 预置管线（Apache-2.0 代码 + MIT 分割/VAD + Apache-2.0 embedding，约 33MB），不做 CoreML 转换、直接以 ONNX Runtime/sherpa 原生库集成，作为 CoreML 路线受阻时的兜底。**

三个硬结论：

1. **coremltools 9.0 已彻底移除 ONNX 导入**（`ModuleNotFoundError: No module named 'coremltools.converters.onnx'`，实测）；ONNX→CoreML 只能经 torch 中转，且 onnx2pytorch/onnx2torch 对 CAM++ 图均失败（见 §3.3）——**最终走原始 checkpoint 路径成功**。
2. **Windows 上无法完成 mlprogram 导出**：PyPI coremltools 9.0 只发布 macOS/manylinux wheel（无 win wheel），Windows 从 sdist 构建缺 `libmilstoragepython`（BlobWriter），`ct.convert` 在最后序列化一步 `RuntimeError: BlobWriter not loaded`。**绕行：WSL(ubuntu) + manylinux wheel，已实测跑通**（本产物即由此产出）。macOS 上转换天然可用（项目现有 Tools/accent/convert_accent_to_coreml.py 即为该模式）。
3. **推理成本对课堂场景绰绰有余**（本机单线程 onnxruntime 实测）：CAM++ 每秒音频约 13~15ms（2s 窗 26ms、4s 窗 49ms）；Silero VAD 每 512 样本 0.1ms（RTF 0.004）；完整 diarization（pyannote 分割+CAM+++聚类）对 56.9s 中文四说话人音频 RTF=0.093。句级方案每句只算 1 次 embedding，负担更低。

---

## 2. 候选对比表

| 候选 | 代码 / 模型 License（来源） | 模型体积 | 输入格式 | 现成 ONNX | 准确率证据 | 转换可行性（本机实测） | 结论 |
|---|---|---|---|---|---|---|---|
| **① 3D-Speaker CAM++（zh_en advanced）** | 代码 Apache-2.0（GitHub LICENSE 实测）；**模型卡 Apache License 2.0**（ModelScope API 实测） | ONNX 27.0MB / checkpoint 26.7MB / CoreML(FP16) 13.8MB | 16kHz，log-mel fbank [N,T,80]（10ms hop），输出 192 维 | ✓（sherpa-onnx release 官方导出，opset 13） | 官方基准 EER：VoxCeleb1-O 0.65% / CNCeleb 6.78% / 3D-Speaker 7.75%（7.2M 参数，3D-Speaker README 表）；本地实测同人余弦 **0.81** vs 异人 **0.25/0.33** | ONNX 直转 ✗（§3.3）；**checkpoint→torch→CoreML ✓（§3.5，产物已生成）** | **主选** |
| ② sherpa-onnx speaker-diarization 预置组合 | 代码 Apache-2.0（LICENSE 实测）；pyannote segmentation-3.0 **MIT**（tarball LICENSE=CNRS MIT；HF 卡 cardData.license="mit"）；VAD Silero **MIT**；embedding 同① | 分割 5.7MB(int8 1.5MB) + embedding 27MB + VAD 0.6MB ≈ **33MB** | 16kHz wav；全套 ONNX | ✓（sherpa 官方发布 tar 包） | 本地跑官方 4 说话人中文测试音频，输出与官方文档**逐段一致**（§3.6），RTF 0.093 | 无需转换即可用；若要进 CoreML 则同① | **备选**（不转换的兜底） |
| ③ Silero VAD | **MIT**（LICENSE 文件实测；README 徽章 alt 文本残留 "CC BY-NC 4.0" 但徽章链接即 MIT LICENSE，正文声明 "Published under permissive license (MIT)"，以 LICENSE 为准） | k2-fsa 导出 629KB(16k-only) / int8 208KB；官方 v5 2.22MB(8k+16k) | 每 512 采样一步，输入 x[1,512] + LSTM h/c[2,1,64]，输出语音概率 | ✓ | 官方：<1ms/chunk 单线程；本地实测 0.1ms/512 样本，RTF 0.004 | LSTM 状态模型→CoreML **未实测**（受同一 BlobWriter 限制，WSL 可转但本次未做） | **可选组件**（句级方案可先用能量门控替代） |
| ④ WeSpeaker | 代码 Apache-2.0（LICENSE 实测）；**VoxCeleb 系模型按数据集为 CC-BY-4.0**（官方 pretrained.md 明文，可商用需署名）；CNCeleb 系模型按 CN-Celeb 条款**未核验** | resnet34 25.3MB、resnet152 75.5MB、CAM++ 27.9MB（sherpa release 列表） | ONNX 输入格式**未验证**（官方 python 推理先提 fbank） | ✓ | VoxCeleb1-O：ResNet34-TSTP-emb256 EER 0.66~0.87%（6.63M 参数 4.55G FLOPs，官方表） | 未测（有①足够） | 不选（EN 训练为主，模型 license 分叉） |
| ⑤ Resemblyzer (GE2E) | 代码 Apache-2.0（LICENSE 实测）；权重 license 未单独声明（跟随仓库），训练数据 VoxCeleb 条款**未验证** | pretrained.pth ~17MB（未下载） | 16kHz 波形，3 秒窗，192 维（**参数格式未验证**） | ✗ 官方仅 .pt（社区 ONNX 未验证） | GE2E（2017）明显落后于现代模型 | 需自行导出 | 不选 |
| ⑥ NeMo TitaNet-small（sherpa release 有售） | NVIDIA NeMo 模型 license **未核验** | 38.4MB | 未验证 | ✓ | NeMo 官方基准（未引用） | 未测 | 不选（license 未核验 + 英文为主） |

### 授权合规（使用产物逐项）

| 产物 / 依赖 | License | 出处 URL |
|---|---|---|
| `SpeakerCAM++ZHEng.mlpackage`（本次转换产物） | **Apache-2.0** | https://www.modelscope.cn/models/iic/speech_campplus_sv_zh_en_16k-common_advanced （模型卡 License=Apache License 2.0，经 ModelScope API 实测） |
| `models/campplus_cn_en_common.pt`（权重） | Apache-2.0 | 同上（resolve/master/campplus_cn_en_common.pt） |
| `models/campplus_zh_en_advanced.onnx`（sherpa 官方导出，对照用） | Apache-2.0 | https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx |
| `thirdparty/speakerlab/models/campplus/{DTDNN.py,layers.py}`（转换时实例化网络用，附 ATTRIBUTION.md） | Apache-2.0 | https://github.com/modelscope/3D-Speaker （LICENSE 实测为 Apache-2.0） |
| `models/silero_vad.onnx` | **MIT** | https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx （上游 https://github.com/snakers4/silero-vad LICENSE=MIT） |
| `models/sherpa-onnx-pyannote-segmentation-3-0/` | **MIT**（包内 LICENSE：Copyright2022 CNRS；源头 HF 卡 license=mit） | https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2 |
| sherpa-onnx 转换/验证工具链 | Apache-2.0 | https://github.com/k2-fsa/sherpa-onnx |
| 测试音频（fangjun/leijun/0-four-speakers-zh.wav） | 随 sherpa-onnx release 分发 | https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models |

- **主选/备选全部组件均为 MIT / Apache-2.0，无 NC、无研究限定**，可商用。
- 若将来启用 WeSpeaker VoxCeleb 模型：CC-BY-4.0（可商用，需在 About/文档署名）；**CNCeleb 系模型数据集条款未核验，暂不纳入**。
- **未验证假设**：ModelScope 卡片将 zh_en advanced 标为 Apache-2.0，但其训练数据构成（是否含 VoxCeleb/CN-Celeb）未逐一核验；如需绝对保险，可只用 zh-cn-16k-common 或 eres2net-cn 系（同为卡片声明 Apache-2.0）。

---

## 3. 转换实测记录（命令与输出摘录）

### 3.1 环境安装

```text
C:\...\python.exe -m pip install coremltools onnx onnxruntime
→ Downloading coremltools-9.0.tar.gz (1.7 MB)   ← PyPI 无 Windows wheel，从 sdist 构建
→ Successfully installed coremltools-9.0 onnx-1.23.0 onnxruntime-1.30.0 ...
```
（后续按需安装：`torch torchvision onnx2pytorch onnx2torch sherpa-onnx`，国内 PyPI 直连慢时用 `-i https://mirrors.aliyun.com/pypi/simple/`，实测 500KB/s+。）

### 3.2 关键问题 A：coremltools 是否还支持 ONNX 导入？——**已移除**

```text
>>> import coremltools as ct; print(ct.__version__)
9.0
>>> ct.converters members: ['ClassifierConfig','ColorLayout','EnumeratedShapes','ImageType','RangeDim','Shape','StateType','TensorType','convert','libsvm','mil','sklearn','xgboost']   ← 无 onnx
>>> from coremltools.converters.onnx import convert
ModuleNotFoundError: No module named 'coremltools.converters.onnx'
```

PyPI coremltools 9.0 全部分发文件：`coremltools-9.0-cp3XX-none-{macosx_10_15_x86_64|macosx_11_0_arm64|manylinux1_x86_64}.whl`（cp37~cp313）+ `coremltools-9.0.tar.gz`——**只有 macOS 与 Linux x86_64 wheel，无 Windows wheel**（conda-forge 同样无 win-64，实测 api.anaconda.org）。

结论：ONNX→CoreML 只剩「中转 torch」或「换运行时」两条路。可行替代：
1. **onnx→torch→coremltools**（onnx2pytorch / onnx2torch，或反向路线：直接用原始 PyTorch checkpoint，绕开 ONNX）✅ 本项目最终采用第 2 种；
2. App 内直接跑 ONNX（ONNX Runtime 官方 XCFramework / 社区 SwiftPM 包装，或 sherpa-onnx 发布的 `xcframework` tag —— `git ls-remote` 实测存在 `refs/tags/xcframework`；具体 SPM 接入方式**未验证**）；
3. macOS / Linux 上转换（BlobWriter 只在这两个平台的 wheel 里）。

### 3.3 关键问题 B：ONNX 直转 torch 的实测（失败记录）

```text
python try_converters.py
[onnx2pytorch experimental=False] shape=(1, 192) max|diff|=2.708e+00 cos=0.9584
[onnx2pytorch experimental=True]  shape=(1, 192) max|diff|=2.708e+00 cos=0.9584
[onnx2torch] FAILED: NotImplementedError: BatchNorm operation with spatial rank == -2 is not implemented
RESULT: parity OK via NONE
```
- onnx2pytorch 与参考实现 cos 只有 0.9584，数值**不可接受**；其 gather.py/slice.py 伴随 "Using a non-tuple sequence ... will be changed in pytorch 2.9" 告警，且最新 torch 的列表索引语义变化会加剧此问题（成因分析，**未逐一验证根因**）。
- onnx2torch 直接在 BatchNorm 节点 NotImplementedError。
- 注：对比输入为随机 fbank [1,400,80]，参考=onnxruntime 同图执行。

### 3.4 路径确定：ModelScope checkpoint → torch → CoreML（Windows 端走到最后一步失败）

```text
python convert_checkpoint_to_coreml.py     # Windows，torch 2.14.0+cpu + coremltools 9.0(sdist)
[3/5] parity check vs sherpa-onnx ONNX export ...
  ref shape=(1, 192) got shape=(1, 192)
  max|diff|=2.787e-06  cos=1.000000        ← checkpoint 与 sherpa ONNX 完全等价
[4/5] torch.jit.trace ... trace OK
[5/5] coremltools convert ...
Converting PyTorch Frontend ==> MIL Ops: 100%| 2556/2557
Running MIL frontend_pytorch pipeline: 100%| 5/5
Running MIL default pipeline: 100%| 95/95
Running MIL backend_mlprogram pipeline: 100%| 12/12
  File ".../coremltools/converters/mil/backend/mil/load.py", line 499, in export
    raise RuntimeError("BlobWriter not loaded")
RuntimeError: BlobWriter not loaded
```
同时打印：`Fail to import BlobWriter from libmilstoragepython. No module named 'coremltools.libmilstoragepython'`（sdist 构建不含该 C 扩展）。**失败点唯一、位置明确：Windows 无法序列化 mlprogram 权重。**

### 3.5 绕行成功：WSL + manylinux coremltools（最终产物）

`wsl_convert.sh`（Tools/speaker/ 下）：WSL Ubuntu26.04 内用 uv 装 CPython3.12 + `coremltools`（manylinux wheel 自带 BlobWriter）+ `torch==2.6.0+cpu`（阿里云 pytorch-wheels/cpu 镜像最新版；WSL 系统 python3.14 无对应 coremltools wheel，故用 uv 提供3.12）。

中间排错（均实测）：
1. torch2.6.0 图在 coremltools 前端 `_cast` 处 `TypeError: only 0-dimensional arrays can be converted to Python scalars` —— numpy 2.x 把「1 元素数组→标量」变为硬错误（numpy1.x 只是告警）。**`numpy==1.26.4` 后通过**；Windows 端 torch2.14 的图恰好无此模式，故未撞上。
2. 首次脚本内 `python -c "..."` 的双引号被 PowerShell→wsl 参数链吃掉（SyntaxError），改为直接执行 .py。

最终成功日志（节选）：
```text
[3/5] parity check vs sherpa-onnx ONNX export ...
  max|diff|=3.338e-06  cos=1.000000
[4/5] torch.jit.trace ... trace OK
[5/5] coremltools convert ...
Converting PyTorch Frontend ==> MIL Ops: 100%| 2556/2557
...（3 条 pipeline 全部100%）
  convert done in 5.7s
saved: /mnt/d/Project/ClassroomTranslator/Tools/speaker/models/SpeakerCAM++ZHEng.mlpackage
[verify] reopen .mlpackage ...
  IN  fbank [1, 400, 80] elem=65568      (FLOAT32)
  OUT embedding [1, 192] elem=65552      (FLOAT16，因 compute_precision=FLOAT16)
  specificationVersion: 9
```

产物结构（Windows 侧实测）：
```text
SpeakerCAM++ZHEng.mlpackage/            总计 13.8 MB
├── Manifest.json
└── Data/com.apple.CoreML/
    ├── model.mlmodel        0.5 MB   （spec protobuf）
    └── weights/weight.bin  13.2 MB   （6.91M 参数 × FP16 ≈ 13.8MB，吻合）
```

**复现命令**（macOS 上无需 WSL，直接 python 即可）：
```bash
pip install numpy coremltools onnx onnxruntime "torch==2.7.0"   # macOS 用 coremltools 官方 wheel
python Tools/speaker/convert_checkpoint_to_coreml.py             # --no-fp16 可得 Float32 输出
```

### 3.6 模型与管线质量实测

```text
python test_diarization.py          # sherpa-onnx 1.13.8 Python API
[emb] fangjun-sr-1.wav: dur=2.30s dim=(192,) infer=37ms
[emb] fangjun-sr-2.wav: dur=5.17s dim=(192,) infer=71ms
[emb] leijun-sr-1.wav:  dur=4.20s dim=(192,) infer=60ms
[emb] cosine matrix:
  SAME fangjun-sr-1 vs fangjun-sr-2: 0.8088
  DIFF fangjun-sr-1 vs leijun-sr-1 : 0.2490
  DIFF fangjun-sr-2 vs leijun-sr-1 : 0.3284
[diar] sample_rate=16000 audio=56.86s wall=5.29s RTF=0.0929
[diar] segments=10 speakers=4
   0.32--6.87 spk0 | 7.02--10.75 spk1 | 11.46--13.63 spk1 | 13.75--17.04 spk2
   22.14--24.84 spk0 | 27.64--29.48 spk3 | 30.00--31.55 spk3 | 33.68--37.93 spk3
   48.04--50.47 spk2 | 52.53--54.60 spk0
```
- 与 sherpa 官方文档（k2-fsa.github.io …/speaker-diarization/models.html）给出的4说话人输出**逐段一致**（时间戳/说话人数完全吻合）。
- 同人/异人余弦 **0.81 vs 0.25~0.33**，中线 ≈0.55 → 在线聚类阈值建议 τ=0.6（见 §4.4）。

### 3.7 CPU 推理成本实测（本机 onnxruntime 1.30，Windows）

| 模型 | 条件 | 结果 |
|---|---|---|
| CAM++ embedding（参数量 6.91M，ONNX 初值和实测） | 单线程，fbank 窗1s /2s /4s /12s | **15.0 / 26.4 / 49.0 / 145.1 ms**（≈12~13ms/秒音频） |
| CAM++（sherpa 内含 fbank 前处理） | 单线程，真实音频2.3s/4.2s/5.2s | 37 / 60 / 71 ms |
| Silero VAD（629KB 版） | 单步512样本@16k | mean **0.1ms**；整段56.8s音频 wall 0.233s → **RTF 0.004** |
| 完整 diarization（pyannote 5.7M 分割 + CAM++ + 聚类） | 本机 | 56.86s 音频 wall 5.29s → **RTF 0.093**（官方文档在另一机器为 RTF0.297，可作上界参考） |

折算到产品：句级方案每句只算一次 embedding（2~4s 窗 ≈26~49ms 单线程），Apple Silicon 多核/ANE 会更快；FLOPs 未单独测量（**未验证假设**：与 WeSpeaker ResNet34 6.63M/4.55G 同量级，约2~5G）。

---

## 4. Swift 集成草案（给 Swift 工程师，可直接照做）

### 4.1 资源与加载

- 打包 `SpeakerCAM++ZHEng.mlpackage` 进 app（同 AccentECAPA.mlpackage 模式），`MLModel(contentsOf:)` 单例常驻；输入 `fbank: MLMultiArray [1,400,80] Float32`，输出 `embedding: MLMultiArray [1,192]`（**Float16**，需转 Float 再算余弦；或重转 --no-fp16 得 Float32）。
- 可选：`silero_vad.onnx`（若走 ONNX 备选）或用能量门控（RMS 阈值 -45dBFS 起步）替代，首版建议**能量门控**，零依赖。

### 4.2 音频取窗策略

```
AVAudioEngine tap (16kHz mono Float32)
  └─ ringBuffer（保留最近 30s，供回溯拼窗）
SpeechAnalyzer 每句 final segment 到达（start/end/文本）
  └─ 取该段音频 PCM（可前后各加 0.15s 余量，避开切句截字）
      ├─ 时长 < 0.6s  → 不算 embedding：沿用上一句说话人（学生短「嗯/对」场景）
      ├─ 0.6s ≤ t ≤ 4s → 零/定长填充到 400 帧（右侧补0），一次推理
      └─ t > 4s        → 取前 400 帧（0~4s）参与 embedding；长讲段每 4s 滑窗取2~3个窗求平均更稳（首版可只取头窗）
```
- 句内基本无重叠（题目前提），无需100ms 级切分；重叠检测留作后续（pyannote overlap 能力，未启用）。

### 4.3 fbank 特征（关键决策，二选一）

- **方案 A（推荐，项目已有先例）**：像 Tools/accent/convert_accent_to_coreml.py 那样把 **fbank 计算包进 CoreML 模型**（其产物输入就是 waveform）。需要补做：用 torch 复刻 kaldi-style fbank（80维/25ms/10ms/512-FFT，dither=0），包一层 `Waveform→fbank→CAMPPlus` 再转一次；**在 Python 端用真实 wav 校验「包装版 embedding vs sherpa ONNX embedding」余弦 ≥0.98** 后才可发布（本报告未执行此步——**待办**）。
- **方案 B**：Swift 侧实现 fbank（Accelerate/vDSP，参照 sherpa-onnx `fbank.cc` 参数），喂现有 fbank 模型。风险：特征不对齐会整体拉低余弦，必须用 §5-3 的对齐测试把关。
- 两案都不需要重训模型；**不要**用非 25/10ms 或非80维的替代前端。

### 4.4 在线聚类（增量、流式）

```swift
struct Cluster { var centroid: [Float]        //192维，L2归一化
                 var count: Int; var totalSpeech: TimeInterval
                 var memberSegIds: [UUID] }
var clusters: [Cluster] = []                   // 上限 maxSpeakers=6
let tau: Float = 0.6                            // 余弦阈值（实测同人0.81/异人0.25~0.33）

func assign(embed e: [Float], to seg: TranscriptSegment) {
  let ne = l2normalize(e)
  guard let (i, s) = clusters.enumerated().map({ ($0.offset, cosine(ne, $0.element.centroid)) })
        .max(by: { $0.1 < $1.1 }) else { spawnNew(ne, seg); return }
  if s >= tau {                                 // 归入已有说话人
    clusters[i].centroid = l2normalize(0.8*clusters[i].centroid + 0.2*ne)   // EMA，防漂移
    clusters[i].count += 1; clusters[i].totalSpeech += seg.duration
    seg.speakerID = i
  } else if clusters.count < maxSpeakers { spawnNew(ne, seg) }
  else { seg.speakerID = i }                    // 达到上限：硬归最近，避免标签膨胀
}

// 每积累 N=10 句 或 每5分钟：全量重聚类（average-linkage 层次聚类，阈值 1-tau），
// 用存储的逐句 embedding 重算 label 并回写历史 segment —— 修正早期误分（在线方案的核心补丁）
// 导出/转录展示前强制再跑一次重聚类。
```
- **【老师】绑定**：重聚类后取 `totalSpeech` 最大的簇 = 老师；其余按首次出现顺序 = 【学生1】【学生2】。绑定只在每次重聚类后更新一次，避免标签跳动（迟滞：新簇须累计 ≥2 句且总时长 >6s 才参与「老师」竞争）。
- 参数依据：τ=0.6 来自 §3.6 实测；sherpa 官方 FastClustering 默认 threshold=0.5、文档给出该批模型参考值0.9（`--clustering.cluster-threshold`，大=更少说话人），可作重聚类时的对照起点。

### 4.5 标签流转

```
SpeechAnalyzer final segment
   → SpeakerEngine.async: 取窗 → embedding → assign() → 写入 segment.speakerID
   → TranscriptSegment { …, speakerID: Int? , displayName: "【老师】"/"【学生2】"/nil }
   → 转录 UI / 导出（SRT/TXT/Markdown）读 displayName；重聚类后广播 relabel 通知刷新
```

### 4.6 降级路径

1. 模型文件缺失/加载失败/预测抛错 → `speakerID=nil`，显示不带说话人标签（转录功能不受影响）；
2. 句长 <0.6s 或 RMS 过低（静音/噪） → 沿用上一句 speakerID；
3. 聚类只产生1个簇且总时长 <30s → 全部显示【说话人】不硬猜老师；
4. embedding 模型 ANE 不可用 → `MLModelConfiguration.computeUnits = .cpuAndGPU` 重试；
5. 全链路失败（CoreML 备选也挂） → 走 §2 备选（ONNX Runtime/sherpa 库），或完全关闭说话人标签。

---

## 5. Mac 端验证清单

1. **加载与编译**：Xcode 引入 `SpeakerCAM++ZHEng.mlpackage`（deployment ≥ macOS15；目标 macOS26 实测），确认 `MLModel` 加载、input/output 名称与 §3.5 一致（fbank Float32 / embedding Float16）。
2. **数值对齐（必做）**：Mac 上对同一随机/真实 fbank 输入，`mlmodel.predict` vs onnxruntime 输出，FP16 误差应 <1e-2 且余弦 >0.999；再对真实 wav 走完整前端（fbank 实现）与 sherpa ONNX embedding 对比，**余弦 ≥0.98** 才算特征对齐通过。
3. **fbank 包装版（若走 §4.3 方案 A）**：重新执行转换脚本并重复第2条。
4. **端到端质量**：真实课堂录音（≥2 人，≥30 分钟），人工抽检句子标签正确率；重点看：学生短提问(<0.6s)、长讲段中途换人、轻微重叠、录音开头噪声段。
5. **性能**：Apple Silicon 上每句 embedding 延迟（预期 CPU <20ms、ANE 视兼容性）、整场课内存增量（embedding 缓存按2人200句 ≈200×192×4B≈150KB，可忽略）、连续1h 无内存增长。
6. **流式时效**：segment final 到标签写入 UI 的端到端延迟 <200ms（embedding 本身 + 队列排队）。
7. **聚类稳定性**：老师/学生标签整场不互换；重聚类触发后历史标签变化次数统计（应只在前2~3分钟抖动）。
8. **备选通路验证**（如 CoreML 有任何问题）：ONNX Runtime XCFramework 或 sherpa-onnx `xcframework` tag 在 Xcode 集成跑通 §3.6 同一段 wav，输出应与本报告一致。
9. **打包体积**：app 新增 ≈14MB（FP16 模型）；确认分发许可（Apache-2.0/MIT 免费，附署名即可）。

---

## 6. 来源 URL 列表

**License / 模型卡**
- https://github.com/k2-fsa/sherpa-onnx/blob/master/LICENSE （Apache-2.0）
- https://github.com/modelscope/3D-Speaker/blob/main/LICENSE （Apache-2.0）
- https://www.modelscope.cn/api/v1/models/iic/speech_campplus_sv_zh_en_16k-common_advanced （License=Apache License 2.0）
- https://www.modelscope.cn/api/v1/models/iic/speech_campplus_sv_zh-cn_16k-common （License=Apache License 2.0）
- https://github.com/snakers4/silero-vad/blob/master/LICENSE （MIT）
- https://github.com/snakers4/silero-vad/blob/master/README.md （正文声明 MIT；徽章 alt 残留 CC BY-NC）
- https://github.com/wenet-e2e/wespeaker/blob/master/LICENSE （Apache-2.0）
- https://github.com/wenet-e2e/wespeaker/blob/master/docs/pretrained.md （模型 license 跟数据集，VoxCeleb→CC-BY-4.0 明文）
- https://github.com/resemble-ai/Resemblyzer/blob/master/LICENSE （Apache-2.0）
- https://hf-mirror.com/api/models/pyannote/segmentation-3.0 （cardData.license=mit）
- https://pypi.org/pypi/coremltools/9.0/json （无 win wheel，仅 macOS/manylinux+sdist）
- https://api.anaconda.org/package/conda-forge/coremltools （无 win-64）

**模型下载（本次实际使用）**
- https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models （CAM++/ERes2Net/WeSpeaker/TitaNet ONNX 及测试 wav、体积）
- https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-segmentation-models （pyannote segmentation tar 包、四说话人中文测试音频）
- https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
- https://www.modelscope.cn/models/iic/speech_campplus_sv_zh_en_16k-common_advanced/resolve/master/campplus_cn_en_common.pt
- https://www.modelscope.cn/models/iic/speech_campplus_sv_zh_en_16k-common_advanced/resolve/master/config.yaml
- https://github.com/modelscope/3D-Speaker/raw/main/speakerlab/models/campplus/DTDNN.py 、 .../layers.py（vendored）

**文档 / 基准 / 用法**
- https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/index.html
- https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/models.html （官方4说话人输出、FastClustering 参数、RTF0.297）
- https://k2-fsa.github.io/sherpa/onnx/vad/silero-vad.html （Silero 各版本体积、16k/8k 支持）
- https://github.com/modelscope/3D-Speaker/blob/main/README.md （EER 基准表：CAM++/ERes2Net/…）
- https://github.com/wenet-e2e/wespeaker/blob/master/examples/voxceleb/v2/README.md （EER/参数量/FLOPs 表）
- https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/master/python-api-examples/offline-speaker-diarization.py （API 用法）

**工具镜像（本机网络实测可达）**
- https://mirrors.aliyun.com/pypi/simple/ ；https://mirrors.aliyun.com/pytorch-wheels/cpu/ ；https://mirrors.cloud.tencent.com/pytorch-wheels/ ；https://hf-mirror.com ；https://www.modelscope.cn

---

## 附：本次产出的文件（均在 Tools/speaker/）

- `convert_checkpoint_to_coreml.py` —— **主路径**：ModelScope checkpoint → .mlpackage（含 ONNX parity 校验与产物自检；macOS/WSL 可直跑）
- `convert_speaker_to_coreml.py` —— ONNX→torch→CoreML 备选脚本（本机实测 parity 不过，留档）
- `try_converters.py` —— onnx2pytorch/onnx2torch 对比实测工具
- `bench_onnx.py` —— VAD/embedding CPU 延迟基准
- `test_diarization.py` —— embedding 质量 + 全管线验证（sherpa Python API）
- `wsl_convert.sh` —— WSL 内一键转换（BlobWriter 绕行）
- `thirdparty/speakerlab/...` —— 3D-Speaker 源码副本（Apache-2.0，ATTRIBUTION.md）
- `models/` —— campplus ONNX(27MB)/checkpoint(26.7MB)/silero_vad(0.6MB)/pyannote 分割(5.7MB)/**SpeakerCAM++ZHEng.mlpackage(13.8MB)**/测试 wav
