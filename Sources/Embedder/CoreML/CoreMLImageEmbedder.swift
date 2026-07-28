//
//  CoreMLImageEmbedder.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/28/26.
//

import CoreML
import IrisCommon
import Synchronization

public final class CoreMLImageEmbedder: Sendable, ImageEmbeddingProvider {
    public let dimension: Int = 0
    
    public func embed(content: String) async throws -> [Double] {
        <#code#>
    }
}
