//
//  BasicChunker.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/8/26.
//

public struct BasicTextChunker: TextChunker, Sendable {
    public init() { }
    
    public func chunk(content: String) -> [String] {
        return chunkText(input: content, splits: ["\n", "."], targetCharacters: 512, overlap: 0)
    }
    
    private func chunkText(input: String, splits: [Character], targetCharacters: Int, overlap: Int) -> [String] {
        var results: [String] = []
        
        var dirtyResults: [String] = input.split { character in return splits.contains(character) }.compactMap({String($0)})
        
        var builder: String = ""
        while(!dirtyResults.isEmpty) {
            var nextResult = dirtyResults.removeFirst()
            
            if nextResult.count > targetCharacters {
                let maxOffset = nextResult.index(nextResult.startIndex, offsetBy: targetCharacters)
                let hold = String(nextResult[maxOffset..<nextResult.endIndex])
                
                nextResult = String(nextResult[nextResult.startIndex..<maxOffset])
                dirtyResults.insert(hold, at: 0)
            }
            
            if (builder.count + nextResult.count) > targetCharacters {
                // Reset the string builder and then append the overlap into the next one.
                results.append(builder)
                
                let overlapOffset: String.Index
                if overlap >= builder.count {
                    overlapOffset = builder.startIndex
                } else {
                    overlapOffset = builder.index(builder.endIndex, offsetBy: -overlap)
                }
                builder = String(builder[overlapOffset...])
            }
            
            builder += nextResult
        }
        
        if !builder.isEmpty {
            results.append(builder)
        }
        
        results.removeAll(where: {$0.isEmpty})
        return results
    }

}
