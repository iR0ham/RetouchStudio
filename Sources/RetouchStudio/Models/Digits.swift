import Foundation

/// Numbers follow the language of the interface: Latin digits in English,
/// Persian-Indic digits in Persian, so a Persian screen reads as one script.
enum Digits {
    private static let persianDigits = Array("۰۱۲۳۴۵۶۷۸۹")

    static func num(_ value: Int) -> String {
        convert(String(value))
    }

    /// A percentage, written the way the language writes it.
    static func percent(_ value: Int) -> String {
        guard AppLanguage.current == .persian else { return "\(value)%" }
        return "\(num(value))٪"
    }

    /// A width × height readout with its unit token. The token is Latin in both
    /// languages — `MB`, `GB` and `px` are technical units, not words. In
    /// Persian the whole run is isolated left-to-right, because inside a
    /// right-to-left paragraph an unisolated run puts the unit in front of the
    /// numbers and swaps the pair ("px ۴۰۳۲ × ۲۲۶۸").
    static func pixelSize(_ width: Int, _ height: Int,
                          language: AppLanguage = .current) -> String {
        let run = "\(number(width, language)) × \(number(height, language)) px"
        return language == .persian ? isolate(run) : run
    }

    /// One pixel count, such as a brush diameter, under the same rule.
    static func pixels(_ value: Int, language: AppLanguage = .current) -> String {
        let run = "\(number(value, language)) px"
        return language == .persian ? isolate(run) : run
    }

    /// A size already formatted by `ByteCountFormatter` ("48.5 MB"). English
    /// gets it back untouched; Persian converts the digits and the decimal
    /// separator, keeps the unit token Latin, and isolates the run.
    ///
    /// The conversion is per character rather than per token, because that
    /// formatter spells some readings out in words: 0 bytes is "Zero KB" and a
    /// one-byte file is "1 byte", so a split into number plus unit does not
    /// always apply. Every Persian reading this produces is still one isolated
    /// left-to-right run — a spelled-out unit is two Latin words, and inside an
    /// RTL paragraph an unisolated pair of them can flip.
    static func size(_ formatted: String, language: AppLanguage = .current) -> String {
        guard language == .persian else { return formatted }
        let number = persian(formatted).replacingOccurrences(of: ".", with: "٫")
        return isolate(number)
    }

    /// A left-to-right run inside right-to-left prose. The isolate pair
    /// (U+2066 … U+2069) keeps the run's internal order whatever the
    /// paragraph direction does around it.
    static func isolate(_ text: String) -> String { "\u{2066}\(text)\u{2069}" }

    private static func number(_ value: Int, _ language: AppLanguage) -> String {
        language == .persian ? persian(String(value)) : String(value)
    }

    /// Converts the Latin digits inside an already-formatted string and leaves
    /// every other character alone, so a mixed string keeps its punctuation.
    static func convert(_ text: String) -> String {
        guard AppLanguage.current == .persian else { return text }
        return persian(text)
    }

    /// The same conversion without asking the interface language, for a string
    /// that is already written in Persian (the Persian table speaks for
    /// itself, even when a test runs under the English default).
    static func persian(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            if character.isASCII,
               let value = character.wholeNumberValue,
               let index = Int(exactly: value),
               persianDigits.indices.contains(index) {
                out.append(persianDigits[index])
            } else {
                out.append(character)
            }
        }
        return out
    }
}
