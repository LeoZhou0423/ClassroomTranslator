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
            let suffix = cleanDelta(String(current[previousEndInCurrent...]))
            let previousEndInSuffix = suffix.index(suffix.startIndex, offsetBy: min(previous.count, suffix.count))
            if suffix.hasPrefix(previous), isWordBoundary(in: suffix, at: previousEndInSuffix) {
                return cleanDelta(String(suffix[previousEndInSuffix...]))
            }
            return suffix
        }

        let oldWords = words(in: previous)
        let newWords = words(in: current)
        guard !oldWords.isEmpty, !newWords.isEmpty else { return current }

        if newWords.count >= oldWords.count,
           Array(newWords.prefix(oldWords.count).map(\.normalized)) == oldWords.map(\.normalized) {
            let end = newWords[oldWords.count - 1].range.upperBound
            return cleanDelta(String(current[end...]))
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
                        return cleanDelta(String(current[end...]))
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

    /// Recognition revisions often replace the punctuation attached to the
    /// last committed word (for example `Hello.` -> `Hello, everyone`). The
    /// replacement mark belongs to the committed boundary, not the new text.
    private static func cleanDelta(_ text: String) -> String {
        let normalized = clean(text)
        let boundaryMarks = CharacterSet(charactersIn: ",.;:!?，。；：！？")
        guard let start = normalized.unicodeScalars.firstIndex(where: { !boundaryMarks.contains($0) }) else {
            return ""
        }
        return clean(String(normalized.unicodeScalars[start...]))
    }

    private static func isWordBoundary(in text: String, at index: String.Index) -> Bool {
        index == text.endIndex || text[index].isWhitespace || text[index].isPunctuation
    }
}

