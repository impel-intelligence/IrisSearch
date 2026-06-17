//
//  DigesterFactory.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/16/26.
//

import UniformTypeIdentifiers

public struct DigesterFactory {
    private static let registeredDigesters: [any FileDigester.Type] = [TXTDigester.self, PDFDigester.self]
    
    public static var availableUniformTypes: [UTType] {
        return registeredDigesters.flatMap({$0.fileTypes})
    }
    
    public static func digester(for type: UTType) throws -> any FileDigester {
        guard let digesterType = registeredDigesters.first(where: { $0.isValidType(type) }) else {
            throw DigestionError.noAvailableDigester(type: type)
        }

        return digesterType.init()
    }
}
