import Foundation

/// Rule-based handling of self-corrections spoken during dictation ("sorry I mean Tuesday",
/// "scratch that", "delete the last sentence", "no wait, make it 5pm"). Cases the rules can't
/// resolve confidently are flagged so the keyboard can ask the on-device model instead.
struct CorrectionResult: Equatable {
    var text: String
    var applied: Int
    var needsModel: Bool
    /// What each spoken correction replaced, in order ("Monday" → "Tuesday"), for the review diff.
    var changes: [CorrectionChange] = []
}

struct CorrectionChange: Equatable, Codable, Hashable {
    var from: String
    var to: String
}

enum SpokenCorrections {
    private static let gap = #"[\s,]+"#

    private static func phrase(_ words: String) -> String {
        words.split(separator: " ").joined(separator: gap)
    }

    private static let deleteCues = [
        "scratch that", "strike that", "delete that", "forget that",
        "delete the last sentence", "delete last sentence", "remove the last sentence",
        "scratch the last sentence",
    ]

    private static let replaceCues = [
        "sorry i mean", "sorry i meant", "sorry make it", "sorry make that",
        "no i mean", "no i meant", "no wait make it", "no wait make that", "wait no make it",
        "no wait", "wait no", "no make it", "no make that", "actually make it", "actually make that",
        "i meant", "or rather", "correction",
    ]

    private static let deletePattern =
        #"\b(?:"# + deleteCues.map(phrase).joined(separator: "|") + #")\b[.!?,:]*"#
    private static let replacePattern =
        #"\b(?:"# + replaceCues.map(phrase).joined(separator: "|") + #")\b[,:]?"#

    private static let weekdays = "monday|tuesday|wednesday|thursday|friday|saturday|sunday|today|tomorrow|tonight|yesterday"
    private static let months = "january|february|march|april|may|june|july|august|september|october|november|december"
    private static let time = #"(?:\d{1,2}(?::\d{2})?\s?(?:a\.?m\.?|p\.?m\.?|o'clock)|\d{1,2}:\d{2}|noon|midnight)"#
    private static let numberWords = "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|twenty|thirty|forty|fifty|hundred"
    private static let number = #"(?:\$?\d+(?:[.,]\d+)?%?|"# + numberWords + ")"

    private static let classes: [String] = [
        #"\b(?:"# + weekdays + #")\b"#,
        #"\b(?:"# + months + #")\b"#,
        #"\b"# + time + #"(?=\W|$)"#,
        #"(?<![\w$])"# + number + #"(?![\w%])"#,
    ]

