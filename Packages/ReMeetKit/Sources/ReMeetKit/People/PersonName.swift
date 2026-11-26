import Foundation

/// Normalizes and compares human names across calendar formats (`"Patel, Priya R"`,
/// `"THOMPSON, MORGAN"`), honorifics (`"Dr. Patel"`), and short/first names (`"Elena"`).
public struct PersonName: Equatable, Sendable {
    public var raw: String
    public var honorific: String?
    public var first: String
    public var middle: [String]
    public var last: String
    public var isHonorificLastName: Bool
    public var tokens: [String]

    public init(raw: String,
                honorific: String?,
                first: String,
                middle: [String],
                last: String,
                isHonorificLastName: Bool,
                tokens: [String]) {
        self.raw = raw
        self.honorific = honorific
        self.first = first
        self.middle = middle
        self.last = last
        self.isHonorificLastName = isHonorificLastName
        self.tokens = tokens
    }

    /// Canonical display string in `"First [Middle] Last"` order (preserving honorifics when present).
    public var canonicalDisplayName: String {
        if isHonorificLastName, !last.isEmpty {
            return [honorific, last].compactMap { $0 }.joined(separator: " ")
        }
        if !first.isEmpty, !last.isEmpty {
            let parts = ([honorific, first] + middle.map { Optional($0) } + [last]).compactMap { $0 }
            return parts.joined(separator: " ")
        }
        if !first.isEmpty {
            return [honorific, first].compactMap { $0 }.joined(separator: " ")
        }
        if !tokens.isEmpty {
            return ([honorific] + tokens.map { Optional($0) }).compactMap { $0 }.joined(separator: " ")
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let honorificMap: [String: String] = [
        "dr": "Dr.", "dr.": "Dr.",
        "prof": "Prof.", "prof.": "Prof.", "professor": "Prof.",
        "mr": "Mr.", "mr.": "Mr.",
        "mrs": "Mrs.", "mrs.": "Mrs.",
        "ms": "Ms.", "ms.": "Ms.",
        "mx": "Mx.", "mx.": "Mx.",
    ]

    private static let suffixSet: Set<String> = [
        "jr", "jr.", "sr", "sr.", "ii", "iii", "iv", "v", "phd", "ph.d", "ph.d.",
        "md", "m.d", "m.d.", "pe", "p.e", "p.e.", "esq", "esq."
    ]

    public static func parse(_ rawInput: String) -> PersonName {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return PersonName(raw: rawInput, honorific: nil, first: "", middle: [], last: "", isHonorificLastName: false, tokens: [])
        }

        // Strip trailing/inline parenthetical annotations such as "(External)", "(Guest)", "(Host)".
        let withoutParens = trimmed
            .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let working = withoutParens.isEmpty ? trimmed : withoutParens

        // Detect "Last, First [Middle]" format when there is a single comma and the right side is not a suffix.
        let ordered: String
        let commaParts = working.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if commaParts.count == 2,
           !commaParts[0].isEmpty,
           !commaParts[1].isEmpty,
           !suffixSet.contains(commaParts[1].lowercased()) {
            ordered = "\(commaParts[1]) \(commaParts[0])"
        } else if commaParts.count == 2,
                  !commaParts[0].isEmpty,
                  suffixSet.contains(commaParts[1].lowercased()) {
            ordered = commaParts[0]
        } else {
            ordered = working
        }

        // Fix ALL-CAPS input while preserving mixed-case names like McDonald / O'Brien.
        let isAllCaps = isAllUppercaseWordRun(ordered)
        var rawTokens = ordered
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        if isAllCaps {
            rawTokens = rawTokens.map(titleCaseToken)
        }

        // Drop trailing suffixes like Jr., PhD when parsing core name tokens.
        while let lastTok = rawTokens.last, rawTokens.count > 1, suffixSet.contains(lastTok.lowercased()) {
            rawTokens.removeLast()
        }

        var honorific: String?
        if let firstTok = rawTokens.first, let normalized = honorificMap[firstTok.lowercased()] {
            honorific = normalized
            rawTokens.removeFirst()
        }

        if let _ = honorific, rawTokens.count == 1 {
            let lastOnly = rawTokens[0]
            return PersonName(
                raw: rawInput,
                honorific: honorific,
                first: "",
                middle: [],
                last: lastOnly,
                isHonorificLastName: true,
                tokens: [lastOnly]
            )
        }

        if rawTokens.count >= 2 {
            let first = rawTokens[0]
            let last = rawTokens[rawTokens.count - 1]
            let middle = rawTokens.count > 2 ? Array(rawTokens[1..<(rawTokens.count - 1)]) : []
            return PersonName(
                raw: rawInput,
                honorific: honorific,
                first: first,
                middle: middle,
                last: last,
                isHonorificLastName: false,
                tokens: rawTokens
            )
        }

        let single = rawTokens.first ?? ""
        return PersonName(
            raw: rawInput,
            honorific: honorific,
            first: single,
            middle: [],
            last: "",
            isHonorificLastName: false,
            tokens: rawTokens
        )
    }

    /// Picks the cleanest unified display name when merging two representations of the same person
    /// (e.g. `"Dr. Patel"` + `"Patel, Priya R"` -> `"Dr. Priya R Patel"`).
    public static func preferredMergedDisplayName(existing: String, incoming: String) -> String {
        let e = parse(existing)
        let i = parse(incoming)
        let combinedHonorific = e.honorific ?? i.honorific

        let eFull = !e.first.isEmpty && !e.last.isEmpty
        let iFull = !i.first.isEmpty && !i.last.isEmpty

        if eFull || iFull {
            let chosen: PersonName
            if eFull && iFull {
                if i.tokens.count > e.tokens.count {
                    chosen = i
                } else {
                    chosen = e
                }
            } else {
                chosen = iFull ? i : e
            }
            var parts: [String] = []
            if let combinedHonorific { parts.append(combinedHonorific) }
            parts.append(chosen.first)
            parts.append(contentsOf: chosen.middle)
            parts.append(chosen.last)
            return parts.joined(separator: " ")
        }

        let eCanon = e.canonicalDisplayName
        let iCanon = i.canonicalDisplayName
        if i.tokens.count > e.tokens.count { return iCanon }
        if e.tokens.count > i.tokens.count { return eCanon }
        return eCanon.count >= iCanon.count ? eCanon : iCanon
    }

    /// Returns true if `alias` carries real distinct naming context (e.g. `"Dr. Patel"`, `"Alex"`)
    /// rather than merely being a `"Last, First"` or ALL-CAPS reformatting of `canonical`.
    public static func isReadableAlias(_ alias: String, for canonical: String) -> Bool {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare(canonical) != .orderedSame else { return false }
        let p = parse(trimmed)
        let c = parse(canonical)
        return p.canonicalDisplayName.caseInsensitiveCompare(c.canonicalDisplayName) != .orderedSame
    }

    public static func normalizedToken(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }

    private static func isAllUppercaseWordRun(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 2 else { return false }
        return s == s.uppercased() && s != s.lowercased()
    }

    private static func titleCaseToken(_ token: String) -> String {
        let letters = token.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        // Keep single-letter initials like "L" or "Y" uppercase.
        if letters.count <= 1 { return token.uppercased() }
        // Handle hyphenated/apostrophe names like "O'BRIEN" -> "O'Brien".
        var out = ""
        var startOfWord = true
        for scalar in token.unicodeScalars {
            let ch = Character(scalar)
            if CharacterSet.letters.contains(scalar) {
                let s = String(ch)
                out += startOfWord ? s.uppercased() : s.lowercased()
                startOfWord = false
            } else {
                out.append(ch)
                startOfWord = true
            }
        }
        return out
    }
}
