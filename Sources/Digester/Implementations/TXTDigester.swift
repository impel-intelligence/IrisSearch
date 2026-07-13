//
//  TxtDigester.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import UniformTypeIdentifiers
import IrisCommon
import Foundation

final class TXTDigester: FileDigester {
    static let fileTypes: [UTType] = [.text, .plainText, .utf8PlainText, .utf16PlainText, .utf16ExternalPlainText, UTType(importedAs: "net.daringfireball.markdown")]
    
    struct Sentence {
        let content: String
        let range: Range<Int>
    }

    required init() { }
    
    private func sentences(for content: String) -> [Sentence] {
        var results: [Sentence] = []
        
        var lastUpper: String.Index = content.startIndex
        var cursorOffset: Int = 0
        
        content.enumerateSubstrings(in: content.startIndex..., options: .bySentences) { substring, substringRange, _, _ in
            guard let substring, !substring.isEmpty else { return }
            
            // Add the distance from the end of the last sentence to the start of this sentence to find the starting offset
            let startOffset = cursorOffset + content.distance(from: lastUpper, to: substringRange.lowerBound)
            
            // Add the length of this sentence to the start offset to find the ending offset
            let endOffset = startOffset + content.distance(from: substringRange.lowerBound, to: substringRange.upperBound)
            
            results.append(Sentence(content: substring, range: startOffset..<endOffset))
            
            lastUpper = substringRange.upperBound
            cursorOffset = endOffset
        }
        
        return results
    }
    
    func chunkContent(for content: String, contextSize: Int) -> [EmbeddableContent] {
        let overlapCharacters = Int(Double(contextSize) * 0.05)
        var goodChunks: [[Sentence]] = []
        
        var inProgress: [Sentence] = []
        var inProgressContentLength: Int = 0
        
        for sentence in sentences(for: content) {
            // If adding this content to the builder would push it over the contextSize, save the current builder and create a new one.
            if (inProgressContentLength + sentence.content.count) > contextSize {
                // Create good chunk
                goodChunks.append(inProgress)
                inProgress = []
                
                // Append overlap
                var overlapSentences: [Sentence] = []
                var overlapLength: Int = 0
                
                // Loop from the back and add sentences while we are still under the overlap
                for overlapSentence in inProgress.reversed() {
                    guard overlapLength + overlapSentence.content.count <= overlapCharacters else { break }
                    overlapSentences.append(overlapSentence)
                    overlapLength += overlapSentence.content.count
                }
                
                // Replace the in progress variables with the overlap information we just calculated
                inProgress = overlapSentences
                inProgressContentLength = overlapLength
            }

            // Append the current sentence to the in progress variables
            inProgress.append(sentence)
            inProgressContentLength += sentence.content.count
        }
        
        // Convert sentence chunks into embeddable content and return it
        return goodChunks.enumerated().compactMap { offset, chunk in
            guard let first = chunk.first, let last = chunk.last else { return nil }
            let chunkContent = chunk.map(\.content).joined()
            let chunkRange = first.range.lowerBound..<last.range.upperBound
            let location = DocumentLocation(sequenceIndex: offset, documentLength: goodChunks.count, anchor: .text(characterRange: chunkRange))
            return EmbeddableContent.text(content: chunkContent, location: location)
        }
    }
    
    func digest(file: URL, contextSize: Int) throws -> [EmbeddableContent] {
        // Will bail out if the url is not valid
        try TXTDigester.validateLocalURL(file)

        var usedEncoding: String.Encoding = .utf8
        let stringContent = try String(contentsOf: file, usedEncoding: &usedEncoding)

        return chunkContent(for: stringContent, contextSize: contextSize)
    }
}
