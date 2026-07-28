//
//  BPETokenizer.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/28/26.
//

import Foundation

/// A BPE Tokenizer for the OpenClip family of models.
struct CLIPBPETokenizer: Sendable {
    struct TokenizerConfig: Codable {
        let vocab: [String: Int32]
        let merges: [String]
        let encoder: [Int32: String]
        let decoder: [String: Int32]
        let specialTokens: [String: Int]
        let contextLength: Int
        let vocabSize: Int
        
        enum CodingKeys: String, CodingKey {
            case vocab
            case merges
            case encoder = "byte_encoder"
            case decoder = "byte_decoder"
            case specialTokens = "special_tokens"
            case contextLength = "context_length"
            case vocabSize = "vocab_size"
        }
    }
    
    /// Match the contractions in OpenAI's SimpleTokenizer
    /// https://github.com/openai/CLIP/blob/d05afc436d78f1c48dc0dbf8e5980a9d471f35f6/clip/simple_tokenizer.py#L78
    private static let contractions: [String] = ["'s","'t","'re","'ve","'m","'ll","'d"]
    
    private let startOfTextTokenID: Int32
    private let endOfTextTokenID: Int32
    
    let tokenizerConfig: TokenizerConfig
    
    let contextLength: Int
    
    init(tokenizerURL: URL) throws {
        let tokenizerData = try Data(contentsOf: tokenizerURL)
        tokenizerConfig = try JSONDecoder().decode(TokenizerConfig.self, from: tokenizerData)
        
    }
}
