import Foundation

/// 说话人识别引擎（task-4）：把"final 批次 → 取窗 → 嵌入推理 → 在线聚类 →
/// 命名 → 回写标签"串起来。纯逻辑在 SpeakerWindowPolicy/SpeakerClusterer/
/// SpeakerLabeler（单测覆盖），这里只做编排：
///
///  · 同一个 final 的多个句子单元合并成一个取窗批次（下一 runloop 转身处理，
///    保证 SentenceSplitter 的全部 unit 都已附着）；
///  · 窗口跨度不足 0.6s / 静音 / 推理失败 → 段落保持当前标签（继承降级）；
///  · 模型缺失（init 为 nil）→ canInfer 恒 false，引擎惰性，段落无标签，
///    只能手动标注 —— 录音/翻译路径不经过本类（Lead 约束）；
///  · 每 10 条语句全量重聚类并回写（回写经 HistoryStore.updateSpeakers，
///    落库交给现有 checkpoint 机制，不做逐条 save）。
@MainActor
final class SpeakerEngine {
    /// segmentID → 新显示名；第二个参数是当前（临时）标签，供录音页同步展示。
    typealias ResolutionHandler = (_ updates: [UUID: String], _ currentLabel: String?) -> Void

    private struct Batch {
        let window: [Float]
        let duration: Double
        let ids: [UUID]
    }

    private struct Utterance {
        let embedding: [Float]
        let duration: Double
        var group: Int
        var label: String?
        let segmentIDs: [UUID]
    }

    private let ring: SpeakerAudioRing
    private let model: SpeakerEmbeddingModel?
    private var config: SpeakerDetectionConfiguration
    private var clusterer: SpeakerClusterer
    private var utterances: [Utterance] = []
    private var sessionRecordID: UUID?
    private var active = false
    private var windowEnd: Int?
    private var attached: [UUID] = []
    private var flushScheduled = false
    private var batches: [Batch] = []
    private var pumping = false
    private var generation = 0

    var onLabelsResolved: ResolutionHandler?

    init(
        ring: SpeakerAudioRing,
        model: SpeakerEmbeddingModel?,
        config: SpeakerDetectionConfiguration = SpeakerDetectionConfiguration()
    ) {
        self.ring = ring
        self.model = model
        self.config = config
        self.clusterer = SpeakerClusterer(config: config.clusterConfig)
    }

    /// 模型可用且开关打开时才推理。
    var canInfer: Bool { active && config.isEnabled && model != nil }

    /// 当前（临时）标签：新段落先挂它，窗口解析后被精确标签覆盖。
    private(set) var currentLabel: String?

    /// 新会话记录 → 全量重置；同一记录的恢复/继续 → 保留聚类与标签。
    func activate(recordID: UUID) {
        if recordID != sessionRecordID {
            sessionRecordID = recordID
            utterances = []
            attached = []
            batches = []
            pumping = false
            clusterer = SpeakerClusterer(config: config.clusterConfig)
            currentLabel = nil
            generation += 1
        }
        // 每次开始录音 ring 都会被 setSpeakerCapture(true) 清零，
        // 窗口边界必须重新对齐（auto-detect 中途重启同理）。
        windowEnd = nil
        active = true
        config = SpeakerDetectionConfiguration()
        clusterer.config = config.clusterConfig
    }

    /// 暂停/打断：停止开新窗口；在途推理允许完成回写。
    func suspend() {
        active = false
        windowEnd = nil
    }

    /// 录音结束/页面销毁：作废在途结果并清队列。
    func shutdown() {
        active = false
        generation += 1
        attached = []
        batches = []
        flushScheduled = false
    }

