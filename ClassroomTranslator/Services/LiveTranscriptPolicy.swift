import Foundation

/// Pure text policies shared by live recognition and the subtitle overlay.
/// Keeping these rules independent from Speech/AppKit makes the two live views
/// deterministic and regression-testable.
enum RecognitionTextDelta {
    static func unseenText(after previousSnapshot: String, in currentSnapshot: String) -> String {
        let previous = clean(previousSnapshot)
        let current = clean(currentSnapshot)
        guard !current.isEmpty else { return "" }
        guard !previous.isEmpty else { return current }
        guard current != previous else { return "" }

        if current.hasPrefix(previous) {
            let previousEndInCurrent = current.index(current.startIndex, offsetBy: previous.count)
            guard isWordBoundary(in: current, at: previousEndInCurrent) else { return current }
            let suffix = clean(String(current[previousEndInCurrent...]))
            let previousEndInSuffix = suffix.index(suffix.startIndex, offsetBy: min(previous.count, suffix.count))
            if suffix.hasPrefix(previous), isWordBoundary(in: suffix, at: previousEndInSuffix) {
                return clean(String(suffix[previousEndInSuffix...]))
            }
            return suffix
        }

        let oldWords = words(in: previous)
        let newWords = words(in: current)
        guard !oldWords.isEmpty, !newWords.isEmpty else { return current }

        if newWords.count >= oldWords.count,
           Array(newWords.prefix(oldWords.count).map(\.normalized)) == oldWords.map(\.normalized) {
            let end = newWords[oldWords.count - 1].range.upperBound
            return clean(String(current[end...]))
        }

        // Speech frequently revises the beginning of an already committed
        // hypothesis. Anchor on the longest old suffix still present in the new
        // hypothesis, then emit only what follows that anchor.
        let maximumOverlap = min(oldWords.count, newWords.count)
        if maximumOverlap >= 2 {
            for length in stride(from: maximumOverlap, through: 2, by: -1) {
                let oldSuffix = oldWords.suffix(length).map(\.normalized)
                for start in 0...(newWords.count - length) {
                    let candidate = newWords[start..<(start + length)].map(\.normalized)
                    if candidate == oldSuffix {
                        let end = newWords[start + length - 1].range.upperBound
                        return clean(String(current[end...]))
                    }
                }
            }
        }

        // A shorter hypothesis is normally a correction of the current context,
        // not a new utterance. Waiting for the next expansion avoids replaying it.
        if newWords.count <= oldWords.count,
           newWords.first?.normalized == oldWords.first?.normalized {
            return ""
        }
        return current
    }

    private struct Word {
        let normalized: String
        let range: Range<String.Index>
    }

    private static func words(in text: String) -> [Word] {
        var result: [Word] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { value, range, _, _ in
            guard let value else { return }
            result.append(Word(normalized: value.lowercased(), range: range))
        }
        return result
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isWordBoundary(in text: String, at index: String.Index) -> Bool {
        index == text.endIndex || text[index].isWhitespace || text[index].isPunctuation
    }
}

enum SubtitleCueBuilder {
    static func cue(from text: String, maximumWords: Int = 12, maximumCharacters: Int = 52) -> String {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count > maximumCharacters || clean.split(separator: " ").count > maximumWords else {
            return clean
        }

        let separators = CharacterSet(charactersIn: ",;:，；：.!?。！？")
        if let boundary = clean.unicodeScalars.lastIndex(where: { separators.contains($0) }) {
            let start = clean.unicodeScalars.index(after: boundary)
            let clause = String(clean.unicodeScalars[start...]).trimmingCharacters(in: .whitespaces)
            if clause.count >= 8, clause.count <= maximumCharacters {
                return clause
            }
        }

        let words = clean.split(separator: " ")
        if words.count > 1 {
            return words.suffix(maximumWords).joined(separator: " ")
        }
        return String(clean.suffix(maximumCharacters))
    }
}
