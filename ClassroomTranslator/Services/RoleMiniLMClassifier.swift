import CoreML
import Foundation

/// WordPiece 编码（BERT/MiniLM）。词表：`role_vocab.txt` 一行一词，id = 行号。
/// 生产路径不依赖 Python；CoreML 输入为 int32 张量。
struct WordPieceTokenizer: Sendable {
    private let vocab: [String: Int]
    private let unk: Int
    private let cls: Int
    private let sep: Int
    private let pad: Int

    init?(vocabFileIn bundle: Bundle = .lingoResources) {
        guard let url = bundle.url(forResource: "role_vocab", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            StartupLog.mark("role.vocab-missing")
            return nil
        }
        var map: [String: Int] = [:]
        map.reserveCapacity(30_522)
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            map[String(line)] = index
        }
        guard !map.isEmpty else {
            StartupLog.mark("role.vocab-empty")
            return nil
        }
        self.vocab = map
        self.unk = map["[UNK]"] ?? 100
        self.cls = map["[CLS]"] ?? 101
        self.sep = map["[SEP]"] ?? 102
        self.pad = map["[PAD]"] ?? 0
    }

    /// 基础切词：小写 + 标点分离（与 MiniLM uncased 预训练对齐）。
    func encode(text: String, maxLength: Int) -> (ids: [Int32], mask: [Int32], types: [Int32]) {
        let lowered = text.lowercased()
        var pieces: [String] = []
        var current = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber || ch == "'" {
                current.append(ch)
            } else {
                if !current.isEmpty {
                    pieces.append(current)
                    current = ""
                }
                if !ch.isWhitespace {
                    pieces.append(String(ch))
                }
            }
        }
        if !current.isEmpty { pieces.append(current) }

        var ids: [Int] = [cls]
        for piece in pieces {
            if let id = vocab[piece] {
                ids.append(id)
                continue
            }
            // ## continuation WordPiece
            var start = 0
            var sub: [Int] = []
            var matched = true
            while start < piece.count {
                var end = piece.count
                var found: Int?
                while start < end {
                    let range = piece.index(piece.startIndex, offsetBy: start) ..< piece.index(piece.startIndex, offsetBy: end)
                    var token = String(piece[range])
                    if start > 0 { token = "##" + token }
                    if let id = vocab[token] {
                        found = id
                        break
                    }
                    end -= 1
                }
                guard let id = found else {
                    matched = false
                    break
                }
                sub.append(id)
                start = end
            }
            if matched, !sub.isEmpty {
                ids.append(contentsOf: sub)
            } else {
                ids.append(unk)
            }
        }
        ids.append(sep)

        let capacity = max(1, maxLength)
        if ids.count > capacity {
            ids = Array(ids.prefix(capacity - 1)) + [sep]
        }
        let seq = ids.count
        let padCount = capacity - seq
        let fullIDs = ids + Array(repeating: pad, count: padCount)
        let mask = Array(repeating: 1, count: seq) + Array(repeating: 0, count: padCount)
        let types = Array(repeating: 0, count: capacity)
        return (
            fullIDs.map { Int32($0) },
            mask.map { Int32($0) },
            types.map { Int32($0) }
        )
    }
}

/// 生产角色分类：CoreML MiniLM。init 失败 → 上层回退启发式。
final class RoleMiniLMClassifier: RoleClassifying, @unchecked Sendable {
    static let resourceName = "RoleMiniLM"
    static let maxLength = 128

    private let model: MLModel
    private let tokenizer: WordPieceTokenizer
    private let lock = NSLock()
    private let ids: MLMultiArray
    private let mask: MLMultiArray
    private let types: MLMultiArray

    init?(bundle: Bundle = .lingoResources) {
        guard let tokenizer = WordPieceTokenizer(vocabFileIn: bundle) else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        guard let model = BundledMLModelLoader.load(
            resource: Self.resourceName,
            bundle: bundle,
            configuration: configuration
        ) else {
            StartupLog.mark("role.model-load-failed")
            return nil
        }
        self.model = model
        self.tokenizer = tokenizer

        let shape: [NSNumber] = [1, NSNumber(value: Self.maxLength)]
        guard
            let ids = try? MLMultiArray(shape: shape, dataType: .int32),
            let mask = try? MLMultiArray(shape: shape, dataType: .int32),
            let types = try? MLMultiArray(shape: shape, dataType: .int32)
        else {
            StartupLog.mark("role.model-buffer-allocation-failed")
            return nil
        }
        self.ids = ids
        self.mask = mask
        self.types = types

        let inputs = model.modelDescription.inputDescriptionsByName
        for name in ["input_ids", "attention_mask", "token_type_ids"] {
            guard inputs[name]?.multiArrayConstraint != nil else {
                StartupLog.mark("role.model-inputs-unexpected")
                return nil
            }
        }
        StartupLog.mark("role.model-ready")
    }

    /// 全文 → (label, score)。失败返回 nil（上层可降级）。
    func classify(fullText: String) -> (label: String, score: Double)? {
        let text = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        let encoded = tokenizer.encode(text: text, maxLength: Self.maxLength)
        for index in 0..<Self.maxLength {
            ids[index] = NSNumber(value: encoded.ids[index])
            mask[index] = NSNumber(value: encoded.mask[index])
            types[index] = NSNumber(value: encoded.types[index])
        }

        guard
            let provider = try? MLDictionaryFeatureProvider(dictionary: [
                "input_ids": ids,
                "attention_mask": mask,
                "token_type_ids": types,
            ]),
            let prediction = try? model.prediction(from: provider),
            let logits = prediction.featureValue(for: "logits")?.multiArrayValue
        else {
            StartupLog.mark("role.infer-failed")
            return nil
        }

        // logits [1,2] or [2] → softmax
        let count = logits.count
        guard count >= 2 else { return nil }
        let s0 = logits[count - 2].doubleValue
        let s1 = logits[count - 1].doubleValue
        let maxS = max(s0, s1)
        let e0 = exp(s0 - maxS)
        let e1 = exp(s1 - maxS)
        let sum = e0 + e1
        guard sum > 0 else { return nil }
        let pStudent = e0 / sum
        let pTeacher = e1 / sum
        if pTeacher >= pStudent {
            return ("teacher", pTeacher)
        }
        return ("student", pStudent)
    }
}
