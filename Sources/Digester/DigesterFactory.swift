//
//  DigesterFactory.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/16/26.
//

import UniformTypeIdentifiers

/// A factory for content digesters that abstracts the creation of digesters.
public struct DigesterFactory {
    /// The set of registered ``FileDigester``. For a digester to be recognized by the factory, it must be included in this structure.
    private static let registeredDigesters: [any FileDigester.Type] = [
        TXTDigester.self,
        PDFDigester.self,
        HTMLandXMLDigester.self,
        MarkdownDigester.self
    ]
    
    /// All uniform type identifiers that are supported by registered File Digesters.
    public static var availableUniformTypes: [UTType] {
        return registeredDigesters.flatMap({$0.fileTypes})
    }
    
    /// Create a an instance of ``FileDigester`` that can properly digest the given `type`
    /// - Parameter type: The `UTType` to create a digester for.
    /// - Returns: A ``FileDigester`` that is best fit for the content type.
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
