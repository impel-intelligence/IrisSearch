//
//  QuerySuite.swift
//  IrisSearch
//
//  Authored by Claude Opus 5 (Anthropic) on 2026-08-11.
//

import Foundation

/// The shape of a query, because the retrieval pipeline behaves very differently for each.
///
/// `IrisDB.search(query:)` builds its full-text pattern with `FTS5Pattern(matchingAllTokensIn:)`,
/// which is conjunctive. A one-word query matches an enormous postings list; a long sentence usually
/// matches nothing at all and the result is carried entirely by the vector index. Averaging those
/// together produces a number that describes no real workload, so they are measured separately.
///
/// - Authored by: Claude Opus 5 (Anthropic)
enum QueryCategory: String, Codable, Sendable, CaseIterable {
    /// A single token that appears in a large fraction of the corpus. Worst case for FTS5 postings.
    case commonTerm
    /// A single token that appears in only a handful of chunks. Best case for FTS5, and the case where
    /// the vector index has to carry recall.
    case rareTerm
    /// Three consecutive words lifted from a real chunk. The typical user search.
    case phrase
    /// A full sentence lifted from a real chunk. Conjunctive full-text usually returns nothing, so this
    /// isolates the semantic path plus fusion overhead.
    case sentence
    /// A handwritten natural language question, the way someone actually queries a knowledge base.
    case question

    var displayName: String {
        switch self {
        case .commonTerm: return "common term"
        case .rareTerm: return "rare term"
        case .phrase: return "phrase (3 words)"
        case .sentence: return "sentence"
        case .question: return "question"
        }
    }
}

/// One query the benchmark issues.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct BenchmarkQuery: Sendable, Codable {
    let text: String
    let category: QueryCategory
}

/// Derives a query set from the corpus itself.
///
/// Handwritten queries alone would not reflect the vocabulary or term-frequency distribution of the
/// material being searched, so most queries are sampled out of the real chunks. The term-frequency
/// table drives the common/rare split, which is what actually determines FTS5 cost.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct QuerySuiteBuilder {
    let options: BenchmarkOptions

    /// Natural language questions written against the subject matter of the sample corpora
    /// (ArXiv preprints, MIT and RIT course material, WikiBooks).
    private static let handwrittenQuestions = [
        "How does gradient descent converge on a non convex loss surface",
        "What is the time complexity of a balanced binary search tree insertion",
        "Explain the difference between supervised and unsupervised learning",
        "What are the tradeoffs between mutexes and lock free data structures",
        "How is signal to noise ratio measured in astronomical imaging",
        "What makes a distributed consensus protocol fault tolerant",
        "Describe the role of a real time scheduler in an embedded system",
        "What are the security implications of buffer overflow vulnerabilities",
        "How do you evaluate the statistical significance of an experiment",
        "What is the relationship between entropy and information content",
        "How does a compiler perform register allocation",
        "What are the principles of a layered software architecture"
    ]

    /// Builds the query set from a sample of the corpus.
    ///
    /// - Parameter documents: The prepared corpus. Only the text of real documents is sampled, so that
    ///                        synthetic recombination cannot skew the term distribution.
    /// - Returns: Queries across every category.
    /// - Authored by: Claude Opus 5 (Anthropic)
    func build(from documents: [PreparedDocument]) -> [BenchmarkQuery] {
        var generator = SeededGenerator(seed: options.randomSeed &+ 977)

        let realChunks = documents
            .filter { $0.origin == .real }
            .flatMap(\.chunks)
            .compactMap(\.textContent)
            .filter { $0.count > 120 }

        let sampleChunks = realChunks.count > 4_000
            ? (0..<4_000).map { _ in realChunks.randomElement(using: &generator)! }
            : realChunks

        var queries: [BenchmarkQuery] = []
        let perCategory = max(1, options.queriesPerCategory)

        // MARK: Term frequency table
        var documentFrequency: [String: Int] = [:]
        for chunk in sampleChunks {
            var seen = Set<String>()
            for token in QuerySuiteBuilder.tokenize(chunk) where token.count >= 4 {
                seen.insert(token)
            }
            for token in seen {
                documentFrequency[token, default: 0] += 1
            }
        }

        let ranked = documentFrequency
            .filter { !QuerySuiteBuilder.stopWords.contains($0.key) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }

        if !ranked.isEmpty {
            // Common: drawn from the densest 2% of the vocabulary.
            let commonPool = Array(ranked.prefix(max(perCategory, ranked.count / 50))).map(\.key)
            for _ in 0..<perCategory {
                if let term = commonPool.randomElement(using: &generator) {
                    queries.append(BenchmarkQuery(text: term, category: .commonTerm))
                }
            }

            // Rare: terms appearing in only a few chunks, but not one-off OCR noise.
            let rarePool = ranked.filter { $0.value >= 2 && $0.value <= 5 }.map(\.key)
            let fallbackRare = ranked.suffix(max(perCategory, ranked.count / 10)).map(\.key)
            let effectiveRarePool = rarePool.isEmpty ? fallbackRare : rarePool
            for _ in 0..<perCategory {
                if let term = effectiveRarePool.randomElement(using: &generator) {
                    queries.append(BenchmarkQuery(text: term, category: .rareTerm))
                }
            }
        }

        // MARK: Phrases and sentences pulled from real text
        for _ in 0..<perCategory {
            guard let chunk = sampleChunks.randomElement(using: &generator) else { break }
            let words = QuerySuiteBuilder.tokenize(chunk).filter { $0.count >= 3 }
            guard words.count > 6 else { continue }
            let start = Int.random(in: 0..<(words.count - 3), using: &generator)
            queries.append(
                BenchmarkQuery(text: words[start..<(start + 3)].joined(separator: " "), category: .phrase)
            )
        }

        for _ in 0..<perCategory {
            guard let chunk = sampleChunks.randomElement(using: &generator) else { break }
            let sentences = chunk
                .split(whereSeparator: { $0 == "." || $0 == "?" || $0 == "!" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count > 60 && $0.count < 400 }
            if let sentence = sentences.randomElement(using: &generator) {
                queries.append(BenchmarkQuery(text: sentence, category: .sentence))
            }
        }

        // MARK: Handwritten questions
        for question in QuerySuiteBuilder.handwrittenQuestions.prefix(perCategory) {
            queries.append(BenchmarkQuery(text: question, category: .question))
        }

        return queries
    }

    /// Lowercased alphanumeric tokens, approximating what the FTS5 porter tokenizer sees.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Words excluded from term sampling because they say nothing about the corpus.
    private static let stopWords: Set<String> = [
        "that", "this", "with", "from", "have", "were", "which", "their", "there", "these", "those",
        "been", "will", "would", "could", "should", "when", "then", "than", "they", "them", "such",
        "into", "also", "each", "other", "more", "most", "some", "only", "over", "here", "http",
        "https", "www", "com", "org", "edu", "the", "and", "for", "are", "but", "not", "you", "all",
        "can", "has", "had", "was", "our", "its", "may", "one", "two", "use", "used", "using"
    ]
}
