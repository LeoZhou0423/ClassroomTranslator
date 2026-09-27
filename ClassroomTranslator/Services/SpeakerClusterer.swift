import Foundation

/// 在线余弦 leader-follower 聚类（报告 §4.4，纯逻辑可单测）：
/// 新嵌入与各簇质心余弦 ≥ τ 即并入（质心按 EMA 更新），否则开新簇；
/// 簇数上限 K = maximumSpeakers，K 已满时归入最相似簇（不丢标签）。
/// 质心全程做 L2 归一化，余弦相似度 = 点积。
struct SpeakerClusterer: Equatable {
    struct Config: Equatable {
        var threshold: Double
        var maximumSpeakers: Int
        var emaAlpha: Double
        var newClusterMargin: Double

        init(
            threshold: Double = 0.6,
            maximumSpeakers: Int = 4,
            emaAlpha: Double = 0.3,
            newClusterMargin: Double = 0.12
        ) {
            self.threshold = min(max(threshold, 0.45), 0.75)
            self.maximumSpeakers = min(max(maximumSpeakers, 2), 4)
            self.emaAlpha = min(max(emaAlpha, 0.05), 0.9)
            self.newClusterMargin = min(max(newClusterMargin, 0), 0.25)
        }
    }

    var config: Config
    private(set) var centroids: [[Float]] = []
    // A single noisy/far-field window must not immediately invent a speaker.
    // Keep one candidate and require the next novel window to agree with it.
    private var pendingNovel: [Float]?

    init(config: Config = Config()) {
        self.config = config
    }

    /// 归属簇下标（0..<centroids.count 或新簇）。embedding 为空返回 nil。
    mutating func assign(_ embedding: [Float]) -> Int? {
        guard let unit = Self.normalize(embedding) else { return nil }
        var best = -1
        var bestSimilarity = -Double.greatestFiniteMagnitude
        for (index, centroid) in centroids.enumerated() {
            let similarity = Self.dot(unit, centroid)
            if similarity > bestSimilarity {
                bestSimilarity = similarity
                best = index
            }
        }
        // VM/远场麦克风会让同一个人的相邻窗口有明显抖动。处在阈值附近时
        // 优先并入最相似的已有簇，只有显著低于阈值才创建新人，避免一次
        // 咳嗽、噪声或短句立刻裂成“说话人 2/3”。
        let mergeFloor = config.threshold - config.newClusterMargin
        if best >= 0, bestSimilarity >= mergeFloor {
            pendingNovel = nil
            // EMA 更新质心后重新归一化。
            // 阈值以下属于弱匹配，只做很小的质心更新，避免离群窗口拖偏簇。
            let alpha = Float(bestSimilarity >= config.threshold ? config.emaAlpha : min(config.emaAlpha, 0.08))
            let blended = zip(centroids[best], unit).map { pair in
                (1 - alpha) * pair.0 + alpha * pair.1
            }
            centroids[best] = Self.normalize(blended) ?? centroids[best]
            return best
        }
        // 首个说话人：立即建簇（空表时不走 pending，否则会返回 0 却没有质心）。
        if centroids.isEmpty {
            centroids.append(unit)
            pendingNovel = nil
            return 0
        }
        if centroids.count < config.maximumSpeakers {
            if let candidate = pendingNovel,
               Self.dot(candidate, unit) >= config.threshold {
                let combined = zip(candidate, unit).map { pair in (pair.0 + pair.1) * 0.5 }
                centroids.append(Self.normalize(combined) ?? unit)
                pendingNovel = nil
                return centroids.count - 1
            }
            pendingNovel = unit
            // Conservatively inherit the closest established speaker until a
            // second consistent novel window confirms that this is a person.
            return best
        }
        pendingNovel = nil
        return best
    }

    /// 重聚类后按新分组重建质心，让在线 leader-follower 接续。
    mutating func rebuild(embeddings: [[Float]], groups: [Int]) {
        centroids = Self.centroids(for: embeddings, groups: groups)
        pendingNovel = nil
    }

