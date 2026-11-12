import Foundation

/// Replaces things that look like secrets with `[redacted]` before they reach
/// AI notes. Applied to recognised screen text, window titles and control
/// names. Best effort: it works from the shape of the text, so it is a safety
/// net and not a guarantee. Unlike `AutoRedactor` it does not follow the
/// screenshot PII settings; emails and addresses stay, since notes without
/// them are of little use.
nonisolated enum AINotesRedactor {
    static let mark = "[redacted]"

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are literals in this file; a typo should fail loudly in the tests.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// Whole-match patterns: tokens with a recognisable shape.
    private static let tokens: [NSRegularExpression] = [
        regex(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#),
        regex(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}"#),                 // JWT
        regex(#"\b(sk|pk|rk)[-_](live|test|proj|ant)?[-_]?[A-Za-z0-9_-]{16,}"#),                 // Stripe, OpenAI, Anthropic style
        regex(#"\bgh[pousr]_[A-Za-z0-9]{20,}"#),                                                 // GitHub
        regex(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#),
        regex(#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#),                                               // Slack
        regex(#"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),                                                  // AWS access key ID
        regex(#"\bAIza[0-9A-Za-z_-]{30,}"#),                                                     // Google API key
        regex(#"\b[0-9a-fA-F]{32,}\b"#),                                                         // long hex: hashes, keys
    ]

    /// Patterns where only the value (capture group 2) is hidden and the label stays readable.
    private static let labelled: [NSRegularExpression] = [
        regex(#"\b(bearer|basic)(?:\s+)([A-Za-z0-9._~+/=-]{12,})"#, [.caseInsensitive]),
        regex(#"\b(pass(?:word|wd|phrase)?|secret(?:[ _-]?key)?|token|api[ _-]?key|access[ _-]?key|client[ _-]?secret|auth(?:orization)?|private[ _-]?key)(?:["']?\s*[:=]\s*["']?)([^\s"',;&]{4,})"#, [.caseInsensitive]),
    ]

    private static let digitRuns = regex(#"\b\d(?:[ -]?\d){12,18}\b"#)
    private static let cardGroups = regex(#"\b\d{4}[ -]\d{4}[ -]\d{1,4}(?:[ -]\d{1,4})?\b"#)
    private static let longWords = regex(#"[A-Za-z0-9+/_=-]{40,}"#)

    /// `valuesRunToEndOfLine` is for text recognised from the screen, where a long key is often
    /// read with a space in the middle: after a label such as "Secret key:" the rest of the line
    /// goes, not just the first word.
    static func redact(_ text: String, valuesRunToEndOfLine: Bool = false) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for pattern in tokens {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: mark)
        }
        for pattern in labelled {
            result = replace(pattern, in: result, firstOnly: valuesRunToEndOfLine) { match, string in
                guard match.numberOfRanges > 2, let value = Range(match.range(at: 2), in: string) else { return nil }
                // Already handled, or the scheme word of an Authorization header rather than its value.
                let word = string[value].lowercased()
                if ["bearer", "basic"].contains(word) { return nil }
                if !valuesRunToEndOfLine { return ["redacted", mark].contains(word) ? nil : (value, mark) }
                let end = string[value.upperBound...].firstIndex(where: \.isNewline) ?? string.endIndex
                return string[value.lowerBound..<end] == mark ? nil : (value.lowerBound..<end, mark)
            }
        }
        // Card numbers: 13 to 19 digits that pass the Luhn check.
        result = replace(digitRuns, in: result) { match, string in
            guard let range = Range(match.range, in: string), luhn(string[range].filter(\.isNumber)) else { return nil }
            return (range, mark)
        }
        // A card number still being typed fails the check, so digits in groups of four go regardless.
        result = cardGroups.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: mark)
        // Long unbroken strings that mix cases and digits are almost always keys.
        result = replace(longWords, in: result) { match, string in
            guard let range = Range(match.range, in: string) else { return nil }
            let word = string[range]
            let mixed = word.contains(where: \.isNumber) && word.contains(where: \.isUppercase) && word.contains(where: \.isLowercase)
            return mixed ? (range, mark) : nil
        }
        return result
    }

    static func luhn(_ digits: String) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard var value = character.wholeNumberValue else { return false }
            if index % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }

    /// Applies replacements back to front so earlier ranges stay valid.
    /// `firstOnly` stops at the first match that is replaced, for replacements that reach past the match.
    private static func replace(_ pattern: NSRegularExpression, in text: String, firstOnly: Bool = false,
                                with body: (NSTextCheckingResult, String) -> (Range<String.Index>, String)?) -> String {
        var result = text
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        if firstOnly {
            for match in matches {
                guard let (range, replacement) = body(match, text) else { continue }
                result.replaceSubrange(range, with: replacement)
                break
            }
            return result
        }
        for match in matches.reversed() {
            if let (range, replacement) = body(match, text) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }
}

nonisolated extension AINotesRedactor {
    /// Which characters of `original` were replaced: the span from the first
    /// character that differs to the last, as offsets into `original`.
    static func changedSpan(original: String, redacted: String) -> Range<Int>? {
        guard original != redacted else { return nil }
        let before = Array(original), after = Array(redacted)
        var start = 0
        while start < before.count, start < after.count, before[start] == after[start] { start += 1 }
        var tail = 0
        while tail < before.count - start, tail < after.count - start,
              before[before.count - 1 - tail] == after[after.count - 1 - tail] { tail += 1 }
        return start..<max(before.count - tail, start)
    }
}
