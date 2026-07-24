//
//  Character+isBERTPunctuation.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/23/26.
//

extension Character {
    /// Check to see if a character is within BERT's understanding of punctuation.
    ///
    /// BERT has an extended view of what punctuation is, this is based on the BERT code from google research.
    /// https://github.com/google-research/bert/blob/d66a146741588fb208450bde15aa7db143baaa69/tokenization.py#L386
    var isBERTPunctuation: Bool {
        // If we are recognized by swift's punctuation we are punctuation so exit quickly.
        if isPunctuation { return true }
        // Make sure we can access the first scalar, this is sufficient as it is what isPunctuation does in the swift stdlib.
        // https://github.com/swiftlang/swift/blob/4b4159c628298b6f0fcd752f2c11fa923b76cf76/stdlib/public/core/CharacterProperties.swift#L343
        guard let firstScalar = self.unicodeScalars.first?.value else { return false }
        
        switch firstScalar {
        case 33...47: return true
        case 58...64: return true
        case 91...96: return true
        case 123...126: return true
        default: return false
        }
    }
}