    /// 全量重聚类（每 10 句触发）：平均链接层次聚类，先按余弦 ≥ τ 合并，
    /// 簇数超过 K 时强制合并最相似的一对（结果 ≤ maximumSpeakers）。
    /// 返回每个输入的簇下标，按首次出现顺序重编号。
    static func recluster(_ embeddings: [[Float]], config: Config) -> [Int] {
        let n = embeddings.count
        guard n > 0 else { return [] }
        let units = embeddings.map { normalize($0) ?? [Float]() }

        // 相似度矩阵（i<j 用到即可，这里全存，n 是会话语句数，量级几百）。
        var similarity = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let value = dot(units[i], units[j])
                similarity[i][j] = value
                similarity[j][i] = value
            }
        }

        var clusters: [Set<Int>] = (0..<n).map { Set([$0]) }
        while clusters.count > 1 {
            // 找最佳合并对：组间平均余弦。
            var bestA = -1
            var bestB = -1
            var bestValue = -Double.greatestFiniteMagnitude
            for a in 0..<clusters.count {
                for b in (a + 1)..<clusters.count {
                    let value = averageSimilarity(clusters[a], clusters[b], matrix: similarity)
                    if value > bestValue {
                        bestValue = value
                        bestA = a
                        bestB = b
                    }
                }
            }
            guard bestA >= 0 else { break }
            let overCap = clusters.count > config.maximumSpeakers
            guard overCap || bestValue >= config.threshold else { break }
            clusters[bestA].formUnion(clusters[bestB])
            clusters.remove(at: bestB)
        }

        // One isolated window is usually a cough, clipped boundary, or noisy
        // VM/microphone frame. A real new speaker needs at least two agreeing
        // utterances; merge singleton clusters into their nearest neighbour.
        var singletonIndex = clusters.firstIndex { $0.count == 1 }
        while clusters.count > 1, let source = singletonIndex {
            var target = -1
            var bestValue = -Double.greatestFiniteMagnitude
            for index in clusters.indices where index != source {
                let value = averageSimilarity(clusters[source], clusters[index], matrix: similarity)
                if value > bestValue {
                    bestValue = value
                    target = index
                }
            }
            guard target >= 0 else { break }
            clusters[target].formUnion(clusters[source])
            clusters.remove(at: source)
            singletonIndex = clusters.firstIndex { $0.count == 1 }
        }

        // 按首次出现顺序重编号。
        var labels = [Int](repeating: -1, count: n)
        var nextLabel = 0
        for index in 0..<n where labels[index] < 0 {
            for member in clusters where member.contains(index) {
                for m in member { labels[m] = nextLabel }
            }
            nextLabel += 1
        }
        return labels
    }

    /// 从既有分组重建质心（重聚类后让在线 leader-follower 接续）。
    static func centroids(for embeddings: [[Float]], groups: [Int]) -> [[Float]] {
        guard !embeddings.isEmpty else { return [] }
        var sums: [Int: [Float]] = [:]
        var counts: [Int: Int] = [:]
        for (embedding, group) in zip(embeddings, groups) {
            guard let unit = normalize(embedding) else { continue }
            let current = sums[group] ?? [Float](repeating: 0, count: unit.count)
            sums[group] = zip(current, unit).map { pair in pair.0 + pair.1 }
            counts[group, default: 0] += 1
        }
        return sums.keys.sorted().compactMap { key in
            guard let sum = sums[key], let count = counts[key], count > 0 else { return nil }
            return normalize(sum.map { $0 / Float(count) })
        }
    }

    private static func averageSimilarity(_ a: Set<Int>, _ b: Set<Int>, matrix: [[Double]]) -> Double {
        var total = 0.0
        var pairs = 0
        for i in a {
            for j in b {
                total += matrix[i][j]
                pairs += 1
            }
        }
        guard pairs > 0 else { return -1 }
        return total / Double(pairs)
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        var total: Double = 0
        for i in 0..<a.count { total += Double(a[i]) * Double(b[i]) }
        return total
    }

    static func normalize(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty else { return nil }
        var sum: Double = 0
        for value in vector { sum += Double(value) * Double(value) }
        guard sum > 0 else { return nil }
        let norm = sqrt(sum)
        return vector.map { Float(Double($0) / norm) }
    }
}
