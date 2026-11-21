import Foundation

enum Prompts {
    static func prompt(for task: BridgeTask, text: String) -> String {
        switch task {
        case .fix:
            return """
            Fix the grammar, spelling and punctuation of the text below and remove filler words \
            (um, uh, like, you know). Keep the author's wording, meaning, tone and language. \
            Do not add anything. Reply with only the corrected text.

            Text:
            \(text)
            """
        case .rewrite:
            return """
            Rewrite the text below so it reads clearly and naturally: fix grammar and punctuation, \
            drop filler words and repetition, and tighten the phrasing. Keep the meaning, the facts \
            and the language. Reply with only the rewritten text.

            Text:
            \(text)
            """
        case .correct:
            return """
            The text below was dictated. The speaker corrected themselves while talking \
            (for example "sorry I mean", "scratch that", "no wait", "delete the last sentence"). \
            Write the final text the speaker intended: apply each correction, drop the replaced \
            words and the correction phrases, and keep everything else as spoken. \
            Reply with only the final text.

            Dictation:
            \(text)
            """
        }
    }

    /// Strips wrappers small models like to add ("Here is the corrected text:", quotes, fences).
    static func clean(_ output: String) -> String {
        var s = output.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"^```[a-zA-Z]*\n?|\n?```$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"^(?i)(?:sure[,!.]?\s*)?(?:here(?:'s| is) (?:the )?(?:corrected|fixed|final|rewritten|cleaned[- ]up)?[^:\n]*:)\s*"#,
            with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?i)(?:corrected|fixed|final|rewritten) text:\s*"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, let first = s.first, let last = s.last,
           (first == "\"" && last == "\"") || (first == "“" && last == "”") {
            s = String(s.dropFirst().dropLast())
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
