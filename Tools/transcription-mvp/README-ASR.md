# Windows 转写实验台

双击“启动转写实验台.cmd”，或者运行 run.ps1。默认 small，可在页面切换已下载的 tiny/base/small，或实验性的 small.en。首次启动会安装依赖和下载模型。

只测试英文转写：本地 sherpa-onnx Whisper INT8 + Silero VAD，不加载翻译或人物分类。页面可选麦克风，也可上传 PCM WAV 按原速回放。稳定的完整句子会移入段落区；停止后继续处理已采集音频和最终解码队列，保留已有预览内容。

每次测试保存 sessions 下的 audio.wav、config.json、events.jsonl、transcript.txt、result.json。页面可以导出日志和英文。调节静音阈值、分段时间、更新间隔来对比延迟和误识别；噪声过滤无法保证去除背景里的清晰人声。

地址：http://127.0.0.1:8770/。关闭启动终端即可停止服务。原 app.py 是旧版实验工具，新入口为 asr_lab.py。

测试：python -m unittest test_core test_asr_lab test_asr_runtime

2026-10-05 修复：音频片段归属在首次预览时固定，同窗口解码按完整快照替换；解码日志记录 audio_start/audio_end，便于检查跨窗口重复。

分界校对：读取录音中的真实连续音频（前后各最多 8 秒，包含 VAD 间隔），仅在两侧都有至少 4 个词的匹配锚点时修订。失败保留原文。参考录音补回 talk about；实测每次边界校对约增加 3.5–5.2 秒 CPU 解码。

最新验证：同一课堂录音按原速回放，与耶鲁公开稿对应开头比较，文本 WER 19.7% → 4.5%（讲稿可能整理过口头语）。37→40 项规则/运行时回归测试；实体麦克风采集及停止保存、静音/低噪声均通过。显示和导出使用统一文本；完整日志可导出。正常关闭会先处理完已采集音频。


## Optional English grammar model

The grammar comparison panel uses local vennify/t5-base-grammar-correction. Run it after transcription finishes; it never changes ASR text or audio. First install requirements-grammar.txt and run download_grammar.py. Corrected suggestions are saved separately to grammar.json. Number, name and negation checks reject some unsafe rewrites, but suggestions still require review. Grammar correction cannot reliably recover acoustically mistaken words. The current grammar build opens on port 8771.


## Real-time CPU budget (2026-10-05)

Current port: 8783. Default model: small, 4 threads, 10-second speech windows. Preview at 1.5 seconds and once more before 5 seconds; later redundant full-window partials are omitted. Decoder is preloaded and reused. Completed windows enter a separate translation queue; truncated captions wait for continuation. Local punctuation repair is fast; T5 runs only for explicit agreement/repetition anomalies, or manually for complete review. Context is limited to 24 preceding words. Translation streams per group, with token accounting and original English retained. API credentials remain in process memory. Tested with the official Yale lecture video 0-30 seconds; see Artifacts/yale-final-caption-runtime.json and address-translation-validation.json. These tests do not establish accuracy for all speakers or noise conditions.

## 2026-10-13: audio-backed quality review

- A shortened final hypothesis retains independently anchored words from the live hypothesis. Explicit boundary trims remain possible; distinct audio repetitions are retained.
- Empty, severely shortened and repeated-word finals schedule one background original-audio re-decode. This uses a separate one-thread recognizer and a bounded queue, while live recognition continues. Stop waits for reviews before saving. A stale review cannot overwrite a boundary repair.
- Suspect fragments may use a general text model for minimal correction before translation. Default model: qwen-plus; LINGOCLASS_CORRECTION_MODEL overrides it. LINGOCLASS_AI_CORRECTION=0 disables extra calls. Existing configured credentials/endpoint are reused; unavailable service preserves the original. Five-second read timeout, minimal edit constraints and 256-entry context-aware cache limit overhead. Usage is recorded separately as correction_usage (process totals).
- Settings include course terms for correction context. The installed sherpa-onnx Whisper interface does NOT expose hotwords/initial_prompt; this is not decoder vocabulary biasing. Terms cannot authorize fabricated audio content.
- Regression suite: 101 tests; frontend build passed. Unit tests mock network calls; use replay evidence separately to assess quality. These changes do not guarantee arbitrary-accent accuracy.

## Semantic review (2026-10-13)

Final audio windows are checked asynchronously by qwen-plus with at most 48 preceding words and the configured terminology. The model can propose at most two lexical substitutions; proposals cannot add/delete words or change names, pronouns, numbers, negations or protected tense words. Only changed proposals trigger independent raw-audio recognition (without feeding the proposed words into the recognizer). Each replacement requires matching neighboring words in that audio hypothesis; conflicting/ambiguous hypotheses retain the original. Unconfirmed proposals show a review warning. Late results cannot overwrite newer text or boundary repairs. Reviews have a bounded queue; overload is explicitly logged as deferred rather than blocking live captions. This can miss corrections under sustained load and is not a guarantee of acoustic correctness. Unchanged/failed proposals do not require a second audio decode. Semantic detection consumes an additional cached text API request per reviewed final window; correction_usage records this separately. LINGOCLASS_AI_CORRECTION=0 disables semantic checks too.

## Text reconstruction mode (2026-10-13, user-approved)

The default lexical correction policy now uses qwen-plus to reconstruct current finalized text from bounded preceding/following transcript context and course terms, without requiring acoustic confirmation. Raw ASR remains in ledger rows and language.original; repaired display/translation text is saved separately in language.english. Model output can replace substantially misheard words and grammar; it cannot freely summarize/expand the transcript. Unrecoverable text is marked context_uncertain/[Unclear] and displayed as pending confirmation, rather than presented as audio-verified. Generic translation guidance replaces lecture-specific neuroscience/name-address rewrites. Revisions continue to replace rows by id and reject stale jobs. Correction is cached by model, source, context, terms and mode. Additional API calls apply to finalized groups; LINGOCLASS_AI_CORRECTION=0 disables them. Raw-audio reviews remain for empty/truncated snapshots only, rather than gating text repairs.