/// Turns a recognizer snapshot into appendable sentence units. Translation
/// consumes these units independently so a growing classroom transcript never
/// sends its complete history back through TranslationSession.
enum StableSentenceUnits {
    static func split(_ text: String, includeTrailingFragment: Bool = true) -> [String] {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !clean.isEmpty else { return [] }
        var result: [String] = []
        var start = clean.startIndex
        var index = clean.startIndex
        while index < clean.endIndex {
            let character = clean[index]
            let next = clean.index(after: index)
            var isBoundary = "!?。！？…".contains(character)
            if character == "." {
                let previous = index > clean.startIndex ? clean[clean.index(before: index)] : nil
                let following = next < clean.endIndex ? clean[next] : nil
                isBoundary = !(previous?.isNumber == true && following?.isNumber == true)
            }
            if isBoundary {
                let unit = String(clean[start..<next]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !unit.isEmpty { result.append(unit) }
                start = next
                while start < clean.endIndex, clean[start].isWhitespace {
                    start = clean.index(after: start)
                }
                index = start
            } else {
                index = next
            }
        }
        if includeTrailingFragment, start < clean.endIndex {
            let tail = String(clean[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { result.append(tail) }
        }
        return result
    }
}

/// Whisper decodes overlapping rolling windows rather than a single growing
/// recognizer snapshot. Preserve text that was already shown when a later
/// window (especially the final silence window) contains only its shorter tail.
enum WhisperTranscriptAccumulator {
    static func appendingUtterance(_ utterance: String, to history: String) -> String {
        let history = clean(history)
        let utterance = clean(utterance)
        guard !utterance.isEmpty else { return history }
        return history.isEmpty ? utterance : history + " " + utterance
    }

    /// A silence-boundary decode may legitimately return no text even though
    /// an earlier rolling-window decode already produced a good partial. Keep
    /// that accumulated text so the caller can commit and translate it.
    static func finalCandidate(accumulated: String, decoded: String?) -> String {
        guard let decoded else { return clean(accumulated) }
        let cleanedDecoded = clean(decoded)
        guard !cleanedDecoded.isEmpty else { return clean(accumulated) }
        return merged(previous: accumulated, current: cleanedDecoded)
    }

    static func merged(previous: String, current: String) -> String {
        let old = clean(previous)
        let new = clean(current)
        guard !new.isEmpty else { return old }
        guard !old.isEmpty else { return new }
        guard old.caseInsensitiveCompare(new) != .orderedSame else { return new }

        let oldWords = old.split(separator: " ")
        let newWords = new.split(separator: " ")
        let normalizedOld = oldWords.map { normalize(String($0)) }
        let normalizedNew = newWords.map { normalize(String($0)) }

        if normalizedNew.starts(with: normalizedOld) { return new }
        if normalizedOld.starts(with: normalizedNew) { return old }

        // A rolling window drops words from the front. Join its new tail onto
        // the longest suffix/prefix overlap so earlier correct words survive.
        let maximum = min(normalizedOld.count, normalizedNew.count)
        if maximum >= 2 {
            for length in stride(from: maximum, through: 2, by: -1) {
                if Array(normalizedOld.suffix(length)) == Array(normalizedNew.prefix(length)) {
                    let unseenTail = newWords.dropFirst(length).joined(separator: " ")
                    return unseenTail.isEmpty ? old : old + " " + unseenTail
                }
            }
        }

        // A shorter final is commonly Whisper revising only the tail. Losing
        // the already displayed prefix is worse than keeping that hypothesis.
        if normalizedNew.count < normalizedOld.count { return old }
        return new
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}

/// Keep idle silence from starting a decode, and preserve the utterance while
/// a slow decoder runs after the user stops speaking.
struct WhisperAudioWindow {
    private(set) var samples: [Float] = []
    private var hasSpeech = false
    private var trailingSilence = 0
    private let sampleRate: Int

    init(sampleRate: Int = 16_000) { self.sampleRate = sampleRate }

    @discardableResult
    mutating func append(_ input: [Float], isSpeech: Bool) -> Int {
        if !hasSpeech && !isSpeech {
            samples.append(contentsOf: input)
            let preRoll = sampleRate * 3 / 10
            if samples.count > preRoll { samples.removeFirst(samples.count - preRoll) }
            return 0
        }
        let count: Int
        if isSpeech {
            hasSpeech = true
            trailingSilence = 0
            count = input.count
        } else {
            count = min(input.count, max(0, sampleRate - trailingSilence))
            trailingSilence += count
        }
        samples.append(contentsOf: input.prefix(count))
        let maximum = sampleRate * WhisperSpeechWindowLimit.seconds
        if samples.count > maximum { samples.removeFirst(samples.count - maximum) }
        return count
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        hasSpeech = false
        trailingSilence = 0
    }
}

enum WhisperSpeechWindowLimit {
    static let seconds = 8
}

enum WhisperDecodePolicy {
    /// The VM audio bridge commonly delivers speech around 0.002 RMS. Using a
    /// desktop-microphone threshold of 0.01 drops quiet words and sentence ends.
    static let minimumSpeechRMS: Float = 0.0015

    static func containsSpeech(rms: Float) -> Bool {
        rms >= minimumSpeechRMS
    }

    /// Buffers (each ~42 ms) of consecutive speech needed to open a segment
    /// from silence. Two buffers filter isolated VM noise spikes that sit just
    /// above the quiet-speech RMS floor; once a segment is open, single speech
    /// buffers keep it alive via `hasSpeech`.
    static let segmentOpenSpeechBuffers = 2

    static func shouldOpenSegment(consecutiveSpeechBuffers: Int, hasSpeech: Bool) -> Bool {
        hasSpeech || consecutiveSpeechBuffers >= segmentOpenSpeechBuffers
    }

    static func shouldDecode(
        hasSpeech: Bool,
        decodeInFlight: Bool,
        bufferedSamples: Int,
        newSamplesSinceDecode: Int,
        silentFor: TimeInterval,
        sampleRate: Int = 16_000,
        hasEmittedText: Bool = true
    ) -> Bool {
        guard hasSpeech, !decodeInFlight else { return false }
        // Finalize even a short utterance after a real pause.
        if silentFor > 1.0, bufferedSamples >= sampleRate / 2 { return true }
        // Produce the first preview sooner; subsequent decodes remain spaced
        // out to avoid repeatedly spending CPU on the same rolling window.
        let requiredSamples = hasEmittedText ? sampleRate * 5 / 2 : sampleRate * 5 / 4
        return newSamplesSinceDecode >= requiredSamples
    }

    static func shouldFinalize(
        speechRevisionAtDecodeStart: Int,
        currentSpeechRevision: Int,
        silentFor: TimeInterval
    ) -> Bool {
        silentFor > 1.0 && speechRevisionAtDecodeStart == currentSpeechRevision
    }

    /// A decode that started while speech was still arriving cannot be final.
    /// If it finishes after the pause, immediately decode the newest window;
    /// otherwise a slow model can miss the only silence callback that would
    /// have promoted the utterance to final text.
    static func shouldScheduleFollowUpFinal(
        speechRevisionAtDecodeStart: Int,
        currentSpeechRevision: Int,
        silentFor: TimeInterval,
        hasSpeech: Bool
    ) -> Bool {
        hasSpeech
            && silentFor > 1.0
            && speechRevisionAtDecodeStart != currentSpeechRevision
    }
}

enum WhisperTranscriptQuality {
    /// Reject obvious decoder loops such as "i n i n i n". These are produced
    /// by silence/noise and should never become persisted classroom content.
    static func accepted(_ text: String) -> String? {
        let withoutSoundTags = text.replacingOccurrences(
            of: #"(?i)[\[(](?:sad\s+)?(?:music|noise|sobs?|sobbing|scoffs?|laughter|applause|silence|inaudible)[\])]"#,
            with: "",
            options: .regularExpression
        )
        let clean = withoutSoundTags.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let soundOnly = clean.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard !soundOnly.isEmpty,
              !["music", "sad music", "noise", "sad noise", "sobs", "scoffs", "silence", "inaudible"].contains(soundOnly)
        else { return nil }
        let tokens = clean.split(separator: " ").map {
            $0.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }.filter { !$0.isEmpty }
        guard tokens.count >= 8 else { return clean }
        let uniqueRatio = Double(Set(tokens).count) / Double(tokens.count)
        return uniqueRatio <= 0.25 ? nil : clean
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

/// A completed sentence remains usable when the recognizer appends a new tail.
/// Revisions of that sentence must invalidate its translation.
enum LivePartialTranslationPolicy {
    static func containsUnit(_ unit: String, in snapshot: String) -> Bool {
        guard !unit.isEmpty else { return false }
        return StableSentenceUnits.split(snapshot, includeTrailingFragment: false).last == unit
    }
}

/// Reopen only recent, same-speaker English fragments. Do not use a generic
/// lowercase rule: Whisper can lowercase an entirely new sentence too.
enum TranscriptContinuationPolicy {
    static func needsContinuation(_ text: String) -> Bool {
        let clean = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = clean.last else { return false }
        if !".!?。！？…".contains(end) { return true }
        if "!?。！？".contains(end) { return false }
        let bare = clean.trimmingCharacters(in: .punctuationCharacters)
        let words = bare.split(whereSeparator: \.isWhitespace)
        let last = String(words.last ?? "")
        if ["that is", "you know", "for that"].contains(bare) { return true }
        if ["a", "an", "the", "to", "of", "for", "with", "during", "because", "and", "or", "my", "your", "our", "their", "office"].contains(last) { return true }
        return words.count <= 3 && ["and ", "but ", "to ", "for "].contains { bare.hasPrefix($0) }
    }

    static func joined(previous: String, incoming: String, sameSpeaker: Bool, age: TimeInterval) -> String? {
        guard sameSpeaker, age >= 0, age <= 15 else { return nil }
        let left = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty,
              left.split(whereSeparator: \.isWhitespace).count < 100,
              !"!?。！？".contains(left.last!) else { return nil }
        let words = right.lowercased().split(whereSeparator: \.isWhitespace)
        let leftWords = left.lowercased().split(whereSeparator: \.isWhitespace)
        let last = String(leftWords.last ?? "").trimmingCharacters(in: .punctuationCharacters)
        let first = String(words.first ?? "").trimmingCharacters(in: .punctuationCharacters)
        let incompleteEnds: Set<String> = ["a", "an", "the", "to", "of", "for", "with", "during", "because", "and", "or", "that", "my", "your", "our", "their", "office"]
        let dependentFragment = words.count <= 3 && ["and", "but", "for"].contains(first)
        let startsDependentClause = first == "to" || first == "because" || right.lowercased().hasPrefix("for that") || dependentFragment
        let discourseFragment = ["that is", "you know", "for that"].contains(left.lowercased().trimmingCharacters(in: .punctuationCharacters))
        let incomplete = incompleteEnds.contains(last) || discourseFragment || !".!?。！？…".contains(left.last!)
        guard incomplete || startsDependentClause else { return nil }
        // Restore a compound that was split by an ASR-inserted period.
        let joinsOfficeHours = last == "office" && first == "hours"
        let stripBoundary = incomplete || joinsOfficeHours || first == "to" || first == "because" || dependentFragment
        let prefix = stripBoundary ? left.trimmingCharacters(in: CharacterSet(charactersIn: ".…- ")) : left
        return prefix + " " + right
    }
}
