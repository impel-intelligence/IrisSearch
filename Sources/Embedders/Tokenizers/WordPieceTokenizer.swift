//
//  WordPieceTokenizer.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/22/26.
//

import Foundation

/// Word piece tokenizer
///
struct BERTWordPieceTokenizer: Sendable {
    enum TokenizerError: Error {
        case missingCLSToken
        case missingSEPToken
        case missingUNKToken
    }
    
    private let vocab: [String: Int]
    private let clsTokenID: Int
    private let sepTokenID: Int
    private let unkTokenID: Int
    
    /// <#Description#>
    /// - Parameters:
    ///   - vocabURL: <#vocabURL description#>
    ///   - maximumInputCharactersPerWord: The maximum length of a word. Defaults to 100 (Same as HuggingFaceTokenizers).
    init(vocabURL: URL, maximumInputCharactersPerWord: Int = 100) throws {
        let contents = try String(contentsOf: vocabURL, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        
        // Remove a trailing newline at the end of the file, if it exists.
        if (lines.last?.isEmpty ?? false) {
            lines.removeLast()
        }
        
        // We could use a reduce here, but it creates a new dictionary instance each run which can get heavy with large vocabs.
        var vocab: [String: Int] = [:]
        vocab.reserveCapacity(lines.count)
        
        for (index, line) in lines.enumerated() {
            vocab[line] = index
        }
        
        // Make sure classification token exists
        guard let clsID = vocab["[CLS]"] else { throw TokenizerError.missingCLSToken }
        guard let sepID = vocab["[SEP]"] else { throw TokenizerError.missingSEPToken }
        guard let unkID = vocab["[UNK]"] else { throw TokenizerError.missingUNKToken }
        
        self.vocab = vocab
        self.clsTokenID = clsID
        self.sepTokenID = sepID
        self.unkTokenID = unkID
    }
    
    
}