    /// 段落批量落地（enqueueFinal 之后调用）。provisional 标签在
    /// 创建段落时已从 currentLabel 写入，这里只负责解析窗口并回写精确标签。
    func segmentsCommitted(_ ids: [UUID]) {
        guard canInfer, !ids.isEmpty else { return }
        attached.append(contentsOf: ids)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        // 下一 runloop 转身：同一 final 的全部 unit 已附着、ring 已停止增长。
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.flushAttached()
        }
    }

    private func flushAttached() {
        let ids = attached
        attached = []
        guard canInfer, !ids.isEmpty else { return }

        let end = ring.endIndex
        var start = windowEnd ?? ring.availableStart
        // ring 被中途 reset（auto-detect 重启等）→ 绝对号回退，边界重新对齐。
        if let previous = windowEnd, previous > end {
            start = ring.availableStart
            windowEnd = nil
        }

        let decision = SpeakerWindowPolicy.decision(
            spanStart: start,
            spanEnd: end,
            availableStart: ring.availableStart
        )
        // 无论是否开窗，边界都推进到当前末端（下个句子从这里开始）。
        windowEnd = end

        guard case let .window(windowStart, windowEnd) = decision,
              let samples = ring.window(from: windowStart, to: windowEnd),
              !samples.isEmpty else {
            return  // 继承：段落保持创建时的 currentLabel
        }
        guard SpeakerWindowPolicy.rms(samples) >= SpeakerWindowPolicy.silenceRMS else {
            return  // 静音窗口：继承
        }
        batches.append(Batch(
            window: samples,
            duration: SpeakerWindowPolicy.durationSeconds(windowStart, windowEnd),
            ids: ids
        ))
        pump()
    }

    private func pump() {
        guard !pumping, !batches.isEmpty, let model else { return }
        pumping = true
        let batch = batches.removeFirst()
        let sessionGeneration = generation

        Task.detached(priority: .userInitiated) { [weak self] in
            let embedding = model.embed(window: batch.window)
            await MainActor.run {
                guard let self else { return }
                self.resolve(batch, embedding: embedding, sessionGeneration: sessionGeneration)
            }
        }
    }

    private func resolve(_ batch: Batch, embedding: [Float]?, sessionGeneration: Int) {
        pumping = false
        defer { pump() }
        guard sessionGeneration == generation else { return }
        // 推理失败 / 空嵌入 → 继承：不建语句，不改标签。
        // 注意不要求 active：暂停瞬间的在途推理仍应完成回写。
        guard let embedding else { return }

        let group = clusterer.assign(embedding) ?? 0
        utterances.append(Utterance(
            embedding: embedding,
            duration: batch.duration,
            group: group,
            label: nil,
            segmentIDs: batch.ids
        ))

        let updates = publishLabels()
        if !updates.isEmpty {
            onLabelsResolved?(updates, currentLabel)
        }

        // 每 10 条语句全量重聚类回写（Lead 约定的节奏）。
        if utterances.count >= 10, utterances.count % 10 == 0 {
            reclusterAll()
        }
    }

    private func reclusterAll() {
        let embeddings = utterances.map(\.embedding)
        let groups = SpeakerClusterer.recluster(embeddings, config: clusterer.config)
        guard groups.count == utterances.count else { return }
        for index in utterances.indices {
            utterances[index].group = groups[index]
        }
        clusterer.rebuild(embeddings: embeddings, groups: groups)
        let updates = publishLabels()
        if !updates.isEmpty {
            onLabelsResolved?(updates, currentLabel)
        }
    }

    /// 用 SpeakerLabeler 给每个簇命名，回写与旧值不同的段落标签。
    /// - Returns: segmentID → 新显示名（仅包含发生变化的段落）。
    private func publishLabels() -> [UUID: String] {
        guard !utterances.isEmpty else { return [:] }
        let groups = utterances.map(\.group)
        let groupCount = (groups.max() ?? 0) + 1
        var durations = [Double](repeating: 0, count: groupCount)
        var counts = [Int](repeating: 0, count: groupCount)
        for utterance in utterances where utterance.group >= 0 && utterance.group < groupCount {
            durations[utterance.group] += utterance.duration
            counts[utterance.group] += 1
        }

        let previous = utterances.map(\.label)
        let names = SpeakerLabeler.labels(
            utteranceGroups: groups,
            previousLabels: previous,
            durations: durations,
            counts: counts,
            config: config.labelConfig
        )

        var updates: [UUID: String] = [:]
        for index in utterances.indices {
            let group = utterances[index].group
            guard group >= 0, group < names.count else { continue }
            let name = names[group]
            if utterances[index].label != name {
                utterances[index].label = name
                for id in utterances[index].segmentIDs {
                    updates[id] = name
                }
            }
        }
        currentLabel = utterances.last?.label ?? currentLabel
        return updates
    }
}
