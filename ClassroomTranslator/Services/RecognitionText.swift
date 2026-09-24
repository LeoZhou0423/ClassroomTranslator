import Foundation
import NaturalLanguage

/// Sentence segmentation and recognition-context helpers backed by Apple's
/// NaturalLanguage framework instead of hand-rolled punctuation tables.
enum SentenceSplitter {
    private static let sentenceEnders = ".!?。！？…"

    static func split(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let piece = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { sentences.append(piece) }
            return true
        }
        if sentences.isEmpty {
            return [trimmed]
        }
        return sentences
    }

    static func hasSentenceEnding(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return false }
        return sentenceEnders.contains(last)
    }

    /// Splits `text` into sentence units suitable for committing as segments.
    /// Incomplete trailing material without ending punctuation is kept as its
    /// own unit only when it is the sole piece; callers merge across commits.
    static func commitUnits(from text: String) -> [String] {
        let pieces = split(text)
        guard pieces.count > 1 else { return pieces }
        var units: [String] = []
        for piece in pieces {
            if hasSentenceEnding(piece) {
                units.append(piece)
            } else if let last = units.popLast() {
                units.append(last + " " + piece)
            } else {
                units.append(piece)
            }
        }
        return units
    }
}

/// Builds short contextual phrases for Speech `AnalysisContext` / recognition bias.
/// Apple recommends 1–2 word phrases, total count ≤ 100.
enum RecognitionContextProvider {
    static let maximumPhrases = 100

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "of", "to", "in", "on",
        "at", "for", "with", "as", "by", "is", "are", "was", "were", "be",
        "been", "am", "it", "this", "that", "these", "those", "from", "into",
        "over", "under", "again", "then", "than", "so", "such", "can", "will",
        "just", "not", "no", "yes", "do", "does", "did", "done", "have", "has",
        "had", "you", "your", "we", "our", "they", "their", "he", "she", "his",
        "her", "i", "me", "my", "up", "out", "about", "there", "here"
    ]

    static func phrases(courseName: String, recentText: String) -> [String] {
        var ordered: [String] = []

        let courseWords = words(in: courseName)
        for word in courseWords where word.count >= 2 {
            ordered.append(word)
        }
        appendBigrams(courseWords, to: &ordered)

        let recentSentences = SentenceSplitter.split(recentText).suffix(4)
        for sentence in recentSentences {
            let sentenceWords = words(in: sentence)
            for word in sentenceWords where word.count >= 3 && !stopWords.contains(word) {
                ordered.append(word)
            }
            appendBigrams(sentenceWords.filter { $0.count >= 2 && !stopWords.contains($0) }, to: &ordered)
        }

        var seen = Set<String>()
        var result: [String] = []
        for phrase in ordered {
            let key = phrase.lowercased()
            guard !seen.contains(key), phrase.count <= 40 else { continue }
            seen.insert(key)
            result.append(phrase)
            if result.count >= maximumPhrases { break }
        }
        return result
    }

    private static func appendBigrams(_ tokens: [String], to result: inout [String]) {
        guard tokens.count >= 2 else { return }
        for index in 0..<(tokens.count - 1) {
            let left = tokens[index]
            let right = tokens[index + 1]
            guard left.count >= 2, right.count >= 2 else { continue }
            result.append("\(left) \(right)")
        }
    }

    private static func words(in text: String) -> [String] {
        var tokens: [String] = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range])
            if !token.isEmpty { tokens.append(token) }
            return true
        }
        return tokens
    }
}

enum RecognitionCoverage {
    /// True when `partial` is already represented in `finalText` (ignoring
    /// trailing punctuation and case), so the live partial can be cleared.
    static func isCovered(partial: String, by finalText: String) -> Bool {
        let normalize: (String) -> String = { value in
            value.lowercased()
                .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
                .joined(separator: " ")
        }
        let part = normalize(partial)
        let final = normalize(finalText)
        guard !part.isEmpty else { return true }
        guard !final.isEmpty else { return false }
        if final == part || final.hasSuffix(part) || final.contains(part) {
            return true
        }
        // Partial may be a multi-word head that final split across segments;
        // check word-by-word containment of the partial token sequence.
        let partTokens = part.split(separator: " ", omittingEmptySubsequences: true)
        let finalTokens = final.split(separator: " ", omittingEmptySubsequences: true)
        guard !partTokens.isEmpty, partTokens.count <= finalTokens.count else { return false }
        if partTokens.count == finalTokens.count {
            return partTokens == finalTokens
        }
        return finalTokens.suffix(partTokens.count) == partTokens
    }
}
