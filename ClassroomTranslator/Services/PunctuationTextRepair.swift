import Foundation

/// Pure text repair for punctuation-model output (unit-testable, no model).
///
/// The zh-en CT-Transformer always emits full-width CJK marks (，。) even for
/// English input, and it sometimes inserts a sentence-final mark in the middle
/// of a sentence ("…Shelly Kagan。and the very first thing…"). Both problems
/// break `StableSentenceUnits`, which splits translation units on ASCII
/// `.!?` boundaries. This policy therefore:
///
/// 1. maps full-width marks to ASCII and fixes spacing artifacts;
/// 2. demotes a sentence boundary whose next word starts lowercase — English
///    sentences do not start lowercase, so "Kagan。and" becomes "Kagan, and"
///    while the legitimate "for that。It's" boundary survives.
enum PunctuationTextRepair {
    static func repaired(_ text: String) -> String {
        demoteFalseSentenceBoundaries(normalize(text))
    }

    /// Full-width CJK punctuation → ASCII, plus spacing artifacts produced by
    /// the model (" ," / "Kagan,but" / "- -").
    static func normalize(_ text: String) -> String {
        var mapped = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "，", "、": mapped.append(",")
            case "。": mapped.append(".")
            case "！": mapped.append("!")
            case "？": mapped.append("?")
            case "：": mapped.append(":")
            case "；": mapped.append(";")
            case "…": mapped.append(".")
            default: mapped.append(scalar)
            }
        }
        var output = String(mapped)
        while let collapsed = collapseDuplicateMarks(output) { output = collapsed }
        // No whitespace before a mark; one space after a mark when a letter
        // follows directly ("Kagan,but" → "Kagan, but", "that.It's" → "that. It's").
        // Letters only: "3.5" and "3,5" must stay untouched.
        output = output.replacingOccurrences(
            of: #"\s+([,.!?;:])"#,
            with: "$1",
            options: .regularExpression)
        output = output.replacingOccurrences(
            of: #"([,.!?;:])(?=[A-Za-z])"#,
            with: "$1 ",
            options: .regularExpression)
        // The model spaces Whisper's trailing "--" into "- -".
        output = output.replacingOccurrences(
            of: #"\s-\s-"#,
            with: " --",
            options: .regularExpression)
        return output.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A `.!?` followed by a lowercase word cannot be a real English sentence
    /// end; the model misfired, so demote it to a comma. Digit-dot-digit
    /// decimals and uppercase continuations are left untouched.
    static func demoteFalseSentenceBoundaries(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if ".!?".contains(Character(scalar)) {
                let next = scalars[(index + 1)...].first { !$0.properties.isWhitespace }
                let previous = index > 0 ? scalars[index - 1] : nil
                let decimal = scalar == "."
                    && previous?.properties.numericType == .decimal
                    && next?.properties.numericType == .decimal
                let nextIsLowercase = next.map { character in
                    let string = String(character)
                    return character.properties.isAlphabetic
                        && string == string.lowercased() && string != string.uppercased()
                } ?? false
                if !decimal && nextIsLowercase {
                    output.append(",")
                    index += 1
                    // Swallow any duplicated mark run (".,", "?.") in one step.
                    while index < scalars.count,
                          ".!?,".contains(Character(scalars[index])) {
                        index += 1
                    }
                    continue
                }
            }
            output.append(scalar)
            index += 1
        }
        return String(String.UnicodeScalarView(output))
    }

    /// Collapse only *identical* adjacent marks (",," → ",", "..." → ".").
    /// Differing runs like "?!" / "!?" are legitimate English and stay.
    private static func collapseDuplicateMarks(_ text: String) -> String? {
        let marks: Set<Character> = [",", ".", "!", "?", ";", ":"]
        let scalars = Array(text.unicodeScalars)
        for index in 1..<scalars.count {
            if marks.contains(Character(scalars[index])),
               scalars[index] == scalars[index - 1] {
                var output = scalars
                output.remove(at: index)
                return String(String.UnicodeScalarView(output))
            }
        }
        return nil
    }
}
