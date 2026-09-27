# 层 1 声纹区分 — Windows MVP 方案

> 目标：只区分“是不是同一个人”，输出 `Person A/B/C/unknown`。
> **不做**角色标签（老师/学生）、翻译、ASR 产品集成。
> Windows 原型跑通后，再改阈值/并进 macOS App。

## 1. 边界

| 做 | 不做 |
|---|---|
| 切有效说话段 | 人声分离 / 重叠拆音 |
| 声纹 embedding | 角色猜测 |
| 复用优先聚类（防一人裂成两人） | 跨会话人物库（MVP 仅会话内） |
| 时间轴：Person id + 置信 | Swift / CoreML 集成 |

## 2. 运行环境（Windows）

- Python 3.12 + `sherpa-onnx==1.13.8` + `numpy`
- 模型（已在 `Tools/speaker/models/`）：
  - 切段：`sherpa-onnx-pyannote-segmentation-3-0/model.onnx`
  - 声纹：`campplus_zh_en_advanced.onnx`（192 维）
- 入口：`Tools/speaker/layer1_mvp.py`
- 离线、无 API、无网络

## 3. 管线

```text
wav (16k mono)
  → 切段（pyannote；段长夹在 [0.8s, 4.0s]）
  → 过滤（<0.6s 或 RMS 过低 → 标记 dirty，不参与建人）
  → CAM++ embedding（每段 1 个向量）
  → 复用优先聚类（在线 leader-follower + 句末合并）
  → 时间轴 JSON / 文本：start/end/person/confidence
```

## 4. 复用优先规则（防分裂）

**实测余弦（CAM++ zh_en）**：同人 ≈ 0.81，异人 ≈ 0.25–0.33。课堂远场会把同人拉低到 ~0.55–0.70。

阈值（可调，默认）：

| 参数 | 默认 | 含义 |
|---|---|---|
| `reuse_floor` | **0.42** | ≥ 此：**并入**最近已有 Person（防分裂，不更新或微更新质心） |
| `merge_floor` | **0.52** | ≥ 此：并入 + 温和质心更新 |
| `strong_match` | **0.65** | ≥ 此：强匹配，质心正常 EMA |
| `enroll_match_th` | **0.55** | 课程人物库匹配门槛 |
| `min_segment_sec` | 0.6 | 短于此不建人，只沿用 |
| `min_rms` | 0.01 | 过低视为 dirty |
| `new_person_streak` | 2 | 连续 N 个“谁都不像”的干净段才允许新建 |
| `min_reliable_sec` | 1.2 | 干净且够长 + 谁都不像 → 可立即新建 |
| `max_speakers` | 8 | 人数硬上限 |
| `post_merge_th` | 0.82 | 句末两簇过近则合并 |

动作表：

| 情况 | 动作 |
|---|---|
| 课程库命中（≥ enroll_match_th） | 用注册名，优先于 Person A/B |
| sim ≥ strong_match | 归入，质心 EMA 正常 |
| merge_floor ≤ sim < strong_match | 归入，质心微更新 |
| reuse_floor ≤ sim < merge_floor | **归入最近**，不更新质心 |
| sim < reuse_floor 且短/脏 | 沿用上一 Person 或 `unknown` |
| sim < reuse_floor 且干净够长 | 新建 Person（强证据） |
| 边界情况连续 streak≥2 | 新建 Person |
| 句末簇过近 | 合并（偏 merge） |

原则：**Reuse first, split only with strong evidence.**

## 4b. 课程级注册声纹（不是每节课）

- 同一门课每次上课的人一样 → 人物库挂在 **course**，不是 transcript/session。
- 路径：`Tools/speaker/courses/<course_id>/persons.json`
- 字段：`name`、`centroid`（L2 归一化）、`n_samples`
- 识别时：先对课程库匹配，命中用注册名；未命中再走 Person A/B/C 聚类。
- 多次 enroll 同一姓名 → 质心 EMA 累积，越认越稳。

```powershell
# 注册（整门课共用）
python Tools\speaker\layer1_mvp.py --course math101 --enroll "张老师" --wav zhang.wav
python Tools\speaker\layer1_mvp.py --course math101 --enroll "学生A" --wav stu_a.wav

# 任意一节课识别，自动用课程人物库
python Tools\speaker\layer1_mvp.py --course math101 --wav lesson-03.wav

python Tools\speaker\layer1_mvp.py --course math101 --list-persons
```

Swift 侧对应关系（后续迁移时）：挂在 `Course`，不要挂在 `TranscriptRecord`。

## 5. 输出格式

```json
{
  "audio_sec": 56.86,
  "num_persons": 4,
  "segments": [
    {"start": 0.52, "end": 3.10, "person": "Person A", "confidence": 0.81, "dirty": false}
  ]
}
```

- `person`：`Person A`… 或 `unknown`
- `dirty`：短/低能量，可能沿用，置信降低

## 6. 验收（Windows）

| 用例 | 音频 | 期望 |
|---|---|---|
| A1 同人不应裂开 | `fangjun-sr-1.wav` + `fangjun-sr-2.wav` 拼接 | 全部为同一个 Person（或仅 1 人） |
| A2 异人应分开 | `fangjun-sr-1` vs `leijun-sr-1` 拼接 | ≥2 个 Person |
| A3 多人 | `0-four-speakers-zh.wav` | 人数 ≈ 3–5（允许 ±1，勿 1 人或 8+ 人） |
| A4 无炸裂 | 任意短段 | 无“单短段独占新 Person” |
| A5 性能 | 56s 中文四人 | 墙钟 RTF < 0.5（本机 CPU） |

通过 A1–A5 即 Windows MVP 完成；之后再改阈值或迁 Swift。

## 7. 层 2 角标（已接，可多人同角色）

- 模型：TalkMoves 微调 MiniLM（`Tools/train/role-cls-onnx/model.onnx`）
- 入口：`Tools/speaker/role_classifier.py`
- 规则：每人一句/多句投票；**多老师/多学生只加序号**（Teacher 1/2、Student 1/2）
- 用法：`--role-model Tools/train/role-cls-onnx --texts-json texts.json --use-role`

## 8. 明确延后（Windows 之后）

1. 真流式 ASR 文本自动喂角色分类  
2. 学生类加权（student F1 仍偏低）  
3. 在线流式增量  
4. CoreML / macOS App 集成  
5. 翻译  

## 8. 文件

- 本方案：`Tools/speaker/LAYER1_MVP.md`
- 原型：`Tools/speaker/layer1_mvp.py`
- 参考逻辑：`ClassroomTranslator/Services/SpeakerClusterer.swift`（复用优先已部分存在）
- 对照管线：`Tools/speaker/test_diarization.py`
