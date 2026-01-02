import NaturalLanguage

/// Client-side language detection using Apple's NaturalLanguage framework.
/// Matches webapp pattern: detect locally before sending to backend.
enum LanguageDetectionService {

    /// Minimum text length for reliable detection.
    private static let minLength = 20

    /// Minimum confidence threshold for detection.
    private static let minConfidence: Double = 0.5

    /// Map NLLanguage to our language codes.
    /// Note: Apple's NaturalLanguage doesn't support Romansh (rm) or Swiss German (gsw).
    /// These will fall back to backend LLM detection which handles them correctly.
    private static let languageMap: [NLLanguage: String] = [
        .english: "en",
        .german: "de",
        .french: "fr",
        .italian: "it",
    ]

    /// Detect language from text.
    /// Returns language code if detected with confidence, nil otherwise.
    static func detectLanguage(_ text: String) -> String? {
        // Need minimum text for reliable detection
        guard text.count >= minLength else {
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)

        // Get language hypotheses with probabilities
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)

        // Find best match among our supported languages
        for (language, confidence) in hypotheses.sorted(by: { $0.value > $1.value }) {
            guard confidence >= minConfidence else {
                continue
            }

            if let code = languageMap[language] {
                return code
            }
        }

        return nil
    }

    /// Detect language with confidence level.
    /// Returns (languageCode, confidence) or nil if not detected.
    static func detectLanguageWithConfidence(_ text: String) -> (language: String, confidence: Double)? {
        guard text.count >= minLength else {
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)

        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)

        for (language, confidence) in hypotheses.sorted(by: { $0.value > $1.value }) {
            if let code = languageMap[language] {
                return (code, confidence)
            }
        }

        return nil
    }
}
