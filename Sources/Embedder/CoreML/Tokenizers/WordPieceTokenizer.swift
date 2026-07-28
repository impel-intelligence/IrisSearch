//
//  WordPieceTokenizer.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/22/26.
//

import Foundation

struct Encoding: Sendable {
    let inputIDs: [Int32]
    let attentionMask: [Int32]
}

/// Word piece tokenizer
///
struct BERTWordPieceTokenizer: Sendable {
    enum TokenizerError: Error {
        case missingCLSToken
        case missingSEPToken
        case missingUNKToken
    }
        
    private let vocab: [String: Int32]
    private let classificationTokenID: Int32
    private let separatorTokenID: Int32
    private let unknownTokenID: Int32
    
    private let maximumInputCharactersPerWord: Int
    
    private let normalizer: BertNormalizer
    
    /// <#Description#>
    /// - Parameters:
    ///   - vocabURL: <#vocabURL description#>
    ///   - maximumInputCharactersPerWord: The maximum length of a word. Defaults to 100 (Same as HuggingFaceTokenizers).
    init(vocabURL: URL, normalizer: BertNormalizer, maximumInputCharactersPerWord: Int = 100) throws {
        self.normalizer = normalizer
        self.maximumInputCharactersPerWord = maximumInputCharactersPerWord
        
        let contents = try String(contentsOf: vocabURL, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        
        // Remove a trailing newline at the end of the file, if it exists.
        if (lines.last?.isEmpty ?? false) {
            lines.removeLast()
        }
        
        // We could use a reduce here, but it creates a new dictionary instance each run which can get heavy with large vocabs.
        var vocab: [String: Int32] = [:]
        vocab.reserveCapacity(lines.count)
        
        for (index, line) in lines.enumerated() {
            vocab[line] = Int32(index)
        }
        
        // Make sure classification token exists
        guard let clsID = vocab["[CLS]"] else { throw TokenizerError.missingCLSToken }
        guard let sepID = vocab["[SEP]"] else { throw TokenizerError.missingSEPToken }
        guard let unkID = vocab["[UNK]"] else { throw TokenizerError.missingUNKToken }
        
        self.vocab = vocab
        self.classificationTokenID = clsID
        self.separatorTokenID = sepID
        self.unknownTokenID = unkID
    }
    
    /// Encode text using the WordPiece Tokenizer algorithm
    /// 
    /// - Parameters:
    ///   - text: The text to encode
    ///   - maxLength: The maximum number of tokens that an output can be.
    /// - Returns: An ``Encoding`` structure, containing the encoded tokens and a matching attention mask.
    func encode(_ text: String, maxLength: Int = 512) -> Encoding {
        let basicTokens = basicTokenize(text: text)
        // Convert all of the basic tokens into WordPieced tokens
        let wordPieceTokens = basicTokens.flatMap(wordPiece(word:))
        // Take the maximum number of tokens, removing 2 to make room for the [CLS] and [SEP] tokens.
        let truncated = wordPieceTokens.prefix(maxLength - 2)
        let ids: [Int32] = [classificationTokenID] + truncated.map { vocab[$0] ?? unknownTokenID } + [separatorTokenID]
        return Encoding(inputIDs: ids, attentionMask: [Int32](repeating: 1, count: ids.count))
    }
    
    /// The first step in BERT's tokenization steps, this normalizes text then splits it into simple tokens.
    /// 
    /// A sample input to output chain: "hello world!" -> [hello, world!] -> [hello, world, !]
    /// - Parameter text: The text to convert into basic tokens
    /// - Returns: A list of "tokens" where each entry is either a word, or punctuation. There is no whitespace.
    private func basicTokenize(text: String) -> [String] {
        let normalized = normalizer.normalize(text)
        // Remove all of the the whitespace from the text, creating initial tokens. Then separate the individual tokens by any punctuation they may have.
        return normalized.split(whereSeparator: \.isWhitespace).flatMap { token in
            separateOnPunctuation(word: String(token))
        }
    }
    
    /// Separates a word into letter, punctuation chunks.
    ///
    /// Example: "word!" -> ["word", "!"]
    /// - Parameter word: The word to split
    /// - Returns: A word that has had its punctuation and characters separated.
    private func separateOnPunctuation(word: String) -> [String] {
        var results: [String] = []
        var builder: String = ""
        
        for character in word {
            if character.isBERTPunctuation {
                // We reached punctuation so flush the current builder
                if !builder.isEmpty {
                    results.append(builder)
                    builder = ""
                }
                // Add the punctuation as its own item in the output
                results.append(String(character))
            } else {
                // Append a normal character to the builder.
                builder.append(character)
            }
        }
        
        // Flush builder of any levtovers
        if !builder.isEmpty {
            results.append(builder)
        }
        
        return results
    }
    
    /// <#Description#>
    /// - Parameter word: <#word description#>
    /// - Returns: <#description#>
    private func wordPiece(word: String) -> [String ] {
        // Use an array so we can use integer indexing instead of String.Index
        let scalars = Array(word.unicodeScalars)
        
        guard scalars.count <= maximumInputCharactersPerWord else { return ["[UNK]"] }

        var subTokens: [String] = []
        var startIndex = 0
        
        while startIndex < scalars.count {
            var bestMatch: String?
            var endIndex = scalars.count
            
            while startIndex < endIndex {
                var subString = String(String.UnicodeScalarView(scalars[startIndex..<endIndex]))
                
                // We are not at the beginning of the word so prepend the continuation prefix
                if startIndex > 0 {
                    subString = "##" + subString
                }
                
                // If the substring we made exists in the vocab, call it quits and exit. Otherwise try again.
                if vocab[subString] != nil {
                    bestMatch = subString
                    break
                } else {
                    endIndex -= 1
                    continue
                }
            }
            
            guard let bestMatch else { return ["[UNK]"] }
            subTokens.append(bestMatch)
            startIndex = endIndex
        }
        
        return subTokens
    }
}
