//
//  DigesterFactory.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/16/26.
//

import UniformTypeIdentifiers

struct DigesterFactory {
    private static let registeredDigesters: [FileDigester.Type] = [TXTDigester.self, PDFDigester.self]
    
    static var availableUniformTypes: [UTType] {
        return registeredDigesters.flatMap({$0.fileTypes})
    }
    
    static func digester(for type: UTType) throws -> FileDigester {
        guard let digesterType = registeredDigesters.first(where: { $0.fileTypes.contains(type) }) else {
            throw DigestionError.noAvailableDigester(type: type)
        }

        return digesterType.init()
    }
}
