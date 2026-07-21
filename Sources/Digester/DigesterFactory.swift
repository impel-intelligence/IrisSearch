//
//  DigesterFactory.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/16/26.
//

import UniformTypeIdentifiers

public struct DigesterFactory {
    private static let registeredDigesters: [any FileDigester.Type] = [TXTDigester.self, PDFDigester.self, HTMLandXMLDigester.self]
    
    public static var availableUniformTypes: [UTType] {
        return registeredDigesters.flatMap({$0.fileTypes})
    }
    
    public static func digester(for type: UTType) throws -> any FileDigester {
        let validDigesters = registeredDigesters.filter { $0.isValidType(type) }
        guard !validDigesters.isEmpty else { throw DigestionError.noAvailableDigester(type: type) }
        
        var bestDigester: (any FileDigester.Type)? = nil
        var bestType: UTType? = nil
                
        for digester in validDigesters {
            // Find the type that is the
            guard let candidateType = digester.fileTypes.mostSpecificType(conformingTo: type) else { continue }
                        
            // Check if we already have a best type
            if let currentType = bestType {
                // Replace the best digester and best type if we are a more specific type than the current type.
                if candidateType != currentType, candidateType.conforms(to: currentType) {
                    bestDigester = digester
                    bestType = candidateType
                }
            } else {
                // There exists no bestType, so set these for the first time.
                bestDigester = digester
                bestType = candidateType
            }
        }

        guard let bestDigester else { throw DigestionError.noAvailableDigester(type: type) }
        
        return bestDigester.init()
    }
}

extension Array where Element == UTType {
    /// Find the type in this array that conforms to every other type in the array. Used to find the bottom of a conformance chain.
    func mostSpecificType(conformingTo type: UTType) -> UTType? {
        self.first { a in
            type.conforms(to: a) && self.allSatisfy { b in
                !type.conforms(to: b) || a == b || a.conforms(to: b)
            }
        }
    }
}
