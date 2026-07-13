//
//  SentenceChunker.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/13/26.
//

import IrisCommon

struct SentenceChunker {
    struct Sentence {
        let content: String
        let range: Range<Int>
    }
    
    private static func sentences(for content: String) -> [Sentence] {
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
    
    public static func chunkContent(for content: String, contextSize: Int, sequenceOffset: Int = 0, anchorMaker: (Range<Int>) -> DocumentAnchor) -> [EmbeddableContent] {
        let overlapCharacters = Int(Double(contextSize) * 0.05)
        var goodChunks: [[Sentence]] = []
        
        var inProgress: [Sentence] = []
        var inProgressContentLength: Int = 0
        
        for sentence in sentences(for: content) {
            // If adding this content to the builder would push it over the contextSize, save the current builder and create a new one.
            if (inProgressContentLength + sentence.content.count) > contextSize {
                // Create good chunk
                goodChunks.append(inProgress)
                
                // Append overlap
                var overlapSentences: [Sentence] = []
                var overlapLength: Int = 0
                
                // Loop from the back and add sentences while we are still under the overlap
                for overlapSentence in inProgress.reversed() {
                    guard overlapLength + overlapSentence.content.count <= overlapCharacters else { break }
                    overlapSentences.insert(overlapSentence, at: 0)
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
        
        goodChunks.append(inProgress)
        
        // Convert sentence chunks into embeddable content and return it
        return goodChunks.enumerated().compactMap { offset, chunk in
            guard let first = chunk.first, let last = chunk.last else { return nil }
            let chunkContent = chunk.map(\.content).joined()
            let chunkRange = first.range.lowerBound..<last.range.upperBound
            let anchor = anchorMaker(chunkRange)
            let location = DocumentLocation(sequenceIndex: sequenceOffset + offset, documentLength: goodChunks.count, anchor: anchor)
            return EmbeddableContent.text(content: chunkContent, location: location)
        }
    }
}
