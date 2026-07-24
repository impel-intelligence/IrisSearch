//
//  BertNormalizer.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/23/26.
//

struct BertNormalizer {
    private let cleanText: Bool
    private let handleChineseCharacters: Bool
    private let stripAccents: Bool?
    private let lowercase: Bool
    
    init(cleanText: Bool, handleChineseCharacters: Bool, stripAccents: Bool?, lowercase: Bool) {
        self.cleanText = cleanText
        self.handleChineseCharacters = handleChineseCharacters
        self.stripAccents = stripAccents
        self.lowercase = lowercase
    }
    
    func normalize(_ text: String) -> String {
        var text: String = text
        
        if self.cleanText {
            text = cleanText(text)
        }
        
        if self.handleChineseCharacters {
            text = padCJKCharacters(text)
        }
        
        if stripAccents ?? lowercase {
            text = text.folding(options: .diacriticInsensitive, locale: nil)
        }
        
        if lowercase {
            text = text.lowercased()
        }
        
        return text
    }
    
    private func cleanText(_ text: String) -> String {
        var newScalars = String.UnicodeScalarView()
        newScalars.reserveCapacity(text.unicodeScalars.count)
        
        for scalar in text.unicodeScalars {
            if scalar.value == 0 || scalar.value == 0xFFFD || scalar.isBERTControlCharacter {
                continue // Skip over control characters
            } else {
                newScalars.append(scalar)
            }
        }

        return String(newScalars)
    }

    private func padCJKCharacters(_ text: String) -> String {
        var newScalars = String.UnicodeScalarView()
        newScalars.reserveCapacity(text.unicodeScalars.count)
        guard let spaceScalar = Unicode.Scalar(0x20) else { return text }
        
        for scalar in text.unicodeScalars {
            if scalar.isCJKUnifiedIdeograph {
                newScalars.append(spaceScalar)
                newScalars.append(scalar)
                newScalars.append(spaceScalar)
            } else {
                newScalars.append(scalar)
            }
        }

        return String(newScalars)
    }
}
