//
//  SentenceChunker.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/13/26.
//

import IrisCommon

/// A chunking strategy for breaking text into sentences
struct SentenceChunker {
    /// A sentence with its accompanying range in its parent text.
    struct Sentence {
        let content: String
        let range: Range<Int>
    }
    
    /// Breaks `content` into sentences with corresponding ranges in the overall `content`
    /// - Parameter content: The string to break into sentences.
    /// - Returns: An array of ``Digester/SentenceChunker/Sentence`` built from `content`.
    ///            Chunks are trimmed of any leading and trailing whitespace. Chunks that are entirely
    ///            whitespace are dropped.
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
    
    /// Chunks content into chunks of size `contextSize`.
    ///
    /// - Parameters:
    ///   - content: The content to chunk.
    ///   - contextSize: The size of content chunks.
    ///   - prefix: The prefix that will be appended to every chunk of content . `prefix.count`
    ///             will be removed from `contextSize` to ensure chunks are under `contextSize`.
    ///   - sequenceOffset: The offset for starting the chunk sequencing. Sequencing informs
    ///                     embeddable content of its position in the document.
    ///   - anchorMaker: A function that returns a `DocumentAnchor`, this should provide an
    ///                  appropriate anchor for the integer range of the chunk.
    /// - Returns: An `EmbeddableContent` for each chunk of the input content.
    public static func chunkContent(for content: String, contextSize: Int, prefix: String = "", sequenceOffset: Int = 0, anchorMaker: (Range<Int>) -> DocumentAnchor) -> [EmbeddableContent] {
        let effectiveContextSize = max(contextSize - prefix.count, 1)
        let overlapCharacters = Int(Double(effectiveContextSize) * 0.05)
        
        var goodChunks: [[Sentence]] = []
        var inProgress: [Sentence] = []
        
        var inProgressContentLength: Int = 0
        
        for sentence in sentences(for: content) {
            // If adding this content to the builder would push it over the contextSize, save the current builder and create a new one.
            if (inProgressContentLength + sentence.content.count) > effectiveContextSize {
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
            
            // Find the whitespace in the chunk content
            let joinedContent = chunk.map(\.content).joined()
            let leadingWhitespaceCount = joinedContent.prefix(while: \.isWhitespace).count
            let trailingWhitespaceCount = joinedContent.reversed().prefix(while: \.isWhitespace).count
            let trimmedContent = String(joinedContent.dropFirst(leadingWhitespaceCount).dropLast(trailingWhitespaceCount))
            
            // If the text was just whitespace, drop it
            guard !trimmedContent.isEmpty else { return nil }
            
            let chunkContent = prefix + trimmedContent
            let lowerBound = (first.range.lowerBound + leadingWhitespaceCount)
            let upperBound = (last.range.upperBound - trailingWhitespaceCount)
            
            // Bounds have to be separated by at least one character.
            guard lowerBound < upperBound else { return nil }
            
            let chunkRange = lowerBound..<upperBound
            let anchor = anchorMaker(chunkRange)
            let location = DocumentLocation(sequenceIndex: sequenceOffset + offset, documentLength: goodChunks.count, anchor: anchor)
            return EmbeddableContent.text(content: chunkContent, location: location)
        }
    }
}
