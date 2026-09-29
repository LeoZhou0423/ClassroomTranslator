# Whisper 转写实验台（Windows MVP）

只验证转写链路，不依赖 macOS、GitHub Actions 或 DMG：

- sherpa-onnx Whisper tiny/small int8 可切换对比
- Silero VAD 负责语音/静音与最终分段
- 2.5 秒增量 partial、VAD 完整段 final
- Local Agreement 稳定前缀、窗口重叠合并和退化循环过滤
- CAM++ 声纹聚类区分人物，MiniLM 按每个人的累计文本判定教授/学生
- OPUS-MT en→zh + CTranslate2 INT8 离线翻译稳定文本，自动丢弃过期翻译任务
- 实时显示 VAD 分段长度及解码耗时

在 PowerShell 中运行：

```powershell
cd D:\Project\ClassroomTranslator\Tools\transcription-mvp
.\run.ps1
```

首次运行会安装依赖并下载 Whisper 与 OPUS-MT 翻译模型，后续直接启动。选择实际麦克风或虚拟声卡后点“开始”。

下载精度更高的 small 模型（约 376 MB）：

```powershell
py download_models.py --model small
```

无需麦克风的可重复冒烟测试：

```powershell
py smoke_test.py
```