    static func apply(_ raw: String) -> CorrectionResult {
        var text = raw
        var applied = 0
        var needsModel = false
        var changes: [CorrectionChange] = []
        for _ in 0..<20 {
            let delete = text.range(of: deletePattern, options: [.regularExpression, .caseInsensitive])
            let replace = text.range(of: replacePattern, options: [.regularExpression, .caseInsensitive])
            if let delete, replace == nil || delete.lowerBound <= replace!.lowerBound {
                let before = String(text[..<delete.lowerBound])
                let after = String(text[delete.upperBound...])
                let kept = dropLastSentence(before)
                let removed = String(before.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(kept.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !removed.isEmpty { changes.append(CorrectionChange(from: removed, to: "")) }
                text = join(kept, after)
                applied += 1
            } else if let replace {
                let before = String(text[..<replace.lowerBound])
                var after = String(text[replace.upperBound...])
                after = after.replacingOccurrences(
                    of: #"^[\s,:]*(?:(?:make|change)\s+(?:it|that)(?:\s+to)?|it'?s|it\s+is|it\s+was)?[\s,:]*"#,
                    with: "", options: [.regularExpression, .caseInsensitive])
                let end = after.range(of: #"[.!?](?=\s|$)"#, options: .regularExpression)?.lowerBound ?? after.endIndex
                let replacement = String(after[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rest = String(after[end...])
                guard !replacement.isEmpty else {
                    text = join(before, rest)
                    continue
                }
                let (fixed, confident, removed) = substituteTracked(in: before, with: replacement)
                needsModel = needsModel || !confident
                if !removed.isEmpty {
                    let shown = removed.contains(" ") ? replacement : replacement.replacingOccurrences(
                        of: "^(?:on |at |by |in )", with: "", options: [.regularExpression, .caseInsensitive])
                    changes.append(CorrectionChange(from: removed, to: shown))
                }
                text = join(fixed, rest)
                applied += 1
            } else {
                break
            }
        }
        return CorrectionResult(text: tidy(text), applied: applied, needsModel: needsModel, changes: changes)
    }

    /// Replaces the part of `before` the speaker meant to correct with `replacement`.
    static func substitute(in before: String, with replacement: String) -> (String, Bool) {
        let (text, confident, _) = substituteTracked(in: before, with: replacement)
        return (text, confident)
    }

    /// `substitute`, also returning the text that was replaced.
    static func substituteTracked(in before: String, with replacement: String) -> (String, Bool, String) {
        var head = before.trimmingCharacters(in: .whitespacesAndNewlines)
        var terminator = ""
        while let last = head.last, ".!?,;:".contains(last) {
            if ".!?".contains(last) { terminator = String(last) }
            head.removeLast()
        }
        guard !head.isEmpty else { return (replacement, false, "") }

        let bare = replacement.replacingOccurrences(of: "^(?:on |at |by |in )", with: "", options: [.regularExpression, .caseInsensitive])
        for pattern in classes where bare.range(of: "^" + pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            if var target = lastMatch(of: pattern, in: head) {
                // "Monday at noon, sorry I mean Tuesday at 1pm": later values the replacement
                // also restates are part of what it supersedes.
                let tail = String(bare[(bare.range(of: "^" + pattern, options: [.regularExpression, .caseInsensitive])!.upperBound)...])
                for other in classes where tail.range(of: other, options: [.regularExpression, .caseInsensitive]) != nil {
                    let afterTarget = String(head[target.upperBound...])
                    if let later = lastMatch(of: other, in: afterTarget) {
                        let end = head.index(target.upperBound, offsetBy: afterTarget.distance(from: afterTarget.startIndex, to: later.upperBound))
                        if end > target.upperBound { target = target.lowerBound..<end }
                    }
                }
                let removed = String(head[target])
                head.replaceSubrange(target, with: bare)
                return (head + terminator, true, removed)
            }
        }

        let replacementWords = replacement.split(separator: " ")
        var words = head.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let count = min(replacementWords.count, words.count)
        // "the red one, sorry I mean the blue one": a shared first word aligns the swap.
        var confident = replacementWords.count == 1
        if replacementWords.count > 1, count == replacementWords.count {
            confident = words[words.count - count].lowercased() == replacementWords[0].lowercased()
        }
        if replacementWords.count > 4 { confident = false }
        let removed = words.suffix(count).joined(separator: " ")
        words.removeLast(count)
        words.append(replacement)
        return (words.joined(separator: " ") + terminator, confident, removed)
    }

    private static func lastMatch(of pattern: String, in text: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let last = matches.last else { return nil }
        return Range(last.range, in: text)
    }

    static func dropLastSentence(_ text: String) -> String {
        var head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = head.last, ".!?,;:".contains(last) { head.removeLast() }
        // A sentence ends at . ! ? before whitespace, so "4.50" stays whole. After "Dr" it never ends;
        // after "p.m" or "etc" it ends only when a capitalised word follows.
        let boundary = #"(?<!\b(?:[ap]\.m|e\.g|i\.e|Mr|Mrs|Ms|Dr|St|vs|etc))\.(?=\s)"#
            + #"|(?<=\b(?:[ap]\.m|etc))\.(?=\s+(?-i:[A-Z]))|[!?](?=\s)|\n"#
        guard let end = lastMatch(of: boundary, in: head) else { return "" }
        return String(head[..<end.upperBound])
    }

    private static func join(_ before: String, _ after: String) -> String {
        let a = before.trimmingCharacters(in: .whitespaces)
        let b = after.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        if let first = b.first, ".!?,;:".contains(first) {
            var head = a
            while let last = head.last, ".!?,;:".contains(last) { head.removeLast() }
            return head + b
        }
        return a + " " + b
    }

    private static let fillers = #"(?i)(?<![\w'])(?:um+|uh+|erm+|uhm+|hmm+|ah+)(?![\w'])[,.]?\s*"#

    /// Removes spoken fillers, repairs spacing and sentence capitalization.
    static func tidy(_ text: String) -> String {
        var s = text.replacingOccurrences(of: fillers, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([.!?]){2,}"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #",([.!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        var capitalize = true
        var afterTerminator = false
        for ch in s {
            if afterTerminator, !ch.isWhitespace { capitalize = false }
            afterTerminator = false
            if capitalize, ch.isLetter {
                out += ch.uppercased()
                capitalize = false
            } else {
                out.append(ch)
                if ".!?\n".contains(ch) { capitalize = true; afterTerminator = ch != "\n" }
            }
        }
        out = out.replacingOccurrences(of: #"\bi\b(?!\.)"#, with: "I", options: .regularExpression)
        return out
    }
}
